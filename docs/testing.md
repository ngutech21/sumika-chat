# Testing and Verification

See [Development](development.md) for setup and build instructions, and
[Contributing](../CONTRIBUTING.md) for contribution expectations.
Run commands from the repository root.

## Verification commands

Use the narrowest feedback loop that covers the change:

| Change | Required verification |
| --- | --- |
| One behavior or test suite | `swift test --filter <pattern>` |
| Package logic or integration | `just test` |
| Xcode launcher, resources, embedding, or project wiring | `just build` |
| UI, accessibility, launch-test mode, or UI-facing MLX traces | `just test-ui` |
| Persisted data-model schema | `just data-model` |
| Concurrency or memory safety | `just test-tsan` or `just test-asan` |
| Documentation or comments only | `just typos` |

Before requesting review for code changes, complete:

```sh
just final-check
```

This checks spelling, formatting, lint, dead code, and the full SwiftPM test suite.
If equivalent coverage already passed against unchanged code, run only the missing
checks; a focused test does not replace the full suite. Repeat or broaden checks
only when changes, failures, or unresolved concerns justify it. For documentation
or comments only, run `just typos` and explain why builds and tests were skipped.

`just lint-analyze` combines compiler logs from a clean Debug Xcode app build and
a clean Debug SwiftPM build of all source and test targets. It analyzes the app
launcher, package sources, and package tests together so cross-target callers are
visible. SwiftPM uses `.build/lint-analyze` to preserve the normal test build and
the pinned SwiftLint tool cache; this check builds tests without running them.
The existing file exclusions cover SourceKit replay limitations.

The dead-code check performs SwiftPM and Xcode builds. It explicitly passes
Swift Build's `.build/out/Products/Debug/index/store` index to Periphery 3.8,
whose automatic SwiftPM index lookup expects the older native build system's
directory layout. The recipe checks that the index exists before scanning.
It does not replace `just build` or `just test-ui` when a change affects those areas.
UI tests are local-only, must not download a model, and may skip when their
configured local model is unavailable.

Report the checks you actually ran and their real outcomes in the pull request.
If an unrelated failure or environment restriction blocks a check, identify it
instead of reporting the suite as passing.

For Apple toolchain setup changes, also run
`python3 .github/actions/setup-apple-toolchain/test_metal_toolchain.py`, `actionlint`,
and `shellcheck .github/actions/setup-apple-toolchain/*.sh`. The setup regression
tests use fake commands to check cached lookups, delayed registration, and failure
paths without downloading or modifying the host toolchain. Actions Lint runs them
on Ubuntu. A hosted macOS run must still verify the real installation and build.

## Harbor agent evaluation

The first Harbor integration runs one Python repair task with the native
`SumikaEval` executable. It uses the production MLX runtime, Work loop, model
defaults, typed tools, and automatic approval lifecycle. Harbor owns the Docker
workspace and independently verifies its final contents. A completed Sumika turn
is not itself a passing evaluation.

See [the Harbor runner instructions](../script/harbor/README.md) for installation,
the single-trial command, baseline and oracle checks, and artifact locations.
Use an already installed Work-capable model; evaluation never downloads weights.
The three Harbor run recipes build and launch `SumikaEval` in Release.
Run one trial at a time on the Mac. The CLI keeps settings and attachments in the
trial directory and writes `session.json`, `result.json`, and the existing
`mlx-trace.jsonl` format there.
Use `--ak reasoning_effort=low` (or `medium` / `xhigh`) to forward an explicit
`--reasoning-level` to SumikaEval. Omission keeps the model default; unsupported
levels fail. The override stays in the trial's settings and existing run metadata.

`just check-harbor-suite` calibrates the same shared task list used by
`just run-harbor-suite`, requiring `nop` reward `0` and `oracle` reward `1` for
every task. Run it before the first suite evaluation and after task or environment
changes. Missing, duplicate, failed, unfinished, or incorrectly rewarded trials
fail the check. `just check-harbor-fixture` checks only the local `merge-ranges` task.

