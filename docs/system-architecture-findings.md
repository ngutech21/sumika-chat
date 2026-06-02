# System Architecture Findings

Date: 2026-06-02

This list captures the current system-level architecture findings for the codebase after
`1f0afa3 refactor: add typed tool runtime`. It is intentionally pragmatic: every finding is tied
to concrete files and describes a small incremental direction rather than a rewrite.

## Summary

The codebase is a SwiftUI/MVVM hybrid with service-oriented boundaries for runtime,
model lifecycle, stores, attachment loading, and tools. The largest remaining risks are in the
central UI-state orchestration, synchronous stores marked as `@unchecked Sendable`, a still
inconsistent tool-permission history, and partially UI-adjacent persistence/task coordination.

## Findings

| ID | Severity | Finding | Affected Files |
| --- | --- | --- | --- |
| A-01 | High | `ChatSessionController` is still an oversized UI-state orchestrator | `local-coder/Features/Chat/ChatSessionController.swift` |
| A-02 | High | Store implementations are synchronous and marked as `@unchecked Sendable` | `local-coder/Services/WorkspaceStore.swift`, `local-coder/Services/ModelSettingsStore.swift` |
| A-03 | Medium | Tool permission logic exists in two paths | `local-coder/Services/ToolExecution.swift`, `local-coder/Services/ToolPermissionEvaluator.swift` |
| A-04 | Medium | The approval flow is not implemented in the typed tool runtime path yet | `local-coder/Services/ToolExecution.swift` |
| A-05 | Medium | `AppState` couples navigation, session lifecycle, and persistence | `local-coder/App/AppState.swift` |
| A-06 | Medium | The tool loop still lives in `ChatSessionController` instead of a dedicated coordinator | `local-coder/Features/Chat/ChatSessionController.swift` |
| A-07 | Low | Tool-call parser recovery is controller-adjacent | `local-coder/Features/Chat/ChatSessionController.swift` |
| A-08 | Low | Model/workspace persistence is not actor-isolated yet | `local-coder/Services/WorkspaceStore.swift`, `local-coder/Services/ModelSettingsStore.swift` |

## Details

### A-01: `ChatSessionController` is still an oversized UI-state orchestrator

Severity: High

Affected files:

- `local-coder/Features/Chat/ChatSessionController.swift`

Evidence:

- The file still has `swiftlint:disable file_length` and is over 1000 lines long.
- The controller owns UI state, runtime coordination, model lifecycle, download state,
  context usage, attachments, tool prompting, the tool loop, and persistence callbacks.
- Examples: state and dependencies live in `ChatSessionController.swift:5-45`; the tool loop and
  prompt decision logic live in `ChatSessionController.swift:726-940`.

Risk:

- High change coupling for new features.
- Harder test isolation because many side effects are attached to the same type.
- Higher risk of stale task results and UI-state regressions.

Concrete solution:

- Continue the existing incremental extraction strategy.
- Move the tool loop into a `ToolLoopCoordinator`.
- Move prompt-mode/tool-intent decisions into a small `ToolPromptPolicy` type.
- Keep the controller as the SwiftUI state adapter.

Example refactoring:

```swift
struct ToolLoopRequest: Sendable {
  let assistantMessageID: UUID
  let workspace: Workspace
  let sessionID: CodingSession.ID
}

struct ToolLoopCoordinator: Sendable {
  func run(_ request: ToolLoopRequest, messages: [ChatMessage]) async throws -> ToolLoopResult
}
```

### A-02: Store implementations are synchronous and marked as `@unchecked Sendable`

Severity: High

Affected files:

- `local-coder/Services/WorkspaceStore.swift`
- `local-coder/Services/ModelSettingsStore.swift`

Evidence:

- `WorkspaceStore` is `@unchecked Sendable` and reads/writes synchronously with
  `Data(contentsOf:)` and `data.write(...)` (`WorkspaceStore.swift:8`,
  `WorkspaceStore.swift:22-40`).
- `ModelSettingsStore` is also `@unchecked Sendable` and mixes `UserDefaults` with synchronous
  file IO (`ModelSettingsStore.swift:42`, `ModelSettingsStore.swift:64-103`).

Risk:

- `@unchecked Sendable` moves thread-safety responsibility onto the developer.
- Synchronous IO can be called from MainActor paths.
- The read-modify-write flow in `ModelSettingsStore.save` can lose updates without serialization
  once multiple callers save concurrently.

Concrete solution:

- Gradually migrate store protocols to async APIs or introduce actor-backed implementations.
- Serialize persistence inside `actor WorkspaceStoreActor` and `actor ModelSettingsStoreActor`.
- Keep adapter methods for UI callers initially so views do not need a broad rewrite.

Example refactoring:

```swift
actor WorkspaceStoreActor: WorkspaceStoring {
  func loadLibrary() async -> WorkspaceLibrary
  func saveLibrary(_ library: WorkspaceLibrary) async throws
}
```

### A-03: Tool permission logic exists in two paths

Severity: Medium

Affected files:

- `local-coder/Services/ToolExecution.swift`
- `local-coder/Services/ToolPermissionEvaluator.swift`

Evidence:

- The new typed runtime path calls `TypedToolExecutor.evaluatePermission` through
  `AnyToolExecutor` (`ToolExecution.swift:25-34`).
- The old `ToolPermissionEvaluator` still exists and contains its own rules for `read_file`,
  `list_files`, `write_file`, `apply_patch`, and `run_command`
  (`ToolPermissionEvaluator.swift:3-68`).
- The workspace-ID guard was restored centrally in the active orchestrator path
  (`ToolExecution.swift:459-480`), but the remaining policies can still diverge.

Risk:

- Tests can cover the old evaluator while the active runtime path behaves differently.
- For new tools, it is unclear whether permission should live in the tool, in the evaluator, or in
  both places.

