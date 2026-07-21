import AppKit
import Testing

@testable import SumikaApp
@testable import SumikaCore

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
  func insertedMultilineUserRowUsesItsMeasuredHeightImmediately() throws {
    let coordinator = AppKitChatTranscriptRepresentable.Coordinator(
      onToggleSpeech: { _, _ in },
      onApproveToolCall: { _ in },
      onDenyToolCall: { _ in },
      onAnswerAskUser: { _, _ in }
    )
    let scrollView = coordinator.makeScrollView()
    scrollView.setFrameSize(NSSize(width: 552, height: 300))
    scrollView.layoutSubtreeIfNeeded()
    let tableView = try #require(scrollView.documentView as? NSTableView)
    tableView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: 300))
    let content =
      "Lorem ipsum dolor sit amet, consetetur sadipscing elitr, sed diam nonumy eirmod "
      + "tempor invidunt ut labore et dolore magna aliquyam erat, sed diam voluptua. At vero "
      + "eos et accusam et justo duo dolores et ea rebum. Stet clita kasd gubergren, no sea "
      + "takimata sanctus est Lorem ipsum dolor sit amet. Lorem ipsum dolor sit amet, "
      + "consetetur sadipscing elitr, sed diam nonumy eirmod tempor invidunt ut labore et "
      + "dolore magna aliquyam erat, sed diam voluptua. At vero eos et accusam et justo duo "
      + "dolores et ea rebum. Stet clita kasd gubergren, no sea takimata sanctus est Lorem "
      + "ipsum dolor sit amet. last line 12345"
    let userRow = nativeUserRow(id: "multiline-user", revision: 1, content: content)

    coordinator.update(
      rows: [userRow],
      accessibilityValue: "ready",
      isSpeechEnabled: false,
      activeSpeechRowID: nil,
      in: scrollView
    )
    scrollView.layoutSubtreeIfNeeded()
    tableView.layoutSubtreeIfNeeded()

    let bubbleTextWidth = max(scrollView.contentSize.width - 44 - 80 - 20, 1)
    let requiredTextHeight = ceil(
      NSAttributedString(
        string: content,
        attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
      ).boundingRect(
        with: NSSize(width: bubbleTextWidth, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
      ).height
    )

    #expect(tableView.rect(ofRow: 0).height >= requiredTextHeight + 28)
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
  func snapshotHeightInvalidationOnlyTouchesChangedExistingRows() {
    let rows = NativeTranscriptSnapshotInvalidation.rowIndexes(
      previousIDs: ["user", "assistant"],
      currentIDs: ["user", "tool", "assistant"],
      changedIDs: ["assistant"]
    )

    #expect(rows == IndexSet([2]))
  }

  @Test
  func snapshotHeightInvalidationSkipsPureRemoval() {
    let rows = NativeTranscriptSnapshotInvalidation.rowIndexes(
      previousIDs: ["user", "generation"],
      currentIDs: ["user"],
      changedIDs: []
    )

    #expect(rows.isEmpty)
  }

  @Test
  func snapshotHeightInvalidationSkipsPureReorder() {
    let rows = NativeTranscriptSnapshotInvalidation.rowIndexes(
      previousIDs: ["user", "assistant"],
      currentIDs: ["assistant", "user"],
      changedIDs: []
    )

    #expect(rows.isEmpty)
  }

  @Test
  func thinkingRowUsesDedicatedAccessibilityIdentifier() {
    let row = nativeThinkingRow(id: "thinking", revision: 1)

    #expect(row.accessibilityIdentifier == "chat.assistantThinking")
  }

  @Test
  func assistantAccessibilityLabelDoesNotIncludeMessageContent() {
    let longContent =
      "This assistant response contains implementation details, code, logs, and other long text."
    let row = nativeAssistantMarkdownRow(
      id: "assistant-accessibility",
      revision: 1,
      markdown: longContent
    )
    let cell = configuredNativeCell(for: row)

    #expect(cell.accessibilityLabel() == "Assistant message")
    #expect(cell.accessibilityLabel()?.contains(longContent) == false)
    #expect(cell.descendantTextValues.contains(longContent))
  }

  @Test
  func userAccessibilityLabelDoesNotIncludeMessageContent() {
    let longContent =
      "This user prompt contains pasted logs, source code, and enough text to be expensive."
    let row = nativeUserRow(
      id: "user-accessibility",
      revision: 1,
      content: longContent
    )
    let cell = configuredNativeCell(for: row)

    #expect(cell.accessibilityLabel() == "User message")
    #expect(cell.accessibilityLabel()?.contains(longContent) == false)
    #expect(cell.descendantTextValues.contains(longContent))
  }

  @Test
  func assistantReasoningAccessibilityLabelDoesNotIncludeMessageContent() {
    let longContent =
      "Inspecting the current workspace and comparing all candidate files before answering."
    let row = nativeStreamingThinkingRow(
      id: "thinking-accessibility",
      revision: 1,
      content: longContent
    )
    let cell = configuredNativeCell(
      for: row,
      state: NativeTranscriptCellState(isThinkingExpanded: true)
    )

    #expect(cell.accessibilityLabel() == "Assistant reasoning")
    #expect(cell.accessibilityLabel()?.contains(longContent) == false)
    #expect(cell.descendantTextValues.contains(longContent))
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
  func codeOnlyHighlightUpdateDoesNotChangeRowDiffOrHeightCache() {
    var cache = NativeTranscriptHeightCache()
    let row = nativeAssistantCodeRow(id: "assistant", revision: 1, code: "let value = 1")
    let plan = NativeTranscriptDiffPlan.make(
      previousIDs: [row.id],
      previousRevisions: [row.id: row.revision],
      currentIDs: [row.id],
      currentRevisions: [row.id: row.revision]
    )

    _ = cache.height(for: row, width: 640)
    _ = cache.height(for: row, width: 640)

    #expect(plan.action == .reconfigureRows)
    #expect(plan.changedIDs.isEmpty)
    #expect(cache.cachedEntryCount == 1)
  }

  @Test
  func codeContentChangesAffectHeightCacheRevision() {
    var cache = NativeTranscriptHeightCache()
    let row = nativeAssistantCodeRow(id: "assistant", revision: 1, code: "let value = 1")
    let revisedRow = nativeAssistantCodeRow(
      id: "assistant",
      revision: 2,
      code: "let value = 1\nlet other = 2"
    )

    _ = cache.height(for: row, width: 640)
    let revisedHeight = cache.height(for: revisedRow, width: 640)

    #expect(cache.cachedEntryCount == 2)
    #expect(revisedHeight > 0)
  }

  @Test
  func heightCachePrunesStaleRevisionsForActiveRows() {
    var cache = NativeTranscriptHeightCache()
    let row = nativeAssistantCodeRow(id: "assistant", revision: 1, code: "let value = 1")
    let revisedRow = nativeAssistantCodeRow(
      id: "assistant",
      revision: 2,
      code: "let value = 1\nlet other = 2"
    )

    _ = cache.height(for: row, width: 640)
    _ = cache.height(for: revisedRow, width: 640)
    #expect(cache.cachedEntryCount == 2)

    cache.prune(activeRows: [revisedRow])
    #expect(cache.cachedEntryCount == 1)

    _ = cache.height(for: revisedRow, width: 640)
    #expect(cache.cachedEntryCount == 1)
  }

  @Test
  func streamingRevisionCommitsOnlyLatestVisibleModelAndPromotesItsHeight() throws {
    let coordinator = AppKitChatTranscriptRepresentable.Coordinator(
      onToggleSpeech: { _, _ in },
      onApproveToolCall: { _ in },
      onDenyToolCall: { _ in },
      onAnswerAskUser: { _, _ in }
    )
    let scrollView = coordinator.makeScrollView()
    scrollView.setFrameSize(NSSize(width: 420, height: 300))
    let tableView = try #require(scrollView.documentView as? NSTableView)
    let initialContent = "Initial streaming text."
    let initialRow = nativeStreamingAssistantRow(
      id: "assistant",
      revision: 1,
      content: initialContent
    )

    coordinator.update(
      rows: [initialRow],
      accessibilityValue: "ready",
      isSpeechEnabled: false,
      activeSpeechRowID: nil,
      in: scrollView
    )
    coordinator.flushPendingHeightInvalidationForTesting()
    tableView.layoutSubtreeIfNeeded()
    coordinator.flushPendingStreamingHeightUpdateForTesting()
    tableView.layoutSubtreeIfNeeded()

    let cell = try #require(
      tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        as? NativeChatMessageCellView
    )
    let initialNotedHeight = try #require(
      coordinator.lastNotedHeightByRowIDForTesting[initialRow.id]
    )
    let intermediateRow = nativeStreamingAssistantRow(
      id: initialRow.id,
      revision: 2,
      content: "Intermediate content that must never be drawn."
    )
    let latestContent =
      String(
        repeating: "Latest streaming content wraps across several lines. ",
        count: 24
      ) + "LATEST"
    let latestRow = nativeStreamingAssistantRow(
      id: initialRow.id,
      revision: 3,
      content: latestContent
    )

    coordinator.update(
      rows: [intermediateRow],
      accessibilityValue: "ready",
      isSpeechEnabled: false,
      activeSpeechRowID: nil,
      in: scrollView
    )
    coordinator.update(
      rows: [latestRow],
      accessibilityValue: "ready",
      isSpeechEnabled: false,
      activeSpeechRowID: nil,
      in: scrollView
    )

    #expect(coordinator.pendingStreamingRowIDsForTesting == [initialRow.id])
    #expect(cell.descendantTextValues.contains(initialContent))
    #expect(cell.descendantTextValues.contains { $0.contains("LATEST") } == false)
    #expect(coordinator.lastNotedHeightByRowIDForTesting[initialRow.id] == initialNotedHeight)

    coordinator.flushPendingStreamingHeightUpdateForTesting()
    tableView.layoutSubtreeIfNeeded()

    let committedHeight = try #require(
      coordinator.lastNotedHeightByRowIDForTesting[initialRow.id]
    )
    #expect(cell.descendantTextValues.contains { $0.contains("LATEST") })
    #expect(coordinator.pendingStreamingRowIDsForTesting.isEmpty)
    #expect(coordinator.pendingMeasuredHeightByRowIDForTesting.isEmpty)
    #expect(committedHeight > initialNotedHeight)
    #expect(abs(tableView.rect(ofRow: 0).height - committedHeight) < 0.5)
  }

  @Test
  func heightOfRowIgnoresPendingStreamingMeasurementUntilPromotion() throws {
    let coordinator = AppKitChatTranscriptRepresentable.Coordinator(
      onToggleSpeech: { _, _ in },
      onApproveToolCall: { _ in },
      onDenyToolCall: { _ in },
      onAnswerAskUser: { _, _ in }
    )
    let scrollView = coordinator.makeScrollView()
    scrollView.setFrameSize(NSSize(width: 640, height: 300))
    let tableView = try #require(scrollView.documentView as? NSTableView)
    let row = nativeStreamingAssistantRow(id: "assistant", revision: 1, content: "Streaming")

    coordinator.update(
      rows: [row],
      accessibilityValue: "ready",
      isSpeechEnabled: false,
      activeSpeechRowID: nil,
      in: scrollView
    )
    coordinator.flushPendingHeightInvalidationForTesting()
    tableView.layoutSubtreeIfNeeded()
    coordinator.flushPendingStreamingHeightUpdateForTesting()
    tableView.layoutSubtreeIfNeeded()
    let notedHeight = try #require(coordinator.lastNotedHeightByRowIDForTesting[row.id])

    coordinator.stageMeasuredStreamingHeightForTesting(notedHeight + 100, rowID: row.id)

    #expect(coordinator.tableView(tableView, heightOfRow: 0) == notedHeight)
    #expect(coordinator.lastNotedHeightByRowIDForTesting[row.id] == notedHeight)
  }

  @Test
  func widthChangeCancelsPendingStreamingCommitAndClearsOldMeasurements() throws {
    let coordinator = AppKitChatTranscriptRepresentable.Coordinator(
      onToggleSpeech: { _, _ in },
      onApproveToolCall: { _ in },
      onDenyToolCall: { _ in },
      onAnswerAskUser: { _, _ in }
    )
    let scrollView = coordinator.makeScrollView()
    scrollView.setFrameSize(NSSize(width: 640, height: 300))
    let tableView = try #require(scrollView.documentView as? NSTableView)
    let initialRow = nativeStreamingAssistantRow(
      id: "assistant",
      revision: 1,
      content: "Initial"
    )

    coordinator.update(
      rows: [initialRow],
      accessibilityValue: "ready",
      isSpeechEnabled: false,
      activeSpeechRowID: nil,
      in: scrollView
    )
    coordinator.flushPendingHeightInvalidationForTesting()
    tableView.layoutSubtreeIfNeeded()
    coordinator.flushPendingStreamingHeightUpdateForTesting()
    tableView.layoutSubtreeIfNeeded()

    let revisedRow = nativeStreamingAssistantRow(
      id: initialRow.id,
      revision: 2,
      content: String(repeating: "Growing content. ", count: 12)
    )
    coordinator.update(
      rows: [revisedRow],
      accessibilityValue: "ready",
      isSpeechEnabled: false,
      activeSpeechRowID: nil,
      in: scrollView
    )
    #expect(coordinator.hasPendingStreamCommitForTesting)

    scrollView.setFrameSize(NSSize(width: 520, height: 300))
    coordinator.update(
      rows: [revisedRow],
      accessibilityValue: "ready",
      isSpeechEnabled: false,
      activeSpeechRowID: nil,
      in: scrollView
    )

    #expect(coordinator.hasPendingStreamCommitForTesting == false)
    #expect(coordinator.pendingStreamingRowIDsForTesting.isEmpty)
    #expect(coordinator.pendingMeasuredHeightByRowIDForTesting.isEmpty)
    #expect(coordinator.lastNotedHeightByRowIDForTesting.isEmpty)
  }

  @Test
  func cellHeightReportUsesOnlyTheCurrentlyConfiguredRowID() {
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test")
    )
    cell.frame = host.bounds
    host.addSubview(cell)
    var reportedRowIDs: [String] = []
    cell.onMeasuredHeight = { rowID, _ in
      reportedRowIDs.append(rowID)
    }
    let firstRow = nativeStreamingAssistantRow(id: "first", revision: 1, content: "First")
    let secondRow = nativeStreamingAssistantRow(id: "second", revision: 1, content: "Second")

    cell.configure(row: firstRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    cell.configure(row: secondRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    host.layoutSubtreeIfNeeded()
    cell.layoutSubtreeIfNeeded()

    #expect(reportedRowIDs == [secondRow.id])

    cell.prepareForReuse()
    cell.configure(row: firstRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    cell.layoutSubtreeIfNeeded()
    #expect(reportedRowIDs == [secondRow.id])
  }

  @Test
  func heightCacheReusesMeasuringCellForStreamingRevisions() throws {
    var cache = NativeTranscriptHeightCache()
    let shortRow = nativeStreamingAssistantRow(id: "assistant", revision: 1, content: "Hello")
    let grownRow = nativeStreamingAssistantRow(
      id: "assistant",
      revision: 2,
      content: "Hello " + String(repeating: "streaming answer text that keeps growing. ", count: 12)
    )

    let shortHeight = cache.height(for: shortRow, width: 640)
    let measuringCell = try #require(cache.measuringCellForTesting)
    let hostedView = try #require(measuringCell.hostedContentViewForTesting)

    let grownHeight = cache.height(for: grownRow, width: 640)

    #expect(measuringCell.hostedContentViewForTesting === hostedView)
    #expect(grownHeight > shortHeight)
    #expect(shortHeight == NativeTranscriptRowMeasurer.height(for: shortRow, width: 640))
    #expect(grownHeight == NativeTranscriptRowMeasurer.height(for: grownRow, width: 640))
  }

  @Test
  func heightCacheReusesMeasuringCellForStreamingThinkingRevisions() throws {
    var cache = NativeTranscriptHeightCache()
    let expandedState = NativeTranscriptCellState(isThinkingExpanded: true)
    let shortRow = nativeStreamingThinkingRow(id: "thinking", revision: 1, content: "Inspecting")
    let grownRow = nativeStreamingThinkingRow(
      id: "thinking",
      revision: 2,
      content: "Inspecting " + String(repeating: "more evidence before answering. ", count: 12)
    )

    let shortHeight = cache.height(for: shortRow, width: 640, state: expandedState)
    let measuringCell = try #require(cache.measuringCellForTesting)
    let hostedView = try #require(measuringCell.hostedContentViewForTesting)

    let grownHeight = cache.height(for: grownRow, width: 640, state: expandedState)

    #expect(measuringCell.hostedContentViewForTesting === hostedView)
    #expect(grownHeight > shortHeight)
    #expect(
      grownHeight
        == NativeTranscriptRowMeasurer.height(for: grownRow, width: 640, state: expandedState))
  }

  @Test
  func reusedMeasuringCellMatchesFreshMeasurementAcrossWidths() {
    var cache = NativeTranscriptHeightCache()
    let row = nativeAssistantMarkdownRow(
      id: "assistant",
      revision: 1,
      markdown: String(
        repeating: "A wrapping paragraph that needs several lines at narrow widths. ",
        count: 6
      )
    )

    _ = cache.height(for: row, width: 640)
    let narrowHeight = cache.height(for: row, width: 360)

    #expect(narrowHeight == NativeTranscriptRowMeasurer.height(for: row, width: 360))
  }

  @Test
  func reusedMeasuringCellMatchesFreshMeasurementAcrossRowKinds() {
    var cache = NativeTranscriptHeightCache()
    let assistantRow = nativeAssistantMarkdownRow(
      id: "assistant",
      revision: 1,
      markdown: "**bold** answer"
    )
    let userRow = nativeUserRow(id: "user", revision: 1, content: "A question")
    let toolRow = nativeToolRow(id: "tool", revision: 1)

    let assistantHeight = cache.height(for: assistantRow, width: 640)
    let userHeight = cache.height(for: userRow, width: 640)
    let toolHeight = cache.height(for: toolRow, width: 640)
    cache.invalidate(rowID: "assistant")
    let assistantAgainHeight = cache.height(for: assistantRow, width: 640)

    #expect(assistantHeight == NativeTranscriptRowMeasurer.height(for: assistantRow, width: 640))
    #expect(userHeight == NativeTranscriptRowMeasurer.height(for: userRow, width: 640))
    #expect(toolHeight == NativeTranscriptRowMeasurer.height(for: toolRow, width: 640))
    #expect(assistantAgainHeight == assistantHeight)
  }

  @Test
  func heightMeasurementUsesProvidedMarkdownBlocks() {
    var markdownBlockRequests = 0
    var cache = NativeTranscriptHeightCache()
    let row = nativeAssistantMarkdownRow(
      id: "assistant",
      revision: 1,
      markdown: "**cached** markdown"
    )

    _ = cache.height(
      for: row,
      width: 640,
      markdownBlocks: { markdown in
        markdownBlockRequests += 1
        return NativeTranscriptMarkdownRenderer.blocks(for: markdown)
      }
    )
    _ = cache.height(
      for: row,
      width: 640,
      markdownBlocks: { markdown in
        markdownBlockRequests += 1
        return NativeTranscriptMarkdownRenderer.blocks(for: markdown)
      }
    )

    #expect(markdownBlockRequests == 1)
  }

  @Test
  func tableContentChangesAffectRowRevisionAndHeightCache() {
    var cache = NativeTranscriptHeightCache()
    let row = nativeAssistantMarkdownRow(
      id: "assistant",
      revision: 1,
      markdown: """
        | Name | Value |
        | --- | --- |
        | Model | Gemma |
        """
    )
    let revisedRow = nativeAssistantMarkdownRow(
      id: "assistant",
      revision: 2,
      markdown: """
        | Name | Value |
        | --- | --- |
        | Model | Gemma |
        | State | Ready |
        """
    )
    let plan = NativeTranscriptDiffPlan.make(
      previousIDs: [row.id],
      previousRevisions: [row.id: row.revision],
      currentIDs: [revisedRow.id],
      currentRevisions: [revisedRow.id: revisedRow.revision]
    )

    _ = cache.height(for: row, width: 640)
    let revisedHeight = cache.height(for: revisedRow, width: 640)

    #expect(plan.action == .reconfigureRows)
    #expect(plan.changedIDs == ["assistant"])
    #expect(cache.cachedEntryCount == 2)
    #expect(revisedHeight > 0)
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
  func speechEnabledRowsUseSeparateHeightCacheKey() {
    var cache = NativeTranscriptHeightCache()
    let row = nativeAssistantMarkdownRow(
      id: "assistant",
      revision: 1,
      markdown: "Readable text."
    )

    _ = cache.height(for: row, width: 640)
    _ = cache.height(
      for: row,
      width: 640,
      state: NativeTranscriptCellState(isSpeechEnabled: true)
    )

    #expect(cache.cachedEntryCount == 2)
  }

  @Test
  func expandedToolRowsMeasureWrappingDetailLines() {
    let shortRow = nativeToolRow(
      id: "tool-short",
      revision: 1,
      record: nativeApprovalToolRecord(reason: "Needs permission.")
    )
    let longRow = nativeToolRow(
      id: "tool-long",
      revision: 1,
      record: nativeApprovalToolRecord(
        reason:
          "Needs permission because this command can modify multiple generated files and should remain inspectable before execution."
      )
    )

    let shortHeight = NativeTranscriptRowMeasurer.height(
      for: shortRow,
      width: 360,
      state: NativeTranscriptCellState(isToolExpanded: true)
    )
    let longHeight = NativeTranscriptRowMeasurer.height(
      for: longRow,
      width: 360,
      state: NativeTranscriptCellState(isToolExpanded: true)
    )

    #expect(longHeight > shortHeight)
  }

  @Test
  func interactiveToolExpansionUpdatesTableRowHeightImmediately() throws {
    let coordinator = AppKitChatTranscriptRepresentable.Coordinator(
      onToggleSpeech: { _, _ in },
      onApproveToolCall: { _ in },
      onDenyToolCall: { _ in },
      onAnswerAskUser: { _, _ in }
    )
    let scrollView = coordinator.makeScrollView()
    scrollView.setFrameSize(NSSize(width: 760, height: 520))
    let tableView = try #require(scrollView.documentView as? NSTableView)
    let rows = [
      nativeToolRow(
        id: "tool",
        revision: 1,
        record: nativeCompletedCommandToolRecord()
      ),
      nativeAssistantMarkdownRow(
        id: "assistant",
        revision: 1,
        markdown: "Assistant response below the tool call."
      ),
    ]

    coordinator.update(
      rows: rows,
      accessibilityValue: "ready",
      isSpeechEnabled: false,
      activeSpeechRowID: nil,
      in: scrollView
    )
    tableView.layoutSubtreeIfNeeded()
    let collapsedHeight = tableView.rect(ofRow: 0).height
    let toolCell = try #require(
      tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        as? NativeChatMessageCellView
    )
    let disclosureButton = try #require(
      toolCell.descendantButtons(accessibilityLabel: "Show details").first
    )

    disclosureButton.performClick(nil)
    tableView.layoutSubtreeIfNeeded()

    let expandedHeight = tableView.rect(ofRow: 0).height
    #expect(expandedHeight > collapsedHeight)
    #expect(tableView.rect(ofRow: 1).minY >= tableView.rect(ofRow: 0).maxY)
  }

  @Test
  func approvalBatchButtonsUseFinalIDsCallbacksAndDisableWhileGenerating() throws {
    let anchorID = UUID()
    let siblingID = UUID()
    var approvedIDs: [ToolCallRecord.ID] = []
    var deniedIDs: [ToolCallRecord.ID] = []
    var approvedBatchAnchors: [ToolCallRecord.ID] = []
    let coordinator = AppKitChatTranscriptRepresentable.Coordinator(
      onToggleSpeech: { _, _ in },
      onApproveToolCall: { approvedIDs.append($0) },
      onDenyToolCall: { deniedIDs.append($0) },
      onAnswerAskUser: { _, _ in },
      onApproveToolCallBatch: { approvedBatchAnchors.append($0) }
    )
    let scrollView = coordinator.makeScrollView()
    scrollView.setFrameSize(NSSize(width: 760, height: 520))
    let tableView = try #require(scrollView.documentView as? NSTableView)
    let rows = [
      nativeToolRow(
        id: "tool-anchor",
        revision: 1,
        record: nativeApprovalToolRecord(id: anchorID),
        batchPresentation: ToolApprovalBatchPresentation(
          anchorID: anchorID,
          pendingApprovalCount: 2,
          showsApproveAll: true
        )
      ),
      nativeToolRow(
        id: "tool-sibling",
        revision: 1,
        record: nativeApprovalToolRecord(id: siblingID),
        batchPresentation: ToolApprovalBatchPresentation(
          anchorID: anchorID,
          pendingApprovalCount: 2,
          showsApproveAll: false
        )
      ),
    ]

    coordinator.update(
      rows: rows,
      accessibilityValue: "ready",
      isSpeechEnabled: false,
      activeSpeechRowID: nil,
      areToolActionsEnabled: true,
      in: scrollView
    )
    tableView.layoutSubtreeIfNeeded()
    let anchorCell = try #require(
      tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        as? NativeChatMessageCellView
    )
    let siblingCell = try #require(
      tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
        as? NativeChatMessageCellView
    )
    let approveID = "chat.tool.approve.\(anchorID.uuidString)"
    let denyID = "chat.tool.deny.\(anchorID.uuidString)"
    let approveAllID = "chat.tool.approveAll.\(anchorID.uuidString)"
    let approveButton = try #require(
      anchorCell.descendantButtons(accessibilityIdentifier: approveID).first
    )
    let denyButton = try #require(
      anchorCell.descendantButtons(accessibilityIdentifier: denyID).first
    )
    let approveAllButton = try #require(
      anchorCell.descendantButtons(accessibilityIdentifier: approveAllID).first
    )

    #expect(approveAllButton.title == "Approve all (2)")
    #expect(approveAllButton.accessibilityLabel() == "Approve all 2 tool calls")
    #expect(
      siblingCell.descendantButtons(accessibilityIdentifier: approveAllID).isEmpty
    )
    approveButton.performClick(nil)
    denyButton.performClick(nil)
    approveAllButton.performClick(nil)
    #expect(approvedIDs == [anchorID])
    #expect(deniedIDs == [anchorID])
    #expect(approvedBatchAnchors == [anchorID])

    coordinator.update(
      rows: rows + [nativeAssistantRow(id: "assistant-appended", revision: 1)],
      accessibilityValue: "ready",
      isSpeechEnabled: false,
      activeSpeechRowID: nil,
      areToolActionsEnabled: false,
      in: scrollView
    )
    tableView.layoutSubtreeIfNeeded()
    let disabledAnchorCell = try #require(
      tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        as? NativeChatMessageCellView
    )
    #expect(
      disabledAnchorCell.descendantButtons(accessibilityIdentifier: approveID).first?.isEnabled
        == false
    )
    #expect(
      disabledAnchorCell.descendantButtons(accessibilityIdentifier: denyID).first?.isEnabled
        == false
    )
    #expect(
      disabledAnchorCell.descendantButtons(accessibilityIdentifier: approveAllID).first?.isEnabled
        == false
    )
  }

  @Test
  func automaticApprovalShowsOnlyResumeAutomationForInterruptedBatch() throws {
    let anchorID = UUID()
    var resumedAnchors: [ToolCallRecord.ID] = []
    let coordinator = AppKitChatTranscriptRepresentable.Coordinator(
      onToggleSpeech: { _, _ in },
      onApproveToolCall: { _ in },
      onDenyToolCall: { _ in },
      onAnswerAskUser: { _, _ in },
      onResumeAutomaticApprovalBatch: { resumedAnchors.append($0) }
    )
    let scrollView = coordinator.makeScrollView()
    scrollView.setFrameSize(NSSize(width: 760, height: 520))
    let tableView = try #require(scrollView.documentView as? NSTableView)
    let rows = [
      nativeToolRow(
        id: "tool-anchor",
        revision: 1,
        record: nativeApprovalToolRecord(id: anchorID),
        batchPresentation: ToolApprovalBatchPresentation(
          anchorID: anchorID,
          pendingApprovalCount: 1,
          showsApproveAll: false
        )
      )
    ]

    coordinator.update(
      rows: rows,
      accessibilityValue: "ready",
      isSpeechEnabled: false,
      activeSpeechRowID: nil,
      toolApprovalPolicy: .automatic,
      in: scrollView
    )
    tableView.layoutSubtreeIfNeeded()

    let cell = try #require(
      tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        as? NativeChatMessageCellView
    )
    let resumeID = "chat.tool.resumeAutomation.\(anchorID.uuidString)"
    let resumeButton = try #require(
      cell.descendantButtons(accessibilityIdentifier: resumeID).first
    )

    #expect(
      cell.descendantButtons(accessibilityIdentifier: "chat.tool.approve.\(anchorID)").isEmpty
    )
    #expect(cell.descendantButtons(accessibilityIdentifier: "chat.tool.deny.\(anchorID)").isEmpty)
    resumeButton.performClick(nil)
    #expect(resumedAnchors == [anchorID])
  }

  @Test
  func askUserControlsDisableWhileGenerating() throws {
    let row = nativeToolRow(
      id: "ask-user",
      revision: 1,
      record: nativeAskUserToolRecord()
    )
    let cell = configuredNativeCell(
      for: row,
      state: NativeTranscriptCellState(isToolActionEnabled: false)
    )
    let popup = try #require(cell.descendants(of: NSPopUpButton.self).first)
    let sendButton = try #require(
      cell.descendants(of: NSButton.self).first(where: { $0.title == "Send" })
    )

    #expect(popup.isEnabled == false)
    #expect(sendButton.isEnabled == false)
  }

  @Test
  func interactiveToolExpansionDoesNotForceScrollToBottom() throws {
    let coordinator = AppKitChatTranscriptRepresentable.Coordinator(
      onToggleSpeech: { _, _ in },
      onApproveToolCall: { _ in },
      onDenyToolCall: { _ in },
      onAnswerAskUser: { _, _ in }
    )
    let scrollView = coordinator.makeScrollView()
    scrollView.setFrameSize(NSSize(width: 760, height: 180))
    let tableView = try #require(scrollView.documentView as? NSTableView)
    let rows = [
      nativeToolRow(
        id: "tool",
        revision: 1,
        record: nativeCompletedCommandToolRecord(
          stdout: nativeSearchLikeToolOutput()
        )
      ),
      nativeAssistantMarkdownRow(
        id: "assistant",
        revision: 1,
        markdown: "Assistant response below the tool call."
      ),
    ]

    coordinator.update(
      rows: rows,
      accessibilityValue: "ready",
      isSpeechEnabled: false,
      activeSpeechRowID: nil,
      in: scrollView
    )
    tableView.layoutSubtreeIfNeeded()
    let initialBottomY = max(tableView.bounds.height - scrollView.contentView.bounds.height, 0)
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: initialBottomY))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    let toolCell = try #require(
      tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        as? NativeChatMessageCellView
    )
    let disclosureButton = try #require(
      toolCell.descendantButtons(accessibilityLabel: "Show details").first
    )
    let originBeforeExpansion = scrollView.contentView.bounds.origin.y

    disclosureButton.performClick(nil)
    tableView.layoutSubtreeIfNeeded()

    let originAfterExpansion = scrollView.contentView.bounds.origin.y
    let expandedBottomY = max(tableView.bounds.height - scrollView.contentView.bounds.height, 0)
    #expect(abs(originAfterExpansion - originBeforeExpansion) < 1.5)
    #expect(expandedBottomY > originBeforeExpansion + 80)
  }

  @Test
  func expandedToolRowDoesNotLeavePageSizedSlackBelowContent() throws {
    let coordinator = AppKitChatTranscriptRepresentable.Coordinator(
      onToggleSpeech: { _, _ in },
      onApproveToolCall: { _ in },
      onDenyToolCall: { _ in },
      onAnswerAskUser: { _, _ in }
    )
    let scrollView = coordinator.makeScrollView()
    scrollView.setFrameSize(NSSize(width: 760, height: 520))
    let tableView = try #require(scrollView.documentView as? NSTableView)
    let rows = [
      nativeToolRow(
        id: "tool",
        revision: 1,
        record: nativeCompletedCommandToolRecord(
          stdout: nativeSearchLikeToolOutput()
        )
      ),
      nativeAssistantMarkdownRow(
        id: "assistant",
        revision: 1,
        markdown: "Assistant response below the tool call."
      ),
    ]

    coordinator.update(
      rows: rows,
      accessibilityValue: "ready",
      isSpeechEnabled: false,
      activeSpeechRowID: nil,
      in: scrollView
    )
    tableView.layoutSubtreeIfNeeded()
    let toolCell = try #require(
      tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        as? NativeChatMessageCellView
    )
    let disclosureButton = try #require(
      toolCell.descendantButtons(accessibilityLabel: "Show details").first
    )

    disclosureButton.performClick(nil)
    tableView.layoutSubtreeIfNeeded()

    let contentHost = try #require(toolCell.subviews.first)
    let bottomSlack = contentHost.frame.minY
    let topSlack = toolCell.bounds.height - contentHost.frame.maxY
    #expect(bottomSlack < 32)
    #expect(topSlack < 32)
  }

  @Test
  func imageAttachmentsUsePreviewHeightInUserRows() {
    let textRow = nativeUserRow(
      id: "user-text-attachment",
      revision: 1,
      attachments: [nativeTextAttachment(displayName: "notes.txt")]
    )
    let imageRow = nativeUserRow(
      id: "user-image-attachment",
      revision: 1,
      attachments: [nativeImageAttachment(displayName: "screen.png")]
    )

    let textHeight = NativeTranscriptRowMeasurer.height(for: textRow, width: 640)
    let imageHeight = NativeTranscriptRowMeasurer.height(for: imageRow, width: 640)

    #expect(imageHeight > textHeight + 80)
  }

  @Test
  func imageAttachmentsUsePreviewHeightInAssistantRows() {
    let row = nativeAssistantRow(
      id: "assistant-image-attachment",
      revision: 1,
      attachments: [nativeImageAttachment(displayName: "result.png")]
    )

    let height = NativeTranscriptRowMeasurer.height(for: row, width: 640)

    #expect(height > NativeTranscriptAttachmentPreviewMetrics.imageHeight)
  }

  @Test
  func attachmentThumbnailDescriptorTracksContentSignature() {
    let attachmentID = AttachmentID()
    let first = nativeImageAttachment(
      id: attachmentID,
      displayName: "screen.png",
      contentSHA256: "first"
    )
    let second = nativeImageAttachment(
      id: attachmentID,
      displayName: "screen.png",
      contentSHA256: "second"
    )

    let firstDescriptor = NativeAttachmentThumbDescriptor(
      attachment: first,
      maxPixelSize: 360
    )
    let secondDescriptor = NativeAttachmentThumbDescriptor(
      attachment: second,
      maxPixelSize: 360
    )

    #expect(firstDescriptor != secondDescriptor)
  }

  @Test
  func userImageAttachmentRendersOutsideMessageBubbleWithoutFilename() {
    let row = nativeUserRow(
      id: "user-image-attachment-button",
      revision: 1,
      content: "Question",
      attachments: [nativeImageAttachment(displayName: "screen.png")]
    )
    let cell = configuredNativeCell(for: row)

    let imageButton = cell.descendants(of: NSButton.self).first { button in
      button.toolTip == "screen.png"
    }
    let messageBubble = cell.descendantViews.first { view in
      view.layer?.cornerRadius == 10 && view.layer?.backgroundColor != nil
    }

    #expect(imageButton != nil)
    #expect(messageBubble != nil)
    if let imageButton, let messageBubble {
      #expect(!imageButton.isDescendant(of: messageBubble))
      #expect(imageButton.descendants(of: NSTextField.self).isEmpty)
    }
  }

  @Test
  func imageOnlyUserRowsDoNotRenderEmptyMessageBubble() {
    let row = nativeUserRow(
      id: "user-image-only",
      revision: 1,
      content: "",
      attachments: [nativeImageAttachment(displayName: "screen.png")]
    )
    let cell = configuredNativeCell(for: row)

    let messageBubbles = cell.descendantViews.filter { view in
      view.layer?.cornerRadius == 10 && view.layer?.backgroundColor != nil
    }

    #expect(messageBubbles.isEmpty)
    #expect(
      cell.descendants(of: NSButton.self).contains { button in
        button.toolTip == "screen.png"
      })
  }

  @Test
  func nativeToolDetailsIncludeApprovalPreviewAndPermissionReason() {
    let record = nativeApprovalToolRecord()
    let details = NativeToolDetailContent(record: record)

    #expect(details.argumentLines.contains("command: uv test"))
    #expect(details.permissionLines.contains("Risk: high"))
    #expect(details.permissionLines.contains("Reason: Needs permission."))
    #expect(details.outputTitle == "Preview")
    #expect(details.outputText == "Runs tests.")
    #expect(details.affectedPaths == ["Package.swift"])
    #expect(details.flags == ["truncated"])
    #expect(!details.isEmpty)
  }

  @Test
  func nativeToolDetailsIncludeAutomaticApprovalSource() {
    var record = nativeCompletedCommandToolRecord()
    record.approvalSource = .automatic

    let details = NativeToolDetailContent(record: record)

    #expect(details.permissionLines == ["Approval: Auto-approved"])
  }

  @Test
  func nativeToolDetailsProjectCompletedCommandOutput() {
    let record = nativeCompletedCommandToolRecord()
    let details = NativeToolDetailContent(record: record)

    #expect(details.argumentLines.contains("command: swift test"))
    #expect(details.outputTitle == "Result")
    #expect(details.outputText?.contains("Tests passed.") == true)
    #expect(details.affectedPaths == ["."])
    #expect(details.flags.isEmpty)
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

  @Test
  func speechButtonAppearsOnlyForReadableAssistantTextWhenEnabled() {
    let textCell = configuredNativeCell(
      for: nativeAssistantMarkdownRow(
        id: "assistant-text",
        revision: 1,
        markdown: "Readable text.",
        spokenText: "Readable text."
      ),
      state: NativeTranscriptCellState(isSpeechEnabled: true)
    )
    let codeCell = configuredNativeCell(
      for: nativeAssistantCodeRow(id: "assistant-code", revision: 1, code: "let value = 1"),
      state: NativeTranscriptCellState(isSpeechEnabled: true)
    )
    let disabledCell = configuredNativeCell(
      for: nativeAssistantMarkdownRow(
        id: "assistant-disabled",
        revision: 1,
        markdown: "Readable text.",
        spokenText: "Readable text."
      )
    )

    #expect(textCell.descendantButtons(accessibilityLabel: "Read message aloud").count == 1)
    #expect(codeCell.descendantButtons(accessibilityLabel: "Read message aloud").isEmpty)
    #expect(disabledCell.descendantButtons(accessibilityLabel: "Read message aloud").isEmpty)
  }

  @Test
  func activeSpeechRowShowsStopButton() {
    let cell = configuredNativeCell(
      for: nativeAssistantMarkdownRow(
        id: "assistant",
        revision: 1,
        markdown: "Readable text.",
        spokenText: "Readable text."
      ),
      state: NativeTranscriptCellState(isSpeechEnabled: true, isSpeaking: true)
    )

    #expect(cell.descendantButtons(accessibilityLabel: "Stop reading message").count == 1)
    #expect(cell.descendantButtons(accessibilityLabel: "Read message aloud").isEmpty)
  }

  @Test
  func sameAssistantRowReconfigureKeepsHostedView() throws {
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test")
    )
    let firstRow = nativeStreamingAssistantRow(id: "assistant", revision: 1, content: "Hel")
    let revisedRow = nativeStreamingAssistantRow(id: "assistant", revision: 2, content: "Hello")

    cell.configure(row: firstRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    let firstHostedView = try #require(cell.hostedContentViewForTesting)
    cell.configure(
      row: revisedRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    let revisedHostedView = try #require(cell.hostedContentViewForTesting)

    #expect(firstHostedView === revisedHostedView)
  }

  @Test
  func sameThinkingRowReconfigureKeepsHostedViewAndHeader() throws {
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test")
    )
    let firstRow = nativeStreamingThinkingRow(
      id: "thinking",
      revision: 1,
      content: "Inspecting"
    )
    let revisedRow = nativeStreamingThinkingRow(
      id: "thinking",
      revision: 2,
      content: "Inspecting the search results"
    )

    cell.configure(row: firstRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    let firstHostedView = try #require(cell.hostedContentViewForTesting)
    let firstHeaderLabel = try #require(
      cell.descendantTextFields.first { $0.stringValue == "Reasoning" })

    cell.configure(
      row: revisedRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    let revisedHostedView = try #require(cell.hostedContentViewForTesting)
    let revisedHeaderLabel = try #require(
      cell.descendantTextFields.first { $0.stringValue == "Reasoning" }
    )

    #expect(firstHostedView === revisedHostedView)
    #expect(firstHeaderLabel === revisedHeaderLabel)
    #expect(cell.descendantTextValues.contains("Inspecting the search results"))
  }

  @Test
  func toolGenerationRateAppearsOnlyInExpandedDetails() throws {
    let metrics = ChatGenerationMetrics(
      generatedTokenCount: 493,
      tokensPerSecond: 12.973,
      durationMs: 38_000
    )
    let row = nativeToolRow(
      id: "tool",
      revision: 1,
      record: nativeCompletedCommandToolRecord(),
      generationMetrics: metrics
    )
    let cell = configuredNativeCell(for: row)

    #expect(!cell.descendantTextValues.contains(metrics.visibleSummary))

    cell.configure(
      row: row,
      state: NativeTranscriptCellState(isToolExpanded: true),
      actions: testNativeActions()
    )

    #expect(cell.descendantTextValues.contains(metrics.visibleSummary))
  }

  @Test
  func toolDisclosureButtonStaysAfterToolHeaderTextWhenExpanded() throws {
    let record = nativeCompletedCommandToolRecord()
    let row = nativeToolRow(id: "tool", revision: 1, record: record)
    let cell = configuredNativeCell(for: row)
    _ = try #require(
      cell.descendantTextFields.first {
        $0.stringValue == ToolName.runCommand.rawValue
      }
    )
    let summaryLabel = try #require(
      cell.descendantTextFields.first { $0.stringValue == "swift test" }
    )
    let collapsedButton = try #require(
      cell.descendantButtons(accessibilityLabel: "Show details").first
    )
    let collapsedFrame = collapsedButton.frame(in: cell)
    let summaryFrame = summaryLabel.frame(in: cell)

    #expect(collapsedFrame.minX >= summaryFrame.maxX)
    #expect(collapsedFrame.minX - summaryFrame.maxX < 12)
    #expect(collapsedFrame.maxX < cell.bounds.width)

    cell.configure(
      row: row,
      state: NativeTranscriptCellState(isToolExpanded: true),
      actions: testNativeActions()
    )
    cell.layoutSubtreeIfNeeded()
    let expandedButton = try #require(
      cell.descendantButtons(accessibilityLabel: "Hide details").first
    )
    let expandedFrame = expandedButton.frame(in: cell)

    #expect(abs(expandedFrame.minX - collapsedFrame.minX) < 1)
  }

  @Test
  func reasoningDisclosureButtonStaysAfterTitleWhenExpanded() throws {
    let row = nativeThinkingRow(id: "thinking", revision: 1)
    let cell = configuredNativeCell(for: row)
    let titleLabel = try #require(
      cell.descendantTextFields.first { $0.stringValue == "Reasoning" }
    )
    let collapsedButton = try #require(
      cell.descendantButtons(accessibilityLabel: "Show reasoning").first
    )
    let collapsedFrame = collapsedButton.frame(in: cell)
    let titleFrame = titleLabel.frame(in: cell)

    #expect(collapsedFrame.minX >= titleFrame.maxX)
    #expect(collapsedFrame.minX - titleFrame.maxX < 12)
    #expect(collapsedFrame.maxX < cell.bounds.width * 0.35)

    cell.configure(
      row: row,
      state: NativeTranscriptCellState(isThinkingExpanded: true),
      actions: testNativeActions()
    )
    cell.layoutSubtreeIfNeeded()
    let expandedButton = try #require(
      cell.descendantButtons(accessibilityLabel: "Hide reasoning").first
    )
    let expandedFrame = expandedButton.frame(in: cell)

    #expect(abs(expandedFrame.minX - collapsedFrame.minX) < 1)
  }

  @Test
  func differentRowOrKindReplacesHostedView() throws {
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test")
    )
    let firstRow = nativeStreamingAssistantRow(id: "assistant", revision: 1, content: "Hello")
    let differentAssistantRow = nativeStreamingAssistantRow(
      id: "other-assistant",
      revision: 1,
      content: "Hello"
    )
    let differentKindRow = nativeUserRow(id: "other-assistant", revision: 2, content: "Question")

    cell.configure(row: firstRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    let firstHostedView = try #require(cell.hostedContentViewForTesting)
    cell.configure(
      row: differentAssistantRow,
      state: NativeTranscriptCellState(),
      actions: testNativeActions()
    )
    let differentRowHostedView = try #require(cell.hostedContentViewForTesting)
    cell.configure(
      row: differentKindRow,
      state: NativeTranscriptCellState(),
      actions: testNativeActions()
    )
    let differentKindHostedView = try #require(cell.hostedContentViewForTesting)

    #expect(firstHostedView !== differentRowHostedView)
    #expect(differentRowHostedView !== differentKindHostedView)
  }

  @Test
  func streamingAssistantViewUpdatesPlaceholderTextAndFinalMarkdown() throws {
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test")
    )
    let placeholderRow = nativeStreamingAssistantRow(id: "assistant", revision: 1, content: "")
    let streamingRow = nativeStreamingAssistantRow(id: "assistant", revision: 2, content: "**bo")
    let finalRow = nativeAssistantMarkdownRow(
      id: "assistant",
      revision: 3,
      markdown: "**bold**"
    )

    cell.configure(
      row: placeholderRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    let hostedView = try #require(cell.hostedContentViewForTesting)
    #expect(cell.descendantTextValues.contains("Generating"))

    cell.configure(
      row: streamingRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    let streamingHostedView = try #require(cell.hostedContentViewForTesting)
    #expect(hostedView === streamingHostedView)
    #expect(cell.descendantTextValues.contains("**bo"))
    #expect(!cell.descendantTextValues.contains("Generating"))

    cell.configure(row: finalRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    let finalHostedView = try #require(cell.hostedContentViewForTesting)
    #expect(hostedView === finalHostedView)
    #expect(cell.descendantTextValues.contains { $0.contains("bold") })
    #expect(!cell.descendantTextValues.contains("**bold**"))
  }

  @Test
  func finalAssistantReconfigureWithUnchangedRevisionKeepsContentViews() throws {
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test")
    )
    let row = nativeAssistantMarkdownRow(
      id: "assistant",
      revision: 1,
      markdown: "Stable answer text."
    )
    let revisedRow = nativeAssistantMarkdownRow(
      id: "assistant",
      revision: 2,
      markdown: "Stable answer text with more content."
    )

    cell.configure(row: row, state: NativeTranscriptCellState(), actions: testNativeActions())
    let initialLabel = try #require(
      cell.descendantTextFields.first { $0.stringValue.contains("Stable") }
    )

    cell.configure(
      row: row,
      state: NativeTranscriptCellState(isCopied: true),
      actions: testNativeActions()
    )
    let labelAfterFooterStateChange = try #require(
      cell.descendantTextFields.first { $0.stringValue.contains("Stable") }
    )
    #expect(labelAfterFooterStateChange === initialLabel)

    cell.configure(
      row: revisedRow,
      state: NativeTranscriptCellState(),
      actions: testNativeActions()
    )
    let labelAfterContentChange = try #require(
      cell.descendantTextFields.first { $0.stringValue.contains("Stable") }
    )
    #expect(labelAfterContentChange !== initialLabel)
    #expect(labelAfterContentChange.stringValue.contains("more content"))
  }

  @Test
  func highlightCompletionRecolorsCodeLabelWithoutRebuild() throws {
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test")
    )
    let code = "let value = 1"
    let row = nativeAssistantCodeRow(id: "assistant", revision: 1, code: code)
    let highlightStore = HighlightedCodeTestStore()
    var actions = testNativeActions()
    actions.highlightedCode = { _, _ in highlightStore.value }

    cell.configure(row: row, state: NativeTranscriptCellState(), actions: actions)
    let codeLabel = try #require(
      cell.descendantTextFields.first { $0.stringValue == code }
    )
    let plainColor =
      codeLabel.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil)
      as? NSColor

    highlightStore.value = HighlightedCode(
      code: code,
      language: CodeLanguage(fenceLanguage: "js"),
      spans: [
        HighlightSpan(
          range: HighlightTextRange(location: 0, length: 3),
          style: .keyword
        )
      ]
    )
    cell.applyAvailableCodeHighlights(rowID: "assistant")

    let labelAfterHighlight = try #require(
      cell.descendantTextFields.first { $0.stringValue == code }
    )
    #expect(labelAfterHighlight === codeLabel)
    let keywordColor =
      labelAfterHighlight.attributedStringValue.attribute(
        .foregroundColor, at: 0, effectiveRange: nil
      ) as? NSColor
    #expect(keywordColor == NativeTranscriptCodeRenderer.color(for: .keyword))
    #expect(keywordColor != plainColor)
  }

  @Test
  func thumbnailArrivalRebuildsAssistantAttachmentContent() throws {
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test")
    )
    let row = nativeAssistantRow(
      id: "assistant",
      revision: 1,
      attachments: [nativeImageAttachment(displayName: "diagram.png")]
    )
    var thumbnail: NSImage?
    var actions = testNativeActions()
    actions.attachmentThumbnail = { _, _ in thumbnail }

    cell.configure(row: row, state: NativeTranscriptCellState(), actions: actions)
    #expect(
      !cell.descendants(of: NSImageView.self).contains { $0.image === thumbnail }
    )

    let loadedThumbnail = NSImage(size: NSSize(width: 8, height: 8))
    thumbnail = loadedThumbnail
    cell.configure(row: row, state: NativeTranscriptCellState(), actions: actions)
    #expect(
      cell.descendants(of: NSImageView.self).contains { $0.image === loadedThumbnail }
    )
  }

  @Test
  func streamingTextAppendsIntoTheSameTextViewStorage() throws {
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test")
    )
    let firstRow = nativeStreamingAssistantRow(id: "assistant", revision: 1, content: "Hello")
    let grownRow = nativeStreamingAssistantRow(
      id: "assistant",
      revision: 2,
      content: "Hello world, streaming continues."
    )
    let replacedRow = nativeStreamingAssistantRow(
      id: "assistant",
      revision: 3,
      content: "Regenerated from scratch."
    )

    cell.configure(row: firstRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    let textView = try #require(cell.descendants(of: NativeStreamingTextView.self).first)
    #expect(textView.string == "Hello")

    cell.configure(row: grownRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    let textViewAfterAppend = try #require(
      cell.descendants(of: NativeStreamingTextView.self).first
    )
    #expect(textViewAfterAppend === textView)
    #expect(textViewAfterAppend.string == "Hello world, streaming continues.")

    cell.configure(
      row: replacedRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    #expect(textView.string == "Regenerated from scratch.")
  }

  @Test
  func streamingThinkingTextAppendsIntoTheSameTextView() throws {
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test")
    )
    let firstRow = nativeStreamingThinkingRow(id: "thinking", revision: 1, content: "Inspecting")
    let grownRow = nativeStreamingThinkingRow(
      id: "thinking",
      revision: 2,
      content: "Inspecting the workspace carefully."
    )

    let expandedState = NativeTranscriptCellState(isThinkingExpanded: true)
    cell.configure(row: firstRow, state: expandedState, actions: testNativeActions())
    #expect(cell.descendants(of: NativeReasoningTickerView.self).isEmpty)
    let textView = try #require(cell.descendants(of: NativeStreamingTextView.self).first)
    #expect(textView.string == "Inspecting")

    cell.configure(row: grownRow, state: expandedState, actions: testNativeActions())
    let textViewAfterAppend = try #require(
      cell.descendants(of: NativeStreamingTextView.self).first
    )
    #expect(textViewAfterAppend === textView)
    #expect(textViewAfterAppend.string == "Inspecting the workspace carefully.")
  }

  @Test
  func collapsedStreamingThinkingShowsFixedHeightLiveTicker() throws {
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test")
    )
    let firstRow = nativeStreamingThinkingRow(
      id: "thinking",
      revision: 1,
      content: "Inspecting the workspace."
    )
    let grownRow = nativeStreamingThinkingRow(
      id: "thinking",
      revision: 2,
      content: "Inspecting the workspace.\nComparing candidate files."
    )

    cell.configure(row: firstRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    let ticker = try #require(cell.descendants(of: NativeReasoningTickerView.self).first)
    #expect(ticker.textForTesting == "Inspecting the workspace.")
    let tickerHeight = ticker.intrinsicContentSize.height
    let threeLineFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    #expect(tickerHeight >= NSLayoutManager().defaultLineHeight(for: threeLineFont) * 3)

    cell.configure(row: grownRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    let grownTicker = try #require(cell.descendants(of: NativeReasoningTickerView.self).first)
    #expect(grownTicker === ticker)
    #expect(ticker.textForTesting == "Inspecting the workspace.\nComparing candidate files.")
    #expect(ticker.intrinsicContentSize.height == tickerHeight)
    #expect(cell.descendantTextValues.contains("Reasoning"))
  }

  @Test
  func collapsedStreamingThinkingKeepsMeasuredHeightConstant() {
    let shortRow = nativeStreamingThinkingRow(id: "thinking", revision: 1, content: "Inspecting")
    let grownRow = nativeStreamingThinkingRow(
      id: "thinking",
      revision: 2,
      content: "Inspecting\n"
        + String(repeating: "More reasoning that would wrap over many lines. ", count: 12)
    )

    let shortHeight = NativeTranscriptRowMeasurer.height(for: shortRow, width: 640)
    let grownHeight = NativeTranscriptRowMeasurer.height(for: grownRow, width: 640)
    let expandedHeight = NativeTranscriptRowMeasurer.height(
      for: grownRow,
      width: 640,
      state: NativeTranscriptCellState(isThinkingExpanded: true)
    )

    #expect(shortHeight == grownHeight)
    #expect(expandedHeight > grownHeight)
  }

  @Test
  func completedThinkingShowsReasonedForDuration() throws {
    let startedAt = Date(timeIntervalSinceReferenceDate: 1000)
    let row = nativeCompletedThinkingRow(
      id: "thinking",
      revision: 3,
      content: "Weighed the options.",
      startedAt: startedAt,
      completedAt: startedAt.addingTimeInterval(12.2)
    )
    let cell = configuredNativeCell(for: row)

    #expect(cell.descendantTextValues.contains("Reasoned for 12s"))
    #expect(cell.descendants(of: NativeStreamingTextView.self).isEmpty)
  }

  @Test
  func reasoningTitleReflectsStatusAndDuration() {
    let startedAt = Date(timeIntervalSinceReferenceDate: 0)
    func message(
      status: AssistantThinkingMessage.DeliveryStatus,
      duration: TimeInterval? = nil
    ) -> AssistantThinkingMessage {
      AssistantThinkingMessage(
        content: "Reasoning text.",
        deliveryStatus: status,
        startedAt: duration.map { _ in startedAt },
        completedAt: duration.map { startedAt.addingTimeInterval($0) }
      )
    }

    #expect(
      NativeAssistantThinkingView.reasoningTitle(for: message(status: .streaming)) == "Reasoning")
    #expect(
      NativeAssistantThinkingView.reasoningTitle(for: message(status: .complete)) == "Reasoning")
    #expect(
      NativeAssistantThinkingView.reasoningTitle(for: message(status: .cancelled, duration: 8))
        == "Reasoning")
    #expect(
      NativeAssistantThinkingView.reasoningTitle(for: message(status: .complete, duration: 0.3))
        == "Reasoned for 1s")
    #expect(
      NativeAssistantThinkingView.reasoningTitle(for: message(status: .complete, duration: 12.2))
        == "Reasoned for 12s")
    #expect(
      NativeAssistantThinkingView.reasoningTitle(for: message(status: .complete, duration: 75))
        == "Reasoned for 1m 15s")
  }

  @Test
  func tickerWindowKeepsParagraphAlignedTail() {
    #expect(NativeAssistantThinkingView.tickerWindow(for: "Short reasoning.") == "Short reasoning.")

    let longContent = (1...100)
      .map { "Paragraph number \($0) weighs additional evidence." }
      .joined(separator: "\n")
    let window = NativeAssistantThinkingView.tickerWindow(for: longContent)
    #expect(window.count < 2400)
    #expect(window.hasPrefix("Paragraph number"))
    #expect(window.hasSuffix("Paragraph number 100 weighs additional evidence."))

    let giantParagraph = String(repeating: "y", count: 5000)
    #expect(NativeAssistantThinkingView.tickerWindow(for: giantParagraph).count == 2400)
  }

  @Test
  func streamingBlocksRenderMarkdownTailInPlace() throws {
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test")
    )
    let firstRow = nativeStreamingBlocksAssistantRow(
      id: "assistant",
      revision: 1,
      content: "Streaming **bold** prose"
    )
    let grownRow = nativeStreamingBlocksAssistantRow(
      id: "assistant",
      revision: 2,
      content: "Streaming **bold** prose keeps going"
    )

    cell.configure(row: firstRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    let blocksView = try #require(
      cell.descendants(of: NativeStreamingAssistantBlocksView.self).first
    )
    // Markdown is applied live: the asterisks are consumed by the renderer.
    let tailLabel = try #require(
      blocksView.descendantTextFields.first { $0.stringValue == "Streaming bold prose" }
    )

    cell.configure(row: grownRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    #expect(cell.descendants(of: NativeStreamingAssistantBlocksView.self).first === blocksView)
    #expect(tailLabel.stringValue == "Streaming bold prose keeps going")
    #expect(tailLabel.superview != nil)
  }

  @Test
  func streamingBlocksFreezeParagraphsAtBlankLines() throws {
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test")
    )
    let firstRow = nativeStreamingBlocksAssistantRow(
      id: "assistant",
      revision: 1,
      content: "First paragraph.\n\nSecond paragraph starts"
    )
    let grownRow = nativeStreamingBlocksAssistantRow(
      id: "assistant",
      revision: 2,
      content: "First paragraph.\n\nSecond paragraph starts and grows"
    )

    cell.configure(row: firstRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    let finalizedLabel = try #require(
      cell.descendantTextFields.first { $0.stringValue == "First paragraph." }
    )
    _ = try #require(
      cell.descendantTextFields.first { $0.stringValue == "Second paragraph starts" }
    )

    cell.configure(row: grownRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    let finalizedLabelAfterGrowth = try #require(
      cell.descendantTextFields.first { $0.stringValue == "First paragraph." }
    )
    #expect(finalizedLabelAfterGrowth === finalizedLabel)
    #expect(
      cell.descendantTextValues.contains("Second paragraph starts and grows")
    )
  }

  @Test
  func streamingBlocksShowLiveOpenCodeBlock() throws {
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test")
    )
    let openRow = nativeStreamingBlocksAssistantRow(
      id: "assistant",
      revision: 1,
      content: "Intro.\n\n```swift\nlet value = 1"
    )
    let grownRow = nativeStreamingBlocksAssistantRow(
      id: "assistant",
      revision: 2,
      content: "Intro.\n\n```swift\nlet value = 1\nlet other = 2"
    )

    cell.configure(row: openRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    let codeTail = try #require(cell.descendants(of: NativeStreamingCodeBlockView.self).first)
    #expect(codeTail.codeTextForTesting == "let value = 1")
    #expect(cell.descendants(of: NativeCodeBlockView.self).isEmpty)
    #expect(cell.descendantTextValues.contains("swift"))

    cell.configure(row: grownRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    let grownCodeTail = try #require(
      cell.descendants(of: NativeStreamingCodeBlockView.self).first
    )
    #expect(grownCodeTail === codeTail)
    #expect(codeTail.codeTextForTesting == "let value = 1\nlet other = 2")
  }

  @Test
  func streamingBlocksSwapClosedCodeBlockToFinalViewAndRequestHighlight() throws {
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test")
    )
    let requestedBlocks = HighlightRequestRecorder()
    var actions = testNativeActions()
    actions.requestCodeHighlight = { rowID, codeBlock in
      requestedBlocks.record(rowID: rowID, codeBlock: codeBlock)
    }
    let openRow = nativeStreamingBlocksAssistantRow(
      id: "assistant",
      revision: 1,
      content: "Intro.\n\n```swift\nlet value = 1"
    )
    let closedRow = nativeStreamingBlocksAssistantRow(
      id: "assistant",
      revision: 2,
      content: "Intro.\n\n```swift\nlet value = 1\n```\nOutro begins"
    )

    cell.configure(row: openRow, state: NativeTranscriptCellState(), actions: actions)
    #expect(requestedBlocks.requests.isEmpty)

    cell.configure(row: closedRow, state: NativeTranscriptCellState(), actions: actions)
    #expect(cell.descendants(of: NativeStreamingCodeBlockView.self).isEmpty)
    let finalCodeView = try #require(cell.descendants(of: NativeCodeBlockView.self).first)
    #expect(finalCodeView.codeBlock.isClosed)
    #expect(finalCodeView.codeBlock.text == "let value = 1\n")
    #expect(requestedBlocks.requests.count == 1)
    #expect(requestedBlocks.requests.first?.rowID == "assistant")
    #expect(cell.descendantTextValues.contains("Outro begins"))
  }

  @Test
  func streamingBlocksResetOnNonPrefixRegeneration() throws {
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test")
    )
    let firstRow = nativeStreamingBlocksAssistantRow(
      id: "assistant",
      revision: 1,
      content: "First draft.\n\nWith two paragraphs"
    )
    let regeneratedRow = nativeStreamingBlocksAssistantRow(
      id: "assistant",
      revision: 2,
      content: "Rewritten from scratch"
    )

    cell.configure(row: firstRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    #expect(cell.descendantTextValues.contains("First draft."))

    cell.configure(
      row: regeneratedRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    #expect(cell.descendantTextValues.contains("Rewritten from scratch"))
    #expect(!cell.descendantTextValues.contains("First draft."))
  }

  @Test
  func streamingBlocksWrapToMeasurementWidth() {
    let row = nativeStreamingBlocksAssistantRow(
      id: "assistant",
      revision: 1,
      content: "Intro paragraph.\n\n"
        + String(
          repeating: "Streaming markdown that wraps across several lines at narrow widths. ",
          count: 8
        )
    )

    let wideHeight = NativeTranscriptRowMeasurer.height(for: row, width: 640)
    let narrowHeight = NativeTranscriptRowMeasurer.height(for: row, width: 360)

    #expect(narrowHeight > wideHeight)
    #expect(wideHeight > 44)
  }

  @Test
  func streamingTextViewLimitsHitTestingToLaidOutText() throws {
    let row = nativeStreamingAssistantRow(id: "assistant", revision: 1, content: "Ok.")
    let cell = configuredNativeCell(for: row)
    let textView = try #require(cell.descendants(of: NativeStreamingTextView.self).first)
    let superview = try #require(textView.superview)

    let insideText = superview.convert(
      NSPoint(x: 2, y: textView.bounds.midY), from: textView
    )
    let besideText = superview.convert(
      NSPoint(x: textView.bounds.maxX - 2, y: textView.bounds.midY), from: textView
    )

    #expect(textView.bounds.width > 200)
    #expect(textView.hitTest(insideText) != nil)
    #expect(textView.hitTest(besideText) == nil)
  }

  @Test
  func streamingTextViewExposesStaticTextAccessibilityRole() throws {
    let row = nativeStreamingAssistantRow(id: "assistant", revision: 1, content: "Hello")
    let cell = configuredNativeCell(for: row)
    let textView = try #require(cell.descendants(of: NativeStreamingTextView.self).first)

    #expect(textView.accessibilityRole() == .staticText)
  }

  @Test
  func streamingTextWrapsToMeasurementWidth() {
    let row = nativeStreamingAssistantRow(
      id: "assistant",
      revision: 1,
      content: String(
        repeating: "Streaming text that wraps across several lines at narrow widths. ",
        count: 8
      )
    )

    let wideHeight = NativeTranscriptRowMeasurer.height(for: row, width: 640)
    let narrowHeight = NativeTranscriptRowMeasurer.height(for: row, width: 360)

    #expect(narrowHeight > wideHeight)
    #expect(wideHeight > 44)
  }
}

