import AppKit
import SumikaCore
import SwiftUI

struct AppKitChatTranscriptRepresentable: NSViewRepresentable {
  typealias Coordinator = NativeChatTranscriptCoordinator

  let items: [RenderedChatTurnItem]
  let isGenerating: Bool
  let showsGenerationIndicator: Bool
  let accessibilityValue: String
  let isSpeechEnabled: Bool
  let activeSpeechRowID: String?
  // Space reserved at the bottom of the scroll content so the last message can
  // scroll clear of the floating composer that overlaps this view.
  let bottomContentInset: CGFloat
  let onToggleSpeech: (String, String) -> Void
  let onApproveToolCall: (ToolCallRecord.ID) -> Void
  let onApproveToolCallBatch: (ToolCallRecord.ID) -> Void
  let onDenyToolCall: (ToolCallRecord.ID) -> Void
  let onAnswerAskUser: (ToolCallRecord.ID, String) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onToggleSpeech: onToggleSpeech,
      onApproveToolCall: onApproveToolCall,
      onDenyToolCall: onDenyToolCall,
      onAnswerAskUser: onAnswerAskUser,
      onApproveToolCallBatch: onApproveToolCallBatch
    )
  }

  func makeNSView(context: Context) -> NSScrollView {
    context.coordinator.makeScrollView()
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    let rows = NativeTranscriptRow.rows(
      for: items,
      showsGenerationIndicator: showsGenerationIndicator
    )
    ChatDiagnostics.measure(
      "Transcript updateNSView",
      category: .transcript,
      metadata: context.coordinator.updateNSViewMetadata(itemCount: items.count, rows: rows)
    ) {
      context.coordinator.updateCallbacks(
        onToggleSpeech: onToggleSpeech,
        onApproveToolCall: onApproveToolCall,
        onDenyToolCall: onDenyToolCall,
        onAnswerAskUser: onAnswerAskUser,
        onApproveToolCallBatch: onApproveToolCallBatch
      )
      context.coordinator.applyBottomContentInset(bottomContentInset, to: scrollView)
      context.coordinator.update(
        rows: rows,
        accessibilityValue: accessibilityValue,
        isSpeechEnabled: isSpeechEnabled,
        activeSpeechRowID: activeSpeechRowID,
        areToolActionsEnabled: !isGenerating,
        in: scrollView
      )
    }
  }

}

@MainActor
final class NativeChatTranscriptCoordinator: NSObject {
  private let section = NativeTranscriptSection.main
  private let cellIdentifier = NSUserInterfaceItemIdentifier("NativeChatMessageCellView")
  private var onToggleSpeech: (String, String) -> Void
  private var onApproveToolCall: (ToolCallRecord.ID) -> Void
  private var onApproveToolCallBatch: (ToolCallRecord.ID) -> Void
  private var onDenyToolCall: (ToolCallRecord.ID) -> Void
  private var onAnswerAskUser: (ToolCallRecord.ID, String) -> Void
  private weak var tableView: NSTableView?
  private var dataSource: NSTableViewDiffableDataSource<NativeTranscriptSection, String>?
  private var rowsByID: [String: NativeTranscriptRow] = [:]
  private var rowIDs: [String] = []
  private var revisionsByID: [String: Int] = [:]
  private var isSpeechEnabled = false
  private var activeSpeechRowID: String?
  private var areToolActionsEnabled = true
  private var cellStateStore = NativeTranscriptCoordinatorState()
  private var heightCache = NativeTranscriptHeightCache()
  private var markdownCache = NativeTranscriptMarkdownCache()
  private let codeHighlightStore = NativeTranscriptCodeHighlightStore()
  private let attachmentThumbnailStore = NativeTranscriptAttachmentThumbnailStore()
  private var attachmentPreviewPopover: NSPopover?
  private var pendingHeightInvalidationRows = IndexSet()
  private var pendingHeightInvalidationReasons = Set<String>()
  private var pendingHeightInvalidationWorkItem: DispatchWorkItem?
  private var shouldScrollAfterHeightInvalidation = false
  private var pendingMeasuredHeightByRowID: [String: CGFloat] = [:]
  private var lastNotedHeightByRowID: [String: CGFloat] = [:]
  private var pendingStreamingRowIDs = Set<String>()
  private var streamingRowsBeingCommitted = Set<String>()
  private var streamingHeightWorkItem: DispatchWorkItem?

  init(
    onToggleSpeech: @escaping (String, String) -> Void,
    onApproveToolCall: @escaping (ToolCallRecord.ID) -> Void,
    onDenyToolCall: @escaping (ToolCallRecord.ID) -> Void,
    onAnswerAskUser: @escaping (ToolCallRecord.ID, String) -> Void,
    onApproveToolCallBatch: @escaping (ToolCallRecord.ID) -> Void = { _ in }
  ) {
    self.onToggleSpeech = onToggleSpeech
    self.onApproveToolCall = onApproveToolCall
    self.onApproveToolCallBatch = onApproveToolCallBatch
    self.onDenyToolCall = onDenyToolCall
    self.onAnswerAskUser = onAnswerAskUser
  }
}

extension NativeChatTranscriptCoordinator {

  func makeScrollView() -> NSScrollView {
    let tableView = NativeTranscriptNSTableView()
    tableView.headerView = nil
    tableView.usesAlternatingRowBackgroundColors = false
    tableView.selectionHighlightStyle = .none
    tableView.allowsColumnSelection = false
    tableView.allowsEmptySelection = true
    tableView.allowsMultipleSelection = false
    tableView.backgroundColor = .clear
    tableView.gridStyleMask = []
    tableView.intercellSpacing = NSSize(width: 0, height: 0)
    tableView.rowSizeStyle = .custom
    tableView.delegate = self
    tableView.setAccessibilityIdentifier("chat.transcript.table")

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)

    let scrollView = NSScrollView()
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    // The floating composer manages the bottom inset itself, so opt out of the
    // system-driven adjustment and drive `contentInsets` explicitly.
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.documentView = tableView
    scrollView.setAccessibilityIdentifier("chat.transcript")

    self.tableView = tableView
    dataSource = NSTableViewDiffableDataSource(tableView: tableView) {
      [weak self] tableView, _, _, itemID in
      guard let self else {
        return NSView()
      }
      let cell =
        tableView.makeView(withIdentifier: cellIdentifier, owner: self)
        as? NativeChatMessageCellView
        ?? NativeChatMessageCellView(identifier: cellIdentifier)
      cell.onMeasuredHeight = { [weak self] rowID, height in
        self?.recordMeasuredStreamingHeight(height, rowID: rowID)
      }
      if let row = rowsByID[itemID] {
        configure(cell, with: row)
      }
      return cell
    }