`just run-harbor` runs the selected single task (`openthoughts/auth_token_race_condition`,
whose image uses `/workspace`) and enables a Harbor evidence plugin without
changing task definitions. Artifact
handling uses the resolved task's top-level `task.toml` declarations; output paths
are not configured in the recipe. Each trial retains
the task inputs/reference solution, source and binary provenance, resolved image
IDs, model file fingerprints and effective settings, and a completeness/checksum
report. The adapter resolves the container's working directory with `pwd -P`
through Harbor and uses it for the bridge and native workspace. Tasks without
artifact declarations automatically capture that workspace and an
existing `/output` after command workers drain; an absent `/output` is not requested.
Declared captures honor their service, destination, and configured exclusions.
For legacy `openthoughts/python-api-rate-limit`, completeness still requires captured
regular files for `/output/report.json`, `/output/a.json`, and `/output/b.json`;
missing files or symlinks fail the check until that task declares its artifacts.
Probe and transfer failures remain evidence failures, separate from verifier reward.
The checker matches legacy captures against `agent/runtime.json`'s `workspaceRoot`.
Other paths require task declarations. A workspace of `/` requires declared
artifacts; the fallback never archives the container root.
The recipe checks the fresh job after Harbor finishes; incomplete
or changed evidence fails this gate independently of verifier reward. Failed
trials retain partial evidence. See the runner instructions for artifact paths,
capture limits, and the read-only checker for individual jobs or trials.

This initial profile enables `read_file`, `edit_file`, `write_file`, `run_command`,
`ask_user`, and `finish_task`. Workspace instructions are read from the container.
`web_search` and `web_fetch` are also enabled when Harbor's effective agent-phase
network policy is `public`, or `allowlist` with at least one allowed host.
Offline tasks and empty allowlists exclude both tools. DNS and HTTP execute in
the task container through the authenticated bridge, so redirects and all
connections remain subject to Harbor's network restrictions. The existing
DuckDuckGo search parser and built-in page extractor run on the Mac without
making external network requests. Runtime metadata records the effective network
policy and web settings. Skills, MCP, browser, and other tools remain absent.
Unexpected user questions end the trial as `needs_user`; Harbor still determines
correctness through its verifier. The example is an integration smoke test, not
a measure of general coding ability.

## Incremental detokenizer benchmarks

The production-loader tests use local ByteLevel, SentencePiece, and buffered
tokenizer fixtures. They cover Unicode, whitespace, special tokens, unread final
output, independent streams, typed Gemma/Qwen calls, and generation cancellation
and length stops. Run them with:

```sh
swift test --no-parallel --filter 'MLXTokenizer(Loader|Generation)Tests'
```

The opt-in benchmark uses installed model assets only. It compares the production
adapter against the pinned `NaiveStreamingDetokenizer`; the baseline selector
exists only in the test target. No model is downloaded:

```sh
SUMIKA_DETOKENIZER_BENCHMARK=1 swift test -c release --no-parallel --filter MLXDetokenizerBenchmarkTests
```

The defaults are `gemma4-e4b-qat-4bit` and `qwen3.8-27B-OptiQ-4bit`.
`SUMIKA_DETOKENIZER_MODELS` accepts a comma-separated list of installed catalog
IDs. Missing assets skip the benchmark and provide no passing measurement.

Decoder-only measurements replay identical 1,024/4,096/8,192-token sequences of
newline-free text, JSON, and tool payloads. They time process CPU, include final
flush and output accumulation, and verify byte-for-byte equality with ordinary
decoding outside the timed region. Reported medians exclude one warmup and use
three repetitions with alternating baseline/adapter order.

The separate generation comparison uses `ChatSession` with greedy sampling,
512 maximum output tokens, thinking disabled, the same single-line JSON prompt,
and a fresh conversation cache for each request. It shares the loaded model,
alternates decoder order, and checks paired output/token-count equality. The
table reports median decode throughput and request wall time separately from
decoder CPU cost. Run on an otherwise idle Mac; CPU-only gains do not establish
an end-to-end generation speedup.

The [M4 Max measurements](detokenizer-benchmark-m4.md) record decoder CPU cost,
generation throughput, output parity, and the measurement limits.

## Known upstream parser regression

