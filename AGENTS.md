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

## Suggested Structure

For new code, prefer this shape unless the existing code clearly points elsewhere:

```text
local-coder/
  local_coderApp.swift
  App/
    AppState.swift
    AppCommands.swift
    AppEnvironment.swift
  Views/
    ContentView.swift
  Features/
    Chat/
    Workspace/
    PatchReview/
    ModelSettings/
  Models/
  Services/
    ModelService.swift
    PromptService.swift
    RepositoryService.swift
    PatchService.swift
    CommandService.swift
  Support/
    Extensions/
    Logging/
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
```

Run the unit test suite after every implementation task:

```sh
just test
```

If a task only changes docs or comments, explain why tests were not run. Otherwise, treat a passing test run as part of the task's definition of done.

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