private func revisionMap(_ rows: [NativeTranscriptRow]) -> [String: Int] {
  Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.revision) })
}

private func nativeUserRow(
  id: String,
  revision: Int,
  content: String = "Question",
  attachments: [ChatAttachment] = []
) -> NativeTranscriptRow {
  NativeTranscriptRow(
    id: id,
    revision: revision,
    body: .item(
      RenderedChatTurnItem(
        id: id,
        item: .userMessage(UserTurnMessage(content: content, attachments: attachments)),
        generationMetrics: nil,
        assistantRenderBlocks: [],
        renderRevision: revision
      ))
  )
}

private func nativeAssistantRow(
  id: String,
  revision: Int,
  attachments: [ChatAttachment] = []
) -> NativeTranscriptRow {
  NativeTranscriptRow(
    id: id,
    revision: revision,
    body: .item(
      RenderedChatTurnItem(
        id: id,
        item: .assistantMessage(
          AssistantTurnMessage(content: "Answer", attachments: attachments)
        ),
        generationMetrics: nil,
        assistantRenderBlocks: [
          .paragraph(.init(id: .init(rawValue: "answer"), text: "Answer"))
        ],
        renderRevision: revision
      ))
  )
}

private func nativeThinkingRow(
  id: String,
  revision: Int
) -> NativeTranscriptRow {
  NativeTranscriptRow(
    id: id,
    revision: revision,
    body: .item(
      RenderedChatTurnItem(
        id: id,
        item: .assistantThinking(
          AssistantThinkingMessage(content: "Inspecting the prompt.")
        ),
        generationMetrics: nil,
        assistantRenderBlocks: [],
        renderRevision: revision
      ))
  )
}

