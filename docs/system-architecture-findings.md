# System Architecture Findings

Date: 2026-06-16

This document captures a full system-level architecture, performance, type-safety,
and code-quality review of the codebase. It supersedes the 2026-06-02 review; the
2026-06-16 update prunes findings that have since been resolved (see Resolved) and
reframes the residual context-usage item. Every finding is tied to concrete files and
describes an incremental direction rather than a rewrite. Severity reflects
user-visible/runtime impact and risk, not effort.

## Summary

The codebase is a SwiftUI/MVVM hybrid with strong service-oriented boundaries: a
headless `LocalCoderCore` SwiftPM library plus a macOS app target that owns
SwiftUI/AppKit and the MLX/Gemma backend. The typed tool runtime, explicit chat-turn
lifecycle, frozen append-only model-context ledger, and KV-cache reuse policy are
well-designed and well-documented. Type safety is generally excellent: no force
unwraps, `try!`, or `as!` were found in the reviewed surface, and discriminated-union
`Codable` ADTs are used consistently.

With the markdown-render, regex-compilation, edit-match, and span-filtering hot paths
now resolved (see Resolved), the remaining risks are smaller and cluster in three areas:

1. **Residual recompute paths** — the Gemma KV-cache signature re-hashes the full
   history per turn (P-05), and the context-usage refresh re-renders the system prompt
   on every call (P-02). Both are bounded and neither re-tokenizes the transcript
   anymore.
2. **Stringly-typed runtime dispatch and trace fields** — typed tool input is recovered
   via an `as?` cast and name switch (T-01), and trace/cache-debug fields are compared
   as raw magic strings (T-02, T-03).
3. **Coupling and stale seams** — `ChatSessionController` and `AppState` remain broad
   adapters with duplicated skeletons (Q-02, Q-03), and several dead seams persist that
   this unreleased prototype does not need (Q-05).

## Findings

| ID | Severity | Category | Finding | Affected Files |
| --- | --- | --- | --- | --- |
| P-02 | Low | Perf | Context-usage refresh re-renders the system prompt + re-sums history bytes on every call (~11x/turn) | `Sources/LocalCoderCore/Features/Chat/ContextUsageCoordinator.swift`, `ChatSessionController.swift` |
| P-05 | Medium | Perf | Full-history FNV cache signature re-hashed ~2x per turn (grows O(transcript)) | `local-coder/Services/GemmaMLXRuntime.swift`, `GemmaSessionCachePolicy.swift` |
| P-07 | Medium | Perf | `refreshDebounced` does not debounce; no coalescing of usage refreshes | `Sources/LocalCoderCore/Features/Chat/ContextUsageCoordinator.swift` |
| P-09 | Low | Perf | Whole library re-encoded to one JSON file on every mutation | `Sources/LocalCoderCore/Services/WorkspaceStore.swift`, `Models/Workspace.swift` |
| T-01 | High | TypeSafety | `AnyToolExecutor` recovers typed input via `as?` cast + 48-line name switch | `Sources/LocalCoderCore/Services/ToolExecution.swift` |
| T-02 | Medium | TypeSafety | Cache-debug UI compares raw `cacheMode`/`cacheReason` magic strings | `local-coder/Features/Chat/WorkspaceChatView.swift` |
| T-03 | Medium | TypeSafety | Trace fields (`toolCallFormat`, validation status, cacheMode) passed as raw strings | `Sources/LocalCoderCore/Features/Chat/ToolLoopCoordinator.swift`, `ChatSessionController.swift` |
| T-04 | Low | TypeSafety | `ToolName` is a stringly-typed struct; lists can drift without exhaustiveness | `Sources/LocalCoderCore/Models/ToolCall.swift`, `Services/ToolCallRequestValidator.swift` |
| T-05 | Low | TypeSafety | KVC `setValue(false, forKey: "drawsBackground")` on `WKWebView` | `local-coder/Features/Chat/HTMLPreview.swift` |
| Q-02 | Medium | Quality | A-01: `ChatSessionController` is a god type (1566 lines); approval/deny/answer flows duplicate skeletons | `Sources/LocalCoderCore/Features/Chat/ChatSessionController.swift` |
| Q-03 | Medium | Quality | A-04: `AppState` couples navigation, session lifecycle, persistence; 3x duplicated debounced-save | `local-coder/App/AppState.swift` |
| Q-04 | Medium | Quality | Duplicated logic across result projections and extraction (status maps, diagnostics render, host validation, UTF-8 suffix trimming) | `Sources/LocalCoderCore/Models/ToolCall.swift`, `Models/ToolResultProjection.swift`, `Services/WebAccess.swift`, `Services/WebContentExtraction.swift`, `Services/ToolCommandExecution.swift` |
| Q-05 | Low | Quality | Dead/placeholder seams: `activeAttachmentContextAttachments` returns `[]`; test-only `streamAssistantReply`; no-op `updateContextUsage` closure | `Sources/LocalCoderCore/Features/Chat/ChatSessionController.swift`, `ChatGenerationCoordinator.swift` |

