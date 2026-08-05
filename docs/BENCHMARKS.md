# Benchmarks

This page records TurboFieldfare measurements on an 8 GB M2 MacBook Air, a
24 GB M5 Pro, and a CPU-only Intel N150 (WSL2 + native Windows). Each number
belongs to the workload shown. Prompt length, generated length, cache state,
and hardware all change throughput, so ranges across workloads are not
run-to-run variation.

Each table states its workload and decoding settings. TurboFieldfare uses the
model installed by the [command-line instructions](../README.md#command-line-interface).
Decode rate excludes model installation, model loading, and prompt prefill.

## Results at a glance

| Host and runtime | Decode rate | Reported memory |
| --- | ---: | ---: |
| Intel N150 (800MHz, 4c/4t), WSL2 native | ~0.72 tok/s | ~4.4 GB RSS |
| Intel N150 (800MHz, 4c/4t), Windows native (pre-built b10242) | ~6.23 tok/s | ~11.7 GB RAM |
| Intel N150 (800MHz, 4c/4t), Windows native (custom AVX-VNNI build) | **~14.56 tok/s** | ~11.7 GB RAM |
| 8 GB M2, TurboFieldfare | 5.10-6.30 tok/s | ~1.9-2.1 GB footprint |
| 24 GB M5 Pro, TurboFieldfare | 31-35 tok/s | ~2.1 GB footprint |
| 24 GB M5 Pro, mlx-lm | 76.33-82.07 tok/s | 8.3-9.8 GB RSS; 14.7-15.3 GB GPU allocation |

The Intel N150 is a low-power mobile CPU (Intel Atom N-series, 4 cores at
800MHz, no turbo). The 6.4x speedup from WSL2 to native Windows comes from
doubling the available RAM (11.7 GB vs 5.7 GB), which lets the OS page cache
hold most of the 14 GB model. See [CPU-only optimization](#cpu-only-intel-n150)
below.

## M2 measured decode

These rows ran on a `Mac14,15` M2 MacBook Air with 8 GB of memory. No
experiment, profiler, or trace mode was active.

| Prompt / generated tokens | Prefill | TTFT | Decode | Peak RSS / footprint |
| --- | ---: | ---: | ---: | ---: |
| 6 / 32 | 7,025 ms | 7,979 ms | 6.30 tok/s | 1,304 / 1,791 MiB |
| 121 / 64 | 7,934 ms | 8,862 ms | 5.10 tok/s | 1,528 / 1,776 MiB |
| 527 / 64 | 21,736 ms | 22,649 ms | 5.90 tok/s | 1,535 / 1,886 MiB |
| 1,017 / 128 | 36,729 ms | 37,656 ms | 5.38 tok/s | 1,455 / 1,971 MiB |

Each workload ran once in a fresh process. The file cache was warm but
uncontrolled, and every row produced the same token IDs as its validation
control. These four points show the production path running under the 8 GB
rule; they do not form a confidence interval or describe sustained long
generation.

### Where the short M2 row spent its time

A separate diagnostic pass on the six-token prompt divided a 162.8 ms decode
step into four broad parts:

| Work | ms/token |
| --- | ---: |
| Expert reads | 83.1 |
| Waiting in the command-buffer pipeline | 55.6 |
| Tied output head | 14.2 |
| Other runtime work | 9.9 |

The diagnostic instrumentation disabled the normal command-buffer pipeline
and reduced throughput to 4.23 tok/s. The breakdown explains where that run
spent time; it does not describe independent speedups or a performance bound.

## M5 measured decode

These rows ran on 2026-07-20 on a 24 GB M5 Pro (`Mac17,8`) with macOS 26.5.1,
Xcode 26.6, and Swift 6.3.3. No profiler or trace mode was active.

The benchmark uses chat-framed prompts and fixed, non-repeating natural
continuations. This keeps the generated text and expert-routing workload stable
without rewarding a model repetition loop. The complete production sampling
and decode path still runs for every token.

One warmup preceded three fresh-process measurements per workload. The table
reports medians; the file cache was warm but uncontrolled. A separate
free-generation smoke reached the end of each model turn without a repetition
loop.

| Prompt / generated tokens | Prefill / TTFT | Decode | Peak RSS / footprint |
| --- | ---: | ---: | ---: |
| 61 / 256 | 5,096 / 5,668 ms | 35.17 tok/s | 1,834 / 2,126 MiB |
| 430 / 256 | 6,762 / 7,325 ms | 34.72 tok/s | 1,851 / 2,142 MiB |
| 3,015 / 256 | 23,038 / 23,610 ms | 31.01 tok/s | 1,835 / 2,126 MiB |

## Same-host MLX comparison

The same M5 Pro ran MLX 0.32.0 and mlx-lm 0.31.3 against the same checkpoint,
prompt-token IDs, and generated-token counts. MLX measured 82.07, 80.25, and
76.33 tok/s for the 121-, 527-, and 1,017-token prompts.

Treat this as throughput context, not a complete engine comparison:

- The engines ran in separate blocks rather than a balanced, interleaved order.
- Their first-token clocks started at different points, so TTFT is not comparable.
- Generated IDs matched for the shortest prompt but diverged for the two longer prompts.
- TurboFieldfare recorded a 1.89-2.09 GiB physical footprint. MLX reported
  14.66-15.31 GB of peak GPU allocation and 8.27-9.79 GB of peak process RSS.
  Those counters measure different things and should not be compared as a
  direct memory ratio.

The MLX process required the larger host and is not an 8 GB TurboFieldfare
deployment path.

## CPU-only Intel N150

These rows ran on 2026-08-03 on an Intel N150 (4c/4t, 800MHz, no turbo, AVX2/AVX_VNNI)
with a Q4_0 GGUF of Gemma 4 26B-A4B (~14 GB). The HDD-based system has
11.7 GB of physical RAM when running native Windows, or 5.7 GB under WSL2.

### Windows native vs WSL2

Windows native runs 6.4x faster than WSL2 despite identical CPU frequency.
The speedup comes from having twice as much RAM available for the OS page
cache:

| Runtime | RAM available | Throughput | Speedup |
| --- | ---: | ---: | ---: |
| WSL2 native (MADV_DONTNEED patch) | 5.7 GB | ~0.72 tok/s | 1x (baseline) |
| Windows native (default llama.cpp) | 11.7 GB | ~4.61 tok/s | 6.4x |

With only 5.7 GB, WSL2 cannot hold the working set in RAM. Expert weights are
constantly evicted and re-read from the HDD. Windows native's 11.7 GB lets
the page cache retain most of the 14 GB model, reducing disk I/O dramatically.

### Optimal configuration

Benchmarking 15+ configurations on Windows native found these optimums:

| Setting | Optimal value | Why |
| --- | ---: | ---: |
| Repack | **ON** (default) | Reorganizes weights for faster matmul: +45% speed |
| Threads | **3** on 4-core CPU | Leaves 1 core for OS/disk I/O |
| KV cache | **q4_0** | Less memory bandwidth than q8_0: +5% speed |
| Micro-batch (ub) | **128** | Best throughput with Flash Attention |
| Flash Attention | **-fa on** (enabled) | 2-2.5x speedup at 16K context (b10242 syntax: `-fa on` not `-fa`) |
| CPU strict | **0** | Allow non-deterministic FP: +3-5% speed (negligible output difference) |
| Context (ask/chat) | **4096** | +40-50% tok/s vs 16384 on CPU |
| Context (Pi agent) | **16384** | Tool use needs long context |
| Binary | **Custom MSVC build** | AVX-VNNI instructions: +133% over pre-built (6.23 → 14.56 tok/s) |

The custom MSVC-compiled binary with AVX-VNNI achieves **~14.56 tok/s** steady-state
(10-request average), a **133.7% improvement** over the pre-built b10242 binary (6.23 tok/s).
Compared to the baseline ~2.92 tok/s (no repack, 4 threads, q8_0 KV), that's a **5x speedup**.

### Thermal throttling

The N150 is a **6W TDP** chip. Under sustained all-core load, it will thermal
throttle after ~2-3 minutes, dropping from ~14.5 tok/s to ~2-4 tok/s. This is
expected hardware behavior, not a bug.

**Performance depends on CPU temperature:**

| State | Approximate throughput | Notes |
| --- | ---: | ---: |
| Fresh (cool CPU, < 60°C) | ~14-15 tok/s | After reboot or long idle |
| Warm (1-2 min load) | ~8-12 tok/s | Beginning to throttle |
| Throttled (> 2-3 min sustained) | ~2-4 tok/s | Thermal limit reached |

Performance recovers after a ~30s idle cooldown. For best results:
- Run inference in short bursts
- Ensure adequate ventilation (laptop stand, fan)
- Avoid enclosing the machine in a bag or tight space

### Context size tradeoff

On CPU-only inference, token throughput scales **inversely** with context size
because each decode step reads the full KV cache from RAM. Smaller contexts mean
less memory bandwidth per token.

| Context | Approximate tok/s (cool CPU) | Speedup vs 16384 |
| --- | ---: | ---: |
| 4096 | ~20-22 | +40-50% |
| 8192 | ~17-19 | +20-30% |
| 16384 | ~14-15 | baseline |

The default modes use context=4096 for `--ask` and `--chat` (where long context
isn't needed), and context=16384 for Pi agent mode (where tool use requires it).
Override with `--context N` to set any size.

### Benchmark matrix

These configurations were tested, each with a warmup + 5 measured requests:

| Config | Throughput | Notes |
| --- | ---: | ---: |
| No repack, 4 threads, q8_0 KV, ub 256 (baseline) | 2.92 tok/s | Slow KV loading |
| No repack, 4 threads, q8_0 KV, no cpu-strict | 2.83 tok/s | cpu-strict helps |
| No repack, 4 threads, q4_0 KV, ub 256 | 2.65 tok/s | q4_0 slower without repack |
| No repack, 4 threads, f16 KV | 2.39 tok/s | Too much memory bandwidth |
| No repack, 4 threads, q8_0 KV, ctx 256 | 2.18 tok/s | Small context hurts |
| No repack, 3 threads, q8_0 KV, ub 256 | 2.99 tok/s | 3 threads better than 4 |
| No repack, 2 threads | 1.12 tok/s | Too few threads |
| **Repack, 4 threads, q8_0 KV** | **4.19 tok/s** | Repack is the big win |
| **Repack, 3 threads, q8_0 KV** | **4.36 tok/s** (warm 5.3) | Thread sweet spot |
| **Repack, 3 threads, q4_0 KV** | **4.61 tok/s** (warm 5.43) | **Best configuration** |
| Repack, 3t, q4_0, ub 512 | 3.61 tok/s | Larger ub hurts |
| Repack, 3t, q4_0, ctx 256 | 3.03 tok/s | Small context hurts |

**Repack is a one-time operation.** The first launch takes ~90 seconds because
llama.cpp reorganizes the weight tensors for faster matmul and writes them to a
`.repack` cache file alongside the GGUF (e.g., `gemma-4-26B-A4B-it.Q4_0.gguf.repack`).
**All subsequent launches reuse this cache** and start in ~10s. The repack only
re-runs if you:
- Delete the `.repack` file
- Switch to a different GGUF
- Rebuild llama.cpp with different flags

This persists across reboots — you only endure the 90s once.

### Custom AVX-VNNI build (+133% over pre-built)

The pre-built b10242 binary (6.23 tok/s) is compiled with MSVC using `/arch:AVX2`.
Rebuilding from source with **AVX-VNNI** (`vpdpbusd` instruction for 4-way INT8 dot
product) and proper ISA flags yields **14.56 tok/s** steady-state — a **133.7% improvement**.

Key findings from the build process:

| Factor | Finding |
| --- | --- |
| **Compiler** | MSVC generates superior code for AVX-VNNI on Gracemont (N150). Clang 22 builds were 48-52% slower. |
| **ISA flags** | Must enable `GGML_AVX=ON` + `GGML_AVX2=ON` + `GGML_AVX_VNNI=ON` together. CMake can set AVX=OFF when only AVX_VNNI is passed. |
| **OpenMP** | Critical for multi-threaded matmul. Must be enabled (MSVC: `-openmp`). Without it, performance drops ~50%. |
| **LTO** | Link-time optimization (`/LTCG`) adds ~5-10% improvement. |
| **CPU variant** | MSVC builds `ggml-cpu-alderlake.dll` with `/arch:AVX2 __AVXVNNI__` — automatically selected at runtime on N150. |

#### Hardware requirements

| Requirement | Minimum | Recommended |
| --- | --- | --- |
| CPU | x86_64 with AVX2 | Intel Alder Lake-N or newer (for AVX-VNNI) |
| RAM | 8 GB | 12 GB+ (for 14 GB model + repack) |
| Disk | 30 GB free | SSD strongly preferred |
| OS | Windows 10/11 64-bit | Windows 11 23H2+ |

#### Software prerequisites

| Tool | Required | Notes |
| --- | --- | --- |
| Visual Studio 2022 | Yes | Community, Professional, or BuildTools — "Desktop development with C++" workload |
| CMake 3.25+ | Yes | Script auto-installs via winget if missing |
| Ninja | Yes | Script auto-installs via winget if missing |
| Git | Yes | For cloning llama.cpp source |
| winget | Yes | Windows 10 1709+ / Windows 11 |

#### Step-by-step: build on another machine

**1. Clone the repo:**
```powershell
git clone https://github.com/paulklemstine/turbo-fieldfare.git
cd turbo-fieldfare
```

**2. Install Visual Studio 2022** (if not present):
- Download from https://visualstudio.microsoft.com/downloads/
- Workload: **Desktop development with C++**
- This includes MSVC, Windows SDK, and C++ tools

**3. Place your model** in `C:\Users\<you>\models\`:
```
models\gemma-4-26B-A4B-it.Q4_0.gguf   (14.3 GB)
```

**4. Edit `build-optimized.ps1`** to set your install path:
```powershell
$installDir = "C:\Users\<you>\llama-b10242"  # Change this
```

**5. Edit `start-windows.cmd`** to match your model/install paths:
```batch
set "MODEL_DIR=C:\Users\<you>\models"
set "LLAMA_SERVER_DIR=C:\Users\<you>\llama-b10242"
```

**6. Run the build** (PowerShell, Admin not required):
```powershell
powershell -ExecutionPolicy Bypass -File "build-optimized.ps1"
```
Build takes **10-30 minutes** on N150 (faster on better CPUs). The script:
- Installs CMake/Ninja via winget if missing
- Clones llama.cpp at master (latest optimizations)
- Configures with MSVC + AVX2 + AVX-VNNI + OpenMP
- Builds all 479 targets with Ninja
- Backs up existing binaries to `llama-b10242\backup_<timestamp>\`
- Deploys new binaries to your install dir

**7. Verify the build:**
```powershell
C:\Users\<you>\llama-b10242\llama-server.exe --version
```
Should output: `version: 10242 (...) built with ... for Windows x86_64`

**8. Test with benchmark script:**
```powershell
powershell -ExecutionPolicy Bypass -File "bench-flags.ps1"
```

#### Build configuration details

The script uses these CMake flags:
```
-G Ninja                           # Ninja build system (fastest)
-DCMAKE_C_COMPILER=cl              # MSVC C compiler
-DCMAKE_CXX_COMPILER=cl            # MSVC C++ compiler
-DGGML_NATIVE=ON                   # -march=native equivalent (/arch:AVX2)
-DGGML_AVX=ON                      # Enable AVX
-DGGML_AVX2=ON                     # Enable AVX2
-DGGML_AVX_VNNI=ON                 # Enable AVX-VNNI (the key optimization)
-DGGML_AVX512=OFF                  # Disable AVX-512 (N150 doesn't have it)
-DGGML_CPU_REPACK=ON               # Weight repacking for faster matmul
-DGGML_OPENMP=ON                   # Multi-threading support
-DCMAKE_BUILD_TYPE=Release         # Full optimizations + LTO
-DBUILD_SHARED_LIBS=ON             # Shared libraries (smaller binaries)
```

These produce a `ggml-cpu-alderlake.dll` compiled with:
```
/arch:AVX2 /DGGML_AVX2 /DGGML_FMA /DGGML_F16C /D__AVXVNNI__ /DGGML_AVX_VNNI
```

#### Expected results by CPU

| CPU | Pre-built (AVX2 only) | Custom AVX-VNNI build | Improvement |
| --- | --- | --- | --- |
| Intel N150 (Gracemont, AVX-VNNI) | ~6.2 tok/s | **~14.5 tok/s** | +133% |
| Intel 12th+ gen P-core (AVX-VNNI) | ~15-20 tok/s | ~25-30 tok/s | ~50% |
| AMD Zen 4 (AVX-512 VNNI) | varies | use AVX-512 build instead | — |
| CPUs without AVX-VNNI | — | No benefit from custom build | 0% |

The custom build only helps on CPUs with **AVX-VNNI** support:
- Intel Alder Lake-N (N150, N200, N300 series)
- Intel Alder Lake desktop (12th gen Core, limited AVX-VNNI)
- Intel Meteor Lake (Core Ultra)
- Intel Lunar Lake (Core Ultra 200V)

#### Troubleshooting

| Problem | Solution |
| --- | --- |
| `ninja: error: failed recompaction: Permission denied` | Kill any stale ninja processes: `Stop-Process -Name ninja -Force` |
| `unrecognized file format` linker error | Delete `build/` directory fully (stale objects from prior compiler) |
| `cmake not found` | Script auto-installs via winget, but restart PowerShell first |
| `ninja not found` | Script auto-installs via winget, but restart PowerShell first |
| `error: unknown value for --flash-attn` | Your binary is b10242+; use `-fa on` not `-fa` |
| Slower than pre-built | Check that AVX_VNNI is actually supported on your CPU (cpuid) |

### Quick start

From Windows PowerShell (one-liner, run from the repo directory):

```powershell
cd C:\Users\Paul\turbo-fieldfare; .\start-windows.cmd
```

This starts the server with optimal settings and launches the Pi coding agent
(context=16384). The script auto-detects the model GGUF and llama-server.exe.
If Pi (or Node.js) is not installed, it offers to install them automatically.

Other modes:

```powershell
cd C:\Users\Paul\turbo-fieldfare; .\start-windows.cmd --ask "What is the capital of France?"
cd C:\Users\Paul\turbo-fieldfare; .\start-windows.cmd --chat
cd C:\Users\Paul\turbo-fieldfare; .\start-windows.cmd --chat --speculative
cd C:\Users\Paul\turbo-fieldfare; .\start-windows.cmd --ask "Explain quantum computing" --context 8192
cd C:\Users\Paul\turbo-fieldfare; .\start-windows.cmd --debug
cd C:\Users\Paul\turbo-fieldfare; .\start-windows.cmd --threads 3
```

From WSL2 Ubuntu (auto-dispatches to Windows native):

```bash
./start.sh
```

Use `--wsl` to force WSL2 native mode instead of dispatching to Windows:

```bash
./start.sh --wsl
```

### Server output

By default, llama-server output is redirected to `llama_server.log` in the
script directory. Use `--debug` to show server output in the console instead.

### Environment overrides

```powershell
$env:MODEL_PATH = "C:\path\to\model.gguf"
$env:LLAMA_DIR = "C:\path\to\llama.cpp\build\bin"
$env:CONTEXT_TOKENS = "512"
$env:SERVER_PORT = "8080"
$env:THREADS = "3"
.\start-windows.cmd
```

## Reproduce and contribute a result

The [community benchmark guide](COMMUNITY_BENCHMARKS.md) uses short, medium,
and long chat-framed prompts with fixed seeds. It requires coherent output and
a normal end of turn, so a repetition loop cannot become a published speed
result. The public CLI's timing footer reports decode-only throughput without a
separate research harness.

Community runs generate their own output, while the reference table uses fixed
non-repeating continuations for token-for-token stability. Compare community
submissions only when their prompt and generated token counts match.

A current checkout may not reproduce a historical number after the runtime,
compiler, or operating system changes. Report the commit and all three rows
rather than presenting one run as a general hardware result.

Read [System design](SYSTEM_DESIGN.md) for the runtime and resource split,
[Experiments](OPTIMIZATION_JOURNEY.md) for the main wins and failures, and the
[measurement lessons](experiments/summaries/09-validation-and-measurement-lessons.md)
for the rules used to evaluate performance changes.
