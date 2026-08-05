<p align="center">
  <img src="docs/assets/turbofieldfare-logo-rounded.png" alt="TurboFieldfare logo: a fieldfare inside a segmented cache ring" width="280">
</p>

<h1 align="center">TurboFieldfare</h1>

<p align="center">
  <strong>Gemma 4 26B-A4B inference in about 2 GB of RAM</strong><br>
  A custom Swift + Metal runtime for any Apple Silicon Mac, even the 8 GB ones.
</p>

<p align="center">
  <img alt="Swift 6.2" src="https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white">
  <img alt="Metal 4" src="https://img.shields.io/badge/Metal-4-5E5CE6">
  <img alt="macOS 26 or later" src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white">
  <a href="LICENSE"><img alt="Apache 2.0 license" src="https://img.shields.io/badge/License-Apache%202.0-2ea44f"></a>
</p>

<p align="center">
  <a href="#quick-start--installation">Quick start</a> ·
  <a href="#windows-native-intel-n150">Windows native</a> ·
  <a href="docs/BENCHMARKS.md">Benchmarks</a> ·
  <a href="docs/OPENAI_SERVER.md">Local server</a> ·
  <a href="docs/SYSTEM_DESIGN.md">How it works</a> ·
  <a href="docs/OPTIMIZATION_JOURNEY.md">Experiments</a> ·
  <a href="docs/COMMUNITY_BENCHMARKS.md">Contribute results</a>
</p>

![TurboFieldfare Mac app generating text with Gemma 4 26B-A4B](docs/assets/turbofieldfare-app.webp)

Memory got expensive. So I gave a 26-billion-parameter model a ~2 GB budget.