    applySnapshot(
      previousIDs: [],
      previousRowsByID: [:],
      rowIDs: [],
      currentRowsByID: [:],
      changedIDs: [],
      animatingDifferences: false
    )
    return scrollView
  }

  func updateCallbacks(
    onToggleSpeech: @escaping (String, String) -> Void,
    onApproveToolCall: @escaping (ToolCallRecord.ID) -> Void,
    onDenyToolCall: @escaping (ToolCallRecord.ID) -> Void,
    onAnswerAskUser: @escaping (ToolCallRecord.ID, String) -> Void,
    onApproveToolCallBatch: @escaping (ToolCallRecord.ID) -> Void
  ) {
    self.onToggleSpeech = onToggleSpeech
    self.onApproveToolCall = onApproveToolCall
    self.onApproveToolCallBatch = onApproveToolCallBatch
    self.onDenyToolCall = onDenyToolCall
    self.onAnswerAskUser = onAnswerAskUser
  }

  func updateNSViewMetadata(itemCount: Int, rows: [NativeTranscriptRow])
    -> ChatDiagnostics.Metadata
  {
    ChatDiagnostics.Metadata(
      "itemCount=\(itemCount) rowCount=\(rows.count) visibleRows=\(visibleRowRangeSummary) reason=\(updateReason(for: rows))"
    )
  }

  func update(
    rows: [NativeTranscriptRow],
    accessibilityValue: String,
    isSpeechEnabled: Bool,
    activeSpeechRowID: String?,
    areToolActionsEnabled: Bool = true,
    in scrollView: NSScrollView
  ) {
    ChatDiagnostics.measure("Transcript coordinator update", category: .transcript) {
      guard tableView != nil else {
        return
      }

      let previousRowIDs = rowIDs
      let previousRowsByID = rowsByID
      let previousRevisionsByID = revisionsByID
      let newRowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
      let newRowIDs = rows.map(\.id)
      let newRevisionsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.revision) })
      let plan = NativeTranscriptDiffPlan.make(
        previousIDs: previousRowIDs,
        previousRevisions: previousRevisionsByID,
        currentIDs: newRowIDs,
        currentRevisions: newRevisionsByID
      )
      let wasPinnedToBottom = isPinnedToBottom(scrollView)
      let speechStateChangedIDs = changedSpeechRowIDs(
        currentRowIDs: newRowIDs,
        isSpeechEnabled: isSpeechEnabled,
        activeSpeechRowID: activeSpeechRowID
      )
      let toolActionStateChangedIDs = changedToolActionRowIDs(
        currentRows: rows,
        areToolActionsEnabled: areToolActionsEnabled
      )
      let shouldScrollAfterAppend =
        NativeTranscriptScrollDecision.shouldScrollToBottomAfterAppend(
          previousIDs: rowIDs,
          currentRows: rows
        )

      rowsByID = newRowsByID
      rowIDs = newRowIDs
      revisionsByID = newRevisionsByID
      self.isSpeechEnabled = isSpeechEnabled
      self.activeSpeechRowID = activeSpeechRowID
      self.areToolActionsEnabled = areToolActionsEnabled
      pruneCoordinatorState(activeRows: rows)
      ChatDiagnostics.measure("Transcript accessibility update", category: .transcript) {
        scrollView.setAccessibilityValue(accessibilityValue)
      }
      let didChangeColumnWidth = updateColumnWidth(in: scrollView)
      if didChangeColumnWidth {
        resetStreamingHeightStateForWidthChange(activeRowIDs: Set(newRowIDs))
      } else {
        resetStreamingHeightState(
          for: Set(
            speechStateChangedIDs.filter {
              rowsByID[$0]?.isStreamingTranscriptRow == true
            })
        )
      }

      switch plan.action {
      case .snapshot:
        let snapshotChangedIDs = plan.changedIDs.union(toolActionStateChangedIDs)
        applySnapshot(
          previousIDs: previousRowIDs,
          previousRowsByID: previousRowsByID,
          rowIDs: newRowIDs,
          currentRowsByID: newRowsByID,
          changedIDs: snapshotChangedIDs,
          animatingDifferences: false
        )
        reconfigureVisibleRows(changedIDs: toolActionStateChangedIDs)
        scheduleHeightInvalidation(
          for: NativeTranscriptSnapshotInvalidation.rowIndexes(
            previousIDs: previousRowIDs,
            currentIDs: newRowIDs,
            changedIDs: snapshotChangedIDs
          ),
          reason: "snapshot",
          scrollToBottomAfterFlush: wasPinnedToBottom || shouldScrollAfterAppend
        )
      case .reconfigureRows:
        let reconfiguredIDs =
          plan.changedIDs
          .union(speechStateChangedIDs)
          .union(toolActionStateChangedIDs)
        let streamingMessageChangedIDs = streamingAssistantMessageRowIDs(in: plan.changedIDs)
        let streamingThinkingChangedIDs = streamingAssistantThinkingRowIDs(in: plan.changedIDs)
        let streamingChangedIDs = streamingMessageChangedIDs.union(streamingThinkingChangedIDs)
        let deferredStreamingIDs =
          didChangeColumnWidth
          ? Set<String>()
          : streamingChangedIDs
            .subtracting(speechStateChangedIDs)
            .subtracting(toolActionStateChangedIDs)
        let immediateReconfiguredIDs = reconfiguredIDs.subtracting(deferredStreamingIDs)
        let immediateChangedIDs = plan.changedIDs.subtracting(deferredStreamingIDs)

        reconfigureVisibleRows(changedIDs: immediateReconfiguredIDs)
        scheduleStreamingHeightUpdate(for: deferredStreamingIDs)
        var invalidationRows = rowIndexes(for: immediateReconfiguredIDs)
        if didChangeColumnWidth {
          invalidationRows.formUnion(IndexSet(integersIn: 0..<newRowIDs.count))
        }
        scheduleHeightInvalidation(
          for: invalidationRows,
          reason: heightInvalidationReason(
            didChangeColumnWidth: didChangeColumnWidth,
            streamingMessageChangedIDs: streamingMessageChangedIDs.subtracting(
              deferredStreamingIDs),
            streamingThinkingChangedIDs: streamingThinkingChangedIDs.subtracting(
              deferredStreamingIDs),
            speechStateChangedIDs: speechStateChangedIDs,
            changedIDs: immediateChangedIDs
          ),
          // Re-anchor generic invalidations that changed rows. Pure streaming
          // growth checks the current pin state in its atomic 100ms commit.
          scrollToBottomAfterFlush: wasPinnedToBottom
            && (!immediateChangedIDs.isEmpty || didChangeColumnWidth)
        )
        if shouldScrollAfterAppend || (wasPinnedToBottom && !immediateChangedIDs.isEmpty) {
          scrollToBottom(scrollView)
        }
        return
      }

      let hasRowChanges = plan.action == .snapshot || !plan.changedIDs.isEmpty
      if shouldScrollAfterAppend || (wasPinnedToBottom && hasRowChanges) {
        scrollToBottom(scrollView)
      }
    }
  }

  private var visibleRowRangeSummary: String {
    guard let tableView else {
      return "none"
    }
    let visibleRows = tableView.rows(in: tableView.visibleRect)
    guard visibleRows.location != NSNotFound else {
      return "none"
    }
    let upperBound = visibleRows.location + visibleRows.length
    return "\(visibleRows.location)..<\(upperBound)"
  }

  private func updateReason(for rows: [NativeTranscriptRow]) -> String {
    let currentIDs = rows.map(\.id)
    guard !rowIDs.isEmpty else {
      return "initial"
    }
    guard currentIDs == rowIDs else {
      return currentIDs.count == rowIDs.count ? "rowOrderChanged" : "rowCountChanged"
    }
    let currentRevisionsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.revision) })
    if currentRevisionsByID != revisionsByID {
      return "rowRevisionChanged"
    }
    return "unchanged"
  }

  private func streamingAssistantMessageRowIDs(in changedIDs: Set<String>) -> Set<String> {
    Set(changedIDs.filter { rowsByID[$0]?.isStreamingAssistantMessage == true })
  }

  private func streamingAssistantThinkingRowIDs(in changedIDs: Set<String>) -> Set<String> {
    Set(changedIDs.filter { rowsByID[$0]?.isStreamingAssistantThinkingMessage == true })
  }

  private func changedSpeechRowIDs(
    currentRowIDs: [String],
    isSpeechEnabled: Bool,
    activeSpeechRowID: String?
  ) -> Set<String> {
    guard self.isSpeechEnabled == isSpeechEnabled else {
      return Set(currentRowIDs).union(rowIDs)
    }

    return Set([self.activeSpeechRowID, activeSpeechRowID].compactMap(\.self))
  }

  private func changedToolActionRowIDs(
    currentRows: [NativeTranscriptRow],
    areToolActionsEnabled: Bool
  ) -> Set<String> {
    guard self.areToolActionsEnabled != areToolActionsEnabled else {
      return []
    }
    return Set(currentRows.filter { $0.cellKind == .tool }.map(\.id))
  }
}

extension NativeChatTranscriptCoordinator: NSTableViewDelegate {

  func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
    ChatDiagnostics.measure("Transcript row height", category: .transcript) {
      guard row >= 0, row < rowIDs.count, let rowModel = rowsByID[rowIDs[row]] else {
        return 44
      }
      if rowModel.isStreamingTranscriptRow,
        let notedHeight = lastNotedHeightByRowID[rowModel.id]
      {
        return notedHeight
      }
      let width = max(tableView?.bounds.width ?? 680, 320)
      let measuredHeight = heightCache.height(
        for: rowModel,
        width: width,
        state: cellStateStore.state(
          for: rowModel.id,
          isSpeechEnabled: isSpeechEnabled,
          activeSpeechRowID: activeSpeechRowID
        ),
        markdownBlocks: { [weak self] markdown in
          guard let self else {
            return NativeTranscriptMarkdownRenderer.blocks(for: markdown)
          }
          return self.markdownCache.blocks(for: markdown)
        }
      )
      if rowModel.isStreamingTranscriptRow {
        lastNotedHeightByRowID[rowModel.id] = measuredHeight
      }
      return measuredHeight
    }
  }

  func tableView(_: NSTableView, shouldSelectRow _: Int) -> Bool {
    false
  }

}

extension NativeChatTranscriptCoordinator {

  private func updateColumnWidth(in scrollView: NSScrollView) -> Bool {
    guard let tableColumn = tableView?.tableColumns.first else {
      return false
    }
    let targetWidth = max(scrollView.contentSize.width, 1)
    guard abs(tableColumn.width - targetWidth) >= 0.5 else {
      return false
    }
    tableColumn.width = targetWidth
    return true
  }

  private func applySnapshot(
    previousIDs: [String],
    previousRowsByID: [String: NativeTranscriptRow],
    rowIDs: [String],
    currentRowsByID: [String: NativeTranscriptRow],
    changedIDs: Set<String>,
    animatingDifferences: Bool
  ) {
    ChatDiagnostics.measure(
      "Transcript apply snapshot",
      category: .transcript,
      metadata: snapshotMetadata(
        previousIDs: previousIDs,
        previousRowsByID: previousRowsByID,
        currentIDs: rowIDs,
        currentRowsByID: currentRowsByID,
        changedIDs: changedIDs,
        animatingDifferences: animatingDifferences
      )
    ) {
      var snapshot = NSDiffableDataSourceSnapshot<NativeTranscriptSection, String>()
      snapshot.appendSections([section])
      snapshot.appendItems(rowIDs, toSection: section)
      dataSource?.apply(snapshot, animatingDifferences: animatingDifferences)
    }
  }

  private func snapshotMetadata(
    previousIDs: [String],
    previousRowsByID: [String: NativeTranscriptRow],
    currentIDs: [String],
    currentRowsByID: [String: NativeTranscriptRow],
    changedIDs: Set<String>,
    animatingDifferences: Bool
  ) -> ChatDiagnostics.Metadata {
    let previousIDSet = Set(previousIDs)
    let currentIDSet = Set(currentIDs)
    let insertedIDs = currentIDs.filter { !previousIDSet.contains($0) }
    let removedIDs = previousIDs.filter { !currentIDSet.contains($0) }
    let reloadedCount = changedIDs.intersection(currentIDSet).count
    let reason = snapshotReason(
      previousIDs: previousIDs,
      currentIDs: currentIDs,
      insertedIDs: insertedIDs,
      removedIDs: removedIDs,
      previousRowsByID: previousRowsByID,
      currentRowsByID: currentRowsByID
    )
    let insertedKinds = rowKindSummary(ids: insertedIDs, rowsByID: currentRowsByID)
    let removedKinds = rowKindSummary(ids: removedIDs, rowsByID: previousRowsByID)
    let parts = [
      "reason=\(reason)",
      "previousRows=\(previousIDs.count)",
      "currentRows=\(currentIDs.count)",
      "inserted=\(insertedIDs.count)",
      "deleted=\(removedIDs.count)",
      "reloaded=\(reloadedCount)",
      "insertedIDs=\(insertedIDs.telemetryIDListSummary)",
      "removedIDs=\(removedIDs.telemetryIDListSummary)",
      "insertedKinds=\(insertedKinds)",
      "removedKinds=\(removedKinds)",
      "animated=\(animatingDifferences)",
    ]
    return ChatDiagnostics.Metadata(
      parts.joined(separator: " ")
    )
  }

