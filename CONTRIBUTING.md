# Contributing to Sumika

Thank you for helping improve Sumika. Contributions should stay focused,
reviewable, and compatible with the local-first nature of the project.

For ordinary bugs and feature requests, use the
[issue tracker](https://github.com/ngutech21/sumika-chat/issues). Larger features,
persisted-data changes, and architectural changes should be discussed in an
issue before implementation. Report suspected vulnerabilities privately as
described in [SECURITY.md](SECURITY.md).

## Development Requirements

Sumika is a native macOS project. Development requires:

- A macOS version supported by the selected Xcode release.
- The Xcode, Swift, and macOS SDK versions recorded in
  [versions.env](.github/actions/setup-apple-toolchain/versions.env).
- [Homebrew](https://brew.sh/).
- `just`, Periphery, and `typos` for the complete local verification workflow.
  The project resolves its pinned SwiftLint binary through SwiftPM, and Xcode
  provides `swift-format`.

`versions.env` also defines `MACOS_RUNNER`, the GitHub-hosted runner label used
by all Apple toolchain jobs. A reusable configuration workflow reads it through
the GitHub Contents API on Ubuntu, without checking out or executing repository
files, before GitHub schedules the macOS jobs. Release builds read the file from
their release tag; other jobs use their triggering commit. Change the runner and
toolchain versions together, and update the approved hosted runner labels in
`.github/workflows/apple-toolchain.yml` when selecting a new runner. This does
not change the app's macOS 15 minimum deployment target.

Install `just`, then use the project recipe to install its primary development
tools:

```sh
brew version-install just@1.58.0
brew version-install typos-cli@1.50.0
just deps
```

The first Xcode build may ask you to approve the pinned
`MLXHuggingFaceMacros` package macro. Review and approve it in Xcode. Do not
disable package-plugin or macro validation for normal local development.

## Build the Project

Clone the repository and build the app from its root directory:

```sh
git clone https://github.com/ngutech21/sumika-chat.git
cd sumika-chat
just build
open "build/DerivedData/Build/Products/Debug/Sumika.app"
```

You can also open `Sumika.xcodeproj` and run the `Sumika` scheme for macOS.
Run `just --list` to see the currently supported project tasks.

## Architecture

Keep changes within the existing ownership boundaries:

- `Sources/SumikaCore/` owns provider-neutral domain models, workflows,
  persistence, tools, policies, and runtime protocols.
- `Sources/SumikaRuntimeMLX/` owns MLX, Gemma, and Qwen implementations behind
  core protocols.
- `Sources/SumikaApp/` owns SwiftUI, AppKit, presentation adapters, and macOS
  integrations.
- `sumika/` contains the Xcode app launcher, resources, entitlements, and bundle
  metadata.

Dependencies point from `SumikaApp` to `SumikaRuntimeMLX` to `SumikaCore`.
`SumikaApp` may also use `SumikaCore` directly. Core must remain independent of
SwiftUI, AppKit, MLX, and Tree-sitter products.

Views should call controllers or app state. Parsing model output, file access,
command execution, permission decisions, and MLX details belong behind the
appropriate workflow or service boundary.

Before changing chat or tool behavior, read the relevant documentation:

- [Chat runtime](docs/chat-runtime.md)
- [Tool runtime](docs/tool-runtime.md)
- [Agent loop](docs/agent-loop.md)
- [Data model](docs/model.md)

## Implementation Guidelines

- Prefer narrow changes with focused tests. Preserve unrelated worktree changes.
- Use async/await for model calls, file I/O, and command execution. Long-running
  work should be cancellable.
- Prefer typed inputs and results over raw strings or ad hoc dictionaries.
- Keep declarations at the narrowest access level required by current callers.
- Add an abstraction only when it hides meaningful coordination or supports a
  concrete caller, alternate implementation, or test boundary.
- Do not add speculative layers, parallel implementations, or new top-level
  directories.
- Complete refactors by migrating all in-scope callers and removing the replaced
  code, tests, flags, and compatibility paths.
- Keep comments sparse and useful. Source files should remain ASCII unless
  non-ASCII text is required.

### Persisted Data

Treat `ChatSession.turns` and `ChatTurn.items` as the persisted transcript and
tool-state source of truth. Avoid duplicate persisted collections, caches, or
projections when the same information can be derived reliably.

Persisted-schema changes need focused tests for ownership, ordering, invariants,
and encode/decode round trips. Run `just data-model` and include the regenerated
`docs/data-model.md` when the schema changes. That file is generated and should
not be edited manually; `docs/model.md` is the curated model overview.

### Tools

Tools must use the typed runtime described in
[docs/tool-runtime.md](docs/tool-runtime.md). Registry membership controls
availability, and write, edit, and command tools must enter the approval flow
before execution. Update the runtime documentation when a tool contract changes.

## Tests and Verification

### Prefill benchmarks

The [M4 Max measurements](docs/prefill-benchmark-m4.md) document why production
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

### Verification commands

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

The dead-code check performs SwiftPM and Xcode builds. It explicitly passes
Swift Build's `.build/out/Products/Debug/index/store` index to Periphery 3.8,
whose automatic SwiftPM index lookup expects the older native build system's
directory layout. The recipe checks that the index exists before scanning.
It does not replace `just build` or `just test-ui` when a change affects those areas.
UI tests are local-only, must not download a model, and may skip when their
configured local model is unavailable.

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
races originally observed with `mlx-swift` 0.31.6. It also excludes three native
execution tests in `Swift15ModelLoaderTests`: `testCheckpointMappingPreservesMetadataAndPrecision`,
`testRawNormOffsetsUseFloat32MathAndKeepInputDtype`, and
`testStrictLoadingAndPreparationKeepNativeQwenBehavior`. With `mlx-swift` 0.32.3,
these paths trigger races in the native scheduler's active-task counter and
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

Report the checks you actually ran and their real outcomes in the pull request.
If an unrelated failure or environment restriction blocks a check, identify it
instead of reporting the suite as passing.

### Compiler Checks

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

## Dependencies and Generated Files

Xcode builds embed pinned uv through `script/embed_uv.sh`. The first app build
downloads its checksum-verified Apple Silicon archive into `.build/uv/`; subsequent
builds can use that cache offline. Run `bash script/embed_uv.sh --prepare` to warm
the cache, or set `SUMIKA_UV_OFFLINE=1` to fail immediately if it is unavailable.
Developer ID release signing still requires Apple's timestamp service.
The script uses macOS tools and does not require installed Python or uv. SwiftPM
tests inject fake executables and do not download Python or MCP packages.

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

Update `script/uv-release.sh` and the bundled upstream license together when
upgrading uv, then verify embedding, managed MCP startup, and the exported app.

All product Swift package dependencies are declared in the root `Package.swift`.
The isolated SwiftLint tool package lives under `script/swiftlint`. After
changing product dependencies, run:

```sh
just resolve-packages
just check-package-locks
```

Commit both `Package.resolved` files. The root lockfile is the canonical package
selection, while the Xcode lockfile retains workspace-specific metadata; they
are not expected to be byte-identical.

After changing the pinned SwiftLint dependency, run `just resolve-swiftlint`
and commit `script/swiftlint/Package.resolved`.

Do not commit model downloads, DerivedData, `.build` contents, release artifacts,
or unrelated generated files.

## Commits and Pull Requests

Use intentional Conventional Commit messages, for example:

```text
fix: preserve complete command output records
feat: add a workspace interaction mode
docs: clarify local model setup
```

When a commit closes an issue, add `Fixes #<id>` in a separate paragraph.

Keep pull requests limited to one coherent change. The description should cover:

- The problem and user impact.
- The chosen solution and important tradeoffs.
- Tests and manual checks performed.
- Screenshots or recordings for visible UI changes.
- Persistence, migration, permission, or security implications.
- Known limitations or follow-up work.

Review the complete diff before submitting. Do not include build output,
credentials, private conversations, workspace content, or unrelated edits.
Sanitize logs and MLX traces before attaching them to a public issue or pull
request.

## Releases and License

Maintainers should follow the separate [release process](docs/release.md).
Contributions are made to a project distributed under the terms in [LICENSE](LICENSE).