TurboFieldfare runs the instruction-tuned
**[Gemma 4 26B-A4B](https://ai.google.dev/gemma/docs/core/model_card_4)**
without loading the entire 14.3 GB model into memory. It keeps the shared
1.35 GB core and FP16 KV cache in memory, then streams only the experts needed
for each token from SSD. This is what lets the model run on Macs with 8 GB of
RAM.

The runtime, streaming installer, CLI, and native Mac app are written in Swift
and Metal. TurboFieldfare is model-specific rather than a wrapper around MLX or
llama.cpp. The curated [experiment record](docs/experiments/EXPERIMENT_INVENTORY.md)
summarizes 103 measured results across kernels, caching, I/O, prefill, and
decode.

## Quick Start & Installation

### 1. Build TurboFieldfare
```bash
git clone https://github.com/paulklemstine/turbo-fieldfare.git
cd turbo-fieldfare
swift build -c release
```

### 2. Download and Install Pinned Model
```bash
swift run -c release TurboFieldfareRepack --output scratch/gemma4.gturbo --overwrite
```

### 3. Launch Local Server + Client Stack
`start.sh` starts the TurboFieldfare server on port `8080` and then launches a client.
All modes shut the server down again when the client exits.

```bash
./start.sh                                  # Pi coding agent (tool use)
./start.sh --chat                           # interactive chat directly with the model
./start.sh --ask "What is the capital of France?"   # single prompt, print reply, exit
```

- **Pi Agent** (default): writes `~/.pi/agent/models.json` pointing the
  `turbofieldfare` provider at the local server, then runs
  `pi --model turbofieldfare/gemma-4-26b-a4b-it`.
- **`--chat` / `--ask`**: a minimal client (`Scripts/chat.py`) that talks
  directly to the server's OpenAI-compatible API with no agent or tools.
  `--chat` is an interactive REPL that keeps the conversation history so the
  model can follow up; `--ask` runs a single prompt and exits. Both stream
  tokens as they are generated.

Pi talks to the server directly through its OpenAI-compatible API, so no LiteLLM
proxy or translation bridge is needed. Install Pi once with:

```bash
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
```

---

## Linux (NVIDIA GPU)

On Linux with an NVIDIA GPU, `start.sh` dispatches to `start-linux.sh`, which
runs the same Gemma 4 26B-A4B model on **llama.cpp + CUDA** instead of the
Swift/Metal backend. The modes, the OpenAI-compatible server on port `8080`,
and the Pi agent setup are identical to the Mac path — only the inference
engine changes.

This is the spiritual counterpart to the Mac version's expert-streaming trick:
llama.cpp keeps a small resident core on the GPU and runs the rest on the CPU
(`-ngl` layers), so the ~10.7 GB model fits in a 6 GB VRAM GPU + system RAM.

### Requirements (GPU)

- Linux with an NVIDIA GPU (compute capability 8.0+; tested on an RTX 4050 Laptop, 6 GB VRAM)
- NVIDIA driver 590+ and the CUDA 13.x toolkit
- `cmake` and a C++17 compiler (GCC 13+)
- ~11 GB free disk for the Q2_K quant; ~6 GB VRAM + system RAM

### 1. Install build dependencies

```bash
sudo apt-get install -y cmake cuda-toolkit-13
```

### 2. Build llama.cpp with CUDA

```bash
git clone --depth 1 https://github.com/ggerganov/llama.cpp.git
cd llama.cpp
cmake -B build -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc) --target llama-server
```

### 3. Download the abliterated model (Q2_K)

```bash
pip install hf_transfer
HF_HUB_ENABLE_HF_TRANSFER=1 python3 -c "
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id='mradermacher/gemma-4-26B-A4B-it-abliterated-GGUF',
    allow_patterns=['gemma-4-26B-A4B-it-abliterated.Q2_K.gguf'],
    local_dir='models',
)
"
```

### 4. Launch

```bash
./start.sh                                  # Pi coding agent (tool use)
./start.sh --chat                           # interactive chat
./start.sh --ask "What is the capital of France?"   # single prompt
```

Override the GPU layer count to fit your VRAM (default `18` is tuned for a
6 GB card):

```bash
GPU_LAYERS=15 ./start.sh --chat
```

> **WSL2 note:** if `llama-cli`/`llama-server` segfault at CUDA init, the
> system `libnvidia-ptxjitcompiler.so.1` is likely a stale version that can't
> JIT the CUDA runtime's PTX. Point the symlink at the WSL2 driver's copy:
> ```bash
> sudo ln -sf /usr/lib/wsl/drivers/*/libnvidia-ptxjitcompiler.so.1 \
>   /lib/x86_64-linux-gnu/libnvidia-ptxjitcompiler.so.1
> ```

## Windows native (Intel N150+)

On Windows native, llama.cpp runs 6.4x faster than WSL2 due to more RAM
available for the OS page cache. With a custom MSVC-compiled binary using
**AVX-VNNI** instructions, this reaches **~14.5 tok/s** — a **+133% improvement**
over the pre-built binary.

### Requirements (Windows)

- Windows 10/11 64-bit (23H2+ recommended)
- x86_64 CPU with AVX-VNNI (Intel Alder Lake-N or newer)
- 12 GB+ RAM (for the 14 GB Q4_0 model + repack)
- Visual Studio 2022 (Community or Professional, "Desktop development with C++")
- ~30 GB free disk for model + build artifacts

### 1. Clone the repo

```powershell
git clone https://github.com/paulklemstine/turbo-fieldfare.git
cd turbo-fieldfare
```

### 2. Install Visual Studio 2022

Download from https://visualstudio.microsoft.com/downloads/ and select the
**Desktop development with C++** workload. The build script needs MSVC's `cl.exe`
and `vcvarsall.bat`.

### 3. Download the model

```powershell
# Install Hugging Face CLI
pip install -U huggingface-hub

# Download the Q4_0 model (14.3 GB)
huggingface-cli download mradermacher/gemma-4-26B-A4B-it-abliterated-GGUF ^
  gemma-4-26B-A4B-it-abliterated.Q4_0.gguf ^
  --local-dir C:\Users\Paul\models
```

### 4. Build the optimized binary

```powershell
powershell -ExecutionPolicy Bypass -File "build-optimized.ps1"
```

Build takes 10-30 minutes on N150. See
[docs/BENCHMARKS.md](docs/BENCHMARKS.md#custom-avx-vnni-build-133-over-pre-built)
for full build details and expected results by CPU.

### 5. Launch

```powershell
.\start-windows.cmd                     # Pi coding agent (default)
.\start-windows.cmd --chat               # Interactive chat
.\start-windows.cmd --ask "Hello!"       # Single prompt
.\start-windows.cmd --debug              # Show server logs in console
```

**First launch** takes ~90s because llama.cpp repacks the weight tensors for
faster matrix multiplication. It saves the repacked weights to a `.repack`
cache file alongside the GGUF. **All subsequent launches reuse this cache** and
start in ~10s. The repack only re-runs if you delete the `.repack` file, switch
to a different GGUF, or rebuild llama.cpp with different flags.

The launcher auto-detects the model and llama-server.exe. It starts the server
with these optimal flags:
```
-ngl 0 -t 3 -ctk q4_0 -ctv q4_0 -ub 128 -fa on --cpu-strict 0
```
Plus context size: **4096** for `--ask`/`--chat` modes (fast), **16384** for Pi
agent mode (tool use). Override with `--context N`.

Server output is hidden to `llama_server.log` by default; use `--debug` to show
it in the console.

### Modes

| Mode | Command | Default context | Use case |
| ---- | ------- | -------------- | -------- |
| Pi agent | `.\start-windows.cmd` | 16384 | Coding tasks, tool use |
| Interactive chat | `.\start-windows.cmd --chat` | 4096 | Fast back-and-forth |
| Single prompt | `.\start-windows.cmd --ask "Hello!"` | 4096 | One-shot queries |

`--ask` and `--chat` bypass the Pi agent, avoiding its ~2-3KB system prompt
overhead. They connect directly to llama-server via `Scripts/chat.py`.

### Performance expectations

**Fresh (cool CPU):** ~14.5 tok/s with ctx=16384, up to ~20-22 tok/s with ctx=4096.

**Thermal throttling:** The N150 is a 6W TDP chip. Under sustained all-core load,
it will thermal throttle after ~2-3 minutes, dropping to ~2-4 tok/s. This is
normal. Performance recovers after a cooldown period (~30s idle).

For best performance:
- Run in short bursts (a few requests at a time)
- Ensure adequate ventilation
- Reduce context to 4096 when you don't need long context (`+40-50%` speed)
- Use `--speculative` for repetitive content (`+15-25%` on code/structured text)

---

## Linux (CPU-only, memory-constrained)

On a machine without a GPU and with less RAM than the model size (e.g. 4.8 GB
RAM for a 14 GB model), a custom llama.cpp binary applies the same
expert-streaming trick as the Mac version: it keeps the ~1.5 GB **core**
(attention, shared MLP, norms, embeddings) resident in RAM and releases the
~12 GB of **expert weight pages** via `MADV_DONTNEED`. Expert weights are then
loaded on-demand during inference from the page cache (fast) or disk.

This is the `llama-b10219-custom/` binary included in this repo — it's a
build of llama.cpp b10219 with the `release_expert_memory()` patch. It's
auto-detected by `start-linux.sh` before searching for other binaries.

### Requirements (CPU-only)

- x86_64 Linux with AVX2 (tested on Intel N150, 4 cores, 5.7 GB RAM)
- ~15 GB free disk for the Q4_0 model
- No GPU needed

### Memory savings

| Metric | Without optimization | With MADV_DONTNEED |
| ------ | ------------------- | ------------------ |
| Model file size | 13.45 GB | 13.45 GB |
| RSS (RAM used) | ~14 GB (thrashing) | ~4.5 GB |
| Expert tensors resident | 12 GB (all 128/layer) | 0 (loaded on-demand) |
| Core tensors resident | 1.47 GB | 1.47 GB |
| **Memory savings** | — | **9.6 GB (68%)** |

### Performance

- First generation (cold expert cache): ~0.15-0.83 tok/s (loads 12 GB from disk)
- Subsequent generations (warm cache): ~0.83-1.0 tok/s
- Prompt processing: ~0.5-1.0 tok/s

The speed is bounded by disk I/O on first load, then by CPU compute. This is
the same fundamental tradeoff the Mac version makes: stream experts from
storage instead of keeping them all resident.

### Launch

```bash
./start-linux.sh --chat --cpu --threads 4
./start-linux.sh --ask "What is the capital of France?" --cpu
```

The `--cpu` flag forces CPU-only mode and applies these optimizations
automatically: KV cache q8_0, ubatch 256, cpu-strict priority, and thread
pinning.

---

## Model Replacement & Abliterated Model Support

To use an unquantized model such as `huihui-ai/Huihui-gemma-4-26B-A4B-it-abliterated`:

1. Install `mlx-lm`:
   ```bash
   pip3 install mlx mlx-lm
   ```

2. Quantize the model to 4-bit group-64 affine MLX format:
   ```bash
   python3 -m mlx_lm convert \
     --hf-path huihui-ai/Huihui-gemma-4-26B-A4B-it-abliterated \
     --mlx-path scratch/huihui_gemma4_mlx_4bit \
     -q --q-group-size 64 --q-bits 4 --q-mode affine
   ```

---

## At a glance

| Metric          | Value                                                                                                                    |
| --------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Model           | Gemma 4 26B-A4B IT, 26B total parameters, about 3.88B active per token                                                   |
| Weights         | MLX affine 4-bit, group 64; 8-bit router; 4-bit shared and routed experts                                                |
| Memory (Mac)    | ~2 GB of weights and 4K KV cache                                                                                         |
| Memory (Linux CPU) | ~4.5 GB RSS (1.5 GB core resident + 12 GB experts on-demand via MADV_DONTNEED)                                        |
| Storage         | About 14.3 GB for the installed text-only model                                                                          |
| Hardware        | Apple Silicon Mac (8 GB RAM); Linux + NVIDIA GPU (6 GB+ VRAM); or x86_64 CPU (4+ GB RAM)                                |
| Platform        | macOS 26, Metal 4, Swift 6.2; Windows 11 + MSVC 2022; Linux + CUDA 13.x or CPU-only, llama.cpp                         |
| M2 measured decode | [5.1-6.3 tok/s](docs/BENCHMARKS.md#m2-measured-decode) on an 8 GB M2 MacBook Air |
| M5 measured decode | [31-35 tok/s](docs/BENCHMARKS.md#m5-measured-decode) on a 24 GB M5 Pro |
| Linux CPU decode | ~0.83-1.0 tok/s on an Intel N150 (4.8 GB RAM, MADV_DONTNEED)                                                             |
| Windows decode (pre-built) | ~6.2 tok/s on an Intel N150 (11.7 GB RAM, AVX2 only)                                                               |
| Windows decode (custom AVX-VNNI) | [~14.5 tok/s](docs/BENCHMARKS.md#cpu-only-intel-n150) on an Intel N150 (MSVC build +133%)                     |

The measured result is a reference point, not a performance ceiling. Prompt
length, generated length, page-cache state, and hardware all affect throughput.
To help measure another Apple Silicon Mac, follow the
[community benchmark guide](docs/COMMUNITY_BENCHMARKS.md).

## Using TurboFieldfare

TurboFieldfare provides a native Mac app, a command-line interface, and an
experimental loopback OpenAI-compatible server. They use the same `.gturbo`
model directory, but only one model-owning product should run at a time.

The Swift package exposes six products:

| Product | Purpose |
| --- | --- |
| `TurboFieldfare` | Swift library containing the runtime and Metal kernels |
| `TurboFieldfareMac` | Native Mac app for installation and generation |
| `TurboFieldfareDecodeService` | One-shot local model and Metal owner used by the Mac app |
| `TurboFieldfareCLI` | Command-line instruction chat and raw completion |
| `TurboFieldfareServer` | Loopback OpenAI-compatible Chat Completions server |
| `TurboFieldfareRepack` | Streaming model installer and install verifier |

### Requirements

- An Apple Silicon Mac; the validated target is an 8 GB M2 MacBook Air
- macOS 26 with Metal 4
- Xcode 26 and Swift 6.2 or newer
- Enough free storage for the ~14.3 GB model installation
- An internet connection for the first model install

The package is arm64-only. Older macOS and Metal versions are not supported.

### Prompting the model

The Mac app treats what you type as an instruction and handles Gemma's chat
formatting automatically. Just describe the task and include any context the
model needs.

Generation defaults to temperature `0.2`, Top-K `64`, and Top-P `0.95`. Set
temperature to `0` for deterministic greedy output. The model can still repeat
itself or give incorrect answers, so check important results.

TurboFieldfare is text-only. The app and CLI support user and model messages
plus optional system guidance; they do not expose or execute tools. The
loopback server accepts function-tool declarations and returns
model-produced tool calls for the client to authorize and execute. Images,
audio, and video are not supported.

### Mac app

Clone the repository, then run the app from its root:

```bash
swift build -c release
.build/release/TurboFieldfareMac
```

Build the complete package so the app and its sibling decode service are both
available. When launched from this checkout, the app stores the model in
`scratch/gemma4.gturbo`.

#### Install the model

On first launch, the app checks the available storage and shows the download
and installed sizes. Choose **Download** to begin.

The installer never materializes the full source checkpoint. It streams the
required byte ranges from the pinned Hugging Face revision and repacks them
directly into the `.gturbo` layout as they arrive. This avoids a second full
checkpoint on disk and keeps scratch memory bounded.

The first installation transfers about 15 GB through bounded Hugging Face
range requests. Network speed and Hugging Face response times vary, so it can
take a while. The completed `.gturbo` installation occupies about 14.3 GB and
is accepted only after its manifest and file hashes have been validated.
Installation does not load the model into memory.

#### Load and generate

After installation:

1. Choose **Load Model**.
2. Enter a prompt in the composer.
3. Choose **Generate**, or press <kbd>Command</kbd>+<kbd>Return</kbd>.
4. Use the stop button or <kbd>Escape</kbd> to end generation early.

The status bar shows generation progress, decode speed, and memory use. Use the
right pane to configure sampling, context length, expert-cache slots, and
runtime options. See [Runtime controls](docs/RUNTIME_CONTROLS.md) for details
and defaults.

### Command-line interface

The CLI uses an existing `.gturbo` installation. If you installed the model
through the Mac app, it is already available at `scratch/gemma4.gturbo`.
Otherwise, install it from the command line:

```bash
swift run -c release TurboFieldfareRepack \
  --output scratch/gemma4.gturbo \
  --overwrite
```

Continue a cancelled or interrupted download:

```bash
swift run -c release TurboFieldfareRepack \
  --output scratch/gemma4.gturbo \
  --overwrite \
  --resume
```

Remove saved download state:

```bash
swift run -c release TurboFieldfareRepack \
  --discard-partial \
  --output scratch/gemma4.gturbo
```

The runtime accepts only a completed `.gturbo` directory with a final
`manifest.json`.

Verify an existing installation without loading the model:

```bash
swift run -c release TurboFieldfareRepack \
  --verify-install \
  --input-gturbo scratch/gemma4.gturbo
```

#### Instruction chat

Put chat messages in a JSON array and pass it with `--messages-file`:

```json
[
  {"role": "user", "content": "Explain why chunked prefill reduces time to first token while keeping memory bounded."}
]
```

```bash
swift run -c release TurboFieldfareCLI \
  --model scratch/gemma4.gturbo \
  --messages-file messages.json
```

This formats messages in the same way as the Mac app. The CLI response limit
is set with `--max-new`, which defaults to 1,024 tokens. The Mac app can
generate until the selected context window is full.

#### Raw completion

`--prompt` is available for raw completion and reproducible comparisons. It
passes the text directly to the model without chat formatting. Use
`--messages-file` for instruction-response conversations.

```bash
swift run -c release TurboFieldfareCLI \
  --model scratch/gemma4.gturbo \
  --prompt "The capital of France is" \
  --max-new 64 \
  --temperature 0
```

This example deliberately requests a short greedy completion.

Common generation options include `--max-context`, `--temperature`, `--top-k`,
`--top-p`, `--repetition-penalty`, `--seed`, and repeatable `--stop` strings.
The public CLI uses production runtime defaults. Run the following command for
the complete option list:

```bash
swift run -c release TurboFieldfareCLI --help
```

Generated text goes to standard output. Timing statistics go to standard error;
add `--quiet` to suppress that footer in scripts.

### Local OpenAI-compatible server

Build the server and point it at an installed model:

```bash
swift build -c release --product TurboFieldfareServer
.build/release/TurboFieldfareServer \
  --model scratch/gemma4.gturbo
```

It listens on `http://127.0.0.1:8080/v1` and supports Chat Completions,
streaming, function tools, and single-prefix prompt reuse. The client must
authorize and run every tool call. Keep the server on loopback; it has no
remote authentication or TLS.

See [Local server](docs/OPENAI_SERVER.md) for a test request, Python and
OpenCode setup, prompt reuse, tool handling, and the supported API subset.

## Test and contribute

Run the public test suite serially:

```bash
Scripts/test.sh
```

Before starting a model run, close memory-heavy apps and check
`memory_pressure -Q`. If it reports little free memory, postpone the run. Run
only one TurboFieldfare app, decode service, CLI, server, test, or other
local-model process at a time.

To contribute a comparable performance result, follow the
[community benchmark guide](docs/COMMUNITY_BENCHMARKS.md).

## How the inference engine works

At each transformer layer, Metal computes attention and the router from
resident weights. The CPU uses the router's top-8 expert IDs to plan against
the layer's 16-slot LFU cache, then fills misses with bounded parallel `pread`
calls into Metal-visible buffers. Metal computes the resident shared-expert
branch while those reads run, then combines the shared and routed outputs.

Prompt prefill uses chunks of up to 128 tokens so one fetched expert can serve
multiple rows. Generation repeats the routed layer loop one token at a time.
The installer applies the same bounded-memory rule: it repacks remote ranges
directly into `.gturbo` without staging a full shard or tensor.

For a visual introduction to the model architecture, see Maarten Grootendorst's
[A Visual Guide to Gemma 4](https://newsletter.maartengrootendorst.com/p/a-visual-guide-to-gemma-4).

[System design](docs/SYSTEM_DESIGN.md) explains the `.gturbo` layout, memory
ownership, prefill, router handoff, `cb1`/`io`/`cb2` phases, Metal kernels, and
correctness invariants.

## Status and scope

TurboFieldfare currently includes:

- Remote streaming repack into the `.gturbo` model format
- Instruction-tuned Gemma 4 26B-A4B with verified text-only chat formatting
- 4-bit MLX affine embedding, attention, shared-expert, and routed-expert
  weights, with an 8-bit router
- Custom Metal kernels for quantized GEMV, attention, MoE, normalization,
  RoPE, sampling, and production fusions
- SSD-backed routed-expert streaming with a bounded expert cache
- Chunked single-prompt prefill and token-by-token generation
- FP16 KV storage with bounded circular storage for 25 sliding-window layers
  and linear storage for 5 full-attention layers
- Exact split-K/V decode attention with distinct normalized K and V paths
- A Swift library, streaming installer, command-line interface, loopback
  OpenAI-compatible server, and native SwiftUI/AppKit Mac app with a one-shot
  local decode service

Current scope is text-only inference from the pinned Gemma 4 26B-A4B
instruction checkpoint on Apple Silicon Macs with at least 8 GB of RAM.

### Future work

- Build iPhone and iPad apps, then measure inference speed and memory use on
  mobile hardware.
- Benchmark more Apple Silicon Macs, especially the base 16 GB M4 Mac mini and
  other 8 GB models.

## Experiments and technical documentation

The [experiments that shaped TurboFieldfare](docs/OPTIMIZATION_JOURNEY.md)
explain the largest wins, the plausible ideas that failed, and the early
results that reversed under stronger validation. The detailed
[experiment record](docs/experiments/EXPERIMENT_INVENTORY.md) keeps all 103
audited entries as optional evidence.

Useful entry points:

- [Local OpenAI-compatible server](docs/OPENAI_SERVER.md)
- [System design](docs/SYSTEM_DESIGN.md)
- [Benchmarks](docs/BENCHMARKS.md)
- [The experiments that shaped TurboFieldfare](docs/OPTIMIZATION_JOURNEY.md)
- [Experiment inventory and summaries](docs/experiments/EXPERIMENT_INVENTORY.md)
- [Implementation references](docs/IMPLEMENTATION_REFERENCES.md)

## License and model terms

TurboFieldfare's source and documentation are licensed under the
[Apache License 2.0](LICENSE).

Model weights are not included. The installer downloads them separately from
the pinned Hugging Face checkpoint, and the weights remain governed by their
source terms. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the model
and Swift package license review.

TurboFieldfare is an independent research project. It is not affiliated with,
sponsored by, or endorsed by Google.

## Afterword and the project name

Thanks for checking out this project!

My name is Andrey Mikhaylov. You can find me on
[LinkedIn](https://www.linkedin.com/in/andrey-mikhaylov-ios-dev/).
I am the author of TurboFieldfare and an iOS and Metal engineer. Most of my
work is with images, video, and on-device AI.

I dedicate this project to my wife, Sasha, the most supportive person I know.
She stands by me even through the hardest times. She loves wildlife, goes
birdwatching, and volunteers with our local birding community. Because of her,
I have also grown closer to birds and nature.

TurboFieldfare is named after the fieldfare, a member of the thrush family and
my favourite bird. It is not the most noticeable or brightly coloured bird, but
it definitely has a character and unique features of its own. I think the same
is true of this project: it may not be the most practical, but I built it with
my favourite tools, especially Metal, in my favourite field, on-device ML
inference. It definitely has its own character and unique features.

Next time you are outside, touch the grass and listen to the birds. Sometimes
it is the most beautiful thing you can do. And if you can, support your local
wildlife community. They do important work.

Thank you!
