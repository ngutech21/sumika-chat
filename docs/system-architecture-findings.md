# System Architecture Findings

Date: 2026-06-02

This list captures the current system-level architecture findings for the codebase after the
typed tool runtime and explicit chat-turn lifecycle work. It is intentionally pragmatic: every
finding is tied to concrete files and describes an incremental direction rather than a rewrite.

## Summary

The codebase is a SwiftUI/MVVM hybrid with service-oriented boundaries for runtime,
model lifecycle, stores, attachment loading, and tools. The chat workflow now has an explicit
turn lifecycle with cancellation state and model-context filtering, which removes the largest
stale-task risk from generation cancellation. The main remaining risks are incomplete typed-tool
approval support, duplicate permission policy paths, UI-adjacent session persistence, and the
controller still applying many transcript mutations.

## Findings

| ID | Severity | Finding | Affected Files |
| --- | --- | --- | --- |
| A-01 | Medium | `ChatSessionController` is still a broad UI-state adapter | `local-coder/Features/Chat/ChatSessionController.swift` |
| A-02 | Medium | Tool permission logic exists in two paths | `local-coder/Services/ToolExecution.swift`, `local-coder/Services/ToolPermissionEvaluator.swift` |
| A-03 | Medium | The approval flow is not implemented in the typed tool runtime path yet | `local-coder/Services/ToolExecution.swift` |
| A-04 | Medium | `AppState` couples navigation, session lifecycle, and persistence | `local-coder/App/AppState.swift` |
| A-05 | Low | Stores are actor-isolated but still perform synchronous file IO internally | `local-coder/Services/WorkspaceStore.swift`, `local-coder/Services/ModelSettingsStore.swift` |
| A-06 | Low | Tool-loop transcript application remains controller-adjacent | `local-coder/Features/Chat/ChatSessionController.swift`, `local-coder/Features/Chat/ToolLoopCoordinator.swift` |

## Details

### A-01: `ChatSessionController` is still a broad UI-state adapter

Severity: Medium

Evidence:

- `ChatTurnCoordinator` now owns the active turn task and turn-ID gating, but
  `ChatSessionController` still applies transcript mutations, context refreshes, model state
  callbacks, attachment events, and persistence notifications.
- Generation, tool-loop, cancellation, and context-refresh events still meet in one observable
  type.

Risk:

- Future features such as write-tool approvals, multi-step plans, or per-turn review panes can
  grow the controller again.
- Tests still need to instantiate a large controller to verify some workflow behavior.

Concrete solution:

- Keep `ChatSessionController` as the SwiftUI-observable facade.
- Move transcript mutation application toward turn events emitted by `ChatTurnCoordinator`.
- Keep context filtering in `ChatModelContextBuilder` as the single model-context boundary.

### A-02: Tool permission logic exists in two paths

Severity: Medium

Evidence:

- The active typed runtime path evaluates permissions through each `TypedToolExecutor`.
- `ToolPermissionEvaluator` still exists with its own rules for read, list, write, patch, and
  command requests.

Risk:

- Tests or future features can accidentally cover one permission path while production behavior
  uses the other.
- New tools have an unclear policy home.

Concrete solution:

- Either remove `ToolPermissionEvaluator` or convert it into a shared reusable
  `WorkspacePathPermissionPolicy`.
- Focus tests on the active `ToolOrchestrator` path.

### A-03: The approval flow is not implemented in the typed tool runtime path yet

Severity: Medium

Evidence:

- `AnyToolExecutor` executes only `.allowed`.
- `.requiresApproval` currently falls into the denied branch instead of an awaiting-approval
  handoff.

Risk:

- Write, patch, and command tools cannot enter a reviewable approval state through the active
  typed runtime.
- The system can lose the product distinction between denied and requires approval.

Concrete solution:

- Switch explicitly on `ToolPermissionDecision`.
- Map `.requiresApproval` to `ToolCallStatus.awaitingApproval`.
- Add a separate approval API for executing approved tool calls.

### A-04: `AppState` couples navigation, session lifecycle, and persistence

Severity: Medium

Evidence:

- `AppState` owns the workspace library, active selection, chat controller, stores, and
  persistence callbacks.
- Workspace/session mutations still mix navigation changes, controller loading, snapshotting, and
  save scheduling.

Risk:

- Session switching, deletion, persistence, and future background operations remain highly
  coupled.

Concrete solution:

- Introduce a `WorkspaceSessionCoordinator` for workspace/session mutations.
- Keep `AppState` as an observable facade.
- Move persistence scheduling into a dedicated coordinator.

### A-05: Stores are actor-isolated but still perform synchronous file IO internally

Severity: Low

Evidence:

- `WorkspaceStore` and `ModelSettingsStore` are actors, so callers are serialized.
- The actual file reads and writes still use synchronous `Data(contentsOf:)` and `data.write(...)`.

Risk:

- This is acceptable for small local JSON files today.
- If store payloads grow, actor calls can still occupy executor time during disk IO.

Concrete solution:

- Keep actor isolation.
- Move larger future persistence work to async file APIs or detached IO inside the actor boundary.

### A-06: Tool-loop transcript application remains controller-adjacent

Severity: Low

Evidence:

- `ToolLoopCoordinator` parses and executes a read-only tool call.
- The controller still annotates the tool-call message, appends the tool result, registers turn
  message/tool IDs, and starts the follow-up generation.

Risk:

- Multi-iteration tool loops and approval flows will add more transcript-application cases.

Concrete solution:

- Evolve `ToolLoopCoordinator` to emit typed transcript events.
- Let the controller apply events through `ChatTranscriptMutator` without knowing each tool-loop
  step.

## Already Improved

- `ChatTurnCoordinator` owns the active generation task and turn ID.
- Cancelled turns are persisted as `ChatTurnRecord.status == .cancelled`.
- Cancelled tool-turn audit data remains visible but is excluded from future model context through
  `ChatModelContextBuilder`.
- `ChatMessage` now records `turnID` and `deliveryStatus` with migration-safe decode defaults.
- `WorkspaceStore` and `ModelSettingsStore` are actor-isolated.
- `ToolLoopCoordinator` and `ToolPromptPolicy` have been extracted from the controller.
- The typed tool system has typed inputs, type erasure, a registry, and documentation in
  `docs/tool-runtime.md`.

## Recommended Order

1. Model `.requiresApproval` in the typed runtime path as `awaitingApproval`.
2. Consolidate or remove `ToolPermissionEvaluator` so only one active permission path exists.
3. Move tool-loop transcript application to typed events.
4. Split `AppState` into an observable facade plus a workspace/session coordinator.
5. Revisit async file IO inside actor-backed stores if persisted payloads grow.
