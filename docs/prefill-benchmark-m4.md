# MLX prefill measurements on M4 Max

Recorded 2026-10-01 for [issue #277](https://github.com/ngutech21/sumika-chat/issues/277).

## Decision

Keep the production balanced ceiling at **512**. The 27B runs show essentially
unchanged TTFT at larger ceilings, with higher memory use and much slower
cancellation. The 35B-A3B runs show a modest speed gain, but also higher memory use
and slower cancellation. This tradeoff does not justify a new production policy.
Unsupported internal benchmark ceilings fall back to 512. No public setting,
persisted field, or public API was added.

For example, 27B cold 8K TTFT was 32.38/32.21/32.32 seconds for ceilings
512/1024/2048, while cancellation-to-drain took 1.72/3.70/7.70 seconds.
At 16K, the 2048 ceiling added about 2.6 GiB of peak memory in the cold case
and 2.8 GiB in the warm case without improving TTFT.

## Environment and method

- Apple M4 Max, 128 GiB unified memory, macOS 26.7.1.
- Xcode 27.0 (27A266a), Apple Swift 6.4 (swiftlang-6.4.0.34.1).
- MLX Swift 0.32.3, revision `19601207e9a0de51e03ee6ec0c3c5f3784275075`.
- Bundled MLX core 0.32.2, revision `1f8e74e3f12f31365464a6867c6579f0e9b29d85`.
- MLX Swift LM 3.32.3, revision `3b339ad6e3b3f44c8121ecff5131c7fd55e075e6`.
- Workspace base `49a1ee8e5bf693224751ad5100e170817144c668`, with the benchmark
  implementation in this change. Per-file source hashes are in the run provenance.
- Installed Qwen 3.6 27B and 35B-A3B OptiQ-4bit checkpoints. These use mixed
  4/8-bit affine quantization with group size 64.
  Both have attention head dimension 256.

The primary sweep completed 72 independent Release processes: 48 full-generation
cases and 24 cancellation cases. Each full-generation cell below is one sample,
not a statistical confidence estimate. Build/test activity finished before this
sweep; earlier functional smoke runs are excluded.

Cold means an empty conversation cache after a 512-position kernel warmup.
Warm means a freshly generated 2K prefix followed by the measured suffix.
The harness retains the actual seed response, checks completed seed generation
and exact suffix reuse, and sizes text through the model's real chat template.
The runner rejects differing or truncated request payloads across variants.

Prompts contain repeated synthetic reference text followed by a request to list
integers. Reasoning is off, temperature is zero, top-p is one, top-k is zero,
the context limit is 65536, and each measured full generation emits 128 tokens.
Reported positions are the actually prefilled positions, excluding reused tokens.
TTFT is the runtime trace metric, excluding model loading and application UI work.
Prefill throughput uses the upstream prompt duration; decode throughput uses the
terminal runtime metrics. Cancellation is requested 250 ms after stream creation
and measured through producer and GPU drain with a monotonic clock. Every
cancellation in this sweep occurred during partial prefill, before first output.

Each case resets the process-global MLX peak counter after warmup/seeding and
synchronization, just before the measured request. The reported peak includes
loaded model arrays and generation allocations; it is not total process RSS,
system memory pressure, or swap. Production traces never reset the counter.
Chunk callbacks count submitted positions and add no per-chunk GPU fences.

The checkpoint fingerprints below hash the canonical, sorted JSON mapping of
each installed JSON/safetensors filename to its SHA-256, using compact JSON
separators. The complete file lists are retained in `environment.json`.

| Checkpoint | File-manifest SHA-256 |
|---|---|
| Qwen3.6-27B-OptiQ-4bit | `d870597e9c4dc31247a24fe868ea30a5a8daf57bafb81856f1b2fc3b1bff1be4` |
| qwen3.6-35b-a3b-optiq-4bit | `c12343635a27af8f30f18b4d90303f4c68b54a776ea0b2feb6b98782a00ab5c2` |

## Scope and M5 boundary

This measures one M4 Max and two specific checkpoints with synthetic text.
It does not establish a policy for other M4 variants, lower-memory machines,
other quantizations, natural-document expert routing, image inputs, or M5.
Desktop load and thermal state were not independently controlled.

The pinned upstream [attention dispatch](https://github.com/ml-explore/mlx/blob/1f8e74e3f12f31365464a6867c6579f0e9b29d85/mlx/backend/metal/scaled_dot_product_attention.cpp#L752-L765)
enables the split-head 256 fused path only when M5/NAX support is available, the
query chunk has at least 1024 positions, and its dtype/mask/causal requirements hold. This M4
run does not exercise that M5/NAX path. A configured ceiling alone does not prove
eligibility: the upstream balanced driver gives an 8200-position input with a
1024 ceiling nine 911-position chunks plus the reserved final position, covered
by the focused unit test. M5 claims must be validated in a separate measured run.

## Reproduction and retained artifacts

See [the benchmark workflow](../CONTRIBUTING.md#prefill-benchmarks) for build and
measurement details. The primary sweep used:

```sh
python3 script/benchmark_prefill.py \
  --models Qwen3.6-27B-OptiQ-4bit qwen3.6-35b-a3b-optiq-4bit \
  --tokens 512 2048 8192 16384 --repeats 1 \
  --output-dir .perf/prefill/issue-277-m4
```

The recorded run reused a verified Release build with `--skip-build`.
All models were already installed; no model was downloaded. The local artifact
directory contains `environment.json`, per-case `mlx-trace.jsonl`, the existing
performance report's `latest.json`/`latest.md`, XCTest logs, and `summary.md`.
These artifacts are ignored by Git; the measured tables are preserved below.
The runner defaults to three repetitions when `--repeats` is omitted.

## Repeated 35B-A3B comparison

The follow-up used three independent repetitions per cell at 8192 new positions,
rotating the ceiling order between repetitions. All 24 additional cases passed.
The checkpoint, prompts, settings, cache setup, and runtime code match the primary sweep.

At 1024, median TTFT improved by 5.1% cold and 5.0% warm. Peak memory increased
by 565 MiB cold and 590 MiB warm. Worst observed cancellation-to-drain increased
from 73 to 315 ms cold and from 100 to 348 ms warm. Decode throughput was similar.
A roughly 0.24-second TTFT improvement trades against roughly 0.24 seconds more
cancellation drain and additional memory. The speed gain comes with a cancellation
regression, so the default stays at 512.

Times and throughput below are medians; memory and cancellation are maxima across three samples.

| State | Ceiling | Runs | TTFT s | Prefill tok/s | Decode tok/s | Peak MiB | Cancel to drain ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| cancel-cold | 512 | 3 | - | - | - | 22600.02 | 73.21 |
| cancel-cold | 1024 | 3 | - | - | - | 23063.80 | 314.94 |
| cancel-warm | 512 | 3 | - | - | - | 22679.02 | 100.47 |
| cancel-warm | 1024 | 3 | - | - | - | 23141.05 | 348.45 |
| cold | 512 | 3 | 4.77 | 1730.47 | 99.75 | 22834.80 | - |
| cold | 1024 | 3 | 4.53 | 1823.67 | 98.68 | 23399.38 | - |
| warm | 512 | 3 | 5.00 | 1658.32 | 98.33 | 22914.02 | - |
| warm | 1024 | 3 | 4.75 | 1743.56 | 98.60 | 23503.92 | - |

Reproduce this comparison with:

```sh
python3 script/benchmark_prefill.py \
  --models qwen3.6-35b-a3b-optiq-4bit --tokens 8192 \
  --steps 512 1024 --repeats 3 \
  --output-dir .perf/prefill/issue-277-m4-repeat
```

The recorded run reused the same verified Release build with `--skip-build`.
Full per-case traces, reports, and provenance remain in the indicated directory.

## Full-generation results

`N x size` denotes consecutive submitted chunks. The final one-position chunk
is the reserved tail. Small cold requests can be prepared as one complete chunk,
while warm continuations still reserve that tail. Both paths are reported as
observed. All measured token totals matched the requested positions exactly.

### Qwen3.6-27B-OptiQ-4bit

| State | New positions | Ceiling | Submitted chunks | TTFT s | Prefill tok/s | Decode tok/s | Peak MiB |
|---|---:|---:|---|---:|---:|---:|---:|
| cold | 512 | 512 | 512 | 2.193 | 233.97 | 24.81 | 20069.33 |
| cold | 512 | 1024 | 512 | 2.179 | 235.47 | 24.76 | 20069.33 |
| cold | 512 | 2048 | 512 | 2.152 | 238.40 | 24.65 | 20069.33 |
| cold | 2048 | 512 | 3 x 512 + 511 + 1 | 7.951 | 257.98 | 24.39 | 20018.67 |
| cold | 2048 | 1024 | 1024 + 1023 + 1 | 7.949 | 258.02 | 24.41 | 20615.29 |
| cold | 2048 | 2048 | 2048 | 8.507 | 241.04 | 24.36 | 22547.70 |
| cold | 8192 | 512 | 15 x 512 + 511 + 1 | 32.379 | 253.29 | 23.34 | 20513.53 |
| cold | 8192 | 1024 | 7 x 1024 + 1023 + 1 | 32.209 | 254.62 | 23.70 | 21291.25 |
| cold | 8192 | 2048 | 3 x 2048 + 2047 + 1 | 32.321 | 253.77 | 23.72 | 22650.37 |
| cold | 16384 | 512 | 31 x 512 + 511 + 1 | 66.454 | 246.83 | 22.11 | 21244.45 |
| cold | 16384 | 1024 | 15 x 1024 + 1023 + 1 | 66.329 | 247.30 | 22.66 | 22180.57 |
| cold | 16384 | 2048 | 7 x 2048 + 2047 + 1 | 66.535 | 246.55 | 22.63 | 23930.06 |
| warm | 512 | 512 | 511 + 1 | 2.143 | 240.41 | 24.34 | 20067.12 |
| warm | 512 | 1024 | 511 + 1 | 2.143 | 240.32 | 24.23 | 20067.12 |
| warm | 512 | 2048 | 511 + 1 | 2.134 | 241.50 | 24.33 | 20067.13 |
| warm | 2048 | 512 | 3 x 512 + 511 + 1 | 8.119 | 252.84 | 24.14 | 20205.52 |
| warm | 2048 | 1024 | 1024 + 1023 + 1 | 8.140 | 252.19 | 23.83 | 20837.78 |
| warm | 2048 | 2048 | 2047 + 1 | 8.207 | 250.24 | 24.09 | 22012.35 |
| warm | 8192 | 512 | 15 x 512 + 511 + 1 | 32.833 | 249.85 | 23.36 | 20698.92 |
| warm | 8192 | 1024 | 7 x 1024 + 1023 + 1 | 32.805 | 250.05 | 23.30 | 21525.78 |
| warm | 8192 | 2048 | 3 x 2048 + 2047 + 1 | 33.013 | 248.48 | 23.33 | 22971.10 |
| warm | 16384 | 512 | 31 x 512 + 511 + 1 | 67.540 | 242.91 | 22.54 | 21429.08 |
| warm | 16384 | 1024 | 15 x 1024 + 1023 + 1 | 67.597 | 242.70 | 22.40 | 22405.18 |
| warm | 16384 | 2048 | 7 x 2048 + 2047 + 1 | 67.846 | 241.76 | 22.33 | 24250.83 |

### qwen3.6-35b-a3b-optiq-4bit

| State | New positions | Ceiling | Submitted chunks | TTFT s | Prefill tok/s | Decode tok/s | Peak MiB |
|---|---:|---:|---|---:|---:|---:|---:|
| cold | 512 | 512 | 512 | 0.360 | 1438.21 | 101.68 | 22805.90 |
| cold | 512 | 1024 | 512 | 0.359 | 1439.72 | 101.90 | 22805.90 |
| cold | 512 | 2048 | 512 | 0.358 | 1448.67 | 105.22 | 22805.90 |
| cold | 2048 | 512 | 3 x 512 + 511 + 1 | 1.176 | 1755.58 | 99.86 | 22657.94 |
| cold | 2048 | 1024 | 1024 + 1023 + 1 | 1.103 | 1874.50 | 102.53 | 23087.46 |
| cold | 2048 | 2048 | 2048 | 1.253 | 1648.80 | 100.28 | 24628.80 |
| cold | 8192 | 512 | 15 x 512 + 511 + 1 | 4.791 | 1725.44 | 94.50 | 22834.72 |
| cold | 8192 | 1024 | 7 x 1024 + 1023 + 1 | 4.533 | 1822.34 | 97.57 | 23399.44 |
| cold | 8192 | 2048 | 3 x 2048 + 2047 + 1 | 4.459 | 1851.79 | 96.53 | 24250.88 |
| cold | 16384 | 512 | 31 x 512 + 511 + 1 | 10.273 | 1606.64 | 94.05 | 23142.55 |
| cold | 16384 | 1024 | 15 x 1024 + 1023 + 1 | 9.795 | 1684.41 | 93.79 | 23815.21 |
| cold | 16384 | 2048 | 7 x 2048 + 2047 + 1 | 9.801 | 1684.81 | 94.57 | 24954.56 |
| warm | 512 | 512 | 511 + 1 | 0.344 | 1539.71 | 102.24 | 22677.99 |
| warm | 512 | 1024 | 511 + 1 | 0.343 | 1544.52 | 99.74 | 22677.99 |
| warm | 512 | 2048 | 511 + 1 | 0.348 | 1522.72 | 98.54 | 22678.00 |
| warm | 2048 | 512 | 3 x 512 + 511 + 1 | 1.247 | 1669.36 | 100.00 | 22714.97 |
| warm | 2048 | 1024 | 1024 + 1023 + 1 | 1.177 | 1770.88 | 101.78 | 23191.83 |
| warm | 2048 | 2048 | 2047 + 1 | 1.158 | 1803.68 | 97.71 | 23935.82 |
| warm | 8192 | 512 | 15 x 512 + 511 + 1 | 4.977 | 1660.66 | 99.18 | 22912.10 |
| warm | 8192 | 1024 | 7 x 1024 + 1023 + 1 | 4.763 | 1737.49 | 98.53 | 23503.85 |
| warm | 8192 | 2048 | 3 x 2048 + 2047 + 1 | 4.729 | 1750.18 | 83.48 | 24427.32 |
| warm | 16384 | 512 | 31 x 512 + 511 + 1 | 10.660 | 1548.27 | 92.31 | 23219.80 |
| warm | 16384 | 1024 | 15 x 1024 + 1023 + 1 | 10.220 | 1616.07 | 93.10 | 23919.41 |
| warm | 16384 | 2048 | 7 x 2048 + 2047 + 1 | 10.203 | 1619.94 | 92.52 | 25131.17 |

## Cancellation during prefill

No TTFT or terminal prefill/decode throughput is synthesized for these interrupted requests.
Recorded progress stopped after one submitted chunk in every case; the remaining prompt was not completed.
The outcome in each terminal row is `downstream_terminated`.

| Model | State | New positions | Ceiling | Submitted positions | Cancel to drain ms | Peak MiB |
|---|---|---:|---:|---:|---:|---:|
| 27B | cold | 8192 | 512 | 512 | 1724.05 | 19903.70 |
| 27B | cold | 8192 | 1024 | 1024 | 3696.47 | 20523.37 |
| 27B | cold | 8192 | 2048 | 2048 | 7701.25 | 21685.56 |
| 27B | cold | 16384 | 512 | 512 | 1758.39 | 19903.76 |
| 27B | cold | 16384 | 1024 | 1024 | 3714.45 | 20523.43 |
| 27B | cold | 16384 | 2048 | 2048 | 7644.07 | 21685.62 |
| 27B | warm | 8192 | 512 | 512 | 1778.61 | 20068.59 |
| 27B | warm | 8192 | 1024 | 1024 | 3780.75 | 20727.90 |
| 27B | warm | 8192 | 2048 | 2048 | 7840.48 | 22013.49 |
| 27B | warm | 16384 | 512 | 512 | 1806.20 | 20068.69 |
| 27B | warm | 16384 | 1024 | 1024 | 3774.48 | 20728.00 |
| 27B | warm | 16384 | 2048 | 2048 | 7787.54 | 22013.58 |
| 35B-A3B | cold | 8192 | 512 | 512 | 79.28 | 22600.02 |
| 35B-A3B | cold | 8192 | 1024 | 1024 | 329.83 | 23063.80 |
| 35B-A3B | cold | 8192 | 2048 | 2048 | 813.17 | 23765.81 |
| 35B-A3B | cold | 16384 | 512 | 512 | 110.26 | 22600.06 |
| 35B-A3B | cold | 16384 | 1024 | 1024 | 350.56 | 23063.86 |
| 35B-A3B | cold | 16384 | 2048 | 2048 | 845.51 | 23765.89 |
| 35B-A3B | warm | 8192 | 512 | 512 | 85.67 | 22679.02 |
| 35B-A3B | warm | 8192 | 1024 | 1024 | 344.90 | 23141.05 |
| 35B-A3B | warm | 8192 | 2048 | 2048 | 877.26 | 23936.67 |
| 35B-A3B | warm | 16384 | 512 | 512 | 111.72 | 22679.10 |
| 35B-A3B | warm | 16384 | 1024 | 1024 | 395.50 | 23141.13 |
| 35B-A3B | warm | 16384 | 2048 | 2048 | 905.51 | 23936.76 |