  private func snapshotReason(
    previousIDs: [String],
    currentIDs: [String],
    insertedIDs: [String],
    removedIDs: [String],
    previousRowsByID: [String: NativeTranscriptRow],
    currentRowsByID: [String: NativeTranscriptRow]
  ) -> String {
    guard !previousIDs.isEmpty || !currentIDs.isEmpty else {
      return "initialEmpty"
    }
    if previousIDs.isEmpty {
      return "initialRows"
    }

    var reasons: [String] = []
    if currentIDs.count != previousIDs.count {
      reasons.append(currentIDs.count > previousIDs.count ? "rowAdded" : "rowRemoved")
    } else {
      reasons.append("rowOrderOrReplacement")
    }
    if insertedIDs.contains(where: { currentRowsByID[$0]?.isGenerationIndicator == true }) {
      reasons.append("generationIndicatorAdded")
    }
    if removedIDs.contains(where: { previousRowsByID[$0]?.isGenerationIndicator == true }) {
      reasons.append("generationIndicatorRemoved")
    }
    if insertedIDs.contains(where: {
      currentRowsByID[$0]?.isTransientAssistantPlaceholder == true
    }) {
      reasons.append("transientPlaceholderAdded")
    }
    if removedIDs.contains(where: {
      previousRowsByID[$0]?.isTransientAssistantPlaceholder == true
    }) {
      reasons.append("transientPlaceholderRemoved")
    }
    return reasons.isEmpty ? "rowIDsChanged" : reasons.joined(separator: "+")
  }

  private func rowKindSummary(
    ids: [String],
    rowsByID: [String: NativeTranscriptRow]
  ) -> String {
    let counts = ids.reduce(into: [String: Int]()) { partialResult, id in
      let kind = rowsByID[id]?.cellKind.telemetryName ?? "unknown"
      partialResult[kind, default: 0] += 1
    }
    guard !counts.isEmpty else {
      return "none"
    }
    return counts.keys.sorted().map { "\($0):\(counts[$0] ?? 0)" }.joined(separator: ",")
  }
}

extension NativeChatTranscriptCoordinator {

  private func configure(_ cell: NativeChatMessageCellView, with row: NativeTranscriptRow) {
    ChatDiagnostics.measure("Transcript row configure", category: .transcript) {
      cell.configure(
        row: row,
        state: cellStateStore.state(
          for: row.id,
          isSpeechEnabled: isSpeechEnabled,
          activeSpeechRowID: activeSpeechRowID,
          areToolActionsEnabled: areToolActionsEnabled
        ),
        actions: NativeTranscriptCellActions(
          markdownBlocks: { [weak self] markdown in
            guard let self else {
              return NativeTranscriptMarkdownRenderer.blocks(for: markdown)
            }
            return self.markdownCache.blocks(for: markdown)
          },
          highlightedCode: { [weak self] rowID, codeBlock in
            self?.codeHighlightStore.highlightedCode(rowID: rowID, codeBlock: codeBlock)
          },
          requestCodeHighlight: { [weak self] rowID, codeBlock in
            guard let self else {
              return
            }
            self.codeHighlightStore.requestHighlight(
              rowID: rowID,
              codeBlock: codeBlock
            ) { [weak self] updatedRowID in
              self?.applyCodeHighlightToVisibleRows(rowID: updatedRowID)
            }
          },
          attachmentThumbnail: { [weak self] attachment, maxPixelSize in
            self?.attachmentThumbnailStore.thumbnail(
              for: attachment,
              maxPixelSize: maxPixelSize
            )
          },
          requestAttachmentThumbnail: { [weak self] rowID, attachment, maxPixelSize in
            self?.attachmentThumbnailStore.requestThumbnail(
              rowID: rowID,
              attachment: attachment,
              maxPixelSize: maxPixelSize
            ) { [weak self] updatedRowID in
              self?.reconfigureRows(ids: [updatedRowID])
            }
          },
          showImageAttachment: { [weak self] attachment, sourceView in
            self?.showImageAttachment(attachment, relativeTo: sourceView)
          },
          copy: { [weak self] rowID, content in
            self?.copy(content: content, from: rowID)
          },
          toggleSpeech: { [weak self] rowID, content in
            self?.onToggleSpeech(rowID, content)
          },
          approve: { [weak self] toolCallID in
            self?.onApproveToolCall(toolCallID)
          },
          approveAll: { [weak self] anchorID in
            self?.onApproveToolCallBatch(anchorID)
          },
          deny: { [weak self] toolCallID in
            self?.onDenyToolCall(toolCallID)
          },
          answerAskUser: { [weak self] rowID, toolCallID, answer in
            self?.cellStateStore.updateAskUserSelection(answer, rowID: rowID)
            self?.onAnswerAskUser(toolCallID, answer)
          },
          toggleToolExpansion: { [weak self] rowID in
            self?.toggleToolExpansion(rowID: rowID)
          },
          toggleThinkingExpansion: { [weak self] rowID in
            self?.toggleThinkingExpansion(rowID: rowID)
          },
          updateAskUserSelection: { [weak self] rowID, answer in
            self?.cellStateStore.updateAskUserSelection(answer, rowID: rowID)
          }
        )
      )
    }
  }

  private func showImageAttachment(_ attachment: ChatAttachment, relativeTo sourceView: NSView) {
    attachmentPreviewPopover?.close()
    let popover = NSPopover()
    popover.behavior = .transient
    popover.animates = true
    popover.contentViewController = NativeAttachmentImagePreviewController(
      imageURL: attachmentThumbnailStore.imageURL(for: attachment),
      displayName: attachment.displayName
    )
    attachmentPreviewPopover = popover
    popover.show(relativeTo: sourceView.bounds, of: sourceView, preferredEdge: .minY)
  }

  private func copy(content: String, from rowID: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(content, forType: .string)
    cellStateStore.setCopied(true, rowID: rowID)
    reconfigureRows(ids: [rowID])

    Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.2))
      cellStateStore.setCopied(false, rowID: rowID)
      reconfigureRows(ids: [rowID])
    }
  }

  private func toggleToolExpansion(rowID: String) {
    cellStateStore.toggleToolExpansion(rowID: rowID)
    applyInteractiveHeightChange(
      rowID: rowID,
      isExpanded: cellStateStore.state(for: rowID).isToolExpanded
    )
  }

  func toggleThinkingExpansion(rowID: String) {
    cellStateStore.toggleThinkingExpansion(rowID: rowID)
    applyInteractiveHeightChange(
      rowID: rowID,
      isExpanded: cellStateStore.state(for: rowID).isThinkingExpanded
    )
  }

  private func applyInteractiveHeightChange(rowID: String, isExpanded: Bool) {
    resetStreamingHeightState(for: [rowID])
    heightCache.invalidate(rowID: rowID)
    let rowIndexes = rowIndexes(for: [rowID])
    if isExpanded {
      noteHeightChangeImmediately(for: rowIndexes, reason: "interactiveExpand")
      reconfigureRows(ids: [rowID])
    } else {
      reconfigureRows(ids: [rowID])
      noteHeightChangeImmediately(for: rowIndexes, reason: "interactiveCollapse")
    }
  }
}

extension NativeChatTranscriptCoordinator {

  private func noteHeightChangeImmediately(for rowIndexes: IndexSet, reason: String) {
    guard let tableView, !rowIndexes.isEmpty else {
      return
    }
    pendingHeightInvalidationRows.subtract(rowIndexes)
    ChatDiagnostics.measure(
      "Transcript height invalidation",
      category: .transcript,
      metadata: heightInvalidationMetadata(rowIndexes: rowIndexes, reason: reason)
    ) {
      noteHeightOfRowsWithoutAnimation(tableView, rowIndexes: rowIndexes)
      tableView.layoutSubtreeIfNeeded()
    }
  }

