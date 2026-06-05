# AGENTS.md

## Project Goal

`local-coder` is a macOS Swift app for generating and editing code locally with small Gemma models running through MLX. The product direction is similar to opencode, but optimized for smaller local models, limited context windows, local-first workflows, and fast iterative coding on a developer machine.

The app should make local coding agents practical even when the model is not as capable as a large hosted model. Prefer workflows that break tasks into small, inspectable steps, keep context focused, and make model output easy to review before applying changes.

## Product Principles

- Local-first: code, prompts, model calls, and project context should stay on the machine by default.
- Small-model aware: design prompts, context selection, and planning around constrained reasoning and smaller context windows.
- Reviewable edits: generated changes should be shown clearly before they are applied.
- Fast iteration: favor short model calls, focused file context, and incremental patches over large rewrites.
- Developer control: the user should be able to inspect commands, patches, logs, and model decisions.
- macOS-native: use SwiftUI/AppKit patterns that feel natural on macOS.

## Technical Direction

- Use Swift and SwiftUI for the app shell.
- Keep reusable product logic in the SwiftPM package `LocalCoderCore`.
- Keep the macOS app target as the UI/platform integration layer that imports `LocalCoderCore`.
- Keep MLX/Gemma integration isolated behind service boundaries.
- Treat model inference, prompt construction, repository indexing, command execution, and patch application as separate responsibilities.
- Prefer structured data between components instead of parsing informal strings.
- Keep shell execution explicit and auditable.
- Do not assume network access is available or desirable.

## Architecture Layout

The project is split into a headless SwiftPM core library and a macOS app target:

- `Package.swift` defines the `LocalCoderCore` library and `LocalCoderCoreTests` test target.
- `Sources/LocalCoderCore/` contains reusable, headless product logic. It should stay independent of SwiftUI, AppKit, and MLX-specific implementations so it can be built and tested with `swift test`.
- `Tests/LocalCoderCoreTests/` mirrors core behavior by domain. Add focused tests here for parsing, permission evaluation, persistence, runtime configuration, prompt construction, command/tool execution, and coordinator behavior.
- `local-coder/` contains the Xcode macOS app target. It imports `LocalCoderCore` and owns SwiftUI/AppKit views, app launch wiring, platform services, and MLX-backed implementations.
- `local-coder/local_coderApp.swift` is the application entry point. Keep launch wiring minimal and push app-wide state into `local-coder/App/`.
- `local-coder/ContentView.swift` and `local-coder/Views/` define the macOS shell: sidebar, empty states, and top-level layout. They should coordinate screens, not own model runtime or persistence behavior.
- `local-coder/App/` holds cross-feature app state and navigation selection. Add app-wide state here only when it truly spans multiple features.
- `local-coder/Features/` contains SwiftUI feature surfaces. `Features/Chat/` owns the visible coding workflow, transcript UI, composer UI, and tool summaries. `Features/ModelSettings/` owns model-management screens.
- `local-coder/Services/` contains app/platform integrations such as MLX/Gemma runtime access and Hugging Face model downloads. Keep these behind protocols defined in `LocalCoderCore` where possible.
- `Sources/LocalCoderCore/Models/` contains plain domain types passed between views, services, and tests. Prefer structured model types for messages, tool calls, workspaces, runtime configuration, context usage, and resource metrics.
- `Sources/LocalCoderCore/Services/` contains headless side-effect and integration boundaries: settings persistence, workspace persistence, attachment loading, process monitoring, tool parsing, tool permission checks, and command execution.
- `Sources/LocalCoderCore/Features/` contains non-UI feature orchestration and coordinators, especially chat/session/model lifecycle logic.
- `Sources/LocalCoderCore/Support/` contains small shared helpers that are not product features or service boundaries.
- `local-coderTests/` is reserved for future app-target tests that genuinely need the Xcode app target. Do not put headless core tests there.

Keep dependencies flowing in one direction: the app imports `LocalCoderCore`; `LocalCoderCore` must not import the app. Views call coordinators or app state; coordinators use services; services exchange structured models. Avoid making SwiftUI views parse model output, touch the filesystem directly, run shell commands, or know MLX details.

## Architecture Guardrails

- Do not add more responsibilities to a single controller. Keep controllers moving toward SwiftUI state adapters while tool loops, prompt policy, model lifecycle, and runtime operations live in focused coordinators.

