# AGENTS.md

## Project Goal

`local-coder` is a macOS Swift app for local-first coding with small Gemma models
running through MLX. Keep workflows focused, inspectable, reviewable, and
explicit: local context, short steps, auditable shell execution, and macOS-native
SwiftUI/AppKit UI. Do not assume network access is available or desirable.

## Architecture Rules

The project is split into a headless SwiftPM core library and a macOS app target:

- `Package.swift` defines `LocalCoderCore` and `LocalCoderCoreTests`.
- `Sources/LocalCoderCore/` contains reusable product logic and must not import
  SwiftUI, AppKit, or MLX-specific implementations.
- `Tests/LocalCoderCoreTests/` contains headless tests for parsing, permission
  evaluation, persistence, runtime configuration, prompt construction, command
  execution, tool execution, and coordinators.
- `local-coder/` contains the Xcode macOS app target. It imports
  `LocalCoderCore` and owns SwiftUI/AppKit views, app launch wiring, platform
  services, and MLX-backed implementations.
- `local-coderTests/` is for tests that need the app target, SwiftUI/AppKit, or
  MLX-specific behavior.
- `local-coderUITests/` is for local-only end-to-end app flows that need the real
  macOS UI and real MLX/Gemma runtime.

Keep dependencies one-way: app -> `LocalCoderCore`. Views call controllers or app
state; controllers call coordinators/services; services exchange structured
models. SwiftUI views must not parse model output, touch the filesystem directly,
run shell commands, make permission decisions, or know MLX details.

For new code, follow the current layout:

```text
Sources/LocalCoderCore/
  Features/
  Models/
  Services/
  Support/
Tests/LocalCoderCoreTests/
local-coder/
  App/
  Features/
  Services/
  Views/
local-coderTests/
local-coderUITests/
```

Start small. Do not introduce empty folders or abstractions before there is real
code to put in them.

## Core/App Boundaries

- Keep reusable behavior in `LocalCoderCore`; keep MLX/Gemma backends in
  `local-coder/Services/` behind core protocols.
- SwiftUI controllers are UI facades only: hold view state, expose small user
  actions, call coordinators/services, and map results back to UI.
- Workflow lifecycle belongs in coordinators. Execution, side effects,
  persistence, and platform integration belong in services/executors. Context and
  prompt selection belong in builders/policies.
- If logic can be tested without SwiftUI, it probably belongs in core.

## Data Model Policy

Local Coder is an unreleased prototype. Do not add backwards compatibility,
migrations, legacy decode paths, or fallback fields for old persisted sessions
unless explicitly requested.

Prefer clean ADTs, single sources of truth, derived projections, and intentional
`Codable` schemas covered by tests.

## Tool Runtime

Follow `docs/tool-runtime.md` when adding or changing tools. Tools are registered
through the typed runtime, parsers emit neutral `ToolCallRequest` values,
registry membership controls availability, and concrete tools receive typed
inputs. Denied tools and approval-required tools are distinct: write, patch, and
command tools must enter awaiting-approval before execution. Update
`docs/tool-runtime.md` when the contract changes.

## Workspace Interaction Modes

The chat composer has a manual `WorkspaceInteractionMode` per session:

- `chat`: normal conversation; no tool schemas or tool loop.
- `agent`: coding-agent workflow with `ToolExecutorRegistry.codingAgent`,
  write/edit tools, and approval flow.

Do not infer tool availability from prompt keywords. Mode is explicit
product/session state. Persist it on `ChatSession` and trace
`turn_trace.interactionMode`.

## Implementation And UX

- Use async/await for model calls, file IO, and command execution; make
  long-running work cancellable; stream model output when possible.
- Prefer structured models and typed results over raw strings or ad hoc
  dictionaries. Use `throws` for recoverable failures.
- Avoid singletons unless they wrap immutable platform facilities. Avoid
  synchronous file IO and `@unchecked Sendable` stores in new persistence code.
- Preserve user changes. Never overwrite or revert unrelated edits.
- Prefer narrow patches, focused tests, sparse useful comments, and ASCII source
  unless a file already uses non-ASCII for a reason.
- The primary screen is the coding workflow. Use dense macOS-native layouts, show
  model context and generated diffs, and provide clear loading/generating/
  cancelled/failed/applied states.

## Build And Test

Prefer the project task runner:

```sh
just build
just test-core
just test-app
just ui-test
just test
just lint
just format
just typos
just data-model
just coverage
just coverage-low
just final-check
just periphery
```

Use the narrowest feedback loop while debugging:

- Core-only: `just test-core`.
- App-target only: `just test-app`.
- UI tests, accessibility IDs, launch test mode, model-loading UI, chat/agent UI,
  or Gemma trace behavior used by UI tests: `just ui-test`.
- Cross-boundary or build/test wiring: `just test`.

For final verification after implementation, prefer `just final-check`. It runs
`typos`, `format`, `lint`, `test`, and `check-warnings`. If a focused test just
passed during debugging, it is acceptable to run only the missing equivalent
checks instead of repeating the same test suite immediately. For docs/comments
only, explain why build/test suites were not run and use the narrowest relevant
check, such as `just typos`.

Other useful commands:

```sh
xcrun swift build
xcrun swift test
xcodebuild -project local-coder.xcodeproj -scheme local-coder -destination "platform=macOS" build
./script/build_and_run.sh
./script/build_and_run.sh --verify
```

CI intentionally runs only headless SwiftPM tests with `xcrun swift test`.
`just ui-test` is local-only, enables `LOCAL_CODER_DEBUG_TRACE=1`, must never
download a model, and should skip cleanly if `gemma4-e4b` is missing. Use
`just data-model` to regenerate `docs/data-model.md`.

## Debugging And Tracing

Use the project script before inventing new launch flows:

```sh
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
./script/build_and_run.sh --trace
```

- `--logs`: stream process logs for `local-coder`.
- `--telemetry`: stream subsystem logs for `ngutech21.local-coder`.
- `--trace`: run with `LOCAL_CODER_DEBUG_TRACE=1`.

Normal trace:

```text
~/Library/Application Support/local-coder/debug/gemma-trace.jsonl
```

UI-test per-run traces:

```text
~/Library/Application Support/local-coder/debug/traces/
```

Do not create additional chat/model performance trace formats. Extend
`GemmaDebugTraceStore`. Existing row kinds are `gemma_request`,
`gemma_response`, and `turn_trace`.

When diagnosing latency, group by `turnID` and `generationID`; compare runtime,
tool, tokenization, and persistence phases before assuming model decode is the
bottleneck.

## Git And Standards

- Use intentional conventional commits, e.g. `feat: add mock chat runtime`.
- Include `Fixes #<id>` in a second paragraph for issue-closing commits.
- Review diffs before committing; avoid generated files, build output, and
  unrelated changes.
- Use `just format`, `just lint`, and `just typos`.
- Add tests or focused verification for shared logic, patch application, prompt
  construction, command execution, and tool execution.