  // noteHeightOfRows animates height changes by default; streaming invalidates
  // heights up to ~16x per second, so overlapping ease animations make rows
  // (and everything anchored below them) visibly bounce. Streaming growth must
  // land instantly instead.
  private func noteHeightOfRowsWithoutAnimation(
    _ tableView: NSTableView,
    rowIndexes: IndexSet
  ) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      context.allowsImplicitAnimation = false
      tableView.noteHeightOfRows(withIndexesChanged: rowIndexes)
    }
  }

  private func reconfigureRows(ids: [String]) {
    reconfigureVisibleRows(changedIDs: Set(ids))
  }

  // Finished highlights recolor the affected code labels of the visible cell
  // in place. Cells that are offscreen pick the cached result up from the
  // store on their next configure, exactly like before.
  private func applyCodeHighlightToVisibleRows(rowID: String) {
    guard let tableView else {
      return
    }
    let visibleRows = tableView.rows(in: tableView.visibleRect)
    guard visibleRows.location != NSNotFound else {
      return
    }
    for row in visibleRows.location..<(visibleRows.location + visibleRows.length) {
      guard row >= 0, row < rowIDs.count, rowIDs[row] == rowID,
        let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
          as? NativeChatMessageCellView
      else {
        continue
      }
      cell.applyAvailableCodeHighlights(rowID: rowID)
    }
  }

  private func reconfigureVisibleRows(changedIDs: Set<String>) {
    ChatDiagnostics.measure("Transcript visible row reconfigure", category: .transcript) {
      guard let tableView, !changedIDs.isEmpty else {
        return
      }
      let visibleRows = tableView.rows(in: tableView.visibleRect)
      guard visibleRows.location != NSNotFound else {
        return
      }
      for row in visibleRows.location..<(visibleRows.location + visibleRows.length) {
        guard row >= 0, row < rowIDs.count, changedIDs.contains(rowIDs[row]),
          let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
            as? NativeChatMessageCellView,
          let rowModel = rowsByID[rowIDs[row]]
        else {
          continue
        }
        configure(cell, with: rowModel)
      }
    }
  }

  private func scheduleStreamingHeightUpdate(for rowIDs: Set<String>) {
    guard !rowIDs.isEmpty else {
      return
    }
    pendingStreamingRowIDs.formUnion(rowIDs)

    // A pure streaming revision now owns both the visible reconfigure and its
    // height commit. Do not let an older generic invalidation remeasure it by
    // revision before that atomic commit runs.
    pendingHeightInvalidationRows.subtract(rowIndexes(for: rowIDs))
    if pendingHeightInvalidationRows.isEmpty {
      pendingHeightInvalidationWorkItem?.cancel()
      pendingHeightInvalidationWorkItem = nil
      pendingHeightInvalidationReasons.removeAll()
      shouldScrollAfterHeightInvalidation = false
    }

    guard streamingHeightWorkItem == nil else {
      return
    }
    let workItem = DispatchWorkItem { [weak self] in
      Task { @MainActor in
        self?.flushStreamingHeightUpdate()
      }
    }
    streamingHeightWorkItem = workItem
    // Leading, non-starving coalescing: later revisions update rowsByID but do
    // not move this deadline, so continuous streaming still commits at 10 Hz.
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: workItem)
  }

  private func recordMeasuredStreamingHeight(_ height: CGFloat, rowID: String) {
    guard height.isFinite,
      let row = rowsByID[rowID],
      row.isStreamingTranscriptRow
    else {
      return
    }
    pendingMeasuredHeightByRowID[rowID] = ceil(max(44, height))
    if !streamingRowsBeingCommitted.contains(rowID) {
      scheduleStreamingHeightUpdate(for: [rowID])
    }
  }

  private func flushStreamingHeightUpdate() {
    let committingRowIDs = pendingStreamingRowIDs
    pendingStreamingRowIDs.removeAll()
    streamingHeightWorkItem = nil
    guard let tableView, !committingRowIDs.isEmpty else {
      for rowID in committingRowIDs {
        pendingMeasuredHeightByRowID[rowID] = nil
      }
      return
    }

    // These values belong to the previous visible layout. Only measurements
    // produced by the latest rowsByID models in this commit may be promoted.
    for rowID in committingRowIDs {
      pendingMeasuredHeightByRowID[rowID] = nil
    }
    let scrollView = tableView.enclosingScrollView
    let wasPinnedToBottom = scrollView.map(isPinnedToBottom) ?? false

    streamingRowsBeingCommitted = committingRowIDs
    reconfigureVisibleRows(changedIDs: committingRowIDs)
    layoutVisibleRows(withIDs: committingRowIDs, in: tableView)
    streamingRowsBeingCommitted.removeAll()

    var changedRows = IndexSet()
    for rowID in committingRowIDs {
      defer {
        pendingMeasuredHeightByRowID[rowID] = nil
      }
      guard let measuredHeight = pendingMeasuredHeightByRowID[rowID],
        let rowIndex = rowIDs.firstIndex(of: rowID),
        rowsByID[rowID]?.isStreamingTranscriptRow == true
      else {
        continue
      }
      let notedHeight = lastNotedHeightByRowID[rowID] ?? tableView.rect(ofRow: rowIndex).height
      if lastNotedHeightByRowID[rowID] == nil {
        lastNotedHeightByRowID[rowID] = notedHeight
      }
      guard abs(measuredHeight - notedHeight) >= 0.5 else {
        continue
      }

      // Promote before noteHeightOfRows. Its reentrant heightOfRow callback must
      // observe only the committed value, never pending measurement state.
      lastNotedHeightByRowID[rowID] = measuredHeight
      changedRows.insert(rowIndex)
    }

    guard !changedRows.isEmpty else {
      return
    }
    ChatDiagnostics.measure(
      "Transcript streaming height commit",
      category: .transcript,
      metadata: heightInvalidationMetadata(rowIndexes: changedRows, reason: "streamingCommit")
    ) {
      noteHeightOfRowsWithoutAnimation(tableView, rowIndexes: changedRows)
    }
    tableView.layoutSubtreeIfNeeded()
    guard wasPinnedToBottom, let scrollView else {
      return
    }
    scrollView.tile()
    scrollToBottomImmediately(scrollView)
  }

  private func layoutVisibleRows(withIDs rowIDsToLayout: Set<String>, in tableView: NSTableView) {
    let visibleRows = tableView.rows(in: tableView.visibleRect)
    guard visibleRows.location != NSNotFound else {
      return
    }
    for row in visibleRows.location..<(visibleRows.location + visibleRows.length) {
      guard row >= 0, row < rowIDs.count, rowIDsToLayout.contains(rowIDs[row]),
        let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
          as? NativeChatMessageCellView
      else {
        continue
      }
      cell.layoutSubtreeIfNeeded()
    }
  }

  private func resetStreamingHeightStateForWidthChange(activeRowIDs: Set<String>) {
    streamingHeightWorkItem?.cancel()
    streamingHeightWorkItem = nil
    pendingStreamingRowIDs.removeAll()
    pendingMeasuredHeightByRowID.removeAll()
    lastNotedHeightByRowID.removeAll()
    streamingRowsBeingCommitted.removeAll()
    for rowID in activeRowIDs {
      heightCache.invalidate(rowID: rowID)
    }
  }

  private func resetStreamingHeightState(for rowIDsToReset: Set<String>) {
    pendingStreamingRowIDs.subtract(rowIDsToReset)
    streamingRowsBeingCommitted.subtract(rowIDsToReset)
    for rowID in rowIDsToReset {
      pendingMeasuredHeightByRowID[rowID] = nil
      lastNotedHeightByRowID[rowID] = nil
    }
    if pendingStreamingRowIDs.isEmpty {
      streamingHeightWorkItem?.cancel()
      streamingHeightWorkItem = nil
    }
  }

  // Test-only: the 100ms main-queue hop cannot be drained from inside a
  // main-actor test body.
  // swiftlint:disable:next unused_declaration
  func flushPendingStreamingHeightUpdateForTesting() {
    guard let workItem = streamingHeightWorkItem else {
      return
    }
    workItem.cancel()
    flushStreamingHeightUpdate()
  }

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  var pendingMeasuredHeightByRowIDForTesting: [String: CGFloat] {
    pendingMeasuredHeightByRowID
  }

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  var lastNotedHeightByRowIDForTesting: [String: CGFloat] {
    lastNotedHeightByRowID
  }

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  var pendingStreamingRowIDsForTesting: Set<String> {
    pendingStreamingRowIDs
  }

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  var hasPendingStreamCommitForTesting: Bool {
    streamingHeightWorkItem != nil
  }

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  func stageMeasuredStreamingHeightForTesting(_ height: CGFloat, rowID: String) {
    pendingMeasuredHeightByRowID[rowID] = height
  }

  private func scheduleHeightInvalidation(
    for rowIndexes: IndexSet,
    reason: String,
    scrollToBottomAfterFlush: Bool
  ) {
    guard !rowIndexes.isEmpty else {
      return
    }
    pendingHeightInvalidationRows.formUnion(rowIndexes)
    pendingHeightInvalidationReasons.insert(reason)
    shouldScrollAfterHeightInvalidation =
      shouldScrollAfterHeightInvalidation || scrollToBottomAfterFlush
    guard pendingHeightInvalidationWorkItem == nil else {
      return
    }
    let workItem = DispatchWorkItem { [weak self] in
      Task { @MainActor in
        self?.flushHeightInvalidation()
      }
    }
    pendingHeightInvalidationWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60), execute: workItem)
  }

  // Runs a pending debounced flush synchronously. Test-only: the 60ms
  // asyncAfter hop cannot be drained from inside a main-queue test body.
  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  func flushPendingHeightInvalidationForTesting() {
    guard let workItem = pendingHeightInvalidationWorkItem else {
      return
    }
    workItem.cancel()
    flushHeightInvalidation()
  }

  private func flushHeightInvalidation() {
    guard let tableView else {
      pendingHeightInvalidationRows.removeAll()
      pendingHeightInvalidationReasons.removeAll()
      pendingHeightInvalidationWorkItem = nil
      return
    }
    let rows = pendingHeightInvalidationRows
    let reasons = pendingHeightInvalidationReasons.sorted()
    let shouldScrollToBottom = shouldScrollAfterHeightInvalidation
    pendingHeightInvalidationRows.removeAll()
    pendingHeightInvalidationReasons.removeAll()
    shouldScrollAfterHeightInvalidation = false
    pendingHeightInvalidationWorkItem = nil
    ChatDiagnostics.measure(
      "Transcript height invalidation",
      category: .transcript,
      metadata: heightInvalidationMetadata(
        rowIndexes: rows,
        reason: reasons.isEmpty ? "unknown" : reasons.joined(separator: "+")
      )
    ) {
      noteHeightOfRowsWithoutAnimation(tableView, rowIndexes: rows)
    }
    if shouldScrollToBottom, let scrollView = tableView.enclosingScrollView {
      // Scroll in the same pass as the height change: an async scroll targets
      // a document height that is still settling and visibly overshoots back
      // and forth while streaming.
      //
      // Lay out the scroll view, not just the table view: noteHeightOfRows
      // grows the document but the clip view only re-tiles the document frame
      // on a scroll-view layout pass. Without it, scrollToBottomImmediately
      // reads a stale document frame and the pinned viewport never follows.
      tableView.layoutSubtreeIfNeeded()
      scrollView.tile()
      scrollToBottomImmediately(scrollView)
    }
  }

  private func rowIndexes(for rowIDs: Set<String>) -> IndexSet {
    rowIndexes(for: Array(rowIDs))
  }

  private func rowIndexes(for ids: [String]) -> IndexSet {
    var indexes = IndexSet()
    for id in ids {
      if let index = rowIDs.firstIndex(of: id) {
        indexes.insert(index)
      }
    }
    return indexes
  }

  private func heightInvalidationReason(
    didChangeColumnWidth: Bool,
    streamingMessageChangedIDs: Set<String>,
    streamingThinkingChangedIDs: Set<String>,
    speechStateChangedIDs: Set<String>,
    changedIDs: Set<String>
  ) -> String {
    var reasons: [String] = []
    if didChangeColumnWidth {
      reasons.append("widthChanged")
    }
    if !streamingMessageChangedIDs.isEmpty {
      reasons.append("streamingMessage")
    }
    if !streamingThinkingChangedIDs.isEmpty {
      reasons.append("streamingThinking")
    }
    if !speechStateChangedIDs.isEmpty {
      reasons.append("speechState")
    }
    if !changedIDs.isEmpty
      && streamingMessageChangedIDs.isEmpty
      && streamingThinkingChangedIDs.isEmpty
    {
      reasons.append("rowRevisionChanged")
    }
    return reasons.isEmpty ? "unknown" : reasons.joined(separator: "+")
  }

  private func heightInvalidationMetadata(rowIndexes: IndexSet, reason: String)
    -> ChatDiagnostics.Metadata
  {
    ChatDiagnostics.Metadata(
      "reason=\(reason) rowCount=\(rowIndexes.count) rows=\(rowIndexes.telemetryRangeSummary)"
    )
  }

  // Applies the bottom inset that keeps the last row clear of the floating
  // composer. Re-pins to the bottom when the inset grows/shrinks while the
  // viewport is already pinned, so the newest content stays visible.
  func applyBottomContentInset(_ inset: CGFloat, to scrollView: NSScrollView) {
    let clamped = max(0, inset)
    guard abs(scrollView.contentInsets.bottom - clamped) >= 0.5 else {
      return
    }
    let wasPinnedToBottom = isPinnedToBottom(scrollView)
    scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: clamped, right: 0)
    scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: clamped, right: 0)
    if wasPinnedToBottom {
      scrollView.layoutSubtreeIfNeeded()
      scrollToBottomImmediately(scrollView)
    }
  }

  // The largest valid vertical scroll offset. `constrainBoundsRect` is the same
  // routine AppKit uses while scrolling, so it accounts for `contentInsets`
  // without us re-deriving the arithmetic. While a table row is growing, AppKit
  // can briefly return the old constrained value before the clip view has
  // caught up with the document frame, so also honor the actual document extent.
  private func maxScrollOffsetY(_ scrollView: NSScrollView) -> CGFloat {
    let clipView = scrollView.contentView
    let proposed = NSRect(
      x: clipView.bounds.origin.x,
      y: .greatestFiniteMagnitude,
      width: clipView.bounds.width,
      height: clipView.bounds.height
    )
    let constrainedOffset = clipView.constrainBoundsRect(proposed).origin.y
    guard let documentView = scrollView.documentView else {
      return constrainedOffset
    }
    let documentOffset =
      documentView.frame.height + scrollView.contentInsets.bottom - clipView.bounds.height
    return max(constrainedOffset, documentOffset)
  }

  private func isPinnedToBottom(_ scrollView: NSScrollView) -> Bool {
    guard scrollView.documentView != nil else {
      return true
    }
    return maxScrollOffsetY(scrollView) - scrollView.contentView.bounds.origin.y < 48
  }

  private func scrollToBottom(_ scrollView: NSScrollView) {
    DispatchQueue.main.async {
      self.scrollToBottomImmediately(scrollView)
    }
  }

  private func scrollToBottomImmediately(_ scrollView: NSScrollView) {
    guard scrollView.documentView != nil else {
      return
    }
    let targetY = max(maxScrollOffsetY(scrollView), 0)
    guard abs(scrollView.contentView.bounds.origin.y - targetY) >= 0.5 else {
      return
    }
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  private func pruneCoordinatorState(activeRows: [NativeTranscriptRow]) {
    let activeRowIDs = Set(activeRows.map(\.id))
    let activeStreamingRowIDs = Set(
      activeRows.filter(\.isStreamingTranscriptRow).map(\.id)
    )
    cellStateStore.prune(activeRowIDs: activeRowIDs)
    heightCache.prune(activeRows: activeRows)
    pendingMeasuredHeightByRowID = pendingMeasuredHeightByRowID.filter {
      activeStreamingRowIDs.contains($0.key)
    }
    lastNotedHeightByRowID = lastNotedHeightByRowID.filter {
      activeStreamingRowIDs.contains($0.key)
    }
    pendingStreamingRowIDs.formIntersection(activeStreamingRowIDs)
    streamingRowsBeingCommitted.formIntersection(activeStreamingRowIDs)
    if pendingStreamingRowIDs.isEmpty {
      streamingHeightWorkItem?.cancel()
      streamingHeightWorkItem = nil
    }
    markdownCache.prune(activeTexts: activeMarkdownTexts(in: activeRows))
    codeHighlightStore.prune(activeDescriptors: activeCodeHighlightDescriptors(in: activeRows))
    attachmentThumbnailStore.prune(
      activeDescriptors: activeAttachmentThumbnailDescriptors(in: activeRows)
    )
  }

  private func activeMarkdownTexts(in rows: [NativeTranscriptRow]) -> Set<String> {
    Set(
      rows.flatMap { row -> [String] in
        guard case .item(let item) = row.body else {
          return []
        }
        return item.assistantRenderBlocks.compactMap { block in
          guard case .paragraph(let paragraph) = block else {
            return nil
          }
          return paragraph.text
        }
      })
  }

  private func activeCodeHighlightDescriptors(
    in rows: [NativeTranscriptRow]
  ) -> Set<NativeTranscriptCodeHighlightDescriptor> {
    Set(
      rows.flatMap { row -> [NativeTranscriptCodeHighlightDescriptor] in
        guard case .item(let item) = row.body else {
          return []
        }
        return item.assistantRenderBlocks.compactMap { block in
          guard case .codeBlock(let codeBlock) = block else {
            return nil
          }
          return NativeTranscriptCodeHighlightDescriptor(rowID: row.id, codeBlock: codeBlock)
        }
      })
  }

  private func activeAttachmentThumbnailDescriptors(
    in rows: [NativeTranscriptRow]
  ) -> Set<NativeAttachmentThumbDescriptor> {
    Set(
      rows.flatMap { row -> [NativeAttachmentThumbDescriptor] in
        guard case .item(let item) = row.body else {
          return []
        }
        return item.nativeAttachments
          .filter { $0.kind == .image }
          .map {
            NativeAttachmentThumbDescriptor(
              attachment: $0,
              maxPixelSize: NativeTranscriptAttachmentPreviewMetrics.maxImagePixelSize
            )
          }
      })
  }
}