## Data Model Policy

Local Coder is an unreleased prototype. Do not add backwards compatibility, migrations, legacy decode paths, or fallback fields for old persisted sessions unless explicitly requested.

Prefer clean ADTs, single sources of truth, and derived projections over duplicated stored state.

### SwiftUI Controller Boundaries

SwiftUI controllers should be observable UI facades: hold view state, expose small user-action methods, call coordinators/services, and map their events or results back into view state.

SwiftUI controllers must not own domain rules, permission policy, path validation, prompt construction, provider parsing/rendering, persistence internals, model/runtime details, shell execution, file IO, security-scoped bookmark handling, complex invariants, or multi-step workflow logic.

Workflow lifecycle belongs in coordinators. Typed execution, side effects, persistence, and platform integrations belong in services/executors. Consistency-sensitive mutation belongs in domain mutators/services. Context and prompt selection belong in builders/policies.

If logic can be meaningfully tested without SwiftUI, it probably does not belong in a SwiftUI controller. Controllers may express user intent; they should not know the internal steps needed to enforce invariants, resume workflows, or repair state.

- Prefer moving reusable behavior into `LocalCoderCore` before adding more app-target logic. Keep the app target focused on UI and platform adapters.
- Do not add SwiftUI, AppKit, or MLX imports to `Sources/LocalCoderCore`. If core needs model inference, depend on `ChatModelRuntime`-style protocols and implement platform backends in `local-coder/Services/`.
- Follow `docs/tool-runtime.md` when adding or changing tools. Tools should be registered through the typed runtime, own their typed input, permission evaluation, and execution, and be tested for decoding, permission, execution, registry visibility, and security-sensitive failure modes.
- Preserve the tool-runtime separation of concerns: parsers emit neutral `ToolCallRequest` values, registry membership controls tool availability, and concrete tools receive typed inputs instead of parsing tagged text, JSON, or provider-native payloads themselves.
- Preserve the distinction between denied tools and tools that require approval. Write, patch, and command tools must move to an awaiting-approval state before execution, not fail closed silently or auto-run.
- Avoid adding synchronous file IO or `@unchecked Sendable` stores. New persistence code should be async or actor-isolated, especially for read-modify-write flows.
- Keep `AppState` as an observable facade. New workspace/session behavior should move toward dedicated coordinators instead of coupling navigation, persistence, and controller loading in one type.
- Update `docs/tool-runtime.md` when the tool runtime contract changes.

## Suggested Structure

For new code, follow the current layout unless the surrounding code clearly points elsewhere:

```text
Package.swift
Sources/
  LocalCoderCore/
    Features/
      Chat/
      ModelSettings/
    Models/
    Services/
    Support/
Tests/
  LocalCoderCoreTests/
local-coder/
  local_coderApp.swift
  ContentView.swift
  App/
  Views/
  Features/
    Chat/
    ModelSettings/
    <NewFeature>/
  Services/
local-coderTests/
```

Start small. Do not introduce all folders up front unless there is real code to put in them.

## Implementation Guidance

- Keep SwiftUI views focused on layout and user interaction.
- Put app state, model orchestration, and side effects outside views.
- Use async/await for model calls, file IO, and command execution.
- Make long-running operations cancellable.
- Stream model output when possible.
- Preserve user changes in the working tree. Never overwrite or revert unrelated edits.
- Prefer narrow patches over broad file rewrites.
- Add logging around model loading, prompt construction, command execution, and patch application.

## Code Style

- Prefer small SwiftUI views composed from private subviews or helper methods when layout grows.
- Keep `@State` local to view-only concerns; put shared workflow state in controllers, coordinators, stores, or `AppState`.
- Prefer dependency injection through initializers for services and coordinators so tests can use fakes.
- Keep service APIs async and structured. Return domain models or typed results instead of raw strings when possible.
- Prefer Swift's type system for variant data: use enums with associated values and small payload structs when they make invalid states unrepresentable. Avoid stringly typed APIs and ad hoc dictionaries for domain concepts, but do not introduce extra abstractions when a simple typed value is enough.
- For persisted domain models, keep `Codable` schemas intentional and covered by tests. Use synthesized `Codable` only when the encoded shape is not part of the app's compatibility, migration, or debugging surface; otherwise define explicit coding keys or custom encoding.
- Use `throws` for recoverable failures and surface user-facing error text at the UI boundary.
- Avoid singletons for app services unless they wrap immutable platform facilities.
- Keep model-runtime code behind `ChatModelRuntime`-style protocols so MLX/Gemma backends remain swappable.
- Do not put parsing, permission decisions, filesystem writes, or process execution directly in SwiftUI views.
- When adding headless tests, put them in `Tests/LocalCoderCoreTests` and run them with `xcrun swift test`.
- Put tests in `local-coderTests` only when they need the app target, SwiftUI/AppKit integration, or MLX-specific behavior that cannot run headless.
- Prefer behavior-focused test names and test through public/service boundaries instead of private implementation details.