private func nativeStreamingThinkingRow(
  id: String,
  revision: Int,
  content: String
) -> NativeTranscriptRow {
  NativeTranscriptRow(
    id: id,
    revision: revision,
    body: .item(
      RenderedChatTurnItem(
        id: id,
        item: .assistantThinking(
          AssistantThinkingMessage(content: content, deliveryStatus: .streaming)
        ),
        generationMetrics: nil,
        assistantRenderBlocks: [],
        renderRevision: revision
      ))
  )
}

private func nativeCompletedThinkingRow(
  id: String,
  revision: Int,
  content: String,
  startedAt: Date,
  completedAt: Date
) -> NativeTranscriptRow {
  NativeTranscriptRow(
    id: id,
    revision: revision,
    body: .item(
      RenderedChatTurnItem(
        id: id,
        item: .assistantThinking(
          AssistantThinkingMessage(
            content: content,
            deliveryStatus: .complete,
            startedAt: startedAt,
            completedAt: completedAt
          )
        ),
        generationMetrics: nil,
        assistantRenderBlocks: [],
        renderRevision: revision
      ))
  )
}

private func nativeAssistantCodeRow(
  id: String,
  revision: Int,
  code: String
) -> NativeTranscriptRow {
  NativeTranscriptRow(
    id: id,
    revision: revision,
    body: .item(
      RenderedChatTurnItem(
        id: id,
        item: .assistantMessage(AssistantTurnMessage(content: code)),
        generationMetrics: nil,
        assistantRenderBlocks: [
          .codeBlock(
            .init(
              id: .init(rawValue: "code"),
              language: "js",
              text: code,
              isClosed: true
            ))
        ],
        renderRevision: revision
      ))
  )
}

