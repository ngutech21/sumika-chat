# System Architecture Findings

Date: 2026-06-15

This document captures a full system-level architecture, performance, type-safety,
and code-quality review of the codebase. It supersedes the 2026-06-02 review. Every
finding is tied to concrete files and describes an incremental direction rather than a
rewrite. Severity reflects user-visible/runtime impact and risk, not effort.

## Summary

The codebase is a SwiftUI/MVVM hybrid with strong service-oriented boundaries: a
headless `LocalCoderCore` SwiftPM library plus a macOS app target that owns
SwiftUI/AppKit and the MLX/Gemma backend. The typed tool runtime, explicit chat-turn
lifecycle, frozen append-only model-context ledger, and KV-cache reuse policy are
well-designed and well-documented. Type safety is generally excellent: no force
unwraps, `try!`, or `as!` were found in the reviewed surface, and discriminated-union
`Codable` ADTs are used consistently.

The remaining risks cluster in three areas:

1. **Render/recompute hot paths** — the chat transcript re-parses markdown and rebuilds
   derived collections on every streaming chunk, and context-usage/cache signatures
   re-tokenize or re-hash the full history per turn (O(n^2) over a session).
2. **Per-call regex compilation** in extraction/highlighting/linkifying code that runs
   per render or per keystroke.
3. **Coupling and stale seams** — `ChatSessionController` and `AppState` remain broad
   adapters, and several legacy/dead seams persist that this unreleased prototype does
   not need (see the Data Model Policy in `AGENTS.md`).

## Findings

| ID | Severity | Category | Finding | Affected Files |
| --- | --- | --- | --- | --- |
| P-01 | High | Perf | Chat transcript re-parses markdown + rebuilds derived items every streaming chunk | `local-coder/Features/Chat/ChatTranscript.swift` |
| P-02 | High | Perf | Context usage re-tokenizes the full history on every refresh (O(n^2)/session) | `Sources/LocalCoderCore/Features/Chat/ContextUsageCoordinator.swift`, `ChatSessionController.swift`, `ChatModelContextBuilder.swift` |
| P-03 | High | Perf | Per-call `NSRegularExpression` compilation in hot extraction/highlight/linkify paths | `Sources/LocalCoderCore/Services/WebAccess.swift`, `CodeHighlighting.swift`, `Support/URLTextLinkifier.swift`, `Services/ChatAttachmentLoader.swift` |
| P-04 | High | Perf | Edit-match path re-tokenizes file content and uses `String.distance` per lookup | `Sources/LocalCoderCore/Services/ToolEditExecution.swift` |
| P-05 | Medium | Perf | Full-history FNV cache signature re-hashed ~2x per turn (grows O(transcript)) | `local-coder/Services/GemmaMLXRuntime.swift`, `GemmaSessionCachePolicy.swift` |
| P-06 | Medium | Perf | O(n^2) span overlap filtering and whitespace collapsing | `Sources/LocalCoderCore/Services/CodeHighlighting.swift`, `ChatAttachmentLoader.swift` |
| P-07 | Medium | Perf | `refreshDebounced` does not debounce; no coalescing of usage refreshes | `Sources/LocalCoderCore/Features/Chat/ContextUsageCoordinator.swift` |
| P-08 | Medium | Perf | Command runner busy-polls `process.isRunning` every 20ms | `Sources/LocalCoderCore/Services/ToolCommandExecution.swift` |
| P-09 | Low | Perf | Whole library re-encoded to one JSON file on every mutation | `Sources/LocalCoderCore/Services/WorkspaceStore.swift`, `Models/Workspace.swift` |
| T-01 | High | TypeSafety | `AnyToolExecutor` recovers typed input via `as?` cast + 48-line name switch | `Sources/LocalCoderCore/Services/ToolExecution.swift` |
| T-02 | Medium | TypeSafety | Cache-debug UI compares raw `cacheMode`/`cacheReason` magic strings | `local-coder/Features/Chat/WorkspaceChatView.swift` |
| T-03 | Medium | TypeSafety | Trace fields (`toolCallFormat`, validation status, cacheMode) passed as raw strings | `Sources/LocalCoderCore/Features/Chat/ToolLoopCoordinator.swift`, `ChatSessionController.swift` |
| T-04 | Low | TypeSafety | `ToolName` is a stringly-typed struct; lists can drift without exhaustiveness | `Sources/LocalCoderCore/Models/ToolCall.swift`, `Services/ToolCallRequestValidator.swift` |
| T-05 | Low | TypeSafety | KVC `setValue(false, forKey: "drawsBackground")` on `WKWebView` | `local-coder/Features/Chat/HTMLPreview.swift` |
| Q-01 | High | Quality | `ToolPermissionEvaluator` is dead production code (only tests reference it) | `Sources/LocalCoderCore/Services/ToolPermissionEvaluator.swift` |
| Q-02 | Medium | Quality | A-01: `ChatSessionController` is a god type (1566 lines); approval/deny/answer flows duplicate skeletons | `Sources/LocalCoderCore/Features/Chat/ChatSessionController.swift` |
| Q-03 | Medium | Quality | A-04: `AppState` couples navigation, session lifecycle, persistence; 3x duplicated debounced-save | `local-coder/App/AppState.swift` |
| Q-04 | Medium | Quality | Duplicated logic across result projections and extraction (status maps, diagnostics render, host validation, UTF-8 suffix trimming) | `Sources/LocalCoderCore/Models/ToolCall.swift`, `Models/ToolResultProjection.swift`, `Services/WebAccess.swift`, `Services/WebContentExtraction.swift`, `Services/ToolCommandExecution.swift` |
| Q-05 | Low | Quality | Dead/placeholder seams: `activeAttachmentContextAttachments` returns `[]`; test-only `streamAssistantReply`; no-op `updateContextUsage` closure | `Sources/LocalCoderCore/Features/Chat/ChatSessionController.swift`, `ChatGenerationCoordinator.swift` |
| O-01 | Medium | Outdated | Legacy multi-format `TodoWriteInput` decoding (numbered fields + JSON-string + plain-text rows) | `Sources/LocalCoderCore/Services/ToolExecution.swift` |
| O-02 | Medium | Outdated | `DispatchGroup` + `loadItem(forTypeIdentifier:)` + `@unchecked Sendable` accumulator in an async codebase | `local-coder/Features/Chat/ChatComposer.swift` |
| O-03 | Low | Outdated | Legacy decode/migration shims not needed for an unreleased prototype | `Sources/LocalCoderCore/Support/AssistantMarkdownPreprocessor.swift`, `Services/ModelSettingsStore.swift`, `Features/Chat/Models/ChatSession.swift` |

