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
- Keep MLX/Gemma integration isolated behind service boundaries.
- Treat model inference, prompt construction, repository indexing, command execution, and patch application as separate responsibilities.
- Prefer structured data between components instead of parsing informal strings.
- Keep shell execution explicit and auditable.
- Do not assume network access is available or desirable.

## Architecture Layout

The app is organized around a small SwiftUI shell, feature-specific UI and orchestration, shared data models, and side-effecting services:

- `local_coderApp.swift` is the application entry point. Keep launch wiring minimal and push app-wide state into `App/`.
- `ContentView.swift` and `Views/` define the macOS shell: sidebar, empty states, and top-level layout. They should coordinate screens, not own model runtime or persistence behavior.
- `App/` holds cross-feature app state and navigation selection. Add app-wide state here only when it truly spans multiple features.
- `Features/` contains vertical product areas. `Features/Chat/` owns the main coding workflow, including transcript UI, composer UI, chat session coordination, model lifecycle coordination, and runtime operation coordination. `Features/ModelSettings/` owns model-management screens.
- `Models/` contains plain domain types passed between views, services, and tests. Prefer structured model types for messages, tool calls, workspaces, runtime configuration, context usage, and resource metrics.
- `Services/` contains side effects and integration boundaries: MLX/Gemma runtime access, model downloads and settings persistence, workspace persistence, attachment loading, process monitoring, tool parsing, tool permission checks, and command execution.
- `Support/` contains small shared helpers that are not product features or service boundaries.
- `local-coderTests/` mirrors behavior by domain. Add focused tests next to the responsibility being changed, especially for parsing, permission evaluation, persistence, runtime configuration, and command/tool execution.

Keep dependencies flowing in one direction: views call coordinators or app state; coordinators use services; services exchange structured models. Avoid making SwiftUI views parse model output, touch the filesystem directly, run shell commands, or know MLX details.

## Architecture Guardrails

- Do not add more responsibilities to a single controller. Keep controllers moving toward SwiftUI state adapters while tool loops, prompt policy, model lifecycle, and runtime operations live in focused coordinators.
- Follow `docs/tool-runtime.md` when adding or changing tools. Tools should be registered through the typed runtime, own their typed input, permission evaluation, and execution, and be tested for decoding, permission, execution, registry visibility, and security-sensitive failure modes.
- Preserve the tool-runtime separation of concerns: parsers emit neutral `ToolCallRequest` values, registry membership controls tool availability, and concrete tools receive typed inputs instead of parsing tagged text, JSON, or provider-native payloads themselves.
- Preserve the distinction between denied tools and tools that require approval. Write, patch, and command tools must move to an awaiting-approval state before execution, not fail closed silently or auto-run.
- Avoid adding synchronous file IO or `@unchecked Sendable` stores. New persistence code should be async or actor-isolated, especially for read-modify-write flows.
- Keep `AppState` as an observable facade. New workspace/session behavior should move toward dedicated coordinators instead of coupling navigation, persistence, and controller loading in one type.
- Update `docs/tool-runtime.md` when the tool runtime contract changes.

## Suggested Structure

For new code, follow the current layout unless the surrounding code clearly points elsewhere:

```text
local-coder/
  local_coderApp.swift
  ContentView.swift
  App/
  Views/
  Features/
    Chat/
    ModelSettings/
    <NewFeature>/
  Models/
  Services/
  Support/
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
- Use `throws` for recoverable failures and surface user-facing error text at the UI boundary.
- Avoid singletons for app services unless they wrap immutable platform facilities.
- Keep model-runtime code behind `ChatModelRuntime`-style protocols so MLX/Gemma backends remain swappable.
- Do not put parsing, permission decisions, filesystem writes, or process execution directly in SwiftUI views.
- When adding tests, prefer behavior-focused test names and test through public/service boundaries instead of private implementation details.

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

Use the project script when available:

```sh
./script/build_and_run.sh
./script/build_and_run.sh --verify
```

The app is an Xcode macOS project:

```sh
xcodebuild -project local-coder.xcodeproj -scheme local-coder -destination "platform=macOS" build
```

Prefer the project task runner for routine local checks:

```sh
just build
just test
just lint
just format
just coverage
just coverage-low
just final-check
```

Use `just coverage` when you need an Xcode code coverage report. It runs the test suite with coverage enabled and prints the latest `.xcresult` report via `xcrun xccov`.
Use `just coverage-low threshold=80` for a compact local-source report that only lists files and functions below the chosen coverage percentage. It filters the `xccov` JSON report with the Swift script in `script/`.

Run the final check after every implementation task:

```sh
just final-check
```

If a task only changes docs or comments, explain why final checks were not run. Otherwise, treat a passing final-check run as part of the task's definition of done.

## Git

- Use intentional commits: each commit should describe one coherent change and avoid bundling unrelated work.
- Write commit messages with a lowercase conventional prefix and a lowercase imperative subject, for example `feat: add mock chat runtime`.
- Prefer prefixes such as `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, and `build`.
- Review the diff before committing so generated files, build output, and unrelated user changes are not included accidentally.

## Coding Standards

- Prefer ASCII in source files unless the file already uses non-ASCII text for a reason.
- Keep comments sparse and useful.
- Use clear names over clever abstractions.
- Use `just format` to format Swift sources with `swift-format`.
- Use `just lint` to lint Swift sources with SwiftLint.
- Add tests or focused verification when touching shared logic, patch application, prompt construction, or command execution.
- Keep generated files, build output, and DerivedData out of source control.