private func nativeAssistantMarkdownRow(
  id: String,
  revision: Int,
  markdown: String,
  spokenText: String? = nil
) -> NativeTranscriptRow {
  NativeTranscriptRow(
    id: id,
    revision: revision,
    body: .item(
      RenderedChatTurnItem(
        id: id,
        item: .assistantMessage(AssistantTurnMessage(content: markdown)),
        generationMetrics: nil,
        assistantRenderBlocks: [
          .paragraph(.init(id: .init(rawValue: "markdown"), text: markdown))
        ],
        assistantSpokenText: spokenText,
        renderRevision: revision
      ))
  )
}

private func nativeStreamingAssistantRow(
  id: String,
  revision: Int,
  content: String
) -> NativeTranscriptRow {
  NativeTranscriptRow(
    id: id,
    revision: revision,
    body: .item(
      RenderedChatTurnItem(
        id: id,
        item: .assistantMessage(
          AssistantTurnMessage(content: content, deliveryStatus: .streaming)
        ),
        generationMetrics: nil,
        assistantRenderBlocks: [],
        renderRevision: revision
      ))
  )
}

// Mirrors the renderer's streaming path: raw-parsed blocks, no preprocessor.
private func nativeStreamingBlocksAssistantRow(
  id: String,
  revision: Int,
  content: String
) -> NativeTranscriptRow {
  NativeTranscriptRow(
    id: id,
    revision: revision,
    body: .item(
      RenderedChatTurnItem(
        id: id,
        item: .assistantMessage(
          AssistantTurnMessage(content: content, deliveryStatus: .streaming)
        ),
        generationMetrics: nil,
        assistantRenderBlocks: AssistantRenderBlockParser().parse(content),
        renderRevision: revision
      ))
  )
}

