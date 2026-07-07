import AppKit
import SumikaCore
import SwiftUI

struct AppKitChatTranscriptRepresentable: NSViewRepresentable {
  typealias Coordinator = NativeChatTranscriptCoordinator

  let items: [RenderedChatTurnItem]
  let showsGenerationIndicator: Bool
  let accessibilityValue: String
  let isSpeechEnabled: Bool
  let activeSpeechRowID: String?
  let onToggleSpeech: (String, String) -> Void
  let onApproveToolCall: (ToolCallRecord.ID) -> Void
  let onDenyToolCall: (ToolCallRecord.ID) -> Void
  let onAnswerAskUser: (ToolCallRecord.ID, String) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onToggleSpeech: onToggleSpeech,
      onApproveToolCall: onApproveToolCall,
      onDenyToolCall: onDenyToolCall,
      onAnswerAskUser: onAnswerAskUser
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
        onAnswerAskUser: onAnswerAskUser
      )
      context.coordinator.update(
        rows: rows,
        accessibilityValue: accessibilityValue,
        isSpeechEnabled: isSpeechEnabled,
        activeSpeechRowID: activeSpeechRowID,
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
  private var onDenyToolCall: (ToolCallRecord.ID) -> Void
  private var onAnswerAskUser: (ToolCallRecord.ID, String) -> Void
  private weak var tableView: NSTableView?
  private var dataSource: NSTableViewDiffableDataSource<NativeTranscriptSection, String>?
  private var rowsByID: [String: NativeTranscriptRow] = [:]
  private var rowIDs: [String] = []
  private var revisionsByID: [String: Int] = [:]
  private var isSpeechEnabled = false
  private var activeSpeechRowID: String?
  private var cellStateStore = NativeTranscriptCoordinatorState()
  private var heightCache = NativeTranscriptHeightCache()
  private var markdownCache = NativeTranscriptMarkdownCache()
  private let codeHighlightStore = NativeTranscriptCodeHighlightStore()
  private let attachmentThumbnailStore = NativeTranscriptAttachmentThumbnailStore()
  private var attachmentPreviewPopover: NSPopover?
  private var pinnedToBottom = true
  private var pendingHeightInvalidationRows = IndexSet()
  private var pendingHeightInvalidationReasons = Set<String>()
  private var pendingHeightInvalidationWorkItem: DispatchWorkItem?
  private var shouldScrollAfterHeightInvalidation = false

  init(
    onToggleSpeech: @escaping (String, String) -> Void,
    onApproveToolCall: @escaping (ToolCallRecord.ID) -> Void,
    onDenyToolCall: @escaping (ToolCallRecord.ID) -> Void,
    onAnswerAskUser: @escaping (ToolCallRecord.ID, String) -> Void
  ) {
    self.onToggleSpeech = onToggleSpeech
    self.onApproveToolCall = onApproveToolCall
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
    scrollView.documentView = tableView
    scrollView.postsBoundsChangedNotifications = true
    scrollView.setAccessibilityIdentifier("chat.transcript")

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(clipViewBoundsDidChange(_:)),
      name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView
    )

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
    onAnswerAskUser: @escaping (ToolCallRecord.ID, String) -> Void
  ) {
    self.onToggleSpeech = onToggleSpeech
    self.onApproveToolCall = onApproveToolCall
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
      pruneCoordinatorState(activeRows: rows)
      ChatDiagnostics.measure("Transcript accessibility update", category: .transcript) {
        scrollView.setAccessibilityValue(accessibilityValue)
      }
      let didChangeColumnWidth = updateColumnWidth(in: scrollView)

      switch plan.action {
      case .snapshot:
        applySnapshot(
          previousIDs: previousRowIDs,
          previousRowsByID: previousRowsByID,
          rowIDs: newRowIDs,
          currentRowsByID: newRowsByID,
          changedIDs: plan.changedIDs,
          animatingDifferences: false
        )
        scheduleHeightInvalidation(
          for: NativeTranscriptSnapshotInvalidation.rowIndexes(
            previousIDs: previousRowIDs,
            currentIDs: newRowIDs,
            changedIDs: plan.changedIDs
          ),
          reason: "snapshot",
          scrollToBottomAfterFlush: wasPinnedToBottom || shouldScrollAfterAppend
        )
      case .reconfigureRows:
        let reconfiguredIDs = plan.changedIDs.union(speechStateChangedIDs)
        let streamingMessageChangedIDs = streamingAssistantMessageRowIDs(in: plan.changedIDs)
        let streamingThinkingChangedIDs = streamingAssistantThinkingRowIDs(in: plan.changedIDs)
        let streamingChangedIDs = streamingMessageChangedIDs.union(streamingThinkingChangedIDs)
        let shouldDeferPinnedScroll =
          wasPinnedToBottom
          && !streamingChangedIDs.isEmpty
          && streamingChangedIDs == plan.changedIDs
          && speechStateChangedIDs.isEmpty
          && !didChangeColumnWidth

        reconfigureVisibleRows(changedIDs: reconfiguredIDs)
        var invalidationRows = rowIndexes(for: reconfiguredIDs)
        if didChangeColumnWidth {
          invalidationRows.formUnion(IndexSet(integersIn: 0..<newRowIDs.count))
        }
        scheduleHeightInvalidation(
          for: invalidationRows,
          reason: heightInvalidationReason(
            didChangeColumnWidth: didChangeColumnWidth,
            streamingMessageChangedIDs: streamingMessageChangedIDs,
            streamingThinkingChangedIDs: streamingThinkingChangedIDs,
            speechStateChangedIDs: speechStateChangedIDs,
            changedIDs: plan.changedIDs
          ),
          // Re-anchor the pinned viewport on every flush that changed rows —
          // including streaming thinking growth. Skipping the scroll only for
          // thinking rows made the anchor alternate between "stay" and "jump
          // to bottom" across flushes, which reads as the reasoning block
          // hopping up and down.
          scrollToBottomAfterFlush: wasPinnedToBottom
            && (!plan.changedIDs.isEmpty || didChangeColumnWidth)
        )
        let hasRowChanges = !plan.changedIDs.isEmpty
        if shouldScrollAfterAppend
          || (wasPinnedToBottom && hasRowChanges && !shouldDeferPinnedScroll)
        {
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
}

extension NativeChatTranscriptCoordinator: NSTableViewDelegate {

  func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
    ChatDiagnostics.measure("Transcript row height", category: .transcript) {
      guard row >= 0, row < rowIDs.count, let rowModel = rowsByID[rowIDs[row]] else {
        return 44
      }
      let width = max(tableView?.bounds.width ?? 680, 320)
      return heightCache.height(
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
    }
  }

  func tableView(_: NSTableView, shouldSelectRow _: Int) -> Bool {
    false
  }

  @objc private func clipViewBoundsDidChange(_ notification: Notification) {
    guard
      let clipView = notification.object as? NSClipView,
      let scrollView = clipView.enclosingScrollView
    else {
      return
    }
    pinnedToBottom = isPinnedToBottom(scrollView)
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
          activeSpeechRowID: activeSpeechRowID
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
      tableView.layoutSubtreeIfNeeded()
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

  private func isPinnedToBottom(_ scrollView: NSScrollView) -> Bool {
    guard let documentView = scrollView.documentView else {
      return true
    }
    let visibleMaxY = scrollView.contentView.bounds.maxY
    let documentHeight = documentView.bounds.height
    return documentHeight - visibleMaxY < 48
  }

  private func scrollToBottom(_ scrollView: NSScrollView) {
    DispatchQueue.main.async {
      self.scrollToBottomImmediately(scrollView)
    }
  }

  private func scrollToBottomImmediately(_ scrollView: NSScrollView) {
    guard let documentView = scrollView.documentView else {
      return
    }
    let targetY = max(documentView.bounds.height - scrollView.contentView.bounds.height, 0)
    guard abs(scrollView.contentView.bounds.origin.y - targetY) >= 0.5 else {
      pinnedToBottom = true
      return
    }
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    pinnedToBottom = true
  }

  private func pruneCoordinatorState(activeRows: [NativeTranscriptRow]) {
    let activeRowIDs = Set(activeRows.map(\.id))
    cellStateStore.prune(activeRowIDs: activeRowIDs)
    heightCache.prune(activeRows: activeRows)
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

enum NativeTranscriptCellKind: Equatable {
  case userMessage
  case assistantThinking
  case assistantMessage
  case tool
  case generationIndicator

  var telemetryName: String {
    switch self {
    case .userMessage:
      "user"
    case .assistantThinking:
      "assistantThinking"
    case .assistantMessage:
      "assistant"
    case .tool:
      "tool"
    case .generationIndicator:
      "generationIndicator"
    }
  }
}

struct NativeTranscriptRow: Equatable, Identifiable {
  let id: String
  let revision: Int
  let body: Body

  enum Body: Equatable {
    case item(RenderedChatTurnItem)
    case generationIndicator(revision: Int)
  }

  static func rows(
    for items: [RenderedChatTurnItem],
    showsGenerationIndicator: Bool
  ) -> [NativeTranscriptRow] {
    var rows = items.map { item in
      NativeTranscriptRow(id: item.id, revision: item.renderRevision, body: .item(item))
    }
    if showsGenerationIndicator {
      rows.append(
        NativeTranscriptRow(
          id: "chat.transcript.generationIndicator",
          revision: items.count,
          body: .generationIndicator(revision: items.count)
        ))
    }
    return rows
  }

  var isUserMessage: Bool {
    guard case .item(let item) = body else {
      return false
    }
    guard case .userMessage = item.item else {
      return false
    }
    return true
  }

  var isStreamingAssistantMessage: Bool {
    guard case .item(let item) = body else {
      return false
    }
    return item.isStreamingAssistantMessage
  }

  var isStreamingAssistantThinkingMessage: Bool {
    guard case .item(let item) = body else {
      return false
    }
    return item.isStreamingAssistantThinkingMessage
  }

  var cellKind: NativeTranscriptCellKind {
    switch body {
    case .generationIndicator:
      .generationIndicator
    case .item(let item):
      switch item.item {
      case .userMessage:
        .userMessage
      case .assistantThinking:
        .assistantThinking
      case .assistantMessage:
        .assistantMessage
      case .tool:
        .tool
      }
    }
  }

  var telemetryContentLengthBucket: String {
    switch body {
    case .generationIndicator:
      "0"
    case .item(let item):
      item.content.count.telemetryLengthBucket
    }
  }

  var isGenerationIndicator: Bool {
    if case .generationIndicator = body {
      return true
    }
    return false
  }

  var isTransientAssistantPlaceholder: Bool {
    guard case .item(let item) = body else {
      return false
    }
    return item.shouldShowAssistantPlaceholder
  }
}

extension Int {
  fileprivate var telemetryLengthBucket: String {
    switch self {
    case 0:
      "0"
    case 1...80:
      "1-80"
    case 81...240:
      "81-240"
    case 241...800:
      "241-800"
    case 801...2_000:
      "801-2000"
    case 2_001...8_000:
      "2001-8000"
    default:
      "8001+"
    }
  }
}

extension IndexSet {
  fileprivate var telemetryRangeSummary: String {
    guard let first, let last else {
      return "none"
    }
    return count == 1 ? "\(first)" : "\(first)..<\(last + 1)"
  }
}

extension Array where Element == String {
  fileprivate var telemetryIDListSummary: String {
    guard !isEmpty else {
      return "none"
    }
    let limit = 6
    let visibleIDs = prefix(limit).joined(separator: ",")
    let suffix = count > limit ? ",+\(count - limit)" : ""
    return "[\(visibleIDs)\(suffix)]"
  }
}

struct NativeTranscriptDiffPlan: Equatable {
  enum Action: Equatable {
    case snapshot
    case reconfigureRows
  }

  let action: Action
  let changedIDs: Set<String>

  static func make(
    previousIDs: [String],
    previousRevisions: [String: Int],
    currentIDs: [String],
    currentRevisions: [String: Int]
  ) -> NativeTranscriptDiffPlan {
    let changedIDs = Set(
      currentIDs.filter { id in
        previousRevisions[id] != currentRevisions[id]
      }
    )
    guard previousIDs == currentIDs else {
      return NativeTranscriptDiffPlan(action: .snapshot, changedIDs: changedIDs)
    }
    return NativeTranscriptDiffPlan(action: .reconfigureRows, changedIDs: changedIDs)
  }
}

enum NativeTranscriptScrollDecision {
  static func shouldScrollToBottomAfterAppend(
    previousIDs: [String],
    currentRows: [NativeTranscriptRow]
  ) -> Bool {
    guard currentRows.count > previousIDs.count, let lastRow = currentRows.last else {
      return false
    }
    return lastRow.isUserMessage
  }
}

enum NativeTranscriptSnapshotInvalidation {
  static func rowIndexes(
    previousIDs: [String],
    currentIDs: [String],
    changedIDs: Set<String>
  ) -> IndexSet {
    let previousIDSet = Set(previousIDs)
    let insertedIDs = currentIDs.filter { !previousIDSet.contains($0) }
    let invalidatedIDs = changedIDs.union(insertedIDs)
    var indexes = IndexSet()
    for (index, id) in currentIDs.enumerated() where invalidatedIDs.contains(id) {
      indexes.insert(index)
    }
    return indexes
  }
}

struct NativeToolDetailContent: Equatable {
  var argumentLines: [String]
  var permissionLines: [String]
  var outputTitle: String?
  var outputText: String?
  var affectedPaths: [String]
  var flags: [String]

  init(record: ToolCallRecord) {
    argumentLines = record.transcriptToolCall.arguments.map { argument in
      "\(argument.name): \(argument.value)"
    }

    permissionLines = Self.permissionLines(for: record)

    if let payload = record.resultPayload {
      let display = ToolResultProjector.project(payload: payload, request: record.request).display
      outputTitle = display.nativeOutputTitle
      outputText = display.nativeOutputText
      affectedPaths = display.nativeAffectedPaths
      flags = display.nativeFlags
    } else if let preview = record.approvalPreview {
      outputTitle = "Preview"
      outputText = preview.text.isEmpty ? nil : preview.text
      affectedPaths = preview.affectedPaths
      flags = preview.nativeFlags
    } else {
      outputTitle = nil
      outputText = nil
      affectedPaths = []
      flags = []
    }
  }

  var isEmpty: Bool {
    argumentLines.isEmpty
      && permissionLines.isEmpty
      && outputText == nil
      && affectedPaths.isEmpty
      && flags.isEmpty
  }

  private static func permissionLines(for record: ToolCallRecord) -> [String] {
    switch record.status {
    case .awaitingApproval:
      [
        "Risk: \(record.evaluation.riskLevel.rawValue)",
        "Reason: \(record.evaluation.reason)",
      ]
    case .denied where !record.evaluation.reason.isEmpty:
      ["Denied: \(record.evaluation.reason)"]
    default:
      []
    }
  }
}

struct NativeTranscriptHeightCache {
  private var heightsByKey: [Key: CGFloat] = [:]
  private var lastKnownKeyByRowID: [String: Key] = [:]
  private var measuringCell: NativeChatMessageCellView?

  var cachedEntryCount: Int {
    heightsByKey.count
  }

  var measuringCellForTesting: NativeChatMessageCellView? {
    measuringCell
  }

  mutating func height(
    for row: NativeTranscriptRow,
    width: CGFloat,
    state: NativeTranscriptCellState = NativeTranscriptCellState(),
    markdownBlocks: @escaping @MainActor (String) -> [NativeMarkdownBlock] =
      NativeTranscriptMarkdownRenderer.blocks
  ) -> CGFloat {
    let normalizedWidth = Int(width.rounded(.down))
    let key = Key(
      rowID: row.id,
      revision: row.revision,
      width: normalizedWidth,
      isSpeechEnabled: state.isSpeechEnabled,
      isToolExpanded: state.isToolExpanded,
      isThinkingExpanded: state.isThinkingExpanded
    )
    if let height = heightsByKey[key] {
      lastKnownKeyByRowID[row.id] = key
      return height
    }
    let missReason = cacheMissReason(for: key)
    let cell = reusableMeasuringCell()
    let height = ChatDiagnostics.measure(
      "Transcript row height cache miss",
      category: .transcript,
      metadata: ChatDiagnostics.Metadata(
        "rowKind=\(row.cellKind.telemetryName) contentLengthBucket=\(row.telemetryContentLengthBucket) reason=\(missReason) width=\(normalizedWidth) cacheEntries=\(heightsByKey.count)"
      )
    ) {
      NativeTranscriptRowMeasurer.height(
        for: row,
        width: width,
        state: state,
        markdownBlocks: markdownBlocks,
        reusing: cell
      )
    }
    heightsByKey[key] = height
    lastKnownKeyByRowID[row.id] = key
    return height
  }

  // Reusing one measuring cell keeps its incremental streaming append path
  // alive across measurements: repeated misses for the growing streaming row
  // only append the new suffix instead of rebuilding the full cell content.
  private mutating func reusableMeasuringCell() -> NativeChatMessageCellView {
    if let measuringCell {
      return measuringCell
    }
    let cell = NativeChatMessageCellView(
      identifier: NSUserInterfaceItemIdentifier("NativeChatMessageCellView.Measuring")
    )
    measuringCell = cell
    return cell
  }

  private func cacheMissReason(for key: Key) -> String {
    let rowKeys = heightsByKey.keys.filter { $0.rowID == key.rowID }
    guard !rowKeys.isEmpty else {
      guard let lastKnownKey = lastKnownKeyByRowID[key.rowID] else {
        return "noRowEntry"
      }
      return missReason(comparedWith: lastKnownKey, current: key)
    }
    guard rowKeys.contains(where: { $0.revision == key.revision }) else {
      return "revisionChanged"
    }
    guard rowKeys.contains(where: { $0.revision == key.revision && $0.width == key.width }) else {
      return "widthChanged"
    }
    guard
      rowKeys.contains(where: {
        $0.revision == key.revision && $0.width == key.width
          && $0.isSpeechEnabled == key.isSpeechEnabled
      })
    else {
      return "speechStateChanged"
    }
    guard
      rowKeys.contains(where: {
        $0.revision == key.revision && $0.width == key.width
          && $0.isSpeechEnabled == key.isSpeechEnabled
          && $0.isToolExpanded == key.isToolExpanded
      })
    else {
      return "toolExpansionChanged"
    }
    guard
      rowKeys.contains(where: {
        $0.revision == key.revision && $0.width == key.width
          && $0.isSpeechEnabled == key.isSpeechEnabled
          && $0.isToolExpanded == key.isToolExpanded
          && $0.isThinkingExpanded == key.isThinkingExpanded
      })
    else {
      return "thinkingExpansionChanged"
    }
    return "unknown"
  }

  mutating func invalidate(rowID: String) {
    heightsByKey = heightsByKey.filter { $0.key.rowID != rowID }
    lastKnownKeyByRowID[rowID] = nil
  }

  mutating func prune(activeRows: [NativeTranscriptRow]) {
    let activeRowIDs = Set(activeRows.map(\.id))
    let activeRevisions = Set(
      activeRows.map { ActiveRevision(rowID: $0.id, revision: $0.revision) }
    )
    heightsByKey = heightsByKey.filter {
      activeRevisions.contains(
        ActiveRevision(rowID: $0.key.rowID, revision: $0.key.revision)
      )
    }
    lastKnownKeyByRowID = lastKnownKeyByRowID.filter { activeRowIDs.contains($0.key) }
  }

  private func missReason(comparedWith lastKnownKey: Key, current key: Key) -> String {
    if lastKnownKey.revision != key.revision {
      return "revisionChanged"
    }
    if lastKnownKey.width != key.width {
      return "widthChanged"
    }
    if lastKnownKey.isSpeechEnabled != key.isSpeechEnabled {
      return "speechStateChanged"
    }
    if lastKnownKey.isToolExpanded != key.isToolExpanded {
      return "toolExpansionChanged"
    }
    if lastKnownKey.isThinkingExpanded != key.isThinkingExpanded {
      return "thinkingExpansionChanged"
    }
    return "unknown"
  }

  struct Key: Hashable {
    let rowID: String
    let revision: Int
    let width: Int
    let isSpeechEnabled: Bool
    let isToolExpanded: Bool
    let isThinkingExpanded: Bool

    static func == (lhs: Key, rhs: Key) -> Bool {
      lhs.rowID == rhs.rowID
        && lhs.revision == rhs.revision
        && lhs.width == rhs.width
        && lhs.isSpeechEnabled == rhs.isSpeechEnabled
        && lhs.isToolExpanded == rhs.isToolExpanded
        && lhs.isThinkingExpanded == rhs.isThinkingExpanded
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(rowID)
      hasher.combine(revision)
      hasher.combine(width)
      hasher.combine(isSpeechEnabled)
      hasher.combine(isToolExpanded)
      hasher.combine(isThinkingExpanded)
    }
  }

  private struct ActiveRevision: Hashable {
    let rowID: String
    let revision: Int

    static func == (lhs: ActiveRevision, rhs: ActiveRevision) -> Bool {
      lhs.rowID == rhs.rowID && lhs.revision == rhs.revision
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(rowID)
      hasher.combine(revision)
    }
  }
}

enum NativeTranscriptRowMeasurer {
  static func height(
    for row: NativeTranscriptRow,
    width: CGFloat,
    state: NativeTranscriptCellState = NativeTranscriptCellState(),
    markdownBlocks: @escaping @MainActor (String) -> [NativeMarkdownBlock] =
      NativeTranscriptMarkdownRenderer.blocks,
    reusing reusableCell: NativeChatMessageCellView? = nil
  ) -> CGFloat {
    ChatDiagnostics.measure("Transcript row measure", category: .transcript) {
      NativeChatMessageCellView.measuredHeight(
        for: row,
        width: width,
        state: state,
        actions: measuringActions(markdownBlocks: markdownBlocks),
        reusing: reusableCell
      )
    }
  }

  private static func measuringActions(
    markdownBlocks: @escaping @MainActor (String) -> [NativeMarkdownBlock]
  ) -> NativeTranscriptCellActions {
    NativeTranscriptCellActions(
      markdownBlocks: markdownBlocks,
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
}

struct NativeTranscriptCellState: Equatable {
  var isCopied: Bool
  var isSpeechEnabled: Bool
  var isSpeaking: Bool
  var isToolExpanded: Bool
  var isThinkingExpanded: Bool
  var askUserSelection: String?

  init(
    isCopied: Bool = false,
    isSpeechEnabled: Bool = false,
    isSpeaking: Bool = false,
    isToolExpanded: Bool = false,
    isThinkingExpanded: Bool = false,
    askUserSelection: String? = nil
  ) {
    self.isCopied = isCopied
    self.isSpeechEnabled = isSpeechEnabled
    self.isSpeaking = isSpeaking
    self.isToolExpanded = isToolExpanded
    self.isThinkingExpanded = isThinkingExpanded
    self.askUserSelection = askUserSelection
  }
}

struct NativeTranscriptCoordinatorState: Equatable {
  private var copiedRowIDs: Set<String> = []
  private var expandedToolRowIDs: Set<String> = []
  private var expandedThinkingRowIDs: Set<String> = []
  private var askUserSelections: [String: String] = [:]

  func state(
    for rowID: String,
    isSpeechEnabled: Bool = false,
    activeSpeechRowID: String? = nil
  ) -> NativeTranscriptCellState {
    NativeTranscriptCellState(
      isCopied: copiedRowIDs.contains(rowID),
      isSpeechEnabled: isSpeechEnabled,
      isSpeaking: activeSpeechRowID == rowID,
      isToolExpanded: expandedToolRowIDs.contains(rowID),
      isThinkingExpanded: expandedThinkingRowIDs.contains(rowID),
      askUserSelection: askUserSelections[rowID]
    )
  }

  mutating func setCopied(_ isCopied: Bool, rowID: String) {
    if isCopied {
      copiedRowIDs.insert(rowID)
    } else {
      copiedRowIDs.remove(rowID)
    }
  }

  mutating func toggleToolExpansion(rowID: String) {
    if expandedToolRowIDs.contains(rowID) {
      expandedToolRowIDs.remove(rowID)
    } else {
      expandedToolRowIDs.insert(rowID)
    }
  }

  mutating func toggleThinkingExpansion(rowID: String) {
    if expandedThinkingRowIDs.contains(rowID) {
      expandedThinkingRowIDs.remove(rowID)
    } else {
      expandedThinkingRowIDs.insert(rowID)
    }
  }

  mutating func updateAskUserSelection(_ answer: String, rowID: String) {
    askUserSelections[rowID] = answer
  }

  mutating func prune(activeRowIDs: Set<String>) {
    copiedRowIDs = copiedRowIDs.intersection(activeRowIDs)
    expandedToolRowIDs = expandedToolRowIDs.intersection(activeRowIDs)
    expandedThinkingRowIDs = expandedThinkingRowIDs.intersection(activeRowIDs)
    askUserSelections = askUserSelections.filter { activeRowIDs.contains($0.key) }
  }
}

struct NativeTranscriptCellActions {
  var markdownBlocks: @MainActor (String) -> [NativeMarkdownBlock]
  var highlightedCode: @MainActor (String, AssistantRenderBlock.CodeBlock) -> HighlightedCode?
  var requestCodeHighlight: @MainActor (String, AssistantRenderBlock.CodeBlock) -> Void
  var attachmentThumbnail: @MainActor (ChatAttachment, Int) -> NSImage?
  var requestAttachmentThumbnail: @MainActor (String, ChatAttachment, Int) -> Void
  var showImageAttachment: @MainActor (ChatAttachment, NSView) -> Void
  var copy: @MainActor (String, String) -> Void
  var toggleSpeech: @MainActor (String, String) -> Void
  var approve: @MainActor (ToolCallRecord.ID) -> Void
  var deny: @MainActor (ToolCallRecord.ID) -> Void
  var answerAskUser: @MainActor (String, ToolCallRecord.ID, String) -> Void
  var toggleToolExpansion: @MainActor (String) -> Void
  var toggleThinkingExpansion: @MainActor (String) -> Void
  var updateAskUserSelection: @MainActor (String, String) -> Void
}

final class NativeChatMessageCellView: NSTableCellView {
  private let contentHost = NSView()
  private var hostedContentView: NSView?
  private var configuredRowID: String?
  private var configuredKind: NativeTranscriptCellKind?
  private var alignmentConstraints: [NSLayoutConstraint] = []
  fileprivate var actions: NativeTranscriptCellActions?
  private var askUserPopUpButton: NSPopUpButton?

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

  override func prepareForReuse() {
    super.prepareForReuse()
    actions = nil
    askUserPopUpButton = nil
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

  private func updateAccessibility(for row: NativeTranscriptRow) {
    ChatDiagnostics.measure("Transcript cell accessibility", category: .transcript) {
      setAccessibilityElement(true)
      setAccessibilityIdentifier(row.accessibilityIdentifier)
      setAccessibilityLabel(row.accessibilityLabel)
    }
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
    rowID: String,
    state: NativeTranscriptCellState
  ) -> NSView {
    let stack = verticalStack(spacing: 7)
    let toolCall = record.transcriptToolCall

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
    if record.hasNativeToolDetails {
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

    if state.isToolExpanded {
      stack.addArrangedSubview(makeToolDetails(record: record))
    }

    if record.status == .awaitingApproval {
      let actionsRow = horizontalStack(spacing: 8)
      actionsRow.addArrangedSubview(
        makeSmallButton(title: "Approve") { [weak self] in
          self?.actions?.approve(record.id)
        }
      )
      actionsRow.addArrangedSubview(
        makeSmallButton(title: "Deny") { [weak self] in
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
          rowID: rowID,
          toolCallID: record.id
        )
      )
    }

    if let generationMetrics {
      stack.addArrangedSubview(makeSecondaryLabel(generationMetrics.nativeTokenRateSummary))
    }

    return stack
  }

  private func makeToolDetails(record: ToolCallRecord) -> NSView {
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

    return stack
  }

  private func makeAskUserView(
    input: AskUserInput,
    selectedAnswer: String?,
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
    askUserPopUpButton = popup
    row.addArrangedSubview(popup)
    row.addArrangedSubview(
      makeSmallButton(title: "Send") { [weak self] in
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

// A fixed-height window onto the tail of the live reasoning text: the text
// view is pinned to the bottom and grows upward past the clipped top edge, so
// new lines push old ones out of view like a feed. The fixed intrinsic height
// keeps the transcript row from ever resizing while the model thinks.
final class NativeReasoningTickerView: NSView {
  private static let visibleLineCount: CGFloat = 3

  private let textView = NativeStreamingTextView()
  private let fadeMask = CAGradientLayer()
  private let fixedHeight: CGFloat

  init(font: NSFont) {
    let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
    fixedHeight = ceil(lineHeight * Self.visibleLineCount)
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true

    // Fades the oldest visible line out toward the top edge; the mask also
    // clips the text that has scrolled past the window. Layer origin is
    // bottom-left, so the fade-to-clear sits at the visual top.
    fadeMask.colors = [
      NSColor.black.cgColor,
      NSColor.black.cgColor,
      NSColor.clear.cgColor,
    ]
    fadeMask.locations = [0, NSNumber(value: 1 - (1 / Self.visibleLineCount)), 1]
    layer?.mask = fadeMask

    textView.isSelectable = false
    addSubview(textView)
    NSLayoutConstraint.activate([
      textView.leadingAnchor.constraint(equalTo: leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: trailingAnchor),
      textView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: fixedHeight)
  }

  // The ticker is an ambient preview, not an interaction target: clicks fall
  // through to the row so they cannot grab focus or start a text selection.
  override func hitTest(_: NSPoint) -> NSView? {
    nil
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fadeMask.frame = bounds
    CATransaction.commit()
  }

  func setAttributedText(_ attributedString: NSAttributedString) {
    textView.setAttributedText(attributedString)
  }

  func appendAttributedText(_ attributedString: NSAttributedString) {
    textView.appendAttributedText(attributedString)
  }

  var textForTesting: String {
    textView.string
  }
}

final class NativeAssistantThinkingView: NSView {
  private let stack = NSStackView()
  private let header = NSStackView()
  private let statusHost = NSView()
  private let titleLabel = NSTextField(wrappingLabelWithString: "Reasoning")
  private let disclosureButton = NativeActionButton(title: "")
  private let toggleThinkingExpansion: (String) -> Void
  private var statusView: NSView?
  private var tickerView: NativeReasoningTickerView?
  private var contentTextView: NativeStreamingTextView?
  private var currentRowID: String
  private var currentContent = ""
  private var currentTickerContent = ""
  private var currentStatus: AssistantThinkingMessage.DeliveryStatus?

  init(
    message: AssistantThinkingMessage,
    rowID: String,
    state: NativeTranscriptCellState,
    toggleThinkingExpansion: @escaping (String) -> Void
  ) {
    self.currentRowID = rowID
    self.toggleThinkingExpansion = toggleThinkingExpansion
    super.init(frame: .zero)
    setupLayout()
    update(message: message, rowID: rowID, state: state)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(
    message: AssistantThinkingMessage,
    rowID: String,
    state: NativeTranscriptCellState
  ) {
    currentRowID = rowID
    let isExpanded = state.isThinkingExpanded
    updateStatus(message.deliveryStatus)
    titleLabel.stringValue = Self.reasoningTitle(for: message)
    updateDisclosureButton(isExpanded: isExpanded)
    updateTicker(for: message, isExpanded: isExpanded)
    updateContent(message.content, isExpanded: isExpanded)
  }

  private func setupLayout() {
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.distribution = .gravityAreas
    stack.spacing = 5
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    header.orientation = .horizontal
    header.alignment = .centerY
    header.distribution = .fill
    header.spacing = 7
    stack.addArrangedSubview(header)

    statusHost.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      statusHost.widthAnchor.constraint(equalToConstant: 13),
      statusHost.heightAnchor.constraint(equalToConstant: 13),
    ])
    header.addArrangedSubview(statusHost)

    titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    titleLabel.textColor = .tertiaryLabelColor
    titleLabel.maximumNumberOfLines = 1
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    header.addArrangedSubview(titleLabel)

    disclosureButton.translatesAutoresizingMaskIntoConstraints = false
    disclosureButton.bezelStyle = .inline
    disclosureButton.isBordered = false
    disclosureButton.controlSize = .small
    disclosureButton.setButtonType(.momentaryPushIn)
    disclosureButton.imagePosition = .imageOnly
    disclosureButton.contentTintColor = .tertiaryLabelColor
    disclosureButton.actionHandler = { [weak self] in
      guard let self else {
        return
      }
      toggleThinkingExpansion(currentRowID)
    }
    NSLayoutConstraint.activate([
      disclosureButton.widthAnchor.constraint(equalToConstant: 18),
      disclosureButton.heightAnchor.constraint(equalToConstant: 18),
    ])
    header.addArrangedSubview(disclosureButton)
  }

  private func updateStatus(_ status: AssistantThinkingMessage.DeliveryStatus) {
    guard currentStatus != status else {
      return
    }
    currentStatus = status
    statusView?.removeFromSuperview()

    let view = nativeThinkingStatusIndicator(status: status)
    statusView = view
    statusHost.addSubview(view)
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      view.centerXAnchor.constraint(equalTo: statusHost.centerXAnchor),
      view.centerYAnchor.constraint(equalTo: statusHost.centerYAnchor),
    ])
  }

  private func updateDisclosureButton(isExpanded: Bool) {
    let accessibilityLabel = isExpanded ? "Hide reasoning" : "Show reasoning"
    disclosureButton.image = NSImage(
      systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
      accessibilityDescription: nil
    )
    disclosureButton.image?.isTemplate = true
    disclosureButton.contentTintColor = .tertiaryLabelColor
    disclosureButton.toolTip = accessibilityLabel
    disclosureButton.setAccessibilityLabel(accessibilityLabel)
  }

  // While streaming collapsed, the row shows a fixed three-line window onto
  // the live reasoning tail instead of the growing full text: the row height
  // stays constant, so the transcript neither grows nor scrolls while the
  // model thinks.
  private func updateTicker(for message: AssistantThinkingMessage, isExpanded: Bool) {
    guard message.deliveryStatus == .streaming, !isExpanded, !message.content.isEmpty else {
      removeTickerView()
      return
    }

    let window = Self.tickerWindow(for: message.content)
    let ticker = ensureTickerView()
    if window.hasPrefix(currentTickerContent) {
      let suffix = String(window.dropFirst(currentTickerContent.count))
      if !suffix.isEmpty {
        ticker.appendAttributedText(
          Self.thinkingAttributedString(for: suffix, usesPlaceholderForEmpty: false)
        )
      }
    } else {
      ticker.setAttributedText(Self.thinkingAttributedString(for: window))
    }
    currentTickerContent = window
  }

  private func ensureTickerView() -> NativeReasoningTickerView {
    if let tickerView {
      return tickerView
    }
    let ticker = NativeReasoningTickerView(font: .systemFont(ofSize: NSFont.systemFontSize))
    tickerView = ticker
    stack.insertArrangedSubview(ticker, at: 1)
    ticker.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    return ticker
  }

  private func removeTickerView() {
    currentTickerContent = ""
    guard let tickerView else {
      return
    }
    stack.removeArrangedSubview(tickerView)
    tickerView.removeFromSuperview()
    self.tickerView = nil
  }

  // Only the trailing lines are visible, so the ticker feeds a bounded tail
  // window instead of the whole reasoning text. The window is cut at a
  // paragraph boundary: reflowing a partially cut first paragraph would shift
  // the wrapping of the visible lines between flushes.
  static func tickerWindow(for content: String) -> String {
    let window = content.suffix(2400)
    guard window.count == 2400, let newlineIndex = window.firstIndex(of: "\n") else {
      return String(window)
    }
    return String(window[window.index(after: newlineIndex)...])
  }

  static func reasoningTitle(for message: AssistantThinkingMessage) -> String {
    guard message.deliveryStatus == .complete, let duration = message.reasoningDuration else {
      return "Reasoning"
    }
    return "Reasoned for \(formattedReasoningDuration(duration))"
  }

  private static func formattedReasoningDuration(_ duration: TimeInterval) -> String {
    let totalSeconds = max(1, Int(duration.rounded()))
    guard totalSeconds >= 60 else {
      return "\(totalSeconds)s"
    }
    return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
  }

  private func updateContent(_ content: String, isExpanded: Bool) {
    guard isExpanded, !content.isEmpty else {
      removeContentTextView()
      return
    }

    let textView = ensureContentTextView()
    if content.hasPrefix(currentContent) {
      let suffix = String(content.dropFirst(currentContent.count))
      if !suffix.isEmpty {
        textView.appendAttributedText(
          Self.thinkingAttributedString(for: suffix, usesPlaceholderForEmpty: false)
        )
      }
    } else {
      textView.setAttributedText(Self.thinkingAttributedString(for: content))
    }

    currentContent = content
    invalidateIntrinsicContentSize()
    needsLayout = true
  }

  private func ensureContentTextView() -> NativeStreamingTextView {
    if let contentTextView {
      return contentTextView
    }

    let textView = NativeStreamingTextView()
    contentTextView = textView
    stack.addArrangedSubview(textView)
    textView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    return textView
  }

  private func removeContentTextView() {
    guard let contentTextView else {
      currentContent = ""
      return
    }
    stack.removeArrangedSubview(contentTextView)
    contentTextView.removeFromSuperview()
    self.contentTextView = nil
    currentContent = ""
    invalidateIntrinsicContentSize()
  }

  private static func thinkingAttributedString(
    for text: String,
    usesPlaceholderForEmpty: Bool = true
  ) -> NSAttributedString {
    let source = text.isEmpty && usesPlaceholderForEmpty ? " " : text
    let attributedString = NSMutableAttributedString(
      string: source,
      attributes: [
        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        .foregroundColor: NSColor.secondaryLabelColor,
      ]
    )
    NativeTranscriptMarkdownRenderer.applyLinks(to: attributedString, sourceText: source)
    return attributedString
  }

}

final class NativeAssistantMessageView: NSView {
  typealias PlaceholderBuilder = (String) -> NSView
  typealias ContentBuilder = (RenderedChatTurnItem, String, NativeTranscriptCellState) -> NSView?
  typealias StreamingBlocksBuilder = (String) -> NativeStreamingAssistantBlocksView

  private let stack = NSStackView()
  private let makePlaceholderView: PlaceholderBuilder
  private let makeFinalContentView: ContentBuilder
  private let makeFooterView: ContentBuilder
  private let makeStreamingBlocksView: StreamingBlocksBuilder
  private var contentView: NSView?
  private var footerView: NSView?
  private var streamingTextView: NativeStreamingTextView?
  private var streamingBlocksView: NativeStreamingAssistantBlocksView?
  private var currentStreamingContent = ""
  private var contentMode: ContentMode?

  init(
    item: RenderedChatTurnItem,
    rowID: String,
    state: NativeTranscriptCellState,
    assetsRevision: Int,
    makePlaceholderView: @escaping PlaceholderBuilder,
    makeFinalContentView: @escaping ContentBuilder,
    makeFooterView: @escaping ContentBuilder,
    makeStreamingBlocksView: @escaping StreamingBlocksBuilder
  ) {
    self.makePlaceholderView = makePlaceholderView
    self.makeFinalContentView = makeFinalContentView
    self.makeFooterView = makeFooterView
    self.makeStreamingBlocksView = makeStreamingBlocksView
    super.init(frame: .zero)
    setupStack()
    update(item: item, rowID: rowID, state: state, assetsRevision: assetsRevision)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(
    item: RenderedChatTurnItem,
    rowID: String,
    state: NativeTranscriptCellState,
    assetsRevision: Int
  ) {
    updateContent(item: item, rowID: rowID, state: state, assetsRevision: assetsRevision)
    if item.isStreamingAssistantMessage {
      replaceFooterView(nil)
    } else {
      replaceFooterView(makeFooterView(item, rowID, state))
    }
  }

  private func setupStack() {
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.distribution = .gravityAreas
    stack.spacing = 8
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  private func updateContent(
    item: RenderedChatTurnItem,
    rowID: String,
    state: NativeTranscriptCellState,
    assetsRevision: Int
  ) {
    if item.shouldShowAssistantPlaceholder {
      let mode = ContentMode.placeholder(item.assistantPlaceholderTitle)
      if contentMode != mode {
        replaceContentView(makePlaceholderView(item.assistantPlaceholderTitle))
        resetStreamingText()
        contentMode = mode
      }
      return
    }

    if item.isStreamingAssistantMessage {
      guard item.nativeAttachments.isEmpty else {
        let mode = ContentMode.streamingStructured(
          revision: item.renderRevision,
          assetsRevision: assetsRevision
        )
        if contentMode != mode {
          replaceContentView(makeFinalContentView(item, rowID, state))
          resetStreamingText()
          contentMode = mode
        }
        return
      }

      if item.assistantRenderBlocks.isEmpty {
        updatePlainStreamingText(item.content)
      } else {
        updateStreamingBlocks(item, rowID: rowID)
      }
      return
    }

    // Rebuild only when the content itself or an async asset (attachment
    // thumbnail) changed. Copy/speech state lives in the separately rebuilt
    // footer, and finished code highlights are applied in place via
    // NativeCodeBlockView, so neither needs a content rebuild anymore.
    let mode = ContentMode.final(
      revision: item.renderRevision,
      assetsRevision: assetsRevision
    )
    if contentMode != mode {
      replaceContentView(makeFinalContentView(item, rowID, state))
      resetStreamingText()
      contentMode = mode
    }
  }

  // Streams the message as structured blocks: everything before the last
  // markdown boundary is frozen into final block views, only the volatile
  // tail is re-rendered per flush. See NativeStreamingAssistantBlocksView.
  private func updateStreamingBlocks(_ item: RenderedChatTurnItem, rowID: String) {
    if contentMode != .streamingBlocks || streamingBlocksView == nil {
      let blocksView = makeStreamingBlocksView(rowID)
      resetStreamingText()
      streamingBlocksView = blocksView
      replaceContentView(blocksView)
      blocksView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
      contentMode = .streamingBlocks
    }

    streamingBlocksView?.update(item: item)
    invalidateIntrinsicContentSize()
    needsLayout = true
  }

  private func updatePlainStreamingText(_ content: String) {
    if contentMode != .streamingPlain || streamingTextView == nil {
      let textView = NativeStreamingTextView()
      streamingTextView = textView
      currentStreamingContent = ""
      replaceContentView(textView)
      textView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
      contentMode = .streamingPlain
    }

    guard let streamingTextView else {
      return
    }

    if content.hasPrefix(currentStreamingContent) {
      let suffix = String(content.dropFirst(currentStreamingContent.count))
      if !suffix.isEmpty {
        streamingTextView.appendAttributedText(
          Self.streamingAttributedString(for: suffix, usesPlaceholderForEmpty: false)
        )
      }
    } else {
      streamingTextView.setAttributedText(Self.streamingAttributedString(for: content))
    }

    currentStreamingContent = content
    invalidateIntrinsicContentSize()
    needsLayout = true
  }

  private func replaceContentView(_ view: NSView?) {
    if let contentView {
      stack.removeArrangedSubview(contentView)
      contentView.removeFromSuperview()
    }
    contentView = view
    guard let view else {
      invalidateIntrinsicContentSize()
      return
    }

    let index =
      footerView.flatMap { footer in stack.arrangedSubviews.firstIndex { $0 === footer } }
      ?? stack.arrangedSubviews.count
    stack.insertArrangedSubview(view, at: index)
    invalidateIntrinsicContentSize()
  }

  private func replaceFooterView(_ view: NSView?) {
    if let footerView {
      stack.removeArrangedSubview(footerView)
      footerView.removeFromSuperview()
    }
    footerView = view
    guard let view else {
      invalidateIntrinsicContentSize()
      return
    }

    stack.addArrangedSubview(view)
    invalidateIntrinsicContentSize()
  }

  private func resetStreamingText() {
    streamingTextView = nil
    streamingBlocksView = nil
    currentStreamingContent = ""
  }

  private static func streamingAttributedString(
    for text: String,
    usesPlaceholderForEmpty: Bool = true
  ) -> NSAttributedString {
    let source = text.isEmpty && usesPlaceholderForEmpty ? " " : text
    let attributedString = NSMutableAttributedString(
      string: source,
      attributes: [
        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        .foregroundColor: NSColor.labelColor,
      ]
    )
    NativeTranscriptMarkdownRenderer.applyLinks(to: attributedString, sourceText: source)
    return attributedString
  }

  private enum ContentMode: Equatable {
    case placeholder(String)
    case streamingPlain
    case streamingBlocks
    case streamingStructured(revision: Int, assetsRevision: Int)
    case final(revision: Int, assetsRevision: Int)
  }
}

// Renders a streaming assistant message as structured blocks while it is
// still growing. Content arrives append-only, so every markdown boundary that
// has passed (fence lines, blank lines) is final: those segments are built
// exactly once through the same builders as the final message and never
// touched again. Only the volatile tail after the last boundary is
// re-rendered per flush, so per-flush cost stays proportional to the tail.
final class NativeStreamingAssistantBlocksView: NSStackView {
  typealias MarkdownBlocksProvider = (String) -> [NativeMarkdownBlock]
  typealias MarkdownBlockViewBuilder = (NativeMarkdownBlock) -> NSView
  typealias FinalCodeBlockViewBuilder = (AssistantRenderBlock.CodeBlock) -> NSView

  private let markdownBlocks: MarkdownBlocksProvider
  private let makeMarkdownBlockView: MarkdownBlockViewBuilder
  private let makeFinalCodeBlockView: FinalCodeBlockViewBuilder

  private var trackedContent = ""
  private var finalizedCoreBlockCount = 0
  private var finalizedParagraphUTF16Length = 0
  private var finalizedViewCount = 0

  // The tail region always sits after the finalized views: a sub-stack for
  // the live markdown tail and/or a streaming code view for an open fence.
  private let markdownTailStack = NSStackView()
  private var markdownTailLabel: NSTextField?
  private var codeTailView: NativeStreamingCodeBlockView?

  init(
    markdownBlocks: @escaping MarkdownBlocksProvider,
    makeMarkdownBlockView: @escaping MarkdownBlockViewBuilder,
    makeFinalCodeBlockView: @escaping FinalCodeBlockViewBuilder
  ) {
    self.markdownBlocks = markdownBlocks
    self.makeMarkdownBlockView = makeMarkdownBlockView
    self.makeFinalCodeBlockView = makeFinalCodeBlockView
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    distribution = .gravityAreas
    spacing = 8

    markdownTailStack.orientation = .vertical
    markdownTailStack.alignment = .leading
    markdownTailStack.distribution = .gravityAreas
    markdownTailStack.spacing = 8
    // Hidden while empty so the stack spacing does not leave a phantom gap;
    // NSStackView detaches hidden arranged subviews from layout.
    markdownTailStack.isHidden = true
    addArrangedSubview(markdownTailStack)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(item: RenderedChatTurnItem) {
    if !item.content.hasPrefix(trackedContent) {
      resetAllSegments()
    }
    trackedContent = item.content

    let blocks = item.assistantRenderBlocks
    guard !blocks.isEmpty else {
      resetAllSegments()
      trackedContent = item.content
      return
    }

    let lastIndex = blocks.count - 1
    while finalizedCoreBlockCount < lastIndex {
      finalizeBlock(blocks[finalizedCoreBlockCount])
      finalizedCoreBlockCount += 1
    }

    guard finalizedCoreBlockCount == lastIndex else {
      return
    }

    switch blocks[lastIndex] {
    case .paragraph(let paragraph):
      clearCodeTail()
      updateMarkdownTail(paragraph.text)
    case .codeBlock(let codeBlock) where !codeBlock.isClosed:
      clearMarkdownTail()
      updateCodeTail(codeBlock)
    case .codeBlock(let codeBlock):
      finalizeBlock(.codeBlock(codeBlock))
      finalizedCoreBlockCount += 1
      clearMarkdownTail()
      clearCodeTail()
    }
  }

  private func finalizeBlock(_ block: AssistantRenderBlock) {
    switch block {
    case .paragraph(let paragraph):
      let remainder = utf16Suffix(of: paragraph.text, from: finalizedParagraphUTF16Length)
      finalizedParagraphUTF16Length = 0
      clearMarkdownTail()
      appendFinalizedMarkdown(String(remainder))
    case .codeBlock(let codeBlock):
      clearCodeTail()
      insertFinalizedView(makeFinalCodeBlockView(codeBlock))
    }
  }

  private func updateMarkdownTail(_ paragraphText: String) {
    var remainder = utf16Suffix(of: paragraphText, from: finalizedParagraphUTF16Length)

    if let boundary = remainder.range(of: "\n\n", options: .backwards) {
      let completed = String(remainder[..<boundary.lowerBound])
      finalizedParagraphUTF16Length = boundary.upperBound.utf16Offset(in: paragraphText)
      clearMarkdownTail()
      appendFinalizedMarkdown(completed)
      remainder = utf16Suffix(of: paragraphText, from: finalizedParagraphUTF16Length)
    }

    guard !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      clearMarkdownTail()
      return
    }

    let tailBlocks = markdownBlocks(String(remainder))
    if tailBlocks.count == 1,
      case .text(let attributedString) = tailBlocks[0],
      let markdownTailLabel
    {
      markdownTailLabel.attributedStringValue = attributedString
      return
    }

    clearMarkdownTail()
    markdownTailStack.isHidden = tailBlocks.isEmpty
    for block in tailBlocks {
      let view = makeMarkdownBlockView(block)
      markdownTailStack.addArrangedSubview(view)
      if tailBlocks.count == 1, let label = view as? NSTextField {
        markdownTailLabel = label
      }
    }
  }

  private func updateCodeTail(_ codeBlock: AssistantRenderBlock.CodeBlock) {
    let tailView: NativeStreamingCodeBlockView
    if let codeTailView {
      tailView = codeTailView
    } else {
      tailView = NativeStreamingCodeBlockView()
      codeTailView = tailView
      addArrangedSubview(tailView)
      tailView.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
    tailView.update(codeBlock: codeBlock)
  }

  private func appendFinalizedMarkdown(_ text: String) {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return
    }
    for block in markdownBlocks(text) {
      insertFinalizedView(makeMarkdownBlockView(block))
    }
  }

  private func insertFinalizedView(_ view: NSView) {
    insertArrangedSubview(view, at: finalizedViewCount)
    finalizedViewCount += 1
  }

  private func clearMarkdownTail() {
    markdownTailLabel = nil
    markdownTailStack.isHidden = true
    for view in markdownTailStack.arrangedSubviews {
      markdownTailStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
  }

  private func clearCodeTail() {
    guard let codeTailView else {
      return
    }
    removeArrangedSubview(codeTailView)
    codeTailView.removeFromSuperview()
    self.codeTailView = nil
  }

  private func resetAllSegments() {
    clearMarkdownTail()
    clearCodeTail()
    for view in arrangedSubviews where view !== markdownTailStack {
      removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    trackedContent = ""
    finalizedCoreBlockCount = 0
    finalizedParagraphUTF16Length = 0
    finalizedViewCount = 0
  }

  private func utf16Suffix(of text: String, from offset: Int) -> Substring {
    guard offset > 0 else {
      return text[...]
    }
    guard offset <= text.utf16.count else {
      return text[text.endIndex...]
    }
    return text[String.Index(utf16Offset: offset, in: text)...]
  }
}

// The live view for a still-open fenced code block: same chrome as the final
// NativeCodeBlockView (which replaces it once the fence closes), but the code
// streams into a TextKit-backed text view so appends stay O(delta).
final class NativeStreamingCodeBlockView: NSStackView {
  private let languageLabel: NSTextField
  private let textView = NativeStreamingTextView()
  private var codeText = ""
  private var language: String?

  init() {
    languageLabel = NSTextField(wrappingLabelWithString: "")
    languageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    languageLabel.textColor = .secondaryLabelColor
    languageLabel.maximumNumberOfLines = 1
    languageLabel.isHidden = true
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    distribution = .gravityAreas
    spacing = 4

    addArrangedSubview(languageLabel)

    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor =
      NSColor.secondaryLabelColor.withAlphaComponent(0.08).cgColor
    container.layer?.cornerRadius = 8
    container.layer?.borderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor
    container.layer?.borderWidth = 1
    container.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(textView)
    NSLayoutConstraint.activate([
      textView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
      textView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
      textView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
      textView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
    ])
    addArrangedSubview(container)
    container.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(codeBlock: AssistantRenderBlock.CodeBlock) {
    if codeBlock.language != language {
      language = codeBlock.language
      let name = codeBlock.language ?? ""
      languageLabel.stringValue = name
      languageLabel.isHidden = name.isEmpty
    }

    let text = codeBlock.text
    if !codeText.isEmpty, text.hasPrefix(codeText) {
      let suffix = String(text.dropFirst(codeText.count))
      if !suffix.isEmpty {
        textView.appendAttributedText(Self.codeAttributedString(for: suffix))
      }
    } else {
      textView.setAttributedText(Self.codeAttributedString(for: text.isEmpty ? " " : text))
    }
    codeText = text
  }

  var codeTextForTesting: String {
    textView.string
  }

  private static func codeAttributedString(for text: String) -> NSAttributedString {
    NSAttributedString(
      string: text,
      attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        .foregroundColor: NSColor.labelColor,
      ]
    )
  }
}

final class NativeCodeBlockView: NSStackView {
  let codeBlock: AssistantRenderBlock.CodeBlock
  private let codeLabel: NSTextField
  private var hasHighlightedCode: Bool

  init(
    codeBlock: AssistantRenderBlock.CodeBlock,
    codeLabel: NSTextField,
    hasHighlightedCode: Bool
  ) {
    self.codeBlock = codeBlock
    self.codeLabel = codeLabel
    self.hasHighlightedCode = hasHighlightedCode
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    distribution = .gravityAreas
    spacing = 4
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // Metric-neutral by construction: the highlighted string is the same code in
  // the same monospaced font, spans only recolor. No relayout or height
  // invalidation is needed, so a finished highlight never rebuilds the row.
  func applyHighlightedCodeIfNeeded(_ highlightedCode: HighlightedCode?) {
    guard !hasHighlightedCode, let highlightedCode else {
      return
    }
    codeLabel.attributedStringValue = NativeTranscriptCodeRenderer.attributedString(
      for: highlightedCode
    )
    hasHighlightedCode = true
  }
}

// Non-scrolling, self-sizing text view for live streaming text. Unlike an
// NSTextField label, TextKit keeps its layout between updates: appending a
// suffix relayouts only the affected tail lines instead of re-measuring the
// whole text, keeping per-flush cost O(delta) while a long message streams.
final class NativeStreamingTextView: NSTextView {
  // The manually assembled TextKit 1 stack only retains downwards
  // (storage -> layout manager -> container); the view must keep the storage
  // alive itself.
  private let streamingStorage: NSTextStorage

  init() {
    let storage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(
      containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    )
    container.widthTracksTextView = true
    container.lineFragmentPadding = 0
    storage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(container)
    streamingStorage = storage
    super.init(frame: .zero, textContainer: container)
    translatesAutoresizingMaskIntoConstraints = false
    isEditable = false
    isSelectable = true
    drawsBackground = false
    textContainerInset = .zero
    isVerticallyResizable = false
    isHorizontallyResizable = false
    minSize = .zero
    maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
    setContentHuggingPriority(.defaultHigh, for: .vertical)
    // Read-only transcript text: expose it to VoiceOver like the NSTextField
    // labels it replaced, not as an editable "text entry area".
    setAccessibilityRole(.staticText)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // The width is pinned to the full content column because NSTextView has no
  // intrinsic width. Without these overrides a short streamed line would turn
  // the whole column into an I-beam/selection strip whose clicks also steal
  // first-responder focus from the composer; confine interaction to the text.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let superview, let layoutManager, let textContainer else {
      return super.hitTest(point)
    }
    let localPoint = convert(point, from: superview)
    let usedRect = layoutManager.usedRect(for: textContainer)
    guard localPoint.x <= usedRect.maxX + textContainerOrigin.x else {
      return nil
    }
    return super.hitTest(point)
  }

  override func resetCursorRects() {
    guard let layoutManager, let textContainer else {
      super.resetCursorRects()
      return
    }
    let usedRect = layoutManager.usedRect(for: textContainer)
    let textRect = NSRect(
      x: 0,
      y: 0,
      width: usedRect.maxX + textContainerOrigin.x,
      height: bounds.height
    )
    addCursorRect(textRect.intersection(bounds), cursor: .iBeam)
  }

  override var intrinsicContentSize: NSSize {
    guard let layoutManager, let textContainer else {
      return super.intrinsicContentSize
    }
    layoutManager.ensureLayout(for: textContainer)
    let usedRect = layoutManager.usedRect(for: textContainer)
    return NSSize(width: NSView.noIntrinsicMetric, height: ceil(usedRect.height))
  }

  // The intrinsic height depends on the wrapping width, which only exists
  // after a layout pass has assigned the frame.
  override func setFrameSize(_ newSize: NSSize) {
    let widthChanged = abs(frame.width - newSize.width) >= 0.5
    super.setFrameSize(newSize)
    if widthChanged {
      invalidateIntrinsicContentSize()
    }
  }

  func setAttributedText(_ attributedString: NSAttributedString) {
    streamingStorage.setAttributedString(attributedString)
    invalidateIntrinsicContentSize()
  }

  func appendAttributedText(_ attributedString: NSAttributedString) {
    streamingStorage.append(attributedString)
    invalidateIntrinsicContentSize()
  }
}

extension NativeChatMessageCellView {
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

  fileprivate func makeSmallButton(title: String, action: @escaping () -> Void) -> NSButton {
    let button = NativeActionButton(title: title)
    button.controlSize = .small
    button.bezelStyle = .rounded
    button.setButtonType(.momentaryPushIn)
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

private final class NativeTranscriptTableView: NSView {
  private let table: NativeMarkdownTable
  private let rows: [[NativeMarkdownTableCell]]
  private let labels: [[NSTextField]]

  override var isFlipped: Bool {
    true
  }

  init(table: NativeMarkdownTable) {
    self.table = table
    self.rows = NativeMarkdownTableMetrics.normalizedRows(for: table)
    self.labels = rows.map { row in
      row.map { cell in
        let label = NSTextField(labelWithAttributedString: cell.attributedString)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.isSelectable = true
        label.allowsEditingTextAttributes = true
        label.drawsBackground = false
        label.isBordered = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
      }
    }
    super.init(frame: .zero)

    wantsLayer = false
    setContentHuggingPriority(.defaultLow, for: .horizontal)
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    setContentHuggingPriority(.required, for: .vertical)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Markdown table")

    for row in labels {
      for label in row {
        addSubview(label)
      }
    }
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    let width = measuredWidth
    return NSSize(
      width: NativeMarkdownTableMetrics.preferredWidth(for: table),
      height: NativeMarkdownTableMetrics.height(for: table, width: width)
    )
  }

  override func setFrameSize(_ newSize: NSSize) {
    let oldWidth = frame.width
    super.setFrameSize(newSize)
    guard abs(oldWidth - newSize.width) >= 1 else {
      return
    }
    invalidateIntrinsicContentSize()
    needsDisplay = true
  }

  override func layout() {
    ChatDiagnostics.measure("Transcript markdown table layout", category: .transcript) {
      super.layout()
      guard !rows.isEmpty else {
        return
      }
      let columnWidth = NativeMarkdownTableMetrics.columnWidth(for: table, width: measuredWidth)
      var rowOriginY = NativeMarkdownTableMetrics.borderWidth
      for (rowIndex, row) in rows.enumerated() {
        let rowHeight = NativeMarkdownTableMetrics.rowHeight(for: row, columnWidth: columnWidth)
        var columnOriginX = NativeMarkdownTableMetrics.borderWidth
        for columnIndex in row.indices {
          let label = labels[rowIndex][columnIndex]
          label.frame = NSRect(
            x: columnOriginX + NativeMarkdownTableMetrics.horizontalPadding,
            y: rowOriginY + NativeMarkdownTableMetrics.verticalPadding,
            width: max(columnWidth - NativeMarkdownTableMetrics.horizontalPadding * 2, 12),
            height: max(rowHeight - NativeMarkdownTableMetrics.verticalPadding * 2, 12)
          )
          columnOriginX += columnWidth + NativeMarkdownTableMetrics.separatorWidth
        }
        rowOriginY += rowHeight + NativeMarkdownTableMetrics.separatorWidth
      }
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    ChatDiagnostics.measure("Transcript markdown table draw", category: .transcript) {
      super.draw(dirtyRect)
      guard !rows.isEmpty else {
        return
      }

      let boundsPath = NSBezierPath(
        roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
        xRadius: NativeMarkdownTableMetrics.cornerRadius,
        yRadius: NativeMarkdownTableMetrics.cornerRadius
      )
      NSColor.secondaryLabelColor.withAlphaComponent(0.045).setFill()
      boundsPath.fill()
      NSColor.secondaryLabelColor.withAlphaComponent(0.14).setStroke()
      boundsPath.lineWidth = NativeMarkdownTableMetrics.borderWidth
      boundsPath.stroke()

      let columnWidth = NativeMarkdownTableMetrics.columnWidth(for: table, width: measuredWidth)
      let rowHeights = rows.map { row in
        NativeMarkdownTableMetrics.rowHeight(for: row, columnWidth: columnWidth)
      }

      if !table.header.isEmpty, let headerHeight = rowHeights.first {
        let headerRect = NSRect(
          x: NativeMarkdownTableMetrics.borderWidth,
          y: NativeMarkdownTableMetrics.borderWidth,
          width: bounds.width - NativeMarkdownTableMetrics.borderWidth * 2,
          height: headerHeight
        )
        NSColor.secondaryLabelColor.withAlphaComponent(0.075).setFill()
        headerRect.fill()
      }

      NSColor.secondaryLabelColor.withAlphaComponent(0.10).setStroke()
      let separatorPath = NSBezierPath()
      var rowSeparatorY = NativeMarkdownTableMetrics.borderWidth
      for rowHeight in rowHeights.dropLast() {
        rowSeparatorY += rowHeight + NativeMarkdownTableMetrics.separatorWidth / 2
        separatorPath.move(
          to: NSPoint(x: NativeMarkdownTableMetrics.borderWidth, y: rowSeparatorY))
        separatorPath.line(
          to: NSPoint(x: bounds.width - NativeMarkdownTableMetrics.borderWidth, y: rowSeparatorY)
        )
        rowSeparatorY += NativeMarkdownTableMetrics.separatorWidth / 2
      }

      var columnSeparatorX = NativeMarkdownTableMetrics.borderWidth + columnWidth
      for _ in 1..<max(table.columnCount, 1) {
        separatorPath.move(
          to: NSPoint(x: columnSeparatorX, y: NativeMarkdownTableMetrics.borderWidth))
        separatorPath.line(
          to: NSPoint(
            x: columnSeparatorX,
            y: bounds.height - NativeMarkdownTableMetrics.borderWidth)
        )
        columnSeparatorX += columnWidth + NativeMarkdownTableMetrics.separatorWidth
      }
      separatorPath.lineWidth = NativeMarkdownTableMetrics.separatorWidth
      separatorPath.stroke()
    }
  }

  private var measuredWidth: CGFloat {
    let width =
      bounds.width > 0
      ? bounds.width
      : NativeMarkdownTableMetrics.preferredWidth(
        for: table)
    return max(width, 220)
  }
}

private final class NativeActionButton: NSButton {
  var actionHandler: (() -> Void)?

  init(title: String) {
    super.init(frame: .zero)
    self.title = title
    target = self
    action = #selector(performAction)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc private func performAction() {
    actionHandler?()
  }
}

private final class NativeAttachmentPreviewButton: NSButton {
  var actionHandler: ((NSView) -> Void)?

  init() {
    super.init(frame: .zero)
    title = ""
    isBordered = false
    isTransparent = true
    bezelStyle = .inline
    imagePosition = .noImage
    setButtonType(.momentaryPushIn)
    focusRingType = .none
    target = self
    action = #selector(performAttachmentAction)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    bounds.contains(point) ? self : nil
  }

  override func accessibilityPerformPress() -> Bool {
    actionHandler?(self)
    return true
  }

  @objc private func performAttachmentAction() {
    actionHandler?(self)
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }
}

private final class NativeAttachmentImagePreviewController: NSViewController {
  private let imageURL: URL?
  private let displayName: String

  init(imageURL: URL?, displayName: String) {
    self.imageURL = imageURL
    self.displayName = displayName
    super.init(nibName: nil, bundle: nil)
    preferredContentSize = NSSize(width: 640, height: 480)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    stack.translatesAutoresizingMaskIntoConstraints = false

    let root = NSView()
    root.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: root.topAnchor),
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])

    if let image = imageURL.flatMap(NSImage.init(contentsOf:)) {
      stack.addArrangedSubview(makeImageView(image))
    } else {
      stack.addArrangedSubview(makeUnavailableView())
    }

    let nameLabel = NSTextField(labelWithString: displayName)
    nameLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    nameLabel.textColor = .secondaryLabelColor
    nameLabel.lineBreakMode = .byTruncatingMiddle
    nameLabel.maximumNumberOfLines = 1
    stack.addArrangedSubview(nameLabel)

    self.view = root
  }

  private func makeImageView(_ image: NSImage) -> NSImageView {
    let imageView = NSImageView()
    imageView.image = image
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.translatesAutoresizingMaskIntoConstraints = false

    let fittedSize = fittedImageSize(for: image.size)
    NSLayoutConstraint.activate([
      imageView.widthAnchor.constraint(equalToConstant: fittedSize.width),
      imageView.heightAnchor.constraint(equalToConstant: fittedSize.height),
    ])
    preferredContentSize = NSSize(width: fittedSize.width + 24, height: fittedSize.height + 54)
    return imageView
  }

  private func makeUnavailableView() -> NSView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 8

    let imageView = NSImageView()
    imageView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
    imageView.image?.isTemplate = true
    imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
    imageView.contentTintColor = .secondaryLabelColor
    stack.addArrangedSubview(imageView)

    let label = NSTextField(labelWithString: "Image Unavailable")
    label.textColor = .secondaryLabelColor
    stack.addArrangedSubview(label)

    NSLayoutConstraint.activate([
      stack.widthAnchor.constraint(equalToConstant: 360),
      stack.heightAnchor.constraint(equalToConstant: 240),
    ])
    preferredContentSize = NSSize(width: 384, height: 294)
    return stack
  }

  private func fittedImageSize(for imageSize: NSSize) -> NSSize {
    let maximumSize = NSSize(width: 900, height: 700)
    guard imageSize.width > 0, imageSize.height > 0 else {
      return NSSize(width: 360, height: 240)
    }
    let scale = min(maximumSize.width / imageSize.width, maximumSize.height / imageSize.height, 1)
    return NSSize(
      width: max(1, imageSize.width * scale),
      height: max(1, imageSize.height * scale)
    )
  }
}

private func nativeThinkingStatusIndicator(
  status: AssistantThinkingMessage.DeliveryStatus
) -> NSView {
  if status == .streaming {
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
  imageView.image = NSImage(systemSymbolName: "brain", accessibilityDescription: nil)
  imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
  imageView.contentTintColor = .tertiaryLabelColor
  imageView.setAccessibilityElement(false)
  NSLayoutConstraint.activate([
    imageView.widthAnchor.constraint(equalToConstant: 13),
    imageView.heightAnchor.constraint(equalToConstant: 13),
  ])
  return imageView
}

extension NativeTranscriptRow {
  var accessibilityIdentifier: String {
    switch body {
    case .generationIndicator:
      "chat.generationSpinner"
    case .item(let item):
      item.nativeAccessibilityIdentifier
    }
  }

  fileprivate var accessibilityLabel: String {
    switch body {
    case .generationIndicator:
      "Generating"
    case .item(let item):
      item.nativeAccessibilityLabel
    }
  }
}

extension RenderedChatTurnItem {
  var shouldShowAssistantPlaceholder: Bool {
    assistantMessage?.shouldShowAssistantPlaceholder ?? false
  }

  fileprivate var isStreamingAssistantMessage: Bool {
    assistantMessage?.deliveryStatus == .streaming
  }

  fileprivate var isStreamingAssistantThinkingMessage: Bool {
    guard case .assistantThinking(let message) = item else {
      return false
    }
    return message.deliveryStatus == .streaming
  }

  fileprivate var assistantPlaceholderTitle: String {
    assistantMessage?.assistantPlaceholderTitle ?? "Generating"
  }

  fileprivate var content: String {
    switch item {
    case .userMessage(let message):
      message.content
    case .assistantThinking(let message):
      message.content
    case .assistantMessage(let message):
      message.content
    case .tool:
      ""
    }
  }

  fileprivate var visibleGenerationMetrics: ChatGenerationMetrics? {
    switch item {
    case .tool:
      nil
    case .assistantThinking, .assistantMessage, .userMessage:
      generationMetrics
    }
  }

  fileprivate var nativeAccessibilityIdentifier: String {
    switch item {
    case .assistantThinking:
      "chat.assistantThinking"
    case .assistantMessage:
      "chat.assistantMessage"
    case .userMessage:
      "chat.userMessage"
    case .tool:
      "chat.toolCallMessage"
    }
  }

  fileprivate var nativeAccessibilityLabel: String {
    switch item {
    case .userMessage:
      "User message"
    case .assistantThinking:
      "Assistant reasoning"
    case .assistantMessage:
      shouldShowAssistantPlaceholder ? assistantPlaceholderTitle : "Assistant message"
    case .tool(let record):
      "Tool \(record.request.toolName.rawValue), \(record.status.nativeDisplayName)"
    }
  }

  fileprivate var isNativeUserMessage: Bool {
    guard case .userMessage = item else {
      return false
    }
    return true
  }

  fileprivate var nativeMaximumBubbleWidth: CGFloat {
    switch item {
    case .tool:
      460
    case .assistantThinking, .assistantMessage, .userMessage:
      680
    }
  }

  fileprivate var canNativeCopyMessageContent: Bool {
    switch item {
    case .userMessage(let message):
      !message.content.isEmpty
    case .assistantThinking:
      false
    case .assistantMessage(let message):
      message.canCopyAssistantContent
    case .tool:
      false
    }
  }

  fileprivate var nativeSpokenText: String? {
    guard case .assistantMessage = item else {
      return nil
    }
    return assistantSpokenText
  }

  fileprivate var nativeAttachments: [ChatAttachment] {
    switch item {
    case .userMessage(let message):
      message.attachments
    case .assistantThinking:
      []
    case .assistantMessage(let message):
      message.attachments
    case .tool:
      []
    }
  }

  private var assistantMessage: AssistantTurnMessage? {
    guard case .assistantMessage(let message) = item else {
      return nil
    }
    return message
  }
}

extension ToolCallRecord {
  fileprivate var transcriptToolCall: ToolCallModelMessage {
    var toolCall = ToolCallModelMessage(request: request)
    toolCall.arguments = toolCall.transcriptArguments
    return toolCall
  }

  fileprivate var nativeAskUserInput: AskUserInput? {
    guard case .askUser(let input) = request.payload else {
      return nil
    }
    return input
  }

  fileprivate var hasNativeToolDetails: Bool {
    !NativeToolDetailContent(record: self).isEmpty
  }
}

extension ToolDisplayPayload {
  fileprivate var nativeOutputTitle: String? {
    switch self {
    case .fileContent:
      "File content"
    case .fileList:
      "Files"
    case .searchResults:
      "Matches"
    case .workspaceDiff:
      "Diff"
    case .summary(_, let text, _):
      text.isEmpty ? nil : "Result"
    }
  }

  fileprivate var nativeOutputText: String? {
    let text =
      switch self {
      case .fileContent(_, let content):
        content.text
      case .fileList(_, let entries, _):
        entries.isEmpty
          ? "(empty)"
          : entries.map { entry in
            entry.kind == .directory ? entry.path.rawValue + "/" : entry.path.rawValue
          }.joined(separator: "\n")
      case .searchResults(_, _, let matches, _):
        matches.isEmpty
          ? "(no matches)"
          : matches.map { "\($0.path.rawValue):\($0.line): \($0.snippet)" }
            .joined(separator: "\n")
      case .workspaceDiff(_, let content):
        content.text
      case .summary(_, let text, _):
        text
      }
    return text.isEmpty ? nil : text
  }

  fileprivate var nativeAffectedPaths: [String] {
    switch self {
    case .fileContent(let path, _):
      [path.rawValue]
    case .fileList(let root, _, _), .searchResults(let root, _, _, _):
      [root.rawValue]
    case .workspaceDiff(let path, _):
      path.map { [$0.rawValue] } ?? []
    case .summary(_, _, let paths):
      paths.map(\.rawValue)
    }
  }

  fileprivate var nativeFlags: [String] {
    switch self {
    case .fileContent(_, let content), .workspaceDiff(_, let content):
      content.nativeFlags
    case .fileList(_, _, let truncated), .searchResults(_, _, _, let truncated):
      truncated ? ["truncated"] : []
    case .summary:
      []
    }
  }
}

extension ToolTextOutput {
  fileprivate var nativeFlags: [String] {
    var flags: [String] = []
    if truncated {
      flags.append("truncated")
    }
    if redacted {
      flags.append("redacted")
    }
    return flags
  }
}

extension ToolResultPreview {
  fileprivate var nativeFlags: [String] {
    var flags: [String] = []
    if truncated {
      flags.append("truncated")
    }
    if redacted {
      flags.append("redacted")
    }
    return flags
  }
}

extension ToolCallModelMessage {
  fileprivate var nativeHeaderSummary: String? {
    func argumentValue(named name: String) -> String? {
      guard let value = arguments.first(where: { $0.name == name })?.value,
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        return nil
      }
      return value
    }

    switch toolName {
    case .runCommand:
      return argumentValue(named: "command")
    case .writeFile, .editFile, .readFile, .showFile:
      return argumentValue(named: "path")
    case .webSearch:
      return argumentValue(named: "query")
    case .webFetch:
      return argumentValue(named: "url")
    case .browserInspect:
      return argumentValue(named: "selector") ?? "document.body"
    case .browserRefresh:
      return argumentValue(named: "hard")
    default:
      return nil
    }
  }
}

extension ToolCallStatus {
  fileprivate var nativeDisplayName: String {
    switch self {
    case .pending:
      "pending"
    case .awaitingApproval:
      "approval"
    case .awaitingUserAnswer:
      "question"
    case .denied:
      "denied"
    case .running:
      "running"
    case .completed:
      "done"
    case .failed:
      "failed"
    case .cancelled:
      "cancelled"
    }
  }

  fileprivate var nativeIsInProgress: Bool {
    switch self {
    case .pending, .running:
      true
    case .awaitingApproval, .awaitingUserAnswer, .denied, .completed, .failed, .cancelled:
      false
    }
  }

  fileprivate var nativeQuietSystemImage: String {
    switch self {
    case .completed:
      "checkmark"
    case .failed, .denied:
      "xmark"
    case .cancelled:
      "minus"
    case .awaitingApproval, .awaitingUserAnswer:
      "exclamationmark"
    case .pending, .running:
      "ellipsis"
    }
  }

  fileprivate var nativeQuietColor: NSColor {
    switch self {
    case .completed:
      .systemGreen
    case .failed, .denied:
      .systemOrange
    case .cancelled:
      .secondaryLabelColor
    case .awaitingApproval, .awaitingUserAnswer:
      .systemOrange
    case .pending, .running:
      .secondaryLabelColor
    }
  }
}

extension ChatGenerationMetrics {
  var visibleSummary: String {
    "\(generatedTokenCount) tokens · \(formattedDuration(durationMs))"
  }

  fileprivate var nativeTokenRateSummary: String {
    "\(tokensPerSecond.formatted(.number.precision(.fractionLength(1)))) tok/s"
  }

  private func formattedDuration(_ durationMs: Double) -> String {
    let durationSeconds = durationMs / 1000
    if durationSeconds < 10 {
      return "\(durationSeconds.formatted(.number.precision(.fractionLength(1)))) s"
    }
    return "\(durationSeconds.formatted(.number.precision(.fractionLength(0)))) s"
  }
}