enum NativeTranscriptSection: Hashable {
  case main
}

final class NativeTranscriptNSTableView: NSTableView {
  override func layout() {
    ChatDiagnostics.measure("Transcript table layout", category: .transcript) {
      super.layout()
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    ChatDiagnostics.measure("Transcript table draw", category: .transcript) {
      super.draw(dirtyRect)
    }
  }
}

final class NativeChatMessageCellView: NSTableCellView {
  private let contentHost = NSView()
  private var hostedContentView: NSView?
  private var configuredRowID: String?
  private var configuredKind: NativeTranscriptCellKind?
  private var pendingMeasuredRowID: String?
  private var isReportingMeasuredHeight = false
  private var alignmentConstraints: [NSLayoutConstraint] = []
  fileprivate var actions: NativeTranscriptCellActions?
  private var askUserPopUpButton: NSPopUpButton?
  var onMeasuredHeight: ((String, CGFloat) -> Void)?

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  var hostedContentViewForTesting: NSView? {
    hostedContentView
  }

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    setupContentHost()
  }

  static func measuredHeight(
    for row: NativeTranscriptRow,
    width: CGFloat,
    state: NativeTranscriptCellState,
    actions: NativeTranscriptCellActions,
    reusing reusableCell: NativeChatMessageCellView? = nil
  ) -> CGFloat {
    ChatDiagnostics.measure("Transcript cell measured height", category: .transcript) {
      let constrainedWidth = max(width, 1)
      let cell =
        reusableCell
        ?? NativeChatMessageCellView(
          identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Measuring")
        )
      cell.translatesAutoresizingMaskIntoConstraints = false
      cell.configure(row: row, state: state, actions: actions)
      cell.setFrameSize(NSSize(width: constrainedWidth, height: 1))

      let widthConstraint = cell.widthAnchor.constraint(equalToConstant: constrainedWidth)
      widthConstraint.isActive = true
      defer {
        widthConstraint.isActive = false
      }

      cell.needsLayout = true
      cell.layoutSubtreeIfNeeded()
      return ceil(max(44, cell.fittingSize.height))
    }
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    reportMeasuredHeightIfNeeded()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    actions = nil
    askUserPopUpButton = nil
    onMeasuredHeight = nil
    pendingMeasuredRowID = nil
    isReportingMeasuredHeight = false
    configuredRowID = nil
    configuredKind = nil
    clearHostedContent()
  }