## MLX and Gemma Guidance

- Assume models may be small, quantized, slow to load, and limited in context.
- Build prompts from the smallest useful project context.
- Prefer explicit task decomposition before asking the model to write code.
- Include relevant file snippets, symbols, and diagnostics instead of dumping whole repositories.
- Keep model/provider code swappable so different Gemma or MLX backends can be tested.
- Surface model path, quantization, context length, token limits, and runtime errors in the UI.

## UX Guidance

- The primary screen should be the coding workflow, not a landing page.
- Use a practical macOS layout: sidebar for workspace/session navigation, main area for chat or task flow, inspector/review pane for patches and context.
- Show what context is being sent to the model.
- Show generated diffs before applying them.
- Provide clear states for loading model, generating, cancelled, failed, and applied.
- Avoid decorative UI that reduces information density.

## Build and Run

The reusable core is a SwiftPM package:

```sh
xcrun swift build
xcrun swift test
```

`just test-core` runs the headless SwiftPM unit tests. CI also runs the headless core tests directly with `xcrun swift test`, not through `just`.

Use the project script when available:

```sh
./script/build_and_run.sh
./script/build_and_run.sh --verify
```

The app is an Xcode macOS project:

```sh
xcodebuild -project local-coder.xcodeproj -scheme local-coder -destination "platform=macOS" build
```

Use Xcode/xcodebuild when building or packaging the macOS app, checking app-target integration, or testing code that depends on SwiftUI/AppKit/MLX. Use SwiftPM for core changes and headless CI tests.

`just test-app` runs the Xcode app test target locally. `just test` runs both `test-core` and `test-app`.

The repository also has local-only XCUITests in `local-coderUITests/` for end-to-end app flows that need the real macOS UI and real MLX/Gemma runtime. Run them explicitly with:

```sh
just ui-test
```

`just ui-test` uses the `local-coder-ui-tests` scheme and enables `LOCAL_CODER_DEBUG_TRACE=1`. It is intentionally not part of `just test`, `just test-app`, `just final-check`, or CI. These tests currently use `gemma3-27b` from the existing app model cache and must never download a model. If the local cache is missing, especially `~/Library/Containers/ngutech21.local-coder/Data/Library/Application Support/local-coder/Models/gemma3-27b/config.json`, the UI tests should skip cleanly.

Choose the narrowest test task that matches the change:

- For changes only under `Sources/LocalCoderCore/`, `Tests/LocalCoderCoreTests/`, or `Package.swift`, run `just test-core`.
- For changes only under `local-coder/` or `local-coderTests/`, run `just test-app`.
- For changes to `local-coderUITests/`, UI accessibility identifiers, app launch test mode, model-loading UI, chat/inspect UI flows, or Gemma trace behavior used by the UI tests, run `just ui-test` locally.
- For changes that cross the Core/App boundary, change project wiring, or alter shared build/test configuration, run `just test`.
- CI intentionally runs only `xcrun swift test` so GitHub Actions stays headless.

