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
| Intel N150 (800MHz, 4c/4t), Windows native | ~4.61 tok/s warm | ~11.7 GB RAM |
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
| Flash Attention | **-fa** (enabled) | 2x speedup at 16K context by avoiding full attention matrix |
| CPU strict | **1** | Pin threads to cores: consistent latency |
| Context | **16384** | Full context window (benchmarked on N150: fits in 11.7GB RAM with q4_0 KV) |

The optimal config achieves ~4.8 tok/s warm (after the first few tokens),
compared to the baseline ~2.92 tok/s (no repack, 4 threads, q8_0 KV).

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

First launch with repack takes ~90 seconds (reorganizes and writes repacked
weights to disk). Subsequent launches reuse those weights and start faster.

### Quick start

From Windows PowerShell (one-liner, run from the repo directory):

```powershell
cd C:\Users\Paul\turbo-fieldfare; .\start-windows.cmd
```

This starts the server with optimal settings and launches the Pi coding agent.
The script auto-detects the model GGUF and llama-server.exe. If Pi (or Node.js)
is not installed, it offers to install them automatically.

Other modes:

```powershell
cd C:\Users\Paul\turbo-fieldfare; .\start-windows.cmd --ask "What is the capital of France?"
cd C:\Users\Paul\turbo-fieldfare; .\start-windows.cmd --chat
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
