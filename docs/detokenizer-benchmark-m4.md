# Incremental MLX detokenization on M4 Max

Measured on 2026-10-15 with an Apple M4 Max, 128 GiB memory, macOS 26.7.1,
Xcode 27.0, and Swift 6.4. MLX LM remains pinned to `12d935f9`; MLX Swift is
`0.32.3` and swift-tokenizers is `1.0.0` (`646c5fa`). No model was downloaded.

## Decoder CPU

Both implementations replay identical token IDs from the installed
`gemma4-e4b-qat-4bit` and `qwen3.8-27B-OptiQ-4bit` tokenizers. These are the
catalog's mixed precision 4-bit exports; their exact configuration and tokenizer
fingerprints are retained with the results.

The baseline is the pinned `NaiveStreamingDetokenizer`. The incremental variant
comes from the production tokenizer loader through the MLX tokenizer protocol.
Both preserve special tokens. Timings measure process CPU for append, next,
output accumulation, and final flush; tokenizer loading, token encoding, factory
construction, and output validation are outside the timed region.

Each row is the median of three repetitions after one warmup, with alternating
baseline/adapter order. Payloads contain no newlines. JSON records and tool frames
are repeated and sliced to the requested token count; this measures decoding,
not tool execution. Every replay matched ordinary decoding byte for byte, and
repeated finalization returned no additional text.

| Model | Payload | Tokens | Naive CPU ms | Incremental CPU ms |
| --- | --- | ---: | ---: | ---: |
| Gemma 4 E4B | text | 1024 | 64.269 | 0.188 |
| Gemma 4 E4B | text | 4096 | 1015.630 | 0.756 |
| Gemma 4 E4B | text | 8192 | 4156.975 | 1.596 |
| Gemma 4 E4B | json | 1024 | 52.759 | 0.179 |
| Gemma 4 E4B | json | 4096 | 817.564 | 0.701 |
| Gemma 4 E4B | json | 8192 | 3144.152 | 1.381 |
| Gemma 4 E4B | tool | 1024 | 52.874 | 0.166 |
| Gemma 4 E4B | tool | 4096 | 832.400 | 0.699 |
| Gemma 4 E4B | tool | 8192 | 3266.141 | 1.360 |
| Qwen 3.8 27B | text | 1024 | 14.657 | 0.037 |
| Qwen 3.8 27B | text | 4096 | 232.972 | 0.145 |
| Qwen 3.8 27B | text | 8192 | 926.135 | 0.285 |
| Qwen 3.8 27B | json | 1024 | 10.685 | 0.038 |
| Qwen 3.8 27B | json | 4096 | 159.849 | 0.151 |
| Qwen 3.8 27B | json | 8192 | 632.944 | 0.286 |
| Qwen 3.8 27B | tool | 1024 | 9.233 | 0.032 |
| Qwen 3.8 27B | tool | 4096 | 145.192 | 0.132 |
| Qwen 3.8 27B | tool | 8192 | 573.558 | 0.257 |

The clean repeat reproduced the large decoder CPU reduction. Doubling from
4,096 to 8,192 tokens roughly quadrupled baseline CPU cost while incremental cost
roughly doubled. This is consistent with avoiding repeated prefix decoding.
These ratios describe decoder work only.

## Model generation

Each variant uses the same loaded model and processor through `ChatSession`,
with a new session/cache for every request, greedy sampling, 512 maximum output
tokens, and `enable_thinking: false`. The prompt requests one line of JSON
containing 200 records. There is one warmup per variant and three paired trials
with alternating order. Paired generated text and token counts matched for both
models, including the warmups.

Decode throughput comes from MLX completion info. Request wall time includes
prompt preparation, prefill, generation, and stream synchronization; it excludes
model loading and cache cleanup. This covers the MLX generation path rather
than the full Sumika UI or Work tool loop.

| Model | Decoder | Runs | Generated tokens | Decode tok/s | Request wall ms |
| --- | --- | ---: | ---: | ---: | ---: |
| Gemma 4 E4B | naive | 3 | 512.000 | 81.821 | 6316.255 |
| Gemma 4 E4B | incremental | 3 | 512.000 | 82.220 | 6286.054 |
| Qwen 3.8 27B | naive | 3 | 512.000 | 23.678 | 21953.202 |
| Qwen 3.8 27B | incremental | 3 | 512.000 | 23.747 | 21889.258 |

Observed throughput differences were below 1% (+0.49% for Gemma and +0.29% for
Qwen). These measurements do not establish a meaningful end-to-end speedup.
In particular, the 512-token generation cases do not measure throughput for an
8,192-token response. Statistical uncertainty and thermal state were not
estimated; CPU-only improvements must not be extrapolated to model speed.

## Environment and retained evidence

The initial CPU pass overlapped an unrelated Xcode compile and is retained as
`decoder-initial.log`. The table uses a subsequent clean pass. No competing
build or MLX evaluation was observed in the workload snapshots for the final
CPU and generation passes; short background activity between snapshots is not
excluded. Paired variants used the same underlying tokenizer, prompt, model
weights, sampling, and cache settings, with streaming decoder selection as the
changed variable.

Local artifacts are under `.perf/detokenizer/20261015T113756Z/`: tokenizer/config/index and
source fingerprints, package selections, hardware/compiler information, workload
snapshots, benchmark logs, and verification logs. Weight file contents were not
hashed; both generation variants shared the same loaded weights.

## Reproduction and verification

```sh
xcrun swift build --build-system swiftbuild -c release --target SumikaRuntimeMLXTests -Xswiftc -enable-testing
SUMIKA_DETOKENIZER_BENCHMARK=1 xcrun xctest -XCTest SumikaRuntimeMLXTests.MLXDetokenizerBenchmarkTests/testInstalledTokenizerDecoderCPU .build/out/Products/Release/SumikaRuntimeMLXTests.xctest
SUMIKA_DETOKENIZER_BENCHMARK=1 xcrun xctest -XCTest SumikaRuntimeMLXTests.MLXDetokenizerBenchmarkTests/testInstalledModelGenerationThroughput .build/out/Products/Release/SumikaRuntimeMLXTests.xctest
```

`just final-check`, `just build`, `just resolve-packages`, and
`just check-package-locks` passed. A subsequent `just test` passed after bounding
the cancellation regression fixture. Both lockfiles retain 33 identical package
selections. Dead-code and app builds reported warnings in files outside this
patch. Existing opt-in/model-dependent skips and the known Qwen parser expected
failures remain; they do not establish correctness for that upstream defect.

The new tests cover production-loader behavior, missing-template error mapping,
stable Unicode/whitespace/special-token decoding, malformed final bytes, unread
final output, independent streams, typed Gemma/Qwen tool calls completed by final
flush, and cancellation/length-stop isolation. See [Testing](testing.md#incremental-detokenizer-benchmarks)
for the normal test command and benchmark selection.

UI tests, sanitizers, and long-response end-to-end generation were not run.