  func configure(
    row: NativeTranscriptRow,
    state: NativeTranscriptCellState,
    actions: NativeTranscriptCellActions
  ) {
    self.actions = actions
    askUserPopUpButton = nil
    pendingMeasuredRowID = nil
    defer {
      if row.isStreamingTranscriptRow {
        pendingMeasuredRowID = row.id
        needsLayout = true
      }
    }
    let kind = row.cellKind

    if configuredRowID == row.id,
      configuredKind == kind,
      kind == .assistantMessage,
      case .item(let item) = row.body,
      let assistantView = hostedContentView as? NativeAssistantMessageView
    {
      assistantView.update(
        item: item,
        rowID: row.id,
        state: state,
        assetsRevision: assistantAssetsRevision(for: item)
      )
      updateAccessibility(for: row)
      return
    }

    if configuredRowID == row.id,
      configuredKind == kind,
      kind == .assistantThinking,
      case .item(let item) = row.body,
      case .assistantThinking(let message) = item.item,
      let thinkingView = hostedContentView as? NativeAssistantThinkingView
    {
      thinkingView.update(message: message, rowID: row.id, state: state)
      updateAccessibility(for: row)
      return
    }

    let contentView: NSView
    switch row.body {
    case .generationIndicator:
      contentView = makeGenerationIndicator()
    case .item(let item):
      contentView = makeContentView(for: item, rowID: row.id, state: state)
    }

    replaceHostedContent(with: contentView)
    configuredRowID = row.id
    configuredKind = kind
    updateAlignment(for: row.body)
    updateAccessibility(for: row)
  }

  private func setupContentHost() {
    contentHost.translatesAutoresizingMaskIntoConstraints = false
    addSubview(contentHost)
    NSLayoutConstraint.activate([
      contentHost.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      contentHost.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
    ])
  }

  private func replaceHostedContent(with contentView: NSView) {
    clearHostedContent()
    hostedContentView = contentView

    contentHost.addSubview(contentView)
    contentView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      contentView.topAnchor.constraint(equalTo: contentHost.topAnchor),
      contentView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
      contentView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
    ])
  }

  private func clearHostedContent() {
    hostedContentView?.removeFromSuperview()
    hostedContentView = nil
  }

  private func updateAlignment(for body: NativeTranscriptRow.Body) {
    NSLayoutConstraint.deactivate(alignmentConstraints)

    switch body {
    case .item(let item) where item.isNativeUserMessage:
      alignmentConstraints = [
        contentHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -44),
        contentHost.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 80),
        contentHost.widthAnchor.constraint(
          lessThanOrEqualToConstant: item.nativeMaximumBubbleWidth),
      ]
    default:
      let preferredTrailing = contentHost.trailingAnchor.constraint(
        equalTo: trailingAnchor,
        constant: -80
      )
      preferredTrailing.priority = .defaultHigh
      let preferredWidth = contentHost.widthAnchor.constraint(equalToConstant: 680)
      preferredWidth.priority = .defaultHigh
      alignmentConstraints = [
        contentHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
        contentHost.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -80),
        contentHost.widthAnchor.constraint(lessThanOrEqualToConstant: 680),
        preferredTrailing,
        preferredWidth,
      ]
    }
    NSLayoutConstraint.activate(alignmentConstraints)
  }

  private func makeContentView(
    for item: RenderedChatTurnItem,
    rowID: String,
    state: NativeTranscriptCellState
  ) -> NSView {
    switch item.item {
    case .userMessage(let message):
      return makeUserMessageView(
        message: message,
        rowID: rowID,
        isCopied: state.isCopied
      )
    case .assistantThinking(let message):
      return makeAssistantThinkingView(
        message: message,
        rowID: rowID,
        state: state
      )
    case .assistantMessage:
      return makeAssistantMessageView(
        item: item,
        rowID: rowID,
        state: state
      )
    case .tool(let record):
      return makeToolView(
        record: record,
        generationMetrics: item.generationMetrics,
        batchPresentation: item.toolBatchPresentation,
        rowID: rowID,
        state: state
      )
    }
  }

  private func makeUserMessageView(
    message: UserTurnMessage,
    rowID: String,
    isCopied: Bool
  ) -> NSView {
    let outerStack = verticalStack(spacing: 4)
    outerStack.alignment = .trailing

    if !message.attachments.isEmpty {
      outerStack.addArrangedSubview(
        makeAttachmentPreviews(
          message.attachments,
          rowID: rowID,
          alignsTrailing: true
        ))
    }
    if !message.content.isEmpty {
      let stack = verticalStack(spacing: 0)
      stack.alignment = .trailing
      stack.addArrangedSubview(makeTextLabel(message.content, color: .labelColor))
      outerStack.addArrangedSubview(
        paddedContainer(
          stack,
          fillColor: NSColor.secondaryLabelColor.withAlphaComponent(0.12),
          cornerRadius: 10
        ))
    }
    if !message.content.isEmpty {
      outerStack.addArrangedSubview(
        makeCopyIconButton(rowID: rowID, content: message.content, isCopied: isCopied)
      )
    }
    return outerStack
  }

  private func makeAssistantThinkingView(
    message: AssistantThinkingMessage,
    rowID: String,
    state: NativeTranscriptCellState
  ) -> NSView {
    NativeAssistantThinkingView(
      message: message,
      rowID: rowID,
      state: state,
      toggleThinkingExpansion: { [weak self] rowID in
        self?.actions?.toggleThinkingExpansion(rowID)
      }
    )
  }

  private func makeAssistantFinalContentView(
    item: RenderedChatTurnItem,
    rowID: String,
    state _: NativeTranscriptCellState
  ) -> NSView? {
    let stack = verticalStack(spacing: 8)

    if !item.nativeAttachments.isEmpty {
      stack.addArrangedSubview(
        makeAttachmentPreviews(
          item.nativeAttachments,
          rowID: rowID,
          alignsTrailing: false
        ))
    }

    if item.assistantRenderBlocks.isEmpty {
      if !item.content.isEmpty {
        stack.addArrangedSubview(makeTextLabel(item.content, color: .labelColor))
      }
    } else {
      for block in item.assistantRenderBlocks {
        switch block {
        case .paragraph(let paragraph):
          for markdownBlock in actions?.markdownBlocks(paragraph.text)
            ?? NativeTranscriptMarkdownRenderer.blocks(for: paragraph.text)
          {
            stack.addArrangedSubview(makeMarkdownBlockView(markdownBlock))
          }
        case .codeBlock(let codeBlock):
          actions?.requestCodeHighlight(rowID, codeBlock)
          stack.addArrangedSubview(
            makeCodeBlockView(
              codeBlock,
              highlightedCode: actions?.highlightedCode(rowID, codeBlock)
            )
          )
        }
      }
    }

    return stack.arrangedSubviews.isEmpty ? nil : stack
  }

  private func makeAssistantFooterView(
    item: RenderedChatTurnItem,
    rowID: String,
    state: NativeTranscriptCellState
  ) -> NSView? {
    let footer = horizontalStack(spacing: 8)
    if state.isSpeechEnabled, let spokenText = item.nativeSpokenText {
      footer.addArrangedSubview(
        makeSpeechIconButton(
          rowID: rowID,
          content: spokenText,
          isSpeaking: state.isSpeaking
        )
      )
    }
    if item.canNativeCopyMessageContent {
      footer.addArrangedSubview(
        makeCopyIconButton(rowID: rowID, content: item.content, isCopied: state.isCopied)
      )
    }
    if let metrics = item.visibleGenerationMetrics {
      footer.addArrangedSubview(makeSecondaryLabel(metrics.visibleSummary))
    }
    if footer.arrangedSubviews.isEmpty {
      return nil
    }
    return footer
  }

  private func makeMarkdownBlockView(_ block: NativeMarkdownBlock) -> NSView {
    switch block {
    case .text(let attributedString):
      makeAttributedTextLabel(attributedString)
    case .table(let table):
      NativeTranscriptTableView(table: table)
    }
  }

  private func makeToolView(
    record: ToolCallRecord,
    generationMetrics: ChatGenerationMetrics?,
    batchPresentation: ToolApprovalBatchPresentation?,
    rowID: String,
    state: NativeTranscriptCellState
  ) -> NSView {
    let stack = verticalStack(spacing: 7)
    let toolCall = record.transcriptToolCall
    let hasDetails = record.hasNativeToolDetails || generationMetrics != nil

    let header = horizontalStack(spacing: 7)
    header.distribution = .fill
    header.addArrangedSubview(makeToolStatusIndicator(status: record.status))
    let nameLabel = makeTextLabel(toolCall.toolName.rawValue, color: .labelColor)
    nameLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
    header.addArrangedSubview(nameLabel)
    if let summary = toolCall.nativeHeaderSummary {
      let summaryLabel = makeSecondaryLabel(summary)
      summaryLabel.lineBreakMode = .byTruncatingMiddle
      summaryLabel.maximumNumberOfLines = 1
      header.addArrangedSubview(summaryLabel)
    }
    if hasDetails {
      header.addArrangedSubview(
        makeIconButton(
          systemSymbolName: state.isToolExpanded ? "chevron.down" : "chevron.right",
          accessibilityLabel: state.isToolExpanded ? "Hide details" : "Show details",
          tintColor: .tertiaryLabelColor
        ) { [weak self] in
          self?.actions?.toggleToolExpansion(rowID)
        }
      )
    }
    header.addArrangedSubview(spacer())
    stack.addArrangedSubview(header)
    header.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true

    if state.isToolExpanded, hasDetails {
      stack.addArrangedSubview(makeToolDetails(record: record, metrics: generationMetrics))
    }

    if record.status == .awaitingApproval {
      let actionsRow = horizontalStack(spacing: 8)
      if let batch = batchPresentation, batch.showsApproveAll {
        actionsRow.addArrangedSubview(
          makeSmallButton(
            title: "Approve all (\(batch.pendingApprovalCount))",
            accessibilityIdentifier: "chat.tool.approveAll.\(batch.anchorID.uuidString)",
            accessibilityLabel: "Approve all \(batch.pendingApprovalCount) tool calls",
            isEnabled: state.isToolActionEnabled
          ) { [weak self] in
            self?.actions?.approveAll(batch.anchorID)
          }
        )
      }
      actionsRow.addArrangedSubview(
        makeSmallButton(
          title: "Approve",
          accessibilityIdentifier: "chat.tool.approve.\(record.id.uuidString)",
          accessibilityLabel: "Approve \(toolCall.toolName.rawValue) tool call",
          isEnabled: state.isToolActionEnabled
        ) { [weak self] in
          self?.actions?.approve(record.id)
        }
      )
      actionsRow.addArrangedSubview(
        makeSmallButton(
          title: "Deny",
          accessibilityIdentifier: "chat.tool.deny.\(record.id.uuidString)",
          accessibilityLabel: "Deny \(toolCall.toolName.rawValue) tool call",
          isEnabled: state.isToolActionEnabled
        ) { [weak self] in
          self?.actions?.deny(record.id)
        }
      )
      actionsRow.addArrangedSubview(spacer())
      stack.addArrangedSubview(actionsRow)
    }

    if record.status == .awaitingUserAnswer, let input = record.nativeAskUserInput {
      stack.addArrangedSubview(
        makeAskUserView(
          input: input,
          selectedAnswer: state.askUserSelection,
          isEnabled: state.isToolActionEnabled,
          rowID: rowID,
          toolCallID: record.id
        )
      )
    }

    return stack
  }

  private func makeToolDetails(record: ToolCallRecord, metrics: ChatGenerationMetrics?) -> NSView {
    let stack = verticalStack(spacing: 5)
    let details = NativeToolDetailContent(record: record)

    for line in details.argumentLines {
      stack.addArrangedSubview(makeSecondaryLabel(line))
    }

    for line in details.permissionLines {
      stack.addArrangedSubview(makeSecondaryLabel(line))
    }

    if let outputText = details.outputText {
      if let title = details.outputTitle {
        stack.addArrangedSubview(makeSecondaryLabel(title))
      }
      stack.addArrangedSubview(
        paddedContainer(
          makeCodeLikeLabel(outputText),
          fillColor: NSColor.secondaryLabelColor.withAlphaComponent(0.08),
          cornerRadius: 6
        )
      )
    }

    if !details.affectedPaths.isEmpty {
      stack.addArrangedSubview(
        makeSecondaryLabel("Affected: \(details.affectedPaths.joined(separator: ", "))")
      )
    }

    if !details.flags.isEmpty {
      stack.addArrangedSubview(makeSecondaryLabel(details.flags.joined(separator: " · ")))
    }

    if let metrics {
      stack.addArrangedSubview(makeSecondaryLabel(metrics.visibleSummary))
    }

    return stack
  }

  private func makeAskUserView(
    input: AskUserInput,
    selectedAnswer: String?,
    isEnabled: Bool,
    rowID: String,
    toolCallID: ToolCallRecord.ID
  ) -> NSView {
    let stack = verticalStack(spacing: 6)
    stack.addArrangedSubview(makeTextLabel(input.question, color: .labelColor))
    guard !input.options.isEmpty else {
      return stack
    }

    let selectedOption =
      selectedAnswer.flatMap { input.options.contains($0) ? $0 : nil }
      ?? input.options[0]
    let row = horizontalStack(spacing: 7)
    let popup = NSPopUpButton()
    popup.addItems(withTitles: input.options)
    popup.selectItem(withTitle: selectedOption)
    popup.controlSize = .small
    popup.target = self
    popup.action = #selector(askUserSelectionChanged(_:))
    popup.identifier = NSUserInterfaceItemIdentifier(rowID)
    popup.isEnabled = isEnabled
    askUserPopUpButton = popup
    row.addArrangedSubview(popup)
    row.addArrangedSubview(
      makeSmallButton(title: "Send", isEnabled: isEnabled) { [weak self] in
        let answer = self?.askUserPopUpButton?.selectedItem?.title ?? selectedOption
        self?.actions?.answerAskUser(rowID, toolCallID, answer)
      }
    )
    row.addArrangedSubview(spacer())
    stack.addArrangedSubview(row)
    return stack
  }

  @objc private func askUserSelectionChanged(_ sender: NSPopUpButton) {
    guard let rowID = sender.identifier?.rawValue, let title = sender.selectedItem?.title else {
      return
    }
    actions?.updateAskUserSelection(rowID, title)
  }

  private func makeGenerationIndicator(title: String = "Generating") -> NSView {
    let row = horizontalStack(spacing: 8)
    let spinner = NSProgressIndicator()
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    spinner.startAnimation(nil)
    row.addArrangedSubview(spinner)
    row.addArrangedSubview(makeSecondaryLabel(title))
    return row
  }

  private func makeCodeBlockView(
    _ codeBlock: AssistantRenderBlock.CodeBlock,
    highlightedCode: HighlightedCode?
  ) -> NSView {
    let language = CodeLanguage(fenceLanguage: codeBlock.language)
    let attributedCode =
      highlightedCode.map(NativeTranscriptCodeRenderer.attributedString)
      ?? NativeTranscriptCodeRenderer.plainAttributedString(
        code: codeBlock.text.isEmpty ? " " : codeBlock.text,
        language: language
      )
    let codeLabel = makeCodeAttributedLabel(attributedCode)
    let stack = NativeCodeBlockView(
      codeBlock: codeBlock,
      codeLabel: codeLabel,
      hasHighlightedCode: highlightedCode != nil
    )
    if let languageName = codeBlock.language, !languageName.isEmpty {
      stack.addArrangedSubview(makeSecondaryLabel(languageName))
    }
    stack.addArrangedSubview(
      borderedPaddedContainer(
        codeLabel,
        fillColor: NSColor.secondaryLabelColor.withAlphaComponent(0.08),
        strokeColor: NSColor.secondaryLabelColor.withAlphaComponent(0.12),
        cornerRadius: 8
      )
    )
    return stack
  }

  private func makeTextLabel(_ text: String, color: NSColor) -> NSTextField {
    let label = makeAttributedTextLabel(NativeTranscriptMarkdownRenderer.linkifiedPlainText(text))
    label.textColor = color
    return label
  }

  private func makeCodeLikeLabel(_ text: String) -> NSTextField {
    makeCodeAttributedLabel(
      NativeTranscriptCodeRenderer.plainAttributedString(code: text, language: nil)
    )
  }

  private func makeSecondaryLabel(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    label.textColor = .secondaryLabelColor
    label.maximumNumberOfLines = 0
    label.lineBreakMode = .byWordWrapping
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }

  private func makeAttributedTextLabel(_ attributedString: NSAttributedString) -> NSTextField {
    let label = NSTextField(labelWithAttributedString: attributedString)
    label.maximumNumberOfLines = 0
    label.lineBreakMode = .byWordWrapping
    label.isSelectable = true
    label.allowsEditingTextAttributes = true
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }

  private func makeCodeAttributedLabel(_ attributedString: NSAttributedString) -> NSTextField {
    let label = makeAttributedTextLabel(attributedString)
    label.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    return label
  }

  private func makeToolStatusIndicator(status: ToolCallStatus) -> NSView {
    if status.nativeIsInProgress {
      let spinner = NSProgressIndicator()
      spinner.translatesAutoresizingMaskIntoConstraints = false
      spinner.style = .spinning
      spinner.controlSize = .small
      spinner.startAnimation(nil)
      NSLayoutConstraint.activate([
        spinner.widthAnchor.constraint(equalToConstant: 13),
        spinner.heightAnchor.constraint(equalToConstant: 13),
      ])
      spinner.setAccessibilityElement(false)
      return spinner
    }

    let imageView = NSImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.image = NSImage(
      systemSymbolName: status.nativeQuietSystemImage,
      accessibilityDescription: nil
    )
    imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
    imageView.contentTintColor = status.nativeQuietColor
    imageView.setAccessibilityElement(false)
    NSLayoutConstraint.activate([
      imageView.widthAnchor.constraint(equalToConstant: 13),
      imageView.heightAnchor.constraint(equalToConstant: 13),
    ])
    return imageView
  }

}

