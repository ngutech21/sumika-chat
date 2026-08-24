import AppKit
import Testing

@testable import SumikaApp
@testable import SumikaCore

@MainActor
struct AppKitChatTranscriptDiffPlanTests {
  @Test
  func cellKindsUseDistinctReuseIdentifiers() {
    let kinds: [NativeTranscriptCellKind] = [
      .userMessage,
      .assistantThinking,
      .assistantMessage,
      .tool,
      .generationIndicator,
    ]

    #expect(Set(kinds.map(\.reuseIdentifier)).count == kinds.count)
  }

  @Test
  func transcriptViewportCannotScrollHorizontally() throws {
    let coordinator = AppKitChatTranscriptRepresentable.Coordinator(
      onToggleSpeech: { _, _ in },
      onApproveToolCall: { _ in },
      onDenyToolCall: { _ in },
      onAnswerAskUser: { _, _ in }
    )
    let scrollView = coordinator.makeScrollView()
    scrollView.setFrameSize(NSSize(width: 640, height: 300))
    scrollView.layoutSubtreeIfNeeded()
    let tableView = try #require(scrollView.documentView as? NSTableView)

    coordinator.update(
      rows: [],
      accessibilityValue: "ready",
      isSpeechEnabled: false,
      activeSpeechRowID: nil,
      in: scrollView
    )
    tableView.layoutSubtreeIfNeeded()
    scrollView.layoutSubtreeIfNeeded()

    let clipView = scrollView.contentView
    let proposedBounds = NSRect(
      x: 100,
      y: clipView.bounds.origin.y,
      width: clipView.bounds.width,
      height: clipView.bounds.height
    )
    let constrainedBounds = clipView.constrainBoundsRect(proposedBounds)

    #expect(scrollView.horizontalScrollElasticity == .none)
    #expect(tableView.frame.width == clipView.bounds.width)
    #expect(constrainedBounds.origin.x == 0)
  }

