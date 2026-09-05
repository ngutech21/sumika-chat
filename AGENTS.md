# AGENTS.md

## Project Goal

Sumika is a private macOS AI assistant running local Gemma and Qwen models through
MLX. Chat supports everyday assistance; Agent supports coding, files, and connected
tools. Keep context, tool actions, and network access explicit and inspectable,
with a macOS-native SwiftUI/AppKit UI. Do not assume network access is available
or desirable.

## Working Scope

- Analysis and review requests are read-only. For implementation requests, resolve
  routine choices within the requested scope and continue through verification.
  Ask only when missing information materially changes the result or required
  authorization is absent.
- Preserve unrelated user changes. Keep patches focused on the requested outcome.
- Tool approval and interaction-mode rules below describe Sumika's runtime.
- Report what changed, the checks actually run, and any remaining blocker. A
  skipped or blocked check is not a passing check.

## Architecture And Ownership

Follow the existing layout:

- Core logic: `Sources/SumikaCore/`
- Core unit tests: `Tests/SumikaCoreTests/`
- Core package-interface integration tests: `Tests/SumikaCoreIntegrationTests/`
- macOS app/UI/platform: `Sources/SumikaApp/`
- MLX runtime: `Sources/SumikaRuntimeMLX/`
- App tests: `Tests/SumikaAppTests/`
- MLX runtime tests: `Tests/SumikaRuntimeMLXTests/`
- Shared test helpers: `Tests/SumikaTestSupport/`
- Schema documentation generator: `Sources/DataModelGenerator/`
  and `Tests/DataModelGeneratorTests/`
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
- Do not create new top-level folders. Add only structure required by real code
  within the existing layout.

## Documentation Routing

Read the relevant contract before changing its behavior; update it when that
contract changes:

- Transcript, turn lifecycle, or model context: [chat runtime](docs/chat-runtime.md).
- Tool execution or permissions: [tool runtime](docs/tool-runtime.md).
- Agent continuation, budgets, or completion: [agent loop](docs/agent-loop.md).
- Persisted domain ownership: [model overview](docs/model.md).
- Storage formats, migrations, or recovery: [persistence](docs/persistence.md).
- Setup, dependencies, or contribution workflow: [contributing](CONTRIBUTING.md).

`docs/data-model.md` is the generated schema inventory. Regenerate it with
`just data-model` after schema changes and include the result; never edit it by hand.

## API And Module Design

- Default declarations to the narrowest access level that satisfies current
  callers. Add `public` or `package` API only for a concrete caller outside the
  owning target or module, and identify that caller before widening access.
- Keep public interfaces small and stable. Do not expose storage models, runtime
  details, helper types, intermediate workflow state, dependency internals, or
  mutation points merely for caller convenience.
- Keep protocols substitutable and role-specific, and high-level policy independent
  of vendor/platform implementations. A new abstraction needs a concrete caller,
  alternate implementation, test boundary, or independently changing owner.
- Prefer deep modules: small interfaces that hide implementation and enforce
  invariants. Avoid speculative protocols, factories, wrappers, dependency
  injection, and pass-through facades; reduce caller knowledge or coordination.
- Keep code near its canonical owner. Preserve cohesive vertical slices, such as
  the one-file-per-tool layout, when their inputs, validation, execution, and
  results change together. Move only genuinely shared policy or infrastructure
  into horizontal modules.
- Give each type one primary responsibility. Before extending it, check that new
  behavior shares its owner, lifecycle, invariants, and dependencies. Split unrelated
  responsibilities; file size alone does not justify splitting cohesive code.

## Refactoring Completion

A refactoring is complete only when the repository has one canonical path for the
refactored behavior:

- Migrate every in-scope caller to the new path.
- Remove replaced implementations, obsolete compatibility adapters and overloads,
  unused protocols, and stale flags, tests, fixtures, and documentation.
- Search explicitly for old type names, symbols, configuration keys, and call
  patterns after migration; do not assume compiler success proves cleanup.
- Do not retain parallel old and new architectures for hypothetical compatibility.
  A staged migration is allowed only when explicitly requested; document its
  remaining callers, temporary boundary, and deletion condition.
- Run dead-code analysis after structural refactors and inspect the final diff for
  additions without the corresponding expected deletions.

Before finishing a structural refactor or API change, summarize new or widened
APIs, new types and their responsibilities, old code removed, and any retained
legacy path with its concrete reason. State when no public API was added.

## Data Model Policy

Prefer clean ADTs and intentional `Codable` schemas. Keep persisted state minimal
and use a single source of truth (SSOT):

- Store each domain fact with one canonical owner, including its lifecycle state.
  Use stable IDs for references, not duplicated stored copies or parallel
  collections describing the same event.
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

- Register tools through the typed runtime; registry membership controls availability.
  Parsers emit neutral `ToolCallRequest` values; concrete tools receive typed inputs.