## Details

### Performance

#### P-02: Context-usage refresh re-renders the system prompt every call (Low)

`refreshContextUsage` -> `contextUsageSnapshot` (`ChatSessionController.swift:628-669`)
re-renders the full system prompt via `systemPrompt(toolPromptMode:)` and rebuilds the
transcript on every call, and `estimatedUsage()` (`ContextUsageCoordinator.swift:36-46`)
sums the UTF-8 byte count of the whole history. It runs ~11x per turn (turn start, after
each stream, every tool-loop iteration, attachment add/remove, completion).

Resolved parts: the original O(n^2) re-tokenization is gone — the runtime-tokenizer path
was dropped in favor of a byte estimate, and the per-call
`projectedEntries(.fullHistory)` array allocation was replaced with a direct sum over
`frozenContent.content` (commit `336d9ed0`).

Residual: the per-refresh system-prompt re-render (tool-registry assembly + prompt
render) is O(1) in history but a non-trivial constant repeated ~11x/turn; the history
byte-sum is still O(n) per call. Both are cheap relative to the former tokenization,
hence Low.

Fix (if pursued): memoize the rendered system prompt keyed on `(toolPromptMode,
systemPrompt, todoState, toolCallingPolicy)`. If the byte-sum ever shows up in a profile,
maintain a cumulative byte count on the ledger — but note the ledger is **not** purely
append-only: the terminal->follow-up swap (`ChatTranscriptMutator.swift:83`) and the
write/edit payload redaction (`:436`) mutate existing entries in place while preserving
`entries.count` and entry ids, so a naive "count + last-entry id" memo key would go
stale. Bump a revision stamp on every mutation instead.

#### P-05: Full-history cache signature re-hashed per turn (Medium)

`GemmaMLXRuntime.contextSignature(for:)` (`:336-342, 437-443, 498-504`) +
`GemmaSessionCachePolicy.swift:445-470` iterate every byte of every message for the
whole history on each generation, and `cacheDecision` recomputes the signature again
(`GemmaSessionCachePolicy.swift:34-41`) — the full transcript is hashed ~2x per turn and
grows O(transcript bytes) every turn.

Fix: history is append-only, so keep a rolling/incremental hash of the consumed prefix
on `CachedGemmaSession` and hash only newly appended messages.

#### P-07: `refreshDebounced` does not debounce (Medium)

`ContextUsageCoordinator` accepts `debounceDelay` and `turnTracer` and immediately
discards both (`:75-76`); `refreshDebounced` (`:102-116`) calls the estimate
synchronously with no delay or coalescing. Combined with P-02, the many per-turn refresh
calls each do a full synchronous main-actor recount.

Fix: restore real debouncing (a delayed `Task` the next call cancels) or rename to
`refresh` and delete the dead `debounceDelay`/`turnTracer` parameters so the name stops
implying coalescing that does not happen.

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

Fix: introduce `WorkspaceSessionCoordinator` for the persist->mutate->save->load sequence;
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

- `activeAttachmentContextAttachments` (`ChatSessionController.swift:710-712`) always
  returns `[]` yet is read by `WorkspaceChatView.swift:210`.
- `ChatGenerationCoordinator.streamAssistantReply` (`:60-90`, String-returning) has no
  production callers; production uses `streamAssistantReplyResult`.
- The `updateContextUsage` closure threaded through the stream path is an empty
  `MainActor.run {}` no-op (`ChatSessionController.swift:1317-1319`).

Fix: implement or remove each seam.

## Non-issues verified

- No force unwraps (`!`), `try!`, `as!`, or implicitly unwrapped optionals were found in
  the reviewed surface. `precondition`/`preconditionFailure` usage is intentional
  invariant guarding.