private func nativeToolRow(
  id: String,
  revision: Int,
  record: ToolCallRecord = nativeToolRecord(),
  generationMetrics: ChatGenerationMetrics? = nil,
  batchPresentation: ToolApprovalBatchPresentation? = nil
) -> NativeTranscriptRow {
  return NativeTranscriptRow(
    id: id,
    revision: revision,
    body: .item(
      RenderedChatTurnItem(
        id: id,
        item: .tool(record),
        generationMetrics: generationMetrics,
        assistantRenderBlocks: [],
        renderRevision: revision,
        toolBatchPresentation: batchPresentation
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

private func nativeApprovalToolRecord(
  id: UUID = UUID(),
  reason: String = "Needs permission."
) -> ToolCallRecord {
  let request = nativeRunCommandRequest(id: id, command: "uv test")
  return ToolCallRecord(
    request: request,
    evaluation: ToolPermissionEvaluation(
      decision: .requiresApproval,
      reason: reason,
      riskLevel: .high
    ),
    state: .awaitingApproval(
      preview: ToolResultPreview(
        text: "Runs tests.",
        truncated: true,
        affectedPaths: ["Package.swift"]
      ))
  )
}

private func nativeCompletedCommandToolRecord(stdout: String = "Tests passed.") -> ToolCallRecord {
  let request = nativeRunCommandRequest(command: "swift test")
  return ToolCallRecord(
    request: request,
    evaluation: ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Allowed for test.",
      riskLevel: .low
    ),
    state: .completed(
      .runCommand(
        RunCommandResult(
          command: "swift test",
          timeoutSeconds: 120,
          exitCode: 0,
          durationMs: 1_000,
          stdout: ToolTextOutput(text: stdout),
          stderr: ToolTextOutput(text: "")
        )))
  )
}

private func nativeAskUserToolRecord() -> ToolCallRecord {
  let input = AskUserInput(question: "Which option?", options: ["One", "Two"])
  let request = ToolCallRequest.validated(
    raw: RawToolCallRequest(
      workspaceID: UUID(),
      sessionID: UUID(),
      toolName: .askUser,
      arguments: [
        "question": .string(input.question),
        "option1": .string(input.options[0]),
        "option2": .string(input.options[1]),
      ]
    ),
    payload: .askUser(input)
  )
  return ToolCallRecord(
    request: request,
    evaluation: ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Allowed for test.",
      riskLevel: .low
    ),
    state: .awaitingUserAnswer
  )
}

private func nativeSearchLikeToolOutput() -> String {
  """
  Search provider: DuckDuckGo
  Query: best movies 2010 France

  1. List of French films of 2010 - Wikipedia
  https://en.wikipedia.org/wiki/List_of_French_films_of_2010
  A list of French-produced or co-produced films released in France in 2010. 263 French films were released in 2010.

  2. The 20 Best French Movies of the Decade (2010s) - High On Films
  https://www.highonfilms.com/best-french-movies-of-the-decade-2010s/
  Best French Movies of the Last Decade (2010s): French cinema keeps producing interpersonal drama, politics, naturalism, and unpredictable human complexity.

  3. Top films francais des annees 2010 - Cine
  https://www.allocine.fr/film/meilleurs/pays-5001/decennie-2010/
  Quels sont les meilleurs films francais des annees 2010 ? Decouvrez notre classement des meilleurs films francais des annees 2010.

  4. Top 100 des meilleurs films de 2010 - SensCritique
  https://www.senscritique.com/top/resultats/les_meilleurs_films_de_2010/748463
  Inception (2010), sortie en France le 20 juillet 2010, action, thriller, science-fiction.

  5. Cinema francais des annees 2010 - Wikipedia
  https://fr.wikipedia.org/wiki/Cinema_francais_des_annees_2010
  Cette liste comporte les films ayant depasse le million d'entrees au box-office.
  """
}

private func nativeRunCommandRequest(id: UUID = UUID(), command: String) -> ToolCallRequest {
  ToolCallRequest.validated(
    raw: RawToolCallRequest(
      id: id,
      workspaceID: UUID(),
      sessionID: UUID(),
      toolName: .runCommand,
      arguments: ["command": .string(command)]
    ),
    payload: .runCommand(
      RunCommandInput(
        command: command,
        timeoutSeconds: RunCommandInput.defaultTimeoutSeconds
      ))
  )
}

private func nativeTextAttachment(
  id: AttachmentID = AttachmentID(),
  displayName: String
) -> ChatAttachment {
  ChatAttachment(
    id: id,
    displayName: displayName,
    payload: .text(
      TextAttachmentPayload(
        content: "Attachment body",
        byteSize: 15,
        contentSHA256: "text-\(displayName)"
      ))
  )
}

private func nativeImageAttachment(
  id: AttachmentID = AttachmentID(),
  displayName: String,
  contentSHA256: String = "image-hash"
) -> ChatAttachment {
  ChatAttachment(
    id: id,
    displayName: displayName,
    payload: .image(
      ImageAttachmentPayload(
        mimeType: "image/png",
        byteSize: 1024,
        contentSHA256: contentSHA256
      ))
  )
}

@MainActor
private func configuredNativeCell(
  for row: NativeTranscriptRow,
  state: NativeTranscriptCellState = NativeTranscriptCellState()
) -> NativeChatMessageCellView {
  let cell = NativeChatMessageCellView(
    identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test")
  )
  cell.translatesAutoresizingMaskIntoConstraints = false
  cell.configure(
    row: row,
    state: state,
    actions: testNativeActions()
  )
  cell.setFrameSize(NSSize(width: 640, height: 240))
  let widthConstraint = cell.widthAnchor.constraint(equalToConstant: 640)
  widthConstraint.isActive = true
  cell.layoutSubtreeIfNeeded()
  return cell
}

@MainActor
private final class HighlightRequestRecorder {
  struct Request {
    let rowID: String
    let codeBlock: AssistantRenderBlock.CodeBlock
  }

  private(set) var requests: [Request] = []

  func record(rowID: String, codeBlock: AssistantRenderBlock.CodeBlock) {
    requests.append(Request(rowID: rowID, codeBlock: codeBlock))
  }
}

@MainActor
private final class HighlightedCodeTestStore {
  var value: HighlightedCode?
}

@MainActor
private func testNativeActions() -> NativeTranscriptCellActions {
  NativeTranscriptCellActions(
    markdownBlocks: NativeTranscriptMarkdownRenderer.blocks,
    highlightedCode: { _, _ in nil },
    requestCodeHighlight: { _, _ in },
    attachmentThumbnail: { _, _ in nil },
    requestAttachmentThumbnail: { _, _, _ in },
    showImageAttachment: { _, _ in },
    copy: { _, _ in },
    toggleSpeech: { _, _ in },
    approve: { _ in },
    approveAll: { _ in },
    resumeAutomation: { _ in },
    deny: { _ in },
    answerAskUser: { _, _, _ in },
    toggleToolExpansion: { _ in },
    toggleThinkingExpansion: { _ in },
    updateAskUserSelection: { _, _ in }
  )
}

extension NSView {
  fileprivate var descendantViews: [NSView] {
    subviews + subviews.flatMap(\.descendantViews)
  }

  fileprivate func descendants<View: NSView>(of type: View.Type) -> [View] {
    descendantViews.compactMap { $0 as? View }
  }

  fileprivate func descendantButtons(accessibilityLabel: String) -> [NSButton] {
    descendants(of: NSButton.self).filter {
      $0.accessibilityLabel() == accessibilityLabel
    }
  }

  fileprivate func frame(in ancestor: NSView) -> NSRect {
    convert(bounds, to: ancestor)
  }

  fileprivate var descendantTextValues: [String] {
    descendantTextFields.map(\.stringValue) + descendants(of: NSTextView.self).map(\.string)
  }

  fileprivate var descendantTextFields: [NSTextField] {
    descendants(of: NSTextField.self)
  }

  fileprivate func descendantButtons(accessibilityIdentifier: String) -> [NSButton] {
    descendants(of: NSButton.self).filter {
      $0.accessibilityIdentifier() == accessibilityIdentifier
    }
  }
}
