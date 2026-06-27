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
  func thinkingRowUsesDedicatedAccessibilityIdentifier() {
    let row = nativeThinkingRow(id: "thinking", revision: 1)

    #expect(row.accessibilityIdentifier == "chat.assistantThinking")
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
  func userImageAttachmentRendersOutsideMessageBubbleAsButton() {
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
        toolCallRecord: nil,
        generationMetrics: nil,
        assistantRenderBlocks: []
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
        toolCallRecord: nil,
        generationMetrics: nil,
        assistantRenderBlocks: [
          .paragraph(.init(id: .init(rawValue: "answer"), text: "Answer"))
        ]
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
        toolCallRecord: nil,
        generationMetrics: nil,
        assistantRenderBlocks: []
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
        toolCallRecord: nil,
        generationMetrics: nil,
        assistantRenderBlocks: []
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
        toolCallRecord: nil,
        generationMetrics: nil,
        assistantRenderBlocks: [
          .codeBlock(
            .init(
              id: .init(rawValue: "code"),
              language: "js",
              text: code,
              isClosed: true
            ))
        ]
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
        toolCallRecord: nil,
        generationMetrics: nil,
        assistantRenderBlocks: [
          .paragraph(.init(id: .init(rawValue: "markdown"), text: markdown))
        ],
        assistantSpokenText: spokenText
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
        toolCallRecord: nil,
        generationMetrics: nil,
        assistantRenderBlocks: []
      ))
  )
}

private func nativeToolRow(
  id: String,
  revision: Int,
  record: ToolCallRecord = nativeToolRecord()
) -> NativeTranscriptRow {
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

private func nativeApprovalToolRecord(reason: String = "Needs permission.") -> ToolCallRecord {
  let request = nativeRunCommandRequest(command: "uv test")
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

private func nativeRunCommandRequest(command: String) -> ToolCallRequest {
  ToolCallRequest.validated(
    raw: RawToolCallRequest(
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
    descendantTextFields.map(\.stringValue)
  }

  fileprivate var descendantTextFields: [NSTextField] {
    descendants(of: NSTextField.self)
  }
}