- No `TODO`/`FIXME`/`HACK` comments exist in the reviewed files.
- Streaming/chunked, byte-budgeted file reading (`ReadFilePreviewAccumulator`) and the
  mach/rusage `ProcessResourceMonitor` are well-designed and allocation-light.
- `ChatModelContextBuilder.transcript` correctly short-circuits when nothing is excluded.
- No deprecated Apple APIs other than the KVC item called out above.

## Resolved

### Resolved 2026-06-16

- **P-01** (was High / Perf) — chat transcript re-parsed markdown and rebuilt derived
  items on every streaming chunk. `ChatTranscript` now memoizes parsed render blocks per
  `AssistantMessageRenderKey(id:content:)` (`blocks(for:)`), short-circuits the whole
  `transcriptItems` rebuild via `cachedInput`/`cachedItems`, and scrolls off a
  lightweight `scrollAnchorID` instead of diffing the full items array.
- **P-03** (was High / Perf) — per-call `NSRegularExpression` compilation in hot
  extraction/highlight/linkify paths. All fixed patterns are now precompiled `static let`
  instances (`compiledRegex(...)` statics in `WebAccess`, `cssDimensionRegex` in
  `CodeHighlighting`, `urlDetectionRegex` in `URLTextLinkifier`; the per-draft attachment
  pattern in `ChatAttachmentLoader` was removed). (commit `d5bb59f0`)
- **P-04** (was High / Perf) — edit-match path re-tokenized file content and used
  `String.distance` per lookup. `EditFileToolExecutor` now caches `oldLines`/`contentLines`,
  and `IndexedNormalizedText.sourceRanges` accumulates offsets from a moving cursor so the
  whole search is O(n) instead of O(n*m). (commit `cf72ed48`)
- **P-06** (was Medium / Perf) — O(n^2) span-overlap filtering + whitespace-collapse loop.
  `CodeHighlighting.nonOverlappingSpans` now uses a binary-search neighbor test and the
  `while cleaned.contains("  ")` loop was removed. (commit `d1de0a80`)
- **Q-01 / A-02** (was High / Quality) — the dead `ToolPermissionEvaluator` was deleted;
  the only remaining permission path is each `TypedToolExecutor.evaluatePermission`.
  (commit `9d223a8d`)
- **P-02** (partial) — the context-usage re-tokenization and the per-call projected-array
  allocation are resolved (now a direct byte sum over frozen content; the runtime
  tokenizer path was already removed). The smaller residual is tracked as the reduced
  P-02 above. (commit `336d9ed0`)
- **P-08** (was Medium / Perf) — `DefaultCommandProcessRunner` no longer busy-polls
  `process.isRunning`; it bridges `Process.terminationHandler` into a continuation and
  races process exit against timeout/cancellation in a task group.
- **O-01** (was Medium / Outdated) — legacy `todo_write` input formats were removed.
  `TodoWriteInput` now decodes and encodes only the numbered `item1...item6`/`done1...done6`
  contract advertised by `ToolDefinition.todoWrite`, and validator tests reject the old
  `items` argument.
- **O-02** (was Medium / Outdated) — `ChatComposer` no longer uses `DispatchGroup`,
  callback-style provider loading, or the `@unchecked Sendable` URL accumulator. File
  providers are loaded through async `NSItemProvider.loadItem` calls coordinated by a
  task group.
- **O-03** (was Low / Outdated) — the legacy direct-file-display markdown normalizer and
  the `StoredModelSettings.contextTokenLimit` decode fallback were removed. The
  `ChatSession.resolvingInterruptedStreams` path remains because it protects current
  sessions after crash or hard-quit interruption, not old schema migration.

## Recommended order

1. Incrementalize the Gemma KV-cache full-history signature (P-05) — the largest
   remaining runtime win as conversations grow; optionally finish the context-usage
   residual (P-02) and restore real debounce (P-07).
2. Replace the `as?`-cast input recovery with statically-typed extraction (T-01).
3. Extract `ToolApprovalCoordinator` (Q-02) and `WorkspaceSessionCoordinator` +
   `DebouncedPersistenceScheduler` (Q-03); remove the dead seams (Q-05).
4. Make trace and cache-debug fields typed (T-02, T-03); collapse duplicated helpers
   (Q-04).
5. Address the per-mutation library re-encode (P-09) as scaling work.
