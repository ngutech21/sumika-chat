import AppKit
import SumikaCore
import Testing

@testable import Sumika

@MainActor
struct AppKitChatTranscriptDiffPlanTests {
  @Test
  func sameRowIDsReconfigureChangedRowsWithoutSnapshot() {
    let plan = NativeTranscriptDiffPlan.make(
      previousIDs: ["user", "assistant"],
      previousRevisions: ["user": 1, "assistant": 1],
      currentIDs: ["user", "assistant"],
      currentRevisions: ["user": 1, "assistant": 2]
    )

    #expect(plan.action == .reconfigureRows)
    #expect(plan.changedIDs == ["assistant"])
  }

  @Test
  func appendedUserRowAppliesSnapshotAndScrollsWhenOutgoing() {
    let existingRow = nativeAssistantRow(id: "assistant", revision: 1)
    let appendedRow = nativeUserRow(id: "user", revision: 1)
    let currentRows = [existingRow, appendedRow]
    let plan = NativeTranscriptDiffPlan.make(
      previousIDs: [existingRow.id],
      previousRevisions: [existingRow.id: existingRow.revision],
      currentIDs: currentRows.map(\.id),
      currentRevisions: revisionMap(currentRows)
    )

    #expect(plan.action == .snapshot)
    #expect(plan.changedIDs == ["user"])
    #expect(
      NativeTranscriptScrollDecision.shouldScrollToBottomAfterAppend(
        previousIDs: [existingRow.id],
        currentRows: currentRows
      )
    )
  }

  @Test
  func appendedAssistantRowDoesNotForceOutgoingScrollDecision() {
    let existingRow = nativeUserRow(id: "user", revision: 1)
    let appendedRow = nativeAssistantRow(id: "assistant", revision: 1)

    #expect(
      NativeTranscriptScrollDecision.shouldScrollToBottomAfterAppend(
        previousIDs: [existingRow.id],
        currentRows: [existingRow, appendedRow]
      ) == false
    )
  }

  @Test
  func heightCacheKeysByRowRevisionAndWidth() {
    var cache = NativeTranscriptHeightCache()
    let row = NativeTranscriptRow(
      id: "generation",
      revision: 1,
      body: .generationIndicator(revision: 1)
    )

    _ = cache.height(for: row, width: 400)
    #expect(cache.cachedEntryCount == 1)

    _ = cache.height(for: row, width: 400.8)
    #expect(cache.cachedEntryCount == 1)

    _ = cache.height(for: row, width: 401)
    #expect(cache.cachedEntryCount == 2)

    let revisedRow = NativeTranscriptRow(
      id: "generation",
      revision: 2,
      body: .generationIndicator(revision: 2)
    )
    _ = cache.height(for: revisedRow, width: 400)
    #expect(cache.cachedEntryCount == 3)

    cache.invalidate(rowID: "generation")
    #expect(cache.cachedEntryCount == 0)
  }

  @Test
  func expandedToolRowsUseExpandedHeightCacheKey() {
    var cache = NativeTranscriptHeightCache()
    let row = nativeToolRow(id: "tool", revision: 1)

    let collapsedHeight = cache.height(for: row, width: 640)
    let expandedHeight = cache.height(
      for: row,
      width: 640,
      state: NativeTranscriptCellState(isToolExpanded: true)
    )

    #expect(expandedHeight > collapsedHeight)
    #expect(cache.cachedEntryCount == 2)
  }

  @Test
  func coordinatorStateIsStoredByRowIDAndPrunedByActiveRows() {
    var store = NativeTranscriptCoordinatorState()

    store.setCopied(true, rowID: "tool")
    store.toggleToolExpansion(rowID: "tool")
    store.updateAskUserSelection("Yes", rowID: "tool")

    #expect(
      store.state(for: "tool")
        == NativeTranscriptCellState(
          isCopied: true,
          isToolExpanded: true,
          askUserSelection: "Yes"
        )
    )
    #expect(
      store.state(for: "other")
        == NativeTranscriptCellState(
          isCopied: false,
          isToolExpanded: false,
          askUserSelection: nil
        )
    )

    store.prune(activeRowIDs: ["other"])

    #expect(
      store.state(for: "tool")
        == NativeTranscriptCellState(
          isCopied: false,
          isToolExpanded: false,
          askUserSelection: nil
        )
    )
  }
}

private func revisionMap(_ rows: [NativeTranscriptRow]) -> [String: Int] {
  Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.revision) })
}

private func nativeUserRow(id: String, revision: Int) -> NativeTranscriptRow {
  NativeTranscriptRow(
    id: id,
    revision: revision,
    body: .item(
      RenderedChatTurnItem(
        id: id,
        item: .userMessage(UserTurnMessage(content: "Question")),
        toolCallRecord: nil,
        generationMetrics: nil,
        assistantRenderBlocks: []
      ))
  )
}

private func nativeAssistantRow(id: String, revision: Int) -> NativeTranscriptRow {
  NativeTranscriptRow(
    id: id,
    revision: revision,
    body: .item(
      RenderedChatTurnItem(
        id: id,
        item: .assistantMessage(AssistantTurnMessage(content: "Answer")),
        toolCallRecord: nil,
        generationMetrics: nil,
        assistantRenderBlocks: [
          .paragraph(.init(id: .init(rawValue: "answer"), text: "Answer"))
        ]
      ))
  )
}

private func nativeToolRow(id: String, revision: Int) -> NativeTranscriptRow {
  let record = nativeToolRecord()
  return NativeTranscriptRow(
    id: id,
    revision: revision,
    body: .item(
      RenderedChatTurnItem(
        id: id,
        item: .tool(record),
        toolCallRecord: record,
        generationMetrics: nil,
        assistantRenderBlocks: []
      ))
  )
}

private func nativeToolRecord() -> ToolCallRecord {
  let request = ToolCallRequest.validated(
    raw: RawToolCallRequest(
      workspaceID: UUID(),
      sessionID: UUID(),
      toolName: .browserRefresh,
      arguments: ["hard": .bool(true)]
    ),
    payload: .browserRefresh(BrowserRefreshInput(hard: true))
  )
  return ToolCallRecord(
    request: request,
    evaluation: ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Allowed for test.",
      riskLevel: .low
    ),
    state: .completed(
      .browserRefresh(
        .success(
          path: WorkspaceRelativePath(rawValue: "index.html"),
          url: "http://localhost:3000",
          hard: true
        )))
  )
}
