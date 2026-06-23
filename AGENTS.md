# AGENTS.md

## Project Goal

`sumika-chat` is a macOS Swift app for local-first coding with small Gemma models
running through MLX. Keep workflows focused, inspectable, reviewable, and
explicit: local context, short steps, auditable shell execution, and macOS-native
SwiftUI/AppKit UI. Do not assume network access is available or desirable.

## Architecture Rules

Follow the existing layout:

- Core logic: `Sources/SumikaCore/`
- Core tests: `Tests/SumikaCoreTests/`
- macOS app/UI/platform/MLX: `sumika/`
- App tests: `SumikaTests/`
- UI/runtime tests: `SumikaUITests/`

Keep dependencies one-way: app -> `SumikaCore`. Views call controllers or app
state; controllers call coordinators/services; services exchange structured
models. SwiftUI views must not parse model output, touch the filesystem directly,
run shell commands, make permission decisions, or know MLX details.


Do not create new top-level folders or abstractions unless real code requires them.
Start small. Do not introduce empty folders or abstractions before there is real
code to put in them.

## Core/App Boundaries

- Keep reusable behavior in `SumikaCore`; keep MLX/Gemma backends in
  `sumika/Services/` behind core protocols.
- SwiftUI controllers are UI facades only: hold view state, expose small user
  actions, call coordinators/services, and map results back to UI.
- Workflow lifecycle belongs in coordinators. Execution, side effects,
  persistence, and platform integration belong in services/executors. Context and
  prompt selection belong in builders/policies.
- If logic can be tested without SwiftUI, it probably belongs in core.

## Data Model Policy

Sumika Chat is an unreleased prototype. Do not add backwards compatibility,
migrations, legacy decode paths, or fallback fields for old persisted sessions
unless explicitly requested.

Prefer clean ADTs, single sources of truth, derived projections, and intentional
`Codable` schemas covered by tests.

Keep the persisted data model minimal and SSOT-first:

- Store each domain fact in exactly one place. Do not keep parallel collections
  that can describe the same event or lifecycle state.
- Choose one canonical owner for every persisted concept and keep related
  lifecycle state with that owner. References between concepts should use stable
  IDs, not duplicated stored copies.
- Do not add convenience arrays, caches, summaries, or denormalized fields as
  persisted state when they mirror canonical data. Build UI timelines, prompt
  inputs, traces, summaries, and other read models as derived projections.
- For chat state, `ChatSession.turns` and `ChatTurn.items` are the persisted
  transcript and tool-state SSOT. Do not persist a parallel `toolCalls` list or a
  turn event log unless explicitly requested.
- `ModelContextSnapshot` is an intentional frozen model-facing copy. Keep it as
  the cache-stable prompt ledger, but do not use it as a reason to duplicate UI
  transcript or tool lifecycle state elsewhere.
- Enforce append-only turn membership in the model: append new user, assistant,
  and tool facts; update existing items only for their own lifecycle fields.
  Filter read models instead of deleting persisted transcript items.
- Before adding a stored field, identify the owner, lifecycle, invariants, and
  whether the value can be derived. If it can be derived cheaply and reliably,
  do not persist it.
- Add tests for data-model invariants when changing persisted schemas. Cover
  ordering, ownership, encode/decode round trips, and projection generation from
  the SSOT.

## Tool Runtime

Follow `docs/tool-runtime.md` when adding or changing tools.

Rules:

- Tools are registered through the typed runtime.
- Parsers emit neutral `ToolCallRequest` values.
- Registry membership controls availability.
- Concrete tools receive typed inputs.
- Denied tools and approval-required tools are distinct.
- Write, patch, and command tools must enter awaiting-approval before execution.
- Update `docs/tool-runtime.md` when the tool contract changes.

## Workspace Interaction Modes

The chat composer has a manual `WorkspaceInteractionMode` per session:

- `chat`: normal conversation with public web tools only
  (`ToolExecutorRegistry.chatWeb`, `web_search`, `web_fetch`); no workspace
  tools, writes, shell commands, or local file access.
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
- Keep SwiftUI state at the smallest component that renders or mutates it.
  Root/container views should own only shell state such as selection, routing,
  window/sidebar layout, and command routing. Move fast-changing child-only
  state into dedicated hosts, especially streaming transcript text, console
  logs, terminal output, progress/resource usage, preview/debug refresh state,
  hover/drop state, and editor drafts. Before adding state or broad observable
  reads, identify what will be invalidated and avoid full-window invalidation
  for AX-sensitive panes such as `WKWebView`, terminals, and large scroll views.

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
xcodebuild -project Sumika.xcodeproj -scheme Sumika -destination "platform=macOS" build
./script/build_and_run.sh
./script/build_and_run.sh --verify
```

CI intentionally runs only headless SwiftPM tests with `xcrun swift test`.
`just ui-test` is local-only, enables `SUMIKA_DEBUG_TRACE=1`, must never
download a model, and should skip cleanly if `gemma4-e4b` is missing. Use
`just data-model` to regenerate `docs/data-model.md`.

## Debugging And Tracing

Use the project script before inventing new launch flows:

```sh
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
./script/build_and_run.sh --trace
```

- `--logs`: stream process logs for `sumika-chat`.
- `--telemetry`: stream subsystem logs for `ngutech21.sumika-chat`.
- `--trace`: run with `SUMIKA_DEBUG_TRACE=1`.

Normal trace:

```text
~/Library/Application Support/sumika-chat/debug/gemma-trace.jsonl
```

UI-test per-run traces:

```text
~/Library/Application Support/sumika-chat/debug/traces/
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