Prefer the project task runner for routine local checks:

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
```

Use `just data-model` to regenerate the SwiftSyntax-derived core data model documentation in `docs/data-model.md`.
Use `just coverage` when you need an Xcode code coverage report. It runs the test suite with coverage enabled and prints the latest `.xcresult` report via `xcrun xccov`.
Use `just coverage-low threshold=80` for a compact local-source report that only lists files and functions below the chosen coverage percentage. It filters the `xccov` JSON report with the Swift script in `script/`.

Run the final check after every implementation task:

```sh
just final-check
```

If a task only changes docs or comments, explain why final checks were not run. Otherwise, treat a passing final-check run as part of the task's definition of done.

## Workspace Interaction Modes

The chat composer uses a manual `WorkspaceInteractionMode` for each coding session:

- `chat`: default mode for normal conversation. Do not render tool schemas, do not run the tool loop, and keep the system prompt short.
- `inspect`: read-only workspace help. Render only read-only tool instructions and execute only the `ToolExecutorRegistry.readOnly` registry (`read_file`, `show_file`, `list_files`, `glob_files`, `search_files`).
- `agent`: full coding-agent workflow. Render the full coding tool prompt and use `ToolExecutorRegistry.codingAgent`, including write/edit tools and the approval flow.

Do not decide tool availability with keyword checks such as `prompt.contains("file")`. Mode is product/session state selected by the user, and V1 has no auto-router. If auto-routing is added later, keep it separate from the stable per-turn mode and avoid changing tool schemas unpredictably mid-turn.

Persist the mode on `CodingSession`, keep it in `ChatSessionState`, and default legacy sessions without a stored mode to `.chat`. Trace `turn_trace.interactionMode` so latency analysis can compare chat, inspect, and agent prompts.

## Debugging and Tracing

Use the project script for local app debugging before inventing new launch flows:

```sh
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
./script/build_and_run.sh --trace
```

- `--logs` launches the app and streams process logs for `local-coder`.
- `--telemetry` launches the app and streams logs for subsystem `ngutech21.local-coder`.
- `--trace` launches the app binary with `LOCAL_CODER_DEBUG_TRACE=1` and prints the Gemma trace path.

The debug trace is a single JSONL file:

```text
~/Library/Containers/ngutech21.local-coder/Data/Library/Application Support/local-coder/debug/gemma-trace.jsonl
```

Do not create a second trace file for chat/model performance. Extend `GemmaDebugTraceStore` and keep all debug trace rows in `gemma-trace.jsonl`.

Existing row kinds:

- `gemma_request`: model request metadata, rendered prompt, history, generation settings, and context limit.
- `gemma_response`: model output, generation metrics, and optional runtime error.
- `turn_trace`: structured performance spans without prompt, output, or file contents.

`turn_trace` rows are emitted only when `LOCAL_CODER_DEBUG_TRACE=1`. They should contain timing and size metadata such as `turnID`, `generationID`, `phase`, `durationMs`, `promptBytes`, `promptTokens`, `messageCount`, `toolLoopIteration`, `toolName`, `ttftMs`, `tokensPerSecond`, `cacheMode`, and `interactionMode`. Keep `promptTokens` limited to token counts already computed for normal app behavior; do not add extra tokenization only for tracing.

Stable `turn_trace.phase` values:

- `context_build`
- `tokenize_context_usage`
- `render_system_prompt`
- `runtime_stream_start`
- `runtime_ttft`
- `runtime_decode`
- `runtime_partial_decode`
- `tool_parse`
- `tool_execute`
- `ui_flush`
- `persist`
- `memory_clear`

When diagnosing latency, group rows by `turnID` and `generationID`. Compare `runtime_ttft`, `runtime_decode`, `runtime_partial_decode`, `tool_execute`, `tokenize_context_usage`, and `persist` before assuming the model decode path is the bottleneck. `runtime_partial_decode` is expected when the app stops consuming a generation after detecting one complete tool-action block before the runtime emits normal completion metrics.

## Git

- Use intentional commits: each commit should describe one coherent change and avoid bundling unrelated work.
- Write commit messages with a lowercase conventional prefix and a lowercase imperative subject, for example `feat: add mock chat runtime`.
- For commits that complete a GitHub issue, include a second paragraph with `Fixes #<id>` so GitHub closes the issue when the commit is merged or pushed to the default branch.
- Prefer prefixes such as `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, and `build`.
- Review the diff before committing so generated files, build output, and unrelated user changes are not included accidentally.

## Coding Standards

- Prefer ASCII in source files unless the file already uses non-ASCII text for a reason.
- Keep comments sparse and useful.
- Use clear names over clever abstractions.
- Use `just format` to format Swift sources with `swift-format`.
- Use `just lint` to lint Swift sources with SwiftLint.
- Use `just typos` to check spelling with project-specific allowlisted words.
- Add tests or focused verification when touching shared logic, patch application, prompt construction, or command execution.
- Keep generated files, build output, and DerivedData out of source control.