extension NativeChatMessageCellView {
  private func reportMeasuredHeightIfNeeded() {
    guard let onMeasuredHeight,
      let measuredRowID = pendingMeasuredRowID,
      configuredRowID == measuredRowID,
      superview != nil,
      !isHidden,
      bounds.width > 0,
      !isReportingMeasuredHeight
    else {
      return
    }

    pendingMeasuredRowID = nil
    isReportingMeasuredHeight = true
    let measuredHeight = ceil(max(44, fittingSize.height))
    isReportingMeasuredHeight = false
    guard measuredHeight.isFinite, configuredRowID == measuredRowID else {
      return
    }
    onMeasuredHeight(measuredRowID, measuredHeight)
  }

  private func updateAccessibility(for row: NativeTranscriptRow) {
    ChatDiagnostics.measure("Transcript cell accessibility", category: .transcript) {
      setAccessibilityElement(true)
      setAccessibilityIdentifier(row.accessibilityIdentifier)
      setAccessibilityLabel(row.accessibilityLabel)
    }
  }

  fileprivate func makeCopyIconButton(rowID: String, content: String, isCopied: Bool) -> NSButton {
    makeIconButton(
      systemSymbolName: isCopied ? "checkmark" : "doc.on.doc",
      accessibilityLabel: isCopied ? "Copied" : "Copy message",
      tintColor: .secondaryLabelColor
    ) { [weak self] in
      self?.actions?.copy(rowID, content)
    }
  }

  fileprivate func makeSpeechIconButton(rowID: String, content: String, isSpeaking: Bool)
    -> NSButton
  {
    makeIconButton(
      systemSymbolName: isSpeaking ? "stop.fill" : "play.fill",
      accessibilityLabel: isSpeaking ? "Stop reading message" : "Read message aloud",
      tintColor: .secondaryLabelColor
    ) { [weak self] in
      self?.actions?.toggleSpeech(rowID, content)
    }
  }

