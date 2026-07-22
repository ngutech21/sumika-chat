# AGENTS.md

## Project Goal

`sumika-chat` is the repository for Sumika, a macOS Swift app for local-first
coding with local Gemma and Qwen models running through MLX. Keep workflows
focused, inspectable, reviewable, and explicit: local context, short steps,
auditable shell execution, and macOS-native SwiftUI/AppKit UI. Do not assume
network access is available or desirable.

## Architecture And Ownership

Follow the existing layout:

- Core logic: `Sources/SumikaCore/`
- Core unit tests: `Tests/SumikaCoreTests/`
- Core package-interface integration tests: `Tests/SumikaCoreIntegrationTests/`
- macOS app/UI/platform: `Sources/SumikaApp/`
- MLX runtime: `Sources/SumikaRuntimeMLX/`
- App tests: `Tests/SumikaAppTests/`
- MLX runtime tests: `Tests/SumikaRuntimeMLXTests/`
- Xcode app launcher/resources: `sumika/`
- UI tests: `SumikaUITests/`

- Keep dependencies one-way: `SumikaApp` -> `SumikaRuntimeMLX` -> `SumikaCore`;
  `SumikaApp` may also use `SumikaCore` directly.
- Keep agent/domain workflows, models, policies, and vendor-neutral protocols in
  `SumikaCore`. It must not import SwiftUI, AppKit, MLX, SwiftTreeSitter, or
  TreeSitter language modules, or depend on Tree-sitter products/scanner targets.
- Keep MLX/Gemma/Qwen backends in `SumikaRuntimeMLX` behind core protocols. Keep
  presentation-specific backends such as Tree-sitter highlighting in `SumikaApp`.
- Views call controllers or app state; controllers are thin UI facades that call
  coordinators/services and map results to UI. Views must not parse model output,
  access files, run commands, make permission decisions, or know MLX details.
- Workflow lifecycle belongs in coordinators; execution, side effects,
  persistence, and platform integration in services/executors; context and prompt
  selection in builders/policies.
- Testability does not determine ownership. Keep presentation, vendor, runtime,
  and platform adapters outside core even when independently testable.
- SwiftPM owns package tests, sanitizers, and coverage. Xcode owns only the app
  launcher/resources and UI tests. Production launch code must not detect a unit
  test host or construct test adapters; package tests inject adapters at seams.
- Do not create new top-level folders, empty abstractions, or speculative layers.
  Start with the smallest structure required by real code.

## API And Module Design

- Default declarations to the narrowest access level that satisfies current
  callers. Add `public` or `package` API only for a concrete caller outside the
  owning target or module, and identify that caller before widening access.
- Keep public interfaces small and stable. Do not expose storage models, runtime
  details, helper types, intermediate workflow state, dependency internals, or
  mutation points merely for caller convenience.
- Apply SOLID at concrete boundaries: keep responsibilities cohesive, protocols
  substitutable and role-specific, and high-level policy independent of vendor or
  platform implementations. Do not introduce a seam without a concrete caller,
  alternate implementation, test boundary, or independently changing owner.
- Prefer deep modules: a small interface should hide substantial implementation
  detail and enforce its own invariants. Directory depth, file count, wrapper
  count, and forwarding layers do not make a module deep.
- Do not add speculative protocols, factories, wrappers, dependency injection, or
  pass-through facades. An abstraction must reduce caller knowledge or coordination,
  not merely rename or forward another API.
- Keep code near its canonical owner. Preserve cohesive vertical slices, such as
  the one-file-per-tool layout, when their inputs, validation, execution, and
  results change together. Move only genuinely shared policy or infrastructure
  into horizontal modules.
- Give each type one primary responsibility and one reason to change. Before
  extending a large controller, coordinator, service, store, or runtime, verify
  that the new behavior shares its owner, lifecycle, invariants, and dependencies.
  Split unrelated responsibilities instead of growing a god type.
- Line counts and file sizes are review signals, not design goals. Do not split a
  cohesive implementation into shallow types solely to satisfy a size metric.

## Refactoring Completion

A refactoring is complete only when the repository has one canonical path for the
refactored behavior:

- Migrate every in-scope caller to the new path.
- Remove replaced implementations, compatibility adapters, obsolete overloads,
  unused protocols, stale flags, tests, fixtures, and documentation.
- Search explicitly for old type names, symbols, configuration keys, and call
  patterns after migration; do not assume compiler success proves cleanup.
- Do not retain parallel old and new architectures for hypothetical compatibility.
  A staged migration is allowed only when explicitly requested; document its
  remaining callers, temporary boundary, and deletion condition.
- Run dead-code analysis after structural refactors and inspect the final diff for
  additions without the corresponding expected deletions.
- Preserve unrelated user changes while cleaning the complete refactoring scope.

Before finishing a structural refactor or API change, summarize new or widened
APIs, new types and their responsibilities, old code removed, and any retained
legacy path with its concrete reason. State when no public API was added.

## Data Model Policy

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
- Model-facing prompts are derived projections from the turn SSOT. Keep
  prompt-affecting facts with their canonical owner, such as
  `UserTurnMessage.promptContext`, tool results on `ToolCallRecord`, and
  assistant content/projection policy on `AssistantTurnMessage`; do not persist
  a separate prompt ledger.
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

Use the project task runner and the narrowest feedback loop that covers the change:

- One target, suite, or test: use `swift test --filter <pattern>`.
- Package unit and integration tests: `just test`.
- Xcode app launcher, resources, embedding, or project wiring: `just build`.
- UI tests, accessibility IDs, launch test mode, model-loading UI, chat/agent UI,
  or MLX trace behavior used by UI tests: `just test-ui`.
- Cross-boundary changes spanning package logic and the Xcode shell: run both
  `just test` and `just build`.
- Concurrency or memory-safety work: use `just test-tsan` or `just test-asan` as
  relevant. Data-model schema changes must run `just data-model`.
- Add or update focused tests for shared logic, patch and prompt construction,
  command execution, and tool execution.

For final verification after implementation, prefer `just final-check`; it runs
`typos`, `format`, `lint`, `periphery`, and `test`. If an equivalent focused test
already passed, run only the missing checks instead of repeating it. For docs or
comments only, explain why build/tests were skipped and run the narrowest relevant
check, such as `just typos`.

After dependency changes, run `just resolve-packages`, commit both lockfiles, and
follow the lockfile policy in `README.md`. UI tests are local-only, must never
download a model, and should skip cleanly when the configured model is absent.

## Debugging And Tracing

Use the project script before inventing new launch flows:

- `./script/build_and_run.sh --logs`: stream `Sumika` process logs.
- `./script/build_and_run.sh --telemetry`: stream `chat.sumika` subsystem logs.
- `./script/build_and_run.sh --trace`: run with `SUMIKA_DEBUG_TRACE=1`.
- Normal trace: `~/Library/Application Support/Sumika/debug/mlx-trace.jsonl`.
- UI-test traces: `~/Library/Application Support/Sumika/debug/traces/`.

Do not create additional chat/model performance trace formats. Extend
`MLXDebugTraceStore`. Existing row kinds are `mlx_request`,
`mlx_response`, and `turn_trace`.

When diagnosing latency, group by `turnID` and `generationID`; compare runtime,
tool, tokenization, and persistence phases before assuming model decode is the
bottleneck.

## Git And Standards

- Use intentional conventional commits, e.g. `feat: add mock chat runtime`.
- Include `Fixes #<id>` in a second paragraph for issue-closing commits.
- Review diffs before committing; avoid generated files, build output, and
  unrelated changes.