- Keep denied decisions distinct from approval-required decisions.
- Write, edit, command, and MCP tools must enter `awaitingApproval` in canonical
  `ChatTurn.items` before execution. The Agent session's manual or automatic
  `toolApprovalPolicy` determines whether to pause for human approval. Both paths
  revalidate before execution; neither bypasses denial or `ask_user`.
- Keep runtime termination separate from transcript delivery. When an
  output-limited batch has accepted complete tool calls, mark any streamed
  assistant prose and thinking complete before pausing or completing the turn,
  while preserving the output-limit termination instead of reporting normal
  generation completion.

## Workspace Interaction Modes

The chat composer has a manual `WorkspaceInteractionMode` per session:

- `chat`: normal conversation with public web tools only
  (`ToolExecutorRegistry.chatWeb`, `web_search`, `web_fetch`); no workspace
  tools, writes, shell commands, or local file access.
- `agent`: file, coding, and connected-tool workflows. Production composition uses
  `AgentToolConfiguration.executorRegistry(selectedMCPServerIDs:)` to combine
  configured built-ins and selected MCP servers, with the approval flow above.

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
- Check target isolation in `Package.swift` before changing concurrency boundaries.
  `SumikaApp` defaults to `MainActor` and enables `NonisolatedNonsendingByDefault`;
  Core and MLX runtime use complete strict-concurrency checking without those
  defaults. Do not assume an async function moves work off the main actor.
- Prefer narrow patches, focused tests, sparse useful comments, and ASCII source
  unless a file already uses non-ASCII for a reason.
- Support everyday Chat and Agent workflows with dense macOS-native layouts.
  Show model context, tool actions, and generated diffs where relevant, with clear
  loading/generating/cancelled/failed/applied states.
- Keep SwiftUI state at the smallest component that renders or mutates it.
  Root/container views should own only shell state such as selection, routing,
  window/sidebar layout, and command routing. Move fast-changing child-only
  state into dedicated hosts, especially streaming transcript text, console
  logs, terminal output, progress/resource usage, preview/debug refresh state,
  hover/drop state, and editor drafts. Before adding state or broad observable
  reads, identify what will be invalidated and avoid full-window invalidation
  for AX-sensitive panes such as `WKWebView`, terminals, and large scroll views.

## Build And Test

During implementation, use the narrowest feedback loop that covers the change:

- One target, suite, or test: use `swift test --filter <pattern>`.
- Package unit and integration tests: `just test`.
- Xcode app launcher, resources, embedding, or project wiring: `just build`.
- UI tests, accessibility IDs, launch test mode, model-loading UI, chat/agent UI,
  or MLX trace behavior used by UI tests: `just test-ui`.
- Cross-boundary changes spanning package logic and the Xcode shell: run both
  `just test` and `just build`.
- Concurrency or memory-safety work: use `just test-tsan` or `just test-asan` as
  relevant. Schema changes also require the documentation regeneration above.
- Add or update focused tests for shared logic, patch and prompt construction,
  command execution, and tool execution.

Before handing off code changes for review, complete `just final-check`: `typos`,
`format`, `lint`, `periphery`, and the full SwiftPM test suite. Run only missing
checks if equivalent coverage already passed against unchanged code; a focused
test does not replace the full suite. Repeat or broaden verification only when
changes, failures, or unresolved concerns justify it.

`just format` checks formatting; `just format-fix` rewrites it. `periphery` performs
SwiftPM and Xcode builds and does not replace required `just build` or `just test-ui`
checks above. UI tests are local-only, must never download a model, and should skip
cleanly when the configured model is absent. For docs/comments-only changes, run
`just typos` and explain why builds and tests were skipped.

After product dependency changes, run `just resolve-packages` and
`just check-package-locks`; include both root and Xcode `Package.resolved` files.
For the separate SwiftLint package, use `just resolve-swiftlint` and include
`script/swiftlint/Package.resolved`. Follow the lockfile policy in `README.md`.

## Debugging And Tracing

Use the project script before inventing new launch flows:

- `./script/build_and_run.sh --logs`: stream `Sumika` process logs.
- `./script/build_and_run.sh --telemetry`: stream `chat.sumika` subsystem logs.
- `./script/build_and_run.sh --trace`: enable tracing and print the timestamped
  output file under `~/Library/Application Support/Sumika/debug/traces/`.
- UI-test traces use the same directory. Follow the path printed by the run.
- Runtime trace fallback without a file/basename override:
  `~/Library/Application Support/Sumika/debug/mlx-trace.jsonl`.

Do not create additional chat/model performance trace formats. Extend
`MLXDebugTraceStore`. Existing row kinds are `mlx_request`,
`mlx_response`, and `turn_trace`.

When diagnosing latency, group by `turnID` and `generationID`; compare runtime,
tool, tokenization, and persistence phases before assuming model decode is the
bottleneck.

## Git And Standards

- Use intentional conventional commits, e.g. `feat: add mock chat runtime`.
- Include `Fixes #<id>` in a second paragraph for issue-closing commits.
- Review diffs before committing; avoid unrelated generated files, build output, and
  unrelated changes.