## Details

### Performance

#### P-01: Chat transcript re-parses markdown + rebuilds derived items every chunk (High)

`ChatTranscript.transcriptItems` (`local-coder/Features/Chat/ChatTranscript.swift:67-128`)
runs a full `flatMap` over all turns, builds a `Dictionary` of every tool call, and
calls `AssistantMessageRenderBlocks.blocks(for:)` (markdown parsing) for every assistant
message on each `body` pass. Because `controller.chatSession.turns` mutates per streamed
token, the entire transcript — including markdown re-parse of all prior messages — is
rebuilt on every chunk. The property is also computed twice per pass (empty check at
line 16, body at line 30/131), and `onChange(of: items)` diffs the whole rendered array
(P-01b) including parsed blocks.

Fix: memoize parsed render blocks per message keyed by message id + content length, or
finalize blocks onto the turn model when content stops streaming; compute
`transcriptItems` once per pass; observe a lightweight anchor token (last item id +
count) for scroll instead of the full `items` array.

#### P-02: Context usage re-tokenizes the full history on every refresh (High)

`refreshContextUsage` rebuilds the whole transcript via
`ChatModelContextBuilder.transcript(from:)` and then `estimatedUsage()` walks
`projectedEntries(mode: .fullHistory)` re-encoding every entry's UTF-8 byte count from
scratch (`ContextUsageCoordinator.swift:36-54`, `ChatSessionController.swift:525-537,
628-669`). It is called at turn start, after each stream, after every tool-loop
iteration, on attachment add/remove, and on completion — so an N-entry history is fully
re-tokenized N times within one multi-iteration agent turn, giving O(n^2) growth over a
session.

Fix: the ledger is append-only (per the frozen-context design), so cache the cumulative
byte/token count and only add the delta for newly appended entries; memoize the built
`ModelContextSnapshot` keyed by `entries.count` / last-entry id.

#### P-03: Per-call `NSRegularExpression` compilation in hot paths (High)

- `WebAccess.swift:925-949` (`WebTextExtractor.plainText`) runs 5
  `replacingOccurrences(..., options: .regularExpression)` calls per invocation, each
  recompiling its pattern; `firstMatchGroups` (`:956-971`) recompiles per result block.