  fileprivate func makeIconButton(
    systemSymbolName: String,
    accessibilityLabel: String,
    tintColor: NSColor,
    action: @escaping () -> Void
  ) -> NSButton {
    let button = NativeActionButton(title: "")
    button.translatesAutoresizingMaskIntoConstraints = false
    button.image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil)
    button.image?.isTemplate = true
    button.contentTintColor = tintColor
    button.imagePosition = .imageOnly
    button.bezelStyle = .inline
    button.isBordered = false
    button.controlSize = .small
    button.setButtonType(.momentaryPushIn)
    button.actionHandler = action
    button.toolTip = accessibilityLabel
    button.setAccessibilityLabel(accessibilityLabel)
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 18),
      button.heightAnchor.constraint(equalToConstant: 18),
    ])
    return button
  }

  fileprivate func makeSmallButton(
    title: String,
    accessibilityIdentifier: String? = nil,
    accessibilityLabel: String? = nil,
    isEnabled: Bool = true,
    action: @escaping () -> Void
  ) -> NSButton {
    let button = NativeActionButton(title: title)
    button.controlSize = .small
    button.bezelStyle = .rounded
    button.setButtonType(.momentaryPushIn)
    button.isEnabled = isEnabled
    if let accessibilityIdentifier {
      button.setAccessibilityIdentifier(accessibilityIdentifier)
    }
    if let accessibilityLabel {
      button.setAccessibilityLabel(accessibilityLabel)
    }
    button.actionHandler = action
    return button
  }

  fileprivate func paddedContainer(
    _ view: NSView,
    fillColor: NSColor,
    cornerRadius: CGFloat
  ) -> NSView {
    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor = fillColor.cgColor
    container.layer?.cornerRadius = cornerRadius
    container.addSubview(view)
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      view.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
      view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
      view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
      view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
    ])
    return container
  }

  fileprivate func borderedPaddedContainer(
    _ view: NSView,
    fillColor: NSColor,
    strokeColor: NSColor,
    cornerRadius: CGFloat
  ) -> NSView {
    let container = paddedContainer(view, fillColor: fillColor, cornerRadius: cornerRadius)
    container.layer?.borderColor = strokeColor.cgColor
    container.layer?.borderWidth = 1
    return container
  }

  // Fingerprints the async-loaded assets a final content build would bake in.
  // Thumbnail completion reconfigures the row with an unchanged renderRevision
  // and relies on this value changing to get past the ContentMode guard.
  fileprivate func assistantAssetsRevision(for item: RenderedChatTurnItem) -> Int {
    let attachments = item.nativeAttachments
    guard !attachments.isEmpty else {
      return 0
    }
    var hasher = Hasher()
    let maxPixelSize = NativeTranscriptAttachmentPreviewMetrics.maxImagePixelSize
    for attachment in attachments {
      hasher.combine(attachment.id)
      hasher.combine(actions?.attachmentThumbnail(attachment, maxPixelSize) != nil)
    }
    return hasher.finalize()
  }

  fileprivate func makeAssistantMessageView(
    item: RenderedChatTurnItem,
    rowID: String,
    state: NativeTranscriptCellState
  ) -> NSView {
    NativeAssistantMessageView(
      item: item,
      rowID: rowID,
      state: state,
      assetsRevision: assistantAssetsRevision(for: item),
      makePlaceholderView: { [weak self] title in
        self?.makeGenerationIndicator(title: title) ?? NSView()
      },
      makeFinalContentView: { [weak self] item, rowID, state in
        self?.makeAssistantFinalContentView(item: item, rowID: rowID, state: state)
      },
      makeFooterView: { [weak self] item, rowID, state in
        self?.makeAssistantFooterView(item: item, rowID: rowID, state: state)
      },
      makeStreamingBlocksView: { [weak self] rowID in
        NativeStreamingAssistantBlocksView(
          markdownBlocks: { [weak self] text in
            self?.actions?.markdownBlocks(text)
              ?? NativeTranscriptMarkdownRenderer.blocks(for: text)
          },
          makeMarkdownBlockView: { [weak self] block in
            self?.makeMarkdownBlockView(block) ?? NSView()
          },
          makeFinalCodeBlockView: { [weak self] codeBlock in
            guard let self else {
              return NSView()
            }
            self.actions?.requestCodeHighlight(rowID, codeBlock)
            return self.makeCodeBlockView(
              codeBlock,
              highlightedCode: self.actions?.highlightedCode(rowID, codeBlock)
            )
          }
        )
      }
    )
  }

  func applyAvailableCodeHighlights(rowID: String) {
    guard configuredRowID == rowID, let hostedContentView, let actions else {
      return
    }
    applyAvailableCodeHighlights(in: hostedContentView, rowID: rowID, actions: actions)
  }

  private func applyAvailableCodeHighlights(
    in view: NSView,
    rowID: String,
    actions: NativeTranscriptCellActions
  ) {
    if let codeBlockView = view as? NativeCodeBlockView {
      codeBlockView.applyHighlightedCodeIfNeeded(
        actions.highlightedCode(rowID, codeBlockView.codeBlock)
      )
      return
    }
    for subview in view.subviews {
      applyAvailableCodeHighlights(in: subview, rowID: rowID, actions: actions)
    }
  }

  fileprivate func verticalStack(spacing: CGFloat) -> NSStackView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.distribution = .gravityAreas
    stack.spacing = spacing
    return stack
  }

  fileprivate func horizontalStack(spacing: CGFloat) -> NSStackView {
    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.distribution = .gravityAreas
    stack.spacing = spacing
    return stack
  }

  fileprivate func spacer() -> NSView {
    let view = NSView()
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
  }
  fileprivate func makeAttachmentPreviews(
    _ attachments: [ChatAttachment],
    rowID: String,
    alignsTrailing: Bool
  ) -> NSView {
    let stack = verticalStack(spacing: 4)
    stack.alignment = alignsTrailing ? .trailing : .leading
    for attachment in attachments {
      stack.addArrangedSubview(makeAttachmentPreview(attachment, rowID: rowID))
    }
    return stack
  }

  fileprivate func makeAttachmentPreview(_ attachment: ChatAttachment, rowID: String) -> NSView {
    switch attachment.kind {
    case .image:
      return makeImageAttachmentPreview(attachment, rowID: rowID)
    case .text:
      return makeTextAttachmentPreview(attachment)
    }
  }

  fileprivate func makeImageAttachmentPreview(_ attachment: ChatAttachment, rowID: String) -> NSView
  {
    let stack = verticalStack(spacing: 0)
    stack.alignment = .leading
    let maxPixelSize = NativeTranscriptAttachmentPreviewMetrics.maxImagePixelSize
    actions?.requestAttachmentThumbnail(rowID, attachment, maxPixelSize)
    let imageView = makeAttachmentImageView(
      actions?.attachmentThumbnail(attachment, maxPixelSize)
    )
    stack.addArrangedSubview(imageView)

    let nameLabel = makeSecondaryLabel(attachment.displayName)
    nameLabel.maximumNumberOfLines = 1
    nameLabel.lineBreakMode = .byTruncatingMiddle
    NSLayoutConstraint.activate([
      nameLabel.widthAnchor.constraint(
        lessThanOrEqualToConstant: NativeTranscriptAttachmentPreviewMetrics.imageSize.width
      )
    ])
    stack.addArrangedSubview(nameLabel)

    let container = clickableContainer(stack)
    container.toolTip = attachment.displayPath
    container.setAccessibilityElement(true)
    container.setAccessibilityRole(.button)
    container.setAccessibilityLabel("Attached image \(attachment.displayName)")
    container.actionHandler = { [weak self, attachment] sourceView in
      self?.actions?.showImageAttachment(attachment, sourceView)
    }
    return container
  }

  fileprivate func makeTextAttachmentPreview(_ attachment: ChatAttachment) -> NSView {
    let row = horizontalStack(spacing: 7)
    row.addArrangedSubview(makeAttachmentSymbol("doc.text"))
    let label = makeSecondaryLabel(attachment.displayName)
    label.maximumNumberOfLines = 1
    label.lineBreakMode = .byTruncatingMiddle
    row.addArrangedSubview(label)
    let container = paddedContainer(
      row,
      fillColor: NSColor.secondaryLabelColor.withAlphaComponent(0.12),
      cornerRadius: 8
    )
    container.toolTip = attachment.displayPath
    container.setAccessibilityElement(true)
    container.setAccessibilityLabel("Attached file \(attachment.displayName)")
    return container
  }

  fileprivate func makeAttachmentImageView(_ image: NSImage?) -> NSView {
    let size = NativeTranscriptAttachmentPreviewMetrics.imageSize
    let container = NSView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.wantsLayer = true
    container.layer?.cornerRadius = 5
    container.layer?.masksToBounds = true

    if let image {
      let imageView = NSImageView()
      imageView.image = image
      imageView.imageScaling = .scaleProportionallyUpOrDown
      imageView.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(imageView)
      NSLayoutConstraint.activate([
        imageView.topAnchor.constraint(equalTo: container.topAnchor),
        imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      ])
    } else {
      let placeholder = makeAttachmentSymbol("photo")
      container.addSubview(placeholder)
      placeholder.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        placeholder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        placeholder.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      ])
    }

    NSLayoutConstraint.activate([
      container.widthAnchor.constraint(equalToConstant: size.width),
      container.heightAnchor.constraint(equalToConstant: size.height),
    ])
    return container
  }

  fileprivate func clickableContainer(_ view: NSView) -> NativeAttachmentPreviewButton {
    let container = NativeAttachmentPreviewButton()
    container.addSubview(view)
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      view.topAnchor.constraint(equalTo: container.topAnchor),
      view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    return container
  }

  fileprivate func makeAttachmentSymbol(_ systemSymbolName: String) -> NSImageView {
    let imageView = NSImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil)
    imageView.image?.isTemplate = true
    imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
    imageView.contentTintColor = .secondaryLabelColor
    imageView.setAccessibilityElement(false)
    NSLayoutConstraint.activate([
      imageView.widthAnchor.constraint(equalToConstant: 16),
      imageView.heightAnchor.constraint(equalToConstant: 16),
    ])
    return imageView
  }
}
