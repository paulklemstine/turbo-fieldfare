#!/usr/bin/env python3
"""
Repack GGUF model to separate core tensors from expert tensors.
This allows the OS to keep core tensors resident while streaming experts.

Output layout:
- core.bin: all non-expert tensors (attention, norms, embeddings, shared MLP)
- experts_layer_00.bin through experts_layer_29.bin: per-layer expert weights

Within each expert layer file:
  expert 0: gate_up weight bytes, then down weight bytes
  expert 1: gate_up weight bytes, then down weight bytes
  ... (128 experts total)

Each expert has a fixed stride = gate_up_size + down_size for easy seeking.
"""

import sys
import os
import struct
import numpy as np
from gguf import GGUFReader, GGUFWriter

def repack_gguf(input_path, output_dir):
    print(f"Reading {input_path}...")
    reader = GGUFReader(input_path)
    
    # Separate tensors
    core_tensors = []
    expert_tensors = {}  # layer_num -> list of (name, tensor)
    
    for tensor in reader.tensors:
        name = tensor.name
        # Check if this is an expert tensor
        # Pattern: blk.N.ffn_(gate_up_exps|down_exps).(weight|scale)
        parts = name.split('.')
        if len(parts) >= 4 and parts[0] == 'blk' and 'exps' in name:
            layer_num = int(parts[1])
            if layer_num not in expert_tensors:
                expert_tensors[layer_num] = []
            expert_tensors[layer_num].append(tensor)
        else:
            core_tensors.append(tensor)
    
    os.makedirs(output_dir, exist_ok=True)
    
    # Calculate sizes
    total_core = sum(t.n_bytes for t in core_tensors)
    total_expert = sum(t.n_bytes for layer in expert_tensors.values() for t in layer)
    print(f"Core tensors: {len(core_tensors)}, {total_core/1024/1024/1024:.2f} GiB")
    print(f"Expert tensors: {sum(len(v) for v in expert_tensors.values())}, {total_expert/1024/1024/1024:.2f} GiB")
    print(f"Total: {(total_core+total_expert)/1024/1024/1024:.2f} GiB")
    
    # Write core.bin - all core tensors concatenated
    core_path = os.path.join(output_dir, "core.bin")
    print(f"\nWriting core.bin ({total_core/1024/1024:.0f} MB)...")
    
    # Also write a manifest describing the layout
    manifest = {
        "model": os.path.basename(input_path),
        "core_size": total_core,
        "layers": {}
    }
    
    with open(core_path, 'wb') as f:
        offset = 0
        for tensor in core_tensors:
            # Get tensor data
            data = tensor.data
            f.write(data.tobytes())
            offset += data.nbytes
    
    # Write per-layer expert files
    for layer_num in sorted(expert_tensors.keys()):
        tensors = expert_tensors[layer_num]
        layer_path = os.path.join(output_dir, f"experts_layer_{layer_num:02d}.bin")
        
        # Sort tensors: gate_up first, then down for each expert
        # Group by expert index
        expert_data = {}
        for t in tensors:
            name = t.name
            # Extract expert index from tensor name and shape
            # e.g., blk.0.ffn_gate_up_exps.weight has shape [2816, 1408, 128]
            # The last dimension is the expert dimension
            shape = t.shape
            n_experts = shape[-1]
            
            if 'gate_up' in name:
                key = 'gate_up'
            elif 'down' in name:
                key = 'down'
            else:
                continue
                
            # Read the full tensor data
            data = t.data  # This is the full 3D tensor
            
            for expert_idx in range(n_experts):
                if expert_idx not in expert_data:
                    expert_data[expert_idx] = {}
                # Slice the expert dimension
                if key == 'gate_up':
                    expert_data[expert_idx]['gate_up'] = data[:, :, expert_idx]
                else:
                    expert_data[expert_idx]['down'] = data[:, :, expert_idx]
        
        # Write experts in order
        with open(layer_path, 'wb') as f:
            for expert_idx in range(n_experts):
                gate_up = expert_data[expert_idx]['gate_up']
                down = expert_data[expert_idx]['down']
                f.write(gate_up.tobytes())
                f.write(down.tobytes())
        
        # Record layer info
        per_expert = (expert_data[0]['gate_up'].nbytes + expert_data[0]['down'].nbytes)
        manifest["layers"][layer_num] = {
            "path": f"experts_layer_{layer_num:02d}.bin",
            "n_experts": n_experts,
            "per_expert_bytes": per_expert,
            "gate_up_shape": list(expert_data[0]['gate_up'].shape),
            "gate_up_dtype": str(expert_data[0]['gate_up'].dtype),
            "down_shape": list(expert_data[0]['down'].shape),
            "down_dtype": str(expert_data[0]['down'].dtype),
        }
        
        print(f"  Layer {layer_num}: {n_experts} experts, {per_expert/1024/1024:.2f} MB/expert, "
              f"file size: {os.path.getsize(layer_path)/1024/1024:.1f} MB")
    
    # Write manifest
    import json
    manifest_path = os.path.join(output_dir, "manifest.json")
    with open(manifest_path, 'w') as f:
        json.dump(manifest, f, indent=2)
    
    print(f"\nDone! Output in {output_dir}")
    print(f"  core.bin: {os.path.getsize(core_path)/1024/1024:.0f} MB")
    total_layer_size = sum(os.path.getsize(os.path.join(output_dir, f"experts_layer_{i:02d}.bin")) 
                           for i in range(30) if os.path.exists(os.path.join(output_dir, f"experts_layer_{i:02d}.bin")))
    print(f"  expert layers: {total_layer_size/1024/1024/1024:.2f} GiB total")
    
    return manifest

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <input.gguf> <output_dir>")
        sys.exit(1)
    
    repack_gguf(sys.argv[1], sys.argv[2])