- `CodeHighlighting.swift:533-538` compiles the CSS dimension-unit pattern on every
  highlight pass (runs per keystroke during streaming).
- `URLTextLinkifier.swift:27` recompiles the URL pattern on every assistant message
  render; `ChatAttachmentLoader.swift:50` rebuilds the attachment-path pattern per draft
  change.

Fix: hoist all fixed patterns into `static let` precompiled `NSRegularExpression`
instances and reuse `stringByReplacingMatches`.

#### P-04: Edit-match path re-tokenizes content and uses `String.distance` per lookup (High)

`EditFileToolExecutor.validatedMatch` (`ToolEditExecution.swift:205-241`) runs up to 5
full-content match strategies; `lineSegments(in:)` (`:466-524`) re-tokenizes the whole
file inside every `lineWindowMatches` call (`:389-424`), and
`IndexedNormalizedText.sourceRange` (`:721-722`) calls `text.distance(from:to:)` (O(n))
per lookup, making normalized matching O(n*m) on large files.

Fix: tokenize content once and pass cached `[TextLine]` into all strategies; store
integer offsets instead of recomputing `String.distance`.

#### P-05: Full-history cache signature re-hashed per turn (Medium)

`GemmaMLXRuntime.contextSignature(for:)` (`:336-342, 437-443, 498-504`) +
`GemmaSessionCachePolicy.swift:445-470` iterate every byte of every message for the
whole history on each generation, and `cacheDecision` recomputes the signature again
(`GemmaSessionCachePolicy.swift:34-41`) — the full transcript is hashed ~2x per turn and
grows O(transcript bytes) every turn.

Fix: history is append-only, so keep a rolling/incremental hash of the consumed prefix
on `CachedGemmaSession` and hash only newly appended messages.

#### P-06: O(n^2) span filtering and whitespace collapsing (Medium)

`CodeHighlighting.nonOverlappingSpans` (`:499-511`) does `selectedSpans.contains { ... }`
per candidate — quadratic in span count; large code blocks generate thousands of spans
per highlight pass. `ChatAttachmentLoader.swift:243-245` rescans the whole string each
iteration of `while cleaned.contains("  ")`.

Fix: sort spans once and sweep with a running max upper-bound (O(n log n)); replace the
whitespace loop with a single compiled `" {2,}" -> " "` regex.

#### P-07: `refreshDebounced` does not debounce (Medium)

`ContextUsageCoordinator` accepts `debounceDelay` and `turnTracer` and immediately
discards both (`:75-76`); `refreshDebounced` (`:102-116`) calls the estimate
synchronously with no delay or coalescing. Combined with P-02, the many per-turn refresh
calls each do a full synchronous main-actor recount.

Fix: restore real debouncing (a delayed `Task` the next call cancels) or rename to
`refresh` and delete the dead `debounceDelay`/`turnTracer` parameters so the name stops
implying coalescing that does not happen.

#### P-08: Command runner busy-polls every 20ms (Medium)

`DefaultCommandProcessRunner` (`ToolCommandExecution.swift:381-395`) busy-waits on
`process.isRunning` in a 20ms sleep loop for the full command duration.

Fix: race `process.terminationHandler` (bridged to a continuation) against
`Task.sleep(timeout)` in a `withThrowingTaskGroup`.

#### P-09: Whole library re-encoded per mutation (Low)

`WorkspaceLibrary` serializes all workspaces/sessions/messages into one JSON file
(`Models/Workspace.swift:191-205`, `WorkspaceStore.swift:50-58`); every save is O(total
history). Synchronous `Data(contentsOf:)`/`Data.write(to:)` also block the actor's
executor (also in `ModelSettingsStore`, `ChatAttachmentStore`, `ChatAttachmentLoader`,
`WebAccess`).

Fix: split per-session/per-workspace persistence and move blocking IO off the
cooperative pool; note the scaling ceiling until then.

### Type Safety

#### T-01: `AnyToolExecutor` recovers typed input via `as?` cast (High)

`ToolExecution.swift:473-535` extracts the already-typed input out of `ToolCallPayload`
through a 48-line `typedInput` switch plus `input as? Input` keyed on
`definition.name == actualToolName`. A mismatch becomes a runtime `payloadMismatch`
throw instead of a compile error — stringly/runtime dispatch layered on an already-typed
ADT.