  @Test
  func scrollWheelHitTestingStopsAtTableBoundaryButClicksReachContent() throws {
    let coordinator = AppKitChatTranscriptRepresentable.Coordinator(
      onToggleSpeech: { _, _ in },
      onApproveToolCall: { _ in },
      onDenyToolCall: { _ in },
      onAnswerAskUser: { _, _ in }
    )
    let scrollView = coordinator.makeScrollView()
    scrollView.setFrameSize(NSSize(width: 640, height: 300))
    coordinator.update(
      rows: [nativeUserRow(id: "user", revision: 1, content: "Question")],
      accessibilityValue: "ready",
      isSpeechEnabled: false,
      activeSpeechRowID: nil,
      in: scrollView
    )
    scrollView.layoutSubtreeIfNeeded()

    let tableView = try #require(scrollView.documentView as? NativeTranscriptNSTableView)
    let cell = try #require(
      tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NativeChatMessageCellView
    )
    cell.layoutSubtreeIfNeeded()
    let copyButton = try #require(
      cell.descendantButtons(accessibilityLabel: "Copy message").first
    )
    let buttonCenter = NSPoint(x: copyButton.bounds.midX, y: copyButton.bounds.midY)
    let hitPoint = copyButton.convert(buttonCenter, to: tableView.superview)

    #expect(tableView.hitTest(hitPoint, eventType: .scrollWheel) === tableView)
    #expect(tableView.hitTest(hitPoint, eventType: .leftMouseDown) === copyButton)
  }

  @Test
  func reusedIconButtonKeepsItsSymbolViewStateWhenConfigurationIsUnchanged() throws {
    let button = NativeReusableRowViewStyle.iconButton()
    button.configureIcon(
      systemSymbolName: "doc.on.doc",
      accessibilityLabel: "Copy message",
      tintColor: .secondaryLabelColor
    )
    let initialImage = try #require(button.image)

    button.configureIcon(
      systemSymbolName: "doc.on.doc",
      accessibilityLabel: "Copy message",
      tintColor: .secondaryLabelColor
    )
    #expect(button.image === initialImage)

    button.configureIcon(
      systemSymbolName: "checkmark",
      accessibilityLabel: "Copied",
      tintColor: .secondaryLabelColor
    )
    button.configureIcon(
      systemSymbolName: "doc.on.doc",
      accessibilityLabel: "Copy message",
      tintColor: .secondaryLabelColor
    )
    #expect(button.image === initialImage)

    let otherButton = NativeReusableRowViewStyle.iconButton()
    otherButton.configureIcon(
      systemSymbolName: "doc.on.doc",
      accessibilityLabel: "Copy message",
      tintColor: .secondaryLabelColor
    )
    #expect(otherButton.image === initialImage)
  }

  @Test
  func transcriptIconButtonUsesItsFixedFrameAsAlignmentRect() {
    let button = NativeReusableRowViewStyle.iconButton()
    button.frame = NSRect(x: 0, y: 0, width: 18, height: 18)

    #expect(button.alignmentRect(forFrame: button.frame) == button.frame)
  }

  @Test
  func userTrailingInsetMatchesAssistantLeadingInset() throws {
    let userCell = configuredNativeCell(
      for: nativeUserRow(id: "user", revision: 1, content: "Question")
    )
    let assistantCell = configuredNativeCell(
      for: nativeAssistantRow(id: "assistant", revision: 1)
    )
    let userContentHost = try #require(userCell.subviews.first)
    let assistantContentHost = try #require(assistantCell.subviews.first)

    let userTrailingInset = userCell.bounds.maxX - userContentHost.frame.maxX
    let assistantLeadingInset = assistantContentHost.frame.minX - assistantCell.bounds.minX

    #expect(abs(userTrailingInset - 20) < 0.5)
    #expect(abs(userTrailingInset - assistantLeadingInset) < 0.5)
  }

  @Test
  func shortUserMessageBubbleUsesOnlyItsTextWidth() throws {
    let content = "hey"
    let cell = configuredNativeCell(
      for: nativeUserRow(id: "short-user", revision: 1, content: content)
    )
    let userView = try #require(cell.hostedContentViewForTesting as? NativeUserMessageView)
    let stack = try #require(userView.subviews.compactMap { $0 as? NSStackView }.first)
    let bubble = try #require(
      stack.arrangedSubviews.first {
        !($0 is NSStackView) && !($0 is NSButton)
      }
    )
    let blocks = NativeTranscriptMarkdownRenderer.blocks(for: content)
    let text = try #require(
      blocks.compactMap { block -> NSAttributedString? in
        guard case .text(let attributedString) = block else {
          return nil
        }
        return attributedString
      }.first
    )
    let expectedWidth = ceil(text.size().width) + 20

    #expect(abs(bubble.frame.width - expectedWidth) < 0.5)
  }

  @Test
  func reusedUserMessageBubbleShrinksToLatestTextWidth() throws {
    let longContent = String(
      repeating: "A long user message needs the available width. ",
      count: 20
    )
    let cell = configuredNativeCell(
      for: nativeUserRow(id: "long-user", revision: 1, content: longContent)
    )
    let userView = try #require(cell.hostedContentViewForTesting as? NativeUserMessageView)
    let stack = try #require(userView.subviews.compactMap { $0 as? NSStackView }.first)
    let bubble = try #require(
      stack.arrangedSubviews.first {
        !($0 is NSStackView) && !($0 is NSButton)
      }
    )
    let longWidth = bubble.frame.width

    cell.prepareForReuse()
    cell.configure(
      row: nativeUserRow(id: "short-user", revision: 1, content: "hey"),
      state: NativeTranscriptCellState(),
      actions: testNativeActions()
    )
    cell.layoutSubtreeIfNeeded()

    #expect(cell.hostedContentViewForTesting === userView)
    #expect(bubble.frame.width < longWidth)
    #expect(bubble.frame.width < 80)
  }

  @Test
  func bottomContentInsetDoesNotShortenVerticalScroller() throws {
    let coordinator = AppKitChatTranscriptRepresentable.Coordinator(
      onToggleSpeech: { _, _ in },
      onApproveToolCall: { _ in },
      onDenyToolCall: { _ in },
      onAnswerAskUser: { _, _ in }
    )
    let scrollView = coordinator.makeScrollView()
    scrollView.setFrameSize(NSSize(width: 640, height: 500))
    scrollView.scrollerStyle = .overlay
    scrollView.autohidesScrollers = false

    coordinator.applyBottomContentInset(120, to: scrollView)
    scrollView.tile()
    scrollView.layoutSubtreeIfNeeded()

    let verticalScroller = try #require(scrollView.verticalScroller)
    #expect(scrollView.contentInsets.bottom == 120)
    #expect(scrollView.scrollerInsets.bottom == -120)
    #expect(abs(verticalScroller.frame.height - scrollView.bounds.height) < 0.5)
  }

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

    let bubbleTextWidth = max(scrollView.contentSize.width - 20 - 80 - 20, 1)
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
  func rowHeightUsesRenderedTableColumnWidth() throws {
    let coordinator = AppKitChatTranscriptRepresentable.Coordinator(
      onToggleSpeech: { _, _ in },
      onApproveToolCall: { _ in },
      onDenyToolCall: { _ in },
      onAnswerAskUser: { _, _ in }
    )
    let scrollView = coordinator.makeScrollView()
    scrollView.setFrameSize(NSSize(width: 760, height: 300))
    scrollView.layoutSubtreeIfNeeded()
    let tableView = try #require(scrollView.documentView as? NSTableView)
    tableView.setFrameSize(NSSize(width: 760, height: 300))
    let row = nativeAssistantMarkdownRow(
      id: "assistant",
      revision: 1,
      markdown: String(
        repeating: "Text wrapping must follow the rendered column width. ",
        count: 36
      )
    )

    coordinator.update(
      rows: [row],
      accessibilityValue: "ready",
      isSpeechEnabled: false,
      activeSpeechRowID: nil,
      in: scrollView
    )
    coordinator.flushPendingHeightInvalidationForTesting()

    let column = try #require(tableView.tableColumns.first)
    column.width = 360
    let expectedHeight = NativeTranscriptRowMeasurer.height(for: row, width: column.width)
    let boundsBasedHeight = NativeTranscriptRowMeasurer.height(
      for: row,
      width: tableView.bounds.width
    )

    #expect(expectedHeight > boundsBasedHeight)
    #expect(coordinator.tableView(tableView, heightOfRow: 0) == expectedHeight)
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
  func userMessageUsesMarkdownBlocksForRendering() {
    let markdown = "# Plan\n- **First** step"
    let row = nativeUserRow(
      id: "user-markdown",
      revision: 1,
      content: markdown
    )
    var requestedMarkdown: [String] = []
    var actions = testNativeActions()
    actions.markdownBlocks = { source in
      requestedMarkdown.append(source)
      return NativeTranscriptMarkdownRenderer.blocks(for: source)
    }

    let cell = configuredNativeCell(for: row, actions: actions)
    let renderedText = cell.descendants(of: NativeTranscriptTextView.self).compactMap {
      $0.textStorage?.copy() as? NSAttributedString
    }

    #expect(requestedMarkdown == [markdown])
    #expect(renderedText.contains { $0.string.contains("Plan\n• First step") })
    #expect(renderedText.allSatisfy { !$0.string.contains("**") })
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
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test"),
      kind: .assistantMessage
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
    let measuringCell = try #require(cache.measuringCellForTesting(kind: .assistantMessage))
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
    let measuringCell = try #require(cache.measuringCellForTesting(kind: .assistantThinking))
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
    #expect(cache.measuringCellCountForTesting == 3)
    cache.invalidate(rowID: "assistant")
    let assistantAgainHeight = cache.height(for: assistantRow, width: 640)

    #expect(assistantHeight == NativeTranscriptRowMeasurer.height(for: assistantRow, width: 640))
    #expect(userHeight == NativeTranscriptRowMeasurer.height(for: userRow, width: 640))
    #expect(toolHeight == NativeTranscriptRowMeasurer.height(for: toolRow, width: 640))
    #expect(assistantAgainHeight == assistantHeight)
  }

  @Test
  func activityRowsUseCompactHeightWithoutShrinkingMessages() {
    let startedAt = Date(timeIntervalSinceReferenceDate: 1000)
    let thinkingRow = nativeCompletedThinkingRow(
      id: "thinking",
      revision: 1,
      content: "Inspected the workspace.",
      startedAt: startedAt,
      completedAt: startedAt.addingTimeInterval(4)
    )
    let toolRow = nativeToolRow(id: "tool", revision: 1)
    let generationRow = NativeTranscriptRow(
      id: "generation",
      revision: 1,
      body: .generationIndicator(revision: 1)
    )
    let assistantRow = nativeAssistantRow(id: "assistant", revision: 1)
    let userRow = nativeUserRow(id: "user", revision: 1)

    #expect(NativeTranscriptRowMeasurer.height(for: thinkingRow, width: 640) == 28)
    #expect(NativeTranscriptRowMeasurer.height(for: toolRow, width: 640) == 28)
    #expect(NativeTranscriptRowMeasurer.height(for: generationRow, width: 640) == 28)
    #expect(NativeTranscriptRowMeasurer.height(for: assistantRow, width: 640) >= 44)
    #expect(NativeTranscriptRowMeasurer.height(for: userRow, width: 640) >= 44)
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
  func userHeightMeasurementUsesProvidedMarkdownBlocks() {
    var markdownBlockRequests = 0
    var cache = NativeTranscriptHeightCache()
    let row = nativeUserRow(
      id: "user",
      revision: 1,
      content: "# Plan\n- **First** step"
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
  func longUserRowHeightMatchesItsRenderedReusableCell() {
    let content = """
      Build a complete browser app called "Pixel Forge", a small pixel-art editor.

      Work in this order, creating exactly these five files:
      1. index.html
      2. styles.css
      3. editor-state.js
      4. canvas-view.js
      5. app.js

      Technical constraints:
      - Vanilla HTML, CSS, and JavaScript only. No frameworks, packages, CDNs, external fonts, or image assets. No external network requests of any kind.
      - Use ES modules (a type="module" script tag in index.html).
      - The app must work when served with `python3 -m http.server 8000`.
      - Use exactly one visible <canvas> as the drawing surface.
      - Do not duplicate the pixel document in the view layer: canvas-view.js reads pixels from the state module; only editor-state.js mutates them.
      """
    let row = nativeUserRow(id: "long-user", revision: 1, content: content)
    var cache = NativeTranscriptHeightCache()

    let cachedHeight = cache.height(for: row, width: 1_080)
    let renderedHeight = NativeChatMessageCellView.measuredHeight(
      for: row,
      width: 1_080,
      state: NativeTranscriptCellState(),
      actions: testNativeActions()
    )

    #expect(cachedHeight == renderedHeight)
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

    #expect(messageBubbles.count == 1)
    #expect(messageBubbles.allSatisfy { $0.isHidden })
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

    #expect(details.permissionLines == ["Approval: Automatic"])
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
  func toolHeaderPreviewsNormalizeWhitespaceAndChooseSemanticTruncation() throws {
    let command = ToolCallModelMessage(
      callID: UUID(),
      toolName: .runCommand,
      arguments: [
        ToolCallModelArgument(name: "command", value: "git add main.py\n\t&&   git commit")
      ]
    )
    let path = ToolCallModelMessage(
      callID: UUID(),
      toolName: .readFile,
      arguments: [
        ToolCallModelArgument(
          name: "path",
          value: "/Users/steffen/projects/sumika-chat/Sources/SumikaApp/main.swift"
        )
      ]
    )
    let query = ToolCallModelMessage(
      callID: UUID(),
      toolName: .webSearch,
      arguments: [ToolCallModelArgument(name: "query", value: "early Pong arcade features")]
    )
    let url = ToolCallModelMessage(
      callID: UUID(),
      toolName: .webFetch,
      arguments: [
        ToolCallModelArgument(
          name: "url",
          value: "https://example.com/research/archive/pong/history"
        )
      ]
    )

    let commandPreview = try #require(command.nativeHeaderPreview)
    let pathPreview = try #require(path.nativeHeaderPreview)
    let queryPreview = try #require(query.nativeHeaderPreview)
    let urlPreview = try #require(url.nativeHeaderPreview)

    #expect(commandPreview.text == "git add main.py && git commit")
    #expect(commandPreview.accessibilityLabel == "git add main.py\n\t&&   git commit")
    #expect(commandPreview.lineBreakMode == .byTruncatingTail)
    #expect(pathPreview.lineBreakMode == .byTruncatingMiddle)
    #expect(queryPreview.lineBreakMode == .byTruncatingTail)
    #expect(urlPreview.lineBreakMode == .byTruncatingMiddle)
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
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test"),
      kind: .assistantMessage
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
  func completedAssistantFooterShowsTotalTurnDuration() {
    let cell = configuredNativeCell(
      for: nativeAssistantRow(
        id: "assistant",
        revision: 1,
        totalDuration: 220
      )
    )

    #expect(cell.descendantTextValues.contains("Total 3m 40s"))
  }

  @Test
  func sameThinkingRowReconfigureKeepsHostedViewAndHeader() throws {
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test"),
      kind: .assistantThinking
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
      tokensPerSecond: 12.973
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
  func toolHeaderTogglesFromEntireRowHitArea() throws {
    var toggledRowIDs: [String] = []
    var actions = testNativeActions()
    actions.toggleToolExpansion = { toggledRowIDs.append($0) }
    let cell = configuredNativeCell(
      for: nativeToolRow(
        id: "tool",
        revision: 1,
        record: nativeCompletedCommandToolRecord()
      ),
      actions: actions
    )
    let header = try #require(
      cell.descendants(of: NativeTranscriptDisclosureHeaderView.self).first
    )
    let trailingHeaderPoint = NSPoint(x: header.bounds.maxX - 2, y: header.bounds.midY)

    #expect(header.hitTest(trailingHeaderPoint) === header)

    header.performDisclosureAction()

    #expect(toggledRowIDs == ["tool"])
  }

  @Test
  func automaticApprovalAppearsOnlyInExpandedToolDetails() throws {
    let fullCommand = """
      git add main.py
      && git commit -m "Add win condition: first to 21 points wins with victory screen and restart"
      """
    let previewCommand =
      "git add main.py && git commit -m \"Add win condition: first to 21 points wins with victory screen and restart\""
    var record = nativeCompletedCommandToolRecord(command: fullCommand)
    record.approvalSource = .automatic
    let row = nativeToolRow(id: "long-command", revision: 1, record: record)
    let cell = configuredNativeCell(for: row)

    let nameLabel = try #require(
      cell.descendantTextFields.first { $0.stringValue == ToolName.runCommand.rawValue }
    )
    let previewLabel = try #require(
      cell.descendantTextFields.first { $0.stringValue == previewCommand }
    )
    let disclosureButton = try #require(
      cell.descendantButtons(accessibilityLabel: "Show details").first
    )

    #expect(nameLabel.maximumNumberOfLines == 1)
    #expect(!cell.descendantTextValues.contains("automatic"))
    #expect(cell.accessibilityLabel() == "Tool run_command, done")
    #expect(previewLabel.maximumNumberOfLines == 1)
    #expect(previewLabel.lineBreakMode == .byTruncatingTail)
    #expect(previewLabel.accessibilityLabel() == fullCommand)
    #expect(previewLabel.frame.width < previewLabel.intrinsicContentSize.width)
    #expect(disclosureButton.frame(in: cell).maxX < cell.bounds.width)

    cell.configure(
      row: row,
      state: NativeTranscriptCellState(isToolExpanded: true),
      actions: testNativeActions()
    )
    cell.layoutSubtreeIfNeeded()

    #expect(
      cell.descendantTextFields.contains {
        $0.stringValue == "command: \(fullCommand)"
      }
    )
    #expect(cell.descendantTextValues.contains("Approval: Automatic"))
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
  func reasoningHeaderTogglesFromEntireRowHitArea() throws {
    var toggledRowIDs: [String] = []
    var actions = testNativeActions()
    actions.toggleThinkingExpansion = { toggledRowIDs.append($0) }
    let cell = configuredNativeCell(
      for: nativeThinkingRow(id: "thinking", revision: 1),
      actions: actions
    )
    let header = try #require(
      cell.descendants(of: NativeTranscriptDisclosureHeaderView.self).first
    )
    let trailingHeaderPoint = NSPoint(x: header.bounds.maxX - 2, y: header.bounds.midY)

    #expect(header.hitTest(trailingHeaderPoint) === header)

    header.performDisclosureAction()

    #expect(toggledRowIDs == ["thinking"])
  }

  @Test
  func userRowsAddConversationSpacingWithoutInflatingActivityRows() throws {
    let userCell = configuredNativeCell(
      for: nativeUserRow(id: "user", revision: 1)
    )
    let toolCell = configuredNativeCell(
      for: nativeToolRow(
        id: "tool",
        revision: 1,
        record: nativeCompletedCommandToolRecord()
      )
    )
    let userContentHost = try #require(userCell.subviews.first)
    let toolContentHost = try #require(toolCell.subviews.first)
    let userTopInset = userCell.bounds.maxY - userContentHost.frame.maxY
    let toolTopInset = toolCell.bounds.maxY - toolContentHost.frame.maxY

    #expect(abs(userTopInset - 12) < 0.5)
    #expect(abs(toolTopInset - 3) < 0.5)
  }

  @Test
  func differentRowOfSameKindKeepsHostedViewAndRebindsContent() throws {
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test"),
      kind: .assistantMessage
    )
    let firstRow = nativeStreamingAssistantRow(id: "assistant", revision: 1, content: "Hello")
    let differentAssistantRow = nativeStreamingAssistantRow(
      id: "other-assistant",
      revision: 1,
      content: "A different answer"
    )

    cell.configure(row: firstRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    let firstHostedView = try #require(cell.hostedContentViewForTesting)
    cell.configure(
      row: differentAssistantRow,
      state: NativeTranscriptCellState(),
      actions: testNativeActions()
    )
    let differentRowHostedView = try #require(cell.hostedContentViewForTesting)

    #expect(firstHostedView === differentRowHostedView)
    #expect(cell.descendantTextValues.contains("A different answer"))
    #expect(!cell.descendantTextValues.contains("Hello"))
  }

  @Test
  func differentFinalAssistantRowsWithSameRevisionReuseTextView() throws {
    let firstRow = nativeAssistantMarkdownRow(
      id: "first-assistant",
      revision: 1,
      markdown: "First final answer."
    )
    let secondRow = nativeAssistantMarkdownRow(
      id: "second-assistant",
      revision: 1,
      markdown: "Second final answer."
    )
    let cell = configuredNativeCell(for: firstRow)
    let hostedView = try #require(cell.hostedContentViewForTesting)
    let textView = try #require(cell.descendants(of: NativeTranscriptTextView.self).first)

    cell.configure(
      row: secondRow,
      state: NativeTranscriptCellState(),
      actions: testNativeActions()
    )

    #expect(cell.hostedContentViewForTesting === hostedView)
    #expect(cell.descendants(of: NativeTranscriptTextView.self).first === textView)
    #expect(textView.string == "Second final answer.")
  }

  @Test
  func recycledAssistantCellFitsEveryReboundRowHeight() {
    let width: CGFloat = 760
    let rows = (0..<24).map { index in
      nativeAssistantMarkdownRow(
        id: "assistant-\(index)",
        revision: 1,
        markdown: index.isMultiple(of: 2)
          ? "Short answer \(index)."
          : String(
            repeating: "Long answer \(index) wraps across several transcript lines. ",
            count: 36
          )
      )
    }
    let cell = NativeChatMessageCellView(
      identifier: NativeTranscriptCellKind.assistantMessage.reuseIdentifier,
      kind: .assistantMessage
    )
    var cache = NativeTranscriptHeightCache()

    for row in rows {
      cell.prepareForReuse()
      cell.configure(row: row, state: NativeTranscriptCellState(), actions: testNativeActions())
      let rowHeight = cache.height(for: row, width: width)
      cell.frame = NSRect(x: 0, y: 0, width: width, height: rowHeight)
      cell.layoutSubtreeIfNeeded()

      #expect(abs(cell.fittingSize.height - rowHeight) <= 0.5)
      let marker = row.id.replacing("assistant-", with: "")
      #expect(cell.descendantTextValues.contains { $0.contains(marker) })
    }
  }

  @Test
  func mixedAssistantBlocksKeepRenderedAndCachedWidthsInSync() {
    let width: CGFloat = 1_080
    let seedRow = nativeAssistantMarkdownRow(
      id: "seed-assistant",
      revision: 1,
      markdown: String(repeating: "A wide paragraph establishes the reusable layout. ", count: 8)
    )
    let paragraph = String(
      repeating: "The final answer contains enough prose to wrap over many lines. ",
      count: 32
    )
    let mixedRow = NativeTranscriptRow(
      id: "mixed-assistant",
      revision: 1,
      body: .item(
        RenderedChatTurnItem(
          id: "mixed-assistant",
          item: .assistantMessage(AssistantTurnMessage(content: paragraph)),
          generationMetrics: nil,
          totalDuration: 2_610,
          assistantRenderBlocks: [
            .paragraph(.init(id: .init(rawValue: "paragraph"), text: paragraph)),
            .codeBlock(
              .init(
                id: .init(rawValue: "command"),
                language: nil,
                text: "python3 -m http.server 8000\n",
                isClosed: true
              )),
            .paragraph(
              .init(
                id: .init(rawValue: "trailing-paragraph"),
                text: "Then open http://localhost:8000"
              )),
          ],
          renderRevision: 1
        )
      )
    )
    var cache = NativeTranscriptHeightCache()
    _ = cache.height(for: seedRow, width: width)
    let cachedHeight = cache.height(for: mixedRow, width: width)
    let cell = NativeChatMessageCellView(
      identifier: NativeTranscriptCellKind.assistantMessage.reuseIdentifier,
      kind: .assistantMessage
    )
    let narrowSeedRow = nativeAssistantCodeRow(
      id: "narrow-seed-assistant",
      revision: 1,
      code: "python3 -m http.server 8000\n"
    )
    cell.frame = NSRect(x: 0, y: 0, width: 337, height: 80)
    cell.configure(
      row: narrowSeedRow,
      state: NativeTranscriptCellState(),
      actions: testNativeActions()
    )
    cell.layoutSubtreeIfNeeded()
    cell.prepareForReuse()
    cell.configure(
      row: mixedRow,
      state: NativeTranscriptCellState(),
      actions: testNativeActions()
    )
    cell.frame = NSRect(x: 0, y: 0, width: width, height: cachedHeight)
    cell.layoutSubtreeIfNeeded()

    #expect(abs(cell.fittingSize.height - cachedHeight) <= 0.5)
    #expect(
      cell.descendants(of: NativeTranscriptTextView.self).allSatisfy { $0.frame.width >= 600 }
    )
  }

  @Test
  func tableScrollRecyclesAssistantCellsWithoutBlankOrOverflowingRows() throws {
    let coordinator = AppKitChatTranscriptRepresentable.Coordinator(
      onToggleSpeech: { _, _ in },
      onApproveToolCall: { _ in },
      onDenyToolCall: { _ in },
      onAnswerAskUser: { _, _ in }
    )
    let scrollView = coordinator.makeScrollView()
    scrollView.frame = NSRect(x: 0, y: 0, width: 760, height: 220)
    let window = NSWindow(
      contentRect: NSRect(x: -10_000, y: -10_000, width: 760, height: 220),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.contentView = scrollView
    window.orderFront(nil)
    defer {
      window.orderOut(nil)
    }
    let tableView = try #require(scrollView.documentView as? NSTableView)
    let rows = (0..<24).map { index in
      nativeAssistantMarkdownRow(
        id: "assistant-\(index)",
        revision: 1,
        markdown: index.isMultiple(of: 2)
          ? "Marker \(index): short answer."
          : String(
            repeating: "Marker \(index): long answer wraps across several lines. ",
            count: 36
          )
      )
    }

    coordinator.update(
      rows: rows,
      accessibilityValue: "ready",
      isSpeechEnabled: false,
      activeSpeechRowID: nil,
      in: scrollView
    )
    coordinator.flushPendingHeightInvalidationForTesting()
    scrollView.layoutSubtreeIfNeeded()
    tableView.layoutSubtreeIfNeeded()

    var cellIdentities = Set<ObjectIdentifier>()
    for index in rows.indices {
      let rowRect = tableView.rect(ofRow: index)
      scrollView.contentView.scroll(to: NSPoint(x: 0, y: rowRect.minY))
      scrollView.reflectScrolledClipView(scrollView.contentView)
      scrollView.layoutSubtreeIfNeeded()
      tableView.layoutSubtreeIfNeeded()

      let cell = try #require(
        tableView.view(atColumn: 0, row: index, makeIfNecessary: false)
          as? NativeChatMessageCellView
      )
      let renderedWidthConstraint = cell.widthAnchor.constraint(equalToConstant: cell.bounds.width)
      renderedWidthConstraint.isActive = true
      let fittingHeightAtRenderedWidth = cell.fittingSize.height
      renderedWidthConstraint.isActive = false
      cellIdentities.insert(ObjectIdentifier(cell))
      #expect(cell.descendantTextValues.contains { $0.contains("Marker \(index):") })
      #expect(abs(fittingHeightAtRenderedWidth - rowRect.height) <= 0.5)
    }

    #expect(cellIdentities.count < rows.count)
  }

  @Test
  func differentUserRowsReuseContentAndCopyUsesLatestBinding() throws {
    var copies: [(String, String)] = []
    var actions = testNativeActions()
    actions.copy = { copies.append(($0, $1)) }
    let firstRow = nativeUserRow(id: "first-user", revision: 1, content: "First question")
    let secondRow = nativeUserRow(id: "second-user", revision: 1, content: "Second question")
    let cell = configuredNativeCell(for: firstRow, actions: actions)
    let hostedView = try #require(cell.hostedContentViewForTesting)
    let copyButton = try #require(
      cell.descendantButtons(accessibilityLabel: "Copy message").first
    )

    cell.prepareForReuse()
    copyButton.performClick(nil)
    cell.configure(row: secondRow, state: NativeTranscriptCellState(), actions: actions)
    let reboundCopyButton = try #require(
      cell.descendantButtons(accessibilityLabel: "Copy message").first
    )
    reboundCopyButton.performClick(nil)

    #expect(cell.hostedContentViewForTesting === hostedView)
    #expect(reboundCopyButton === copyButton)
    #expect(copies.count == 1)
    #expect(copies.first?.0 == "second-user")
    #expect(copies.first?.1 == "Second question")
  }

  @Test
  func differentToolRowsReuseHeaderAndDisclosureUsesLatestBinding() throws {
    var toggledRowIDs: [String] = []
    var actions = testNativeActions()
    actions.toggleToolExpansion = { toggledRowIDs.append($0) }
    let firstRow = nativeToolRow(
      id: "first-tool",
      revision: 1,
      record: nativeCompletedCommandToolRecord(command: "swift test")
    )
    let secondRow = nativeToolRow(
      id: "second-tool",
      revision: 1,
      record: nativeCompletedCommandToolRecord(command: "swift build")
    )
    let cell = configuredNativeCell(for: firstRow, actions: actions)
    let hostedView = try #require(cell.hostedContentViewForTesting)
    let header = try #require(
      cell.descendants(of: NativeTranscriptDisclosureHeaderView.self).first
    )

    cell.prepareForReuse()
    header.performDisclosureAction()
    cell.configure(row: secondRow, state: NativeTranscriptCellState(), actions: actions)
    let reboundHeader = try #require(
      cell.descendants(of: NativeTranscriptDisclosureHeaderView.self).first
    )
    reboundHeader.performDisclosureAction()

    #expect(cell.hostedContentViewForTesting === hostedView)
    #expect(reboundHeader === header)
    #expect(toggledRowIDs == ["second-tool"])
    #expect(cell.descendantTextValues.contains("swift build"))
    #expect(!cell.descendantTextValues.contains("swift test"))
  }

  @Test
  func streamingAssistantViewUpdatesPlaceholderTextAndFinalMarkdown() throws {
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test"),
      kind: .assistantMessage
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
  func finalAssistantContentChangesRebindExistingTextView() throws {
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test"),
      kind: .assistantMessage
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
      cell.descendants(of: NativeTranscriptTextView.self).first { $0.string.contains("Stable") }
    )

    cell.configure(
      row: row,
      state: NativeTranscriptCellState(isCopied: true),
      actions: testNativeActions()
    )
    let labelAfterFooterStateChange = try #require(
      cell.descendants(of: NativeTranscriptTextView.self).first { $0.string.contains("Stable") }
    )
    #expect(labelAfterFooterStateChange === initialLabel)

    cell.configure(
      row: revisedRow,
      state: NativeTranscriptCellState(),
      actions: testNativeActions()
    )
    let labelAfterContentChange = try #require(
      cell.descendants(of: NativeTranscriptTextView.self).first { $0.string.contains("Stable") }
    )
    #expect(labelAfterContentChange === initialLabel)
    #expect(labelAfterContentChange.string.contains("more content"))
  }

  @Test
  func highlightCompletionRecolorsCodeLabelWithoutRebuild() throws {
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test"),
      kind: .assistantMessage
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
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test"),
      kind: .assistantMessage
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
  func thumbnailArrivalRebuildsUserAttachmentContent() throws {
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test"),
      kind: .userMessage
    )
    let row = nativeUserRow(
      id: "user",
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
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test"),
      kind: .assistantMessage
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
    let textView = try #require(cell.descendants(of: NativeTranscriptTextView.self).first)
    #expect(textView.string == "Hello")

    cell.configure(row: grownRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    let textViewAfterAppend = try #require(
      cell.descendants(of: NativeTranscriptTextView.self).first
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
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test"),
      kind: .assistantThinking
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
    let textView = try #require(cell.descendants(of: NativeTranscriptTextView.self).first)
    #expect(textView.string == "Inspecting")

    cell.configure(row: grownRow, state: expandedState, actions: testNativeActions())
    let textViewAfterAppend = try #require(
      cell.descendants(of: NativeTranscriptTextView.self).first
    )
    #expect(textViewAfterAppend === textView)
    #expect(textViewAfterAppend.string == "Inspecting the workspace carefully.")
  }

  @Test
  func collapsedStreamingThinkingShowsFixedHeightLiveTicker() throws {
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test"),
      kind: .assistantThinking
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
    let twoLineFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    #expect(tickerHeight >= NSLayoutManager().defaultLineHeight(for: twoLineFont) * 2)

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
    #expect(cell.descendants(of: NativeTranscriptTextView.self).isEmpty)
  }

  @Test
  func reasoningTitleReflectsStatusAndDuration() {
    let startedAt = Date(timeIntervalSinceReferenceDate: 0)
    func message(
      status: AssistantDeliveryStatus,
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
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test"),
      kind: .assistantMessage
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
    let tailTextView = try #require(
      blocksView.descendants(of: NativeTranscriptTextView.self).first {
        $0.string == "Streaming bold prose"
      }
    )

    cell.configure(row: grownRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    #expect(cell.descendants(of: NativeStreamingAssistantBlocksView.self).first === blocksView)
    #expect(tailTextView.string == "Streaming bold prose keeps going")
    #expect(tailTextView.superview != nil)
  }

  @Test
  func streamingBlocksFreezeParagraphsAtBlankLines() throws {
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test"),
      kind: .assistantMessage
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
    let finalizedTextView = try #require(
      cell.descendants(of: NativeTranscriptTextView.self).first {
        $0.string == "First paragraph."
      }
    )
    _ = try #require(
      cell.descendants(of: NativeTranscriptTextView.self).first {
        $0.string == "Second paragraph starts"
      }
    )

    cell.configure(row: grownRow, state: NativeTranscriptCellState(), actions: testNativeActions())
    let finalizedTextViewAfterGrowth = try #require(
      cell.descendants(of: NativeTranscriptTextView.self).first {
        $0.string == "First paragraph."
      }
    )
    #expect(finalizedTextViewAfterGrowth === finalizedTextView)
    #expect(
      cell.descendantTextValues.contains("Second paragraph starts and grows")
    )
  }

  @Test
  func streamingBlocksShowLiveOpenCodeBlock() throws {
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test"),
      kind: .assistantMessage
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
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test"),
      kind: .assistantMessage
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
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test"),
      kind: .assistantMessage
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
    let textView = try #require(cell.descendants(of: NativeTranscriptTextView.self).first)
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
    let textView = try #require(cell.descendants(of: NativeTranscriptTextView.self).first)

    #expect(textView.accessibilityRole() == .staticText)
  }

  @Test
  func finalizedAssistantMarkdownLinksOpenThroughTranscriptAction() throws {
    let recorder = LinkOpenRecorder()
    let cell = configuredNativeCell(
      for: nativeAssistantMarkdownRow(
        id: "assistant",
        revision: 1,
        markdown: "[Docs](https://example.com/docs) and http://localhost:8000"
      ),
      actions: testNativeActions { recorder.record($0) }
    )

    try activateLink(displayText: "Docs", in: cell)
    try activateLink(displayText: "http://localhost:8000", in: cell)

    #expect(
      recorder.urls.map(\.absoluteString) == [
        "https://example.com/docs",
        "http://localhost:8000",
      ])
  }

  @Test
  func finalizedMarkdownTextRetainsVisibleLayout() throws {
    let cell = configuredNativeCell(
      for: nativeAssistantMarkdownRow(
        id: "assistant",
        revision: 1,
        markdown: "Visible linked text at https://example.com/docs"
      )
    )
    let textView = try #require(
      cell.descendants(of: NativeTranscriptTextView.self).first {
        $0.string.contains("Visible linked text")
      })

    #expect(textView.frame.width > 0)
    #expect(textView.frame.height > 0)
  }

  @Test
  func finalizedUserMarkdownLinkOpensThroughTranscriptAction() throws {
    let recorder = LinkOpenRecorder()
    let cell = configuredNativeCell(
      for: nativeUserRow(
        id: "user",
        revision: 1,
        content: "Open [Docs](https://example.com/user-guide)"
      ),
      actions: testNativeActions { recorder.record($0) }
    )

    try activateLink(displayText: "Docs", in: cell)

    #expect(recorder.urls.map(\.absoluteString) == ["https://example.com/user-guide"])
  }

  @Test
  func finalizedPlainAssistantLinkOpensThroughTranscriptAction() throws {
    let recorder = LinkOpenRecorder()
    let cell = configuredNativeCell(
      for: nativePlainAssistantRow(
        id: "assistant",
        revision: 1,
        content: "Open http://localhost:8000/plain"
      ),
      actions: testNativeActions { recorder.record($0) }
    )

    try activateLink(displayText: "http://localhost:8000/plain", in: cell)

    #expect(recorder.urls.map(\.absoluteString) == ["http://localhost:8000/plain"])
  }

  @Test
  func plainStreamingLinkOpensThroughTranscriptAction() throws {
    let recorder = LinkOpenRecorder()
    let cell = configuredNativeCell(
      for: nativeStreamingAssistantRow(
        id: "assistant",
        revision: 1,
        content: "Open http://localhost:8000/live"
      ),
      actions: testNativeActions { recorder.record($0) }
    )

    try activateLink(displayText: "http://localhost:8000/live", in: cell)

    #expect(recorder.urls.map(\.absoluteString) == ["http://localhost:8000/live"])
  }

  @Test
  func structuredStreamingMarkdownLinkOpensThroughTranscriptAction() throws {
    let recorder = LinkOpenRecorder()
    let cell = configuredNativeCell(
      for: nativeStreamingBlocksAssistantRow(
        id: "assistant",
        revision: 1,
        content: "Open [Docs](https://example.com/live-docs)"
      ),
      actions: testNativeActions { recorder.record($0) }
    )

    try activateLink(displayText: "Docs", in: cell)

    #expect(recorder.urls.map(\.absoluteString) == ["https://example.com/live-docs"])
  }

  @Test
  func markdownTableLinkOpensThroughTranscriptAction() throws {
    let recorder = LinkOpenRecorder()
    let cell = configuredNativeCell(
      for: nativeAssistantMarkdownRow(
        id: "assistant",
        revision: 1,
        markdown: """
          | Resource |
          | --- |
          | [Docs](https://example.com/table-docs) |
          """
      ),
      actions: testNativeActions { recorder.record($0) }
    )

    try activateLink(displayText: "Docs", in: cell)

    #expect(recorder.urls.map(\.absoluteString) == ["https://example.com/table-docs"])
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
  attachments: [ChatAttachment] = [],
  totalDuration: TimeInterval? = nil
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
        totalDuration: totalDuration,
        assistantRenderBlocks: [
          .paragraph(.init(id: .init(rawValue: "answer"), text: "Answer"))
        ],
        renderRevision: revision
      ))
  )
}