Concrete solution:

- Either remove `ToolPermissionEvaluator` or convert it into a shared `ToolPermissionPolicy` for
  reusable path/workspace checks.
- Focus tests on the active `ToolOrchestrator` path.

Example refactoring:

```swift
struct WorkspacePathPermissionPolicy: Sendable {
  func allowRead(path: String, in workspace: Workspace) -> ToolPermissionEvaluation
  func requireWriteApproval(path: String, in workspace: Workspace) -> ToolPermissionEvaluation
}
```

### A-04: The approval flow is not implemented in the typed tool runtime path yet

Severity: Medium

Affected files:

- `local-coder/Services/ToolExecution.swift`

Evidence:

- `AnyToolExecutor` currently only executes `.allowed`.
- Everything else fails closed as `.denied` (`ToolExecution.swift:31-45`).
- The inline comment documents that `.requiresApproval` must become an approval handoff when
  write/patch/command tools are introduced.

Risk:

- Once a typed write/command tool is registered, it cannot transition into a UI approval state.
- The active runtime path loses the distinction between "denied" and "requires approval".

Concrete solution:

- Switch explicitly on `evaluation.decision`.
- Map `.requiresApproval` to `ToolCallStatus.awaitingApproval` and prevent execution.
- Introduce a separate `approveToolCall` runtime API for later execution.

Example refactoring:

```swift
switch evaluation.decision {
case .allowed:
  return await runAllowedTool()
case .requiresApproval:
  return makeAwaitingApprovalRecord(evaluation)
case .denied:
  return makeDeniedRecord(evaluation)
}
```

### A-05: `AppState` couples navigation, session lifecycle, and persistence

Severity: Medium

Affected files:

- `local-coder/App/AppState.swift`

Evidence:

- `AppState` is `@MainActor @Observable` and owns the workspace library, active selection,
  `ChatSessionController`, stores, and persistence callbacks (`AppState.swift:4-35`).
- Methods such as `addWorkspace`, `createSession`, and `selectSession` mutate navigation,
  sessions, persistence, and controller loading state in one type (`AppState.swift:61-124`).

Risk:

- New workspace/session features increase coupling between UI navigation and persistence.
- Session-switch edge cases are harder to test because persistence and controller snapshots are
  intertwined.

Concrete solution:

- Introduce a `WorkspaceSessionCoordinator` for workspace/session mutations.
- Keep `AppState` as an observable facade.
- Move persistence calls out of UI mutation methods into a dedicated coordinator.

### A-06: The tool loop still lives in `ChatSessionController` instead of a dedicated coordinator

Severity: Medium

Affected files:

- `local-coder/Features/Chat/ChatSessionController.swift`

Evidence:

- `runReadOnlyToolLoop` parses assistant content, annotates messages, executes tools, writes
  `ToolCallRecord`, creates `ToolResultModelMessage`, appends an assistant placeholder, and starts
  follow-up streaming (`ChatSessionController.swift:726-778`).

Risk:

- The app's core tool system is functionally important but still bound to UI-state mutation.
- Future multi-iteration, write approval, or provider-native tool calls will further grow the
  controller.

Concrete solution:

- Move tool-loop orchestration into `ToolLoopCoordinator`.
- Return mutations as events or a `ToolLoopResult` for the controller to apply.
- Keep the current `maxToolIterations = 1` semantics initially.

### A-07: Tool-call parser recovery is controller-adjacent

Severity: Low

Affected files:

- `local-coder/Features/Chat/ChatSessionController.swift`

Evidence:

- `parseToolCallResult`, `recoverableToolActionContent`, and `singleFencedCodeBlockContent` live in
  the controller (`ChatSessionController.swift:780-858`).

Risk:

- Parser behavior and recovery rules are harder to reuse once JSON or provider-native tool calls
  are added.

Concrete solution:

- Move recovery into a decorator around the parser, for example `RecoveringToolCallParser`.
- The controller should only call `toolCallParser.parse(...)`.

### A-08: Model/workspace persistence is not actor-isolated yet

Severity: Low

Affected files:

- `local-coder/Services/WorkspaceStore.swift`
- `local-coder/Services/ModelSettingsStore.swift`

Evidence:

- Stores are plain classes with synchronous file IO and no internal queue/actor isolation.
- `@unchecked Sendable` is used, but there is no explicit serialization
  (`WorkspaceStore.swift:8`, `ModelSettingsStore.swift:42`).

Risk:

- This is probably controllable today because many calls come from the MainActor.
- During a future async migration, the same instance can be used concurrently.

Concrete solution:

- Introduce actor-backed store implementations first.
- Then remove `@unchecked Sendable` or limit it to adapters.
- Add tests for concurrent saves.

## Already Improved

- `ChatSessionController` is no longer the sole owner of runtime operation ordering;
  `RuntimeOperationCoordinator` serializes runtime operations.
- Model lifecycle and generation have already been extracted into `ModelLifecycleCoordinator` and
  `ChatGenerationCoordinator`.
- `read_file` now reads bounded previews instead of whole files.
- The tool system now has typed inputs, type erasure, a registry, and documentation in
  `docs/tool-runtime.md`.
- The active `ToolOrchestrator` now verifies that `ToolCallRequest.workspaceID` matches the active
  workspace.

## Recommended Order

1. Consolidate or remove `ToolPermissionEvaluator` so only one active permission path exists.
2. Model `.requiresApproval` in the typed runtime path as `awaitingApproval`.
3. Introduce `ToolLoopCoordinator` and move `runReadOnlyToolLoop` out of the controller.
4. Actor-isolate store implementations and reduce `@unchecked Sendable`.
5. Split `AppState` into an observable facade plus a workspace/session coordinator.