Fix: have each `TypedToolExecutor` provide `static func input(from: ToolCallPayload) ->
Input?`, or close over the extraction at `AnyToolExecutor` construction where `T.Input`
is statically known, removing the cast and the switch.

#### T-02: Cache-debug UI compares raw magic strings (Medium)

`RuntimeCacheDebugSection` (`WorkspaceChatView.swift:462-491`) compares
`snapshot.cacheMode == "session_reused"`, `.hasPrefix("invalidated_")`, and
`snapshot.cacheReason == "append_only_delta_reused"` against magic strings that duplicate
enum cases already defined in `GemmaSessionCacheTypes.swift`. Renaming a `rawValue`
silently breaks the UI.

Fix: carry typed enums on the snapshot (or expose typed accessors) instead of comparing
raw strings in the view.

#### T-03: Stringly-typed trace fields (Medium)

`ToolLoopCoordinator.swift:287-290` passes `toolCallFormat: "native"` and
`toolValidationStatus: "valid"/"invalid"`; `cacheMode` is threaded as `String?`. These
should be enums (`ToolCallFormat`, `ToolValidationStatus`) so typos cannot produce bad
trace data.

#### T-04: `ToolName` stringly-typed struct (Low)

`ToolCall.swift:5-39` makes `ToolName` a `RawRepresentable` struct of static constants.
The validator's `payload(for:)` and `builtInDefinition(for:)` both need `default:`
clauses and can silently drift. An enum with an `unknown(String)` case would give
exhaustiveness while still accepting arbitrary model output.

#### T-05: KVC on `WKWebView` (Low)

`HTMLPreview.swift:294` uses `setValue(false, forKey: "drawsBackground")`. Prefer the
public `underPageBackgroundColor`/`isOpaque` configuration.

### Code Quality

#### Q-01: `ToolPermissionEvaluator` is dead production code (High)

Confirmed: `ToolPermissionEvaluator` is referenced only by its own declaration and by
`Tests/LocalCoderCoreTests/ToolPermissionTests.swift`. Production permission logic lives
entirely in each `TypedToolExecutor.evaluatePermission`. The whole permission switch
(`ToolPermissionEvaluator.swift:17-134`) duplicates per-executor decisions and reason
strings.

Fix: delete `ToolPermissionEvaluator.swift` and repoint or remove its test (no
backwards-compat needed). This finally resolves former finding A-02.

#### Q-02: `ChatSessionController` god type (Medium)

Former finding A-01 remains. The 1566-line controller owns model-runtime callbacks,
attachment events, context-usage orchestration, runtime-context-clear plumbing
(`:561-614`), the tool loop (`:1337-1413`), and all approval/deny/answer flows
(`approveToolCall` :781, `runApprovedToolCall` :815, `answerAskUserToolCall` :974,
`denyToolCall` :1060), each hand-building near-identical `ChatWorkflowEvent` arrays and
the same start-turn/stream/finish skeleton (A-03/A-05).

Fix: extract a `ToolApprovalCoordinator` that returns `[ChatWorkflowEvent]` (mirroring
`ToolLoopCoordinator.executeToolCalls`); extract the `PendingRuntimeContextClear`
machinery; collapse the four `finish*ApprovedToolTurn` helpers and the `sendMessage`
catch block into one `completeTurn(_:outcome:)`.

#### Q-03: `AppState` coupling + duplicated debounced-save (Medium)

Former finding A-04 remains unaddressed (no `WorkspaceSessionCoordinator` exists).
`AppState` interleaves navigation/selection, controller loading, snapshotting, and three
near-identical debounced-save task chains (`:189-205, 207-224, 341-364`).

Fix: introduce `WorkspaceSessionCoordinator` for the persist→mutate→save→load sequence;
extract a generic `DebouncedPersistenceScheduler`; leave `AppState` a thin facade.

#### Q-04: Duplicated logic (Medium)

- Identical `ToolFailureReason` status maps: `ToolCall.swift:1683-1692` vs
  `ToolResultProjection.swift:929-937`.
- Identical diagnostics rendering: `ToolCall.swift:1525-1529` vs
  `ToolResultProjection.swift:833-837`.
- Three identical `resolvedHostValidationError` bodies: `WebAccess.swift:521-536,
  781-796`, `WebContentExtraction.swift:159-174`.