`MLXThinkingBudgetCloseTests.testForcedCloseInsideReasoningCodeStillDeliversWriteFile`
uses the pinned `mlx-swift-lm` API and records a strict expected failure for each
unfinished reasoning code fixture. Revision `4cc5504` loses the following tool
call, so these expectations do not establish correct tool parsing. When adopting
upstream support for prompt-primed reasoning, update the test's parser
initialization and remove the expectations. An unexpected pass fails the test.

## Sanitizers

`just test-asan` enables Swift optimization with `-Xswiftc -O` while retaining
the Debug configuration and its test hooks. With Xcode 27 / Swift 6.4,
SwiftSoup 2.13.9's unoptimized ASan-instrumented HTML parser exhausts the Swift
Testing worker thread stack, even for a small HTML fragment. Keep ASan enabled
and use the same configuration when reproducing individual failures:

```sh
xcrun swift test --no-parallel --sanitize address -Xswiftc -O --filter WebAccessTests
```

This enables optimization without adding test exclusions or sanitizer
suppressions. `just test` and `just test-tsan` retain unoptimized Debug coverage.

`just test-tsan` temporarily excludes `MLXChatSessionContinuationTests` and
`MLXGuardedGenerationTests` because of native MLX scheduler and allocator data
races originally observed with `mlx-swift` 0.31.6. It also excludes four native
execution tests in `Swift15ModelLoaderTests`: `testCheckpointMappingPreservesMetadataAndPrecision`,
`testRawNormOffsetsUseFloat32MathAndKeepInputDtype`,
`testStrictLoadingAndPreparationKeepNativeQwenBehavior`, and
`testStrictLoadingAndPreparationDefersVisionAndRetriesFailedMediaLoad`. The deferred-loading
test uses the same existing native-execution exclusion. With `mlx-swift` 0.32.3,
the original tests trigger races in the native scheduler's active-task counter and
Metal completion callbacks, reproduced locally and in
[CI](https://github.com/ngutech21/sumika-chat/actions/runs/37857235029/job/113584266209).
Swift 1.5 manifest and configuration validation remain enabled under TSan.
All excluded tests remain enabled in `just test`; all other tests remain enabled
under TSan. These exclusions reduce coverage and do not fix the dependency.
Remove the exclusion once the pinned MLX code is fixed and the unfiltered command
passes:

```sh
xcrun swift test --no-parallel --sanitize thread
```

`just test-asan` temporarily excludes the same two suites for a separate native
MLX allocator bug observed with `mlx-swift` 0.31.6. In that version, on an Apple
Paravirtual device, `MetalAllocator` returns from its constructor without
initializing `heap_`.
Small allocations then dereference the uninitialized pointer; under ASan its
value is `0xbebebebebebebebe`. The
[CI failure](https://github.com/ngutech21/sumika-chat/actions/runs/35543454227/job/106165160854)
occurs in the first continuation test, and the isolated generation probes use
the same allocator. Earlier CI runs skipped these tests because `default.metallib`
was missing; local ASan runs on a physical Mac pass because heap initialization
takes a different path. Both suites remain enabled in `just test`; all other
tests remain enabled under ASan. This exclusion reduces sanitizer coverage and
does not fix the dependency. Remove it once the pinned MLX code initializes the
heap safely on VMs and the unfiltered command passes on the hosted macOS runner:

```sh
xcrun swift test --no-parallel --sanitize address -Xswiftc -O
```

## Compiler Checks

The product package requires Swift tools 6.4 and uses Swift 6 language mode.
All owned Swift targets treat warnings as errors, require direct imports for
members they use, and enable `ExplicitSendable` for public type declarations.
Declare intentional non-Sendable types with `~Sendable`; do not add unchecked
conformances merely to silence diagnostics. App targets retain MainActor default
isolation and `NonisolatedNonsendingByDefault`; Core and MLX runtime targets retain
their existing isolation behavior.

Additional diagnostics are available as optional audits:

```sh
just audit-memory-safety SumikaCore
just audit-memory-safety SumikaApp
just audit-performance SumikaCore
just audit-async
```

The compiler audits use opt-in package traits and affect only Sumika targets in
the selected target's dependency graph. Memory-safety diagnostics expose existing
C, pointer, Objective-C, and concurrency trust boundaries; a successful audit
build can still report warnings and is not a memory-safety certification. Review
lifetimes, bounds, and synchronization before acknowledging an operation as unsafe.
Performance hints identify potential costs, not measured regressions. Profile
release builds before changing protocol boundaries, error types, or ownership.
Use `@diagnose(PerformanceHints, as: warning)` on a declaration for a narrower audit.

The async lint audit can flag intentional protocol implementations. Review each
result before removing `async`; it is not part of `final-check`. In async code,
use `defer { await cleanup() }` when cleanup must finish before scope exit. This
also keeps test cleanup inside the test's lifetime. It does not shield cleanup
from cancellation. Keep new library APIs compatible with the macOS 15 deployment
target; `Iterable` and task cancellation shields require macOS 27.

## Bundled MCP runtime checks

After building the app, explicitly opt into the networked runtime smoke test with
`SUMIKA_TEST_BUNDLED_UV` set to the absolute path of its `Contents/Helpers/uv`, then
run `xcrun swift test --filter MCPBundledRuntimeSmokeTests`. This uses fresh temporary
runtime storage and a minimal PATH, checks a cold offline failure, installs Python
and the pinned Fetch MCP server, and verifies an offline restart. It does not call
the server's web-fetching tool. A clean-account notarized-app check remains separate.

With the same `SUMIKA_TEST_BUNDLED_UV` path, run
`xcrun swift test --filter MCPBundledRuntimeConfigurationTests` for offline
configuration-isolation checks. These tests use uv's settings inspection without
installing Python or packages. Workspace, home, user, and system configuration
locations are temporary; the developer's real uv configuration is not used.

## Prefill benchmarks

The [M4 Max measurements](prefill-benchmark-m4.md) document why production
continues to use a ceiling of 512.

Use the opt-in runner with already installed Sumika model IDs:

```sh
python3 script/benchmark_prefill.py --models Qwen3.6-27B-OptiQ-4bit qwen3.6-35b-a3b-optiq-4bit
```

The runner builds the MLX test target through SwiftPM in Release with testability
enabled, then invokes that package's XCTest bundle in separate processes for balanced ceilings
512/1024/2048, prompt sizes 512/2048/8192/8200/16384, and three repetitions with
rotating ceiling order. `--tokens`, `--steps`, `--modes`, and `--repeats` narrow the
matrix; `--skip-build` reuses a verified Release build. `--models-path` selects
another existing model directory. No model is downloaded. Ordinary package test
runs skip this benchmark unless its environment is explicitly configured. A
requested benchmark that skips or fails produces no passing measurement.

Cold cases start with an empty conversation cache after kernel warmup. Warm cases
seed a fresh 2K prefix before measuring the selected suffix length. Synthetic text
is sized through the model's chat template, and measured token counts and cache
decisions are checked. An EOS position may change a warm suffix count by one.
Settings, prompts, and quantization stay fixed across variants; differing rendered
request payloads fail the runner. Decode runs use greedy sampling and at most 128
output tokens. Cancellation cases use prompts of at least 8K positions and request
cancellation 250 ms after stream creation; inspect the submitted counts to distinguish cancellation
during prefill from later cancellation.

Each case resets `Memory.peakMemory` only after warmup/seeding and synchronization,
immediately before its measured generation. Its terminal snapshot is therefore a
generation-local MLX active-memory peak. This does not measure total process RSS,
system memory pressure, or swap. Normal application traces never reset the counter.

Results remain under `.perf/prefill/<timestamp>/`: an environment/provenance file,
ordinary `MLXDebugTraceStore` JSONL traces, existing performance-report JSON/Markdown,
test logs, and an aggregate `summary.md`. The aggregate uses median throughput/TTFT
and maximum peak memory/cancellation latency; per-case reports retain individual
samples and actual chunk sizes. The 8192/8200 cases exercise balanced chunk boundaries
around the M5 attention threshold. M4 measurements are required before changing its
production policy; M5 results must be reported separately. Keep 512 unless the
measured gain is repeatable without unacceptable memory or cancellation regressions.

The report parser can be checked without a model:

```sh
python3 script/test_trace_performance_report.py
```