private func nativePlainAssistantRow(
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
        item: .assistantMessage(AssistantTurnMessage(content: content)),
        generationMetrics: nil,
        assistantRenderBlocks: [],
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

private func nativeCompletedCommandToolRecord(
  command: String = "swift test",
  stdout: String = "Tests passed."
) -> ToolCallRecord {
  let request = nativeRunCommandRequest(command: command)
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
          command: command,
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
  state: NativeTranscriptCellState = NativeTranscriptCellState(),
  actions: NativeTranscriptCellActions = testNativeActions()
) -> NativeChatMessageCellView {
  let cell = NativeChatMessageCellView(
    identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Test"),
    kind: row.cellKind
  )
  cell.translatesAutoresizingMaskIntoConstraints = false
  cell.configure(
    row: row,
    state: state,
    actions: actions
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
private final class LinkOpenRecorder {
  private(set) var urls: [URL] = []

  func record(_ url: URL) {
    urls.append(url)
  }
}

@MainActor
private func activateLink(
  displayText: String,
  in cell: NativeChatMessageCellView
) throws {
  let textView = try #require(
    cell.descendants(of: NativeTranscriptTextView.self).first {
      ($0.string as NSString).range(of: displayText).location != NSNotFound
    })
  let characterRange = (textView.string as NSString).range(of: displayText)
  let link = try #require(
    textView.textStorage?.attribute(
      .link,
      at: characterRange.location,
      effectiveRange: nil
    ))

  textView.clicked(onLink: link, at: characterRange.location)
}

@MainActor
private func testNativeActions(
  openLink: @escaping @MainActor (URL) -> Void = { _ in }
) -> NativeTranscriptCellActions {
  NativeTranscriptCellActions(
    markdownBlocks: NativeTranscriptMarkdownRenderer.blocks,
    openLink: openLink,
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