- Three near-identical UTF-8 partial-suffix trimmers: `ToolExecution.swift:1417-1434`,
  `ToolCommandExecution.swift:597-614, 616-633`.

Fix: collapse each set to a single shared helper.

#### Q-05: Dead/placeholder seams (Low)

- `activeAttachmentContextAttachments` (`ChatSessionController.swift:720-722`) always
  returns `[]` yet is read by `WorkspaceChatView.swift:61`.
- `ChatGenerationCoordinator.streamAssistantReply` (`:60-90`, String-returning) has no
  production callers; production uses `streamAssistantReplyResult`.
- The `updateContextUsage` closure threaded through the stream path is an empty
  `MainActor.run {}` no-op (`ChatSessionController.swift:1317-1319`).

Fix: implement or remove each seam.

### Outdated Code

`AGENTS.md` (Data Model Policy) states this is an unreleased prototype with no
backwards-compatibility, migrations, legacy decode paths, or fallback fields required —
so the items below are removal candidates.

#### O-01: Legacy multi-format `TodoWriteInput` decoding (Medium)

`TodoWriteInput.init(from:)` (`ToolExecution.swift:640-700` + helpers `:707-827`) tries
numbered `item1..6` fields, `[TodoItem]`, JSON-string `items`, JSON-string `[String]`,
plain-text rows, then `[String]` rows — the comment at `:698` marks the tail as legacy.
The model-facing schema (`ToolDefinition.todoWrite`, `:482-515`) advertises only the
numbered-field contract.

Fix: keep the numbered-field path; remove the string/rows legacy shims.

#### O-02: `DispatchGroup` drop/paste handler (Medium)

`ChatComposer.swift:459-494` uses `DispatchGroup.enter/leave` + `group.notify` + the
callback-style `NSItemProvider.loadItem(forTypeIdentifier:options:)` + an
`@unchecked Sendable` `AttachmentURLAccumulator` (`:637-652`) — legacy concurrency in an
otherwise async/await codebase.

Fix: load providers with async APIs in a `TaskGroup`, dropping the manual group and the
accumulator class.

#### O-03: Legacy decode/migration shims (Low)

- `AssistantMarkdownPreprocessor.normalizedLegacyDirectFileDisplay` (`:11, 28-88`) —
  legacy "Here is `…`:" direct-file-display path.
- `ModelSettingsStore.init(from:)` (`:18-32`) exists only to `decodeIfPresent` a fallback
  for `contextTokenLimit`.
- `ChatSession.resolvingInterruptedStreams` (`:102-104, 149-166`) — if its sole purpose
  is tolerating pre-existing persisted `.streaming` statuses it is a removal candidate;
  if it also guards crash-interrupted reloads, keep it but drop the "migration-safe"
  framing.

## Non-issues verified

- No force unwraps (`!`), `try!`, `as!`, or implicitly unwrapped optionals were found in
  the reviewed surface. `precondition`/`preconditionFailure` usage is intentional
  invariant guarding.
- No `TODO`/`FIXME`/`HACK` comments exist in the reviewed files.
- Streaming/chunked, byte-budgeted file reading (`ReadFilePreviewAccumulator`) and the
  mach/rusage `ProcessResourceMonitor` are well-designed and allocation-light.
- `ChatModelContextBuilder.transcript` correctly short-circuits when nothing is excluded.
- No deprecated Apple APIs other than the `DispatchGroup`/KVC items called out above.

## Resolved since 2026-06-02

- A-02 is now confirmed fully dead (see Q-01): the only remaining permission path is the
  per-executor `evaluatePermission`. The duplicate is ready to delete.

## Recommended order

1. Delete dead `ToolPermissionEvaluator` (Q-01) — trivial, resolves A-02.
2. Memoize transcript markdown blocks and incrementalize context-usage/cache signatures
   (P-01, P-02, P-05) — the largest runtime wins as conversations grow.
3. Hoist per-call regexes to `static let` (P-03) and fix the edit-match re-tokenization
   (P-04).
4. Replace the `as?`-cast input recovery with statically-typed extraction (T-01).
5. Remove legacy decoding/migration shims (O-01, O-03) per the Data Model Policy.
6. Extract `ToolApprovalCoordinator` (Q-02) and `WorkspaceSessionCoordinator` +
   `DebouncedPersistenceScheduler` (Q-03).
7. Make trace and cache-debug fields typed (T-02, T-03); collapse duplicated helpers
   (Q-04).
