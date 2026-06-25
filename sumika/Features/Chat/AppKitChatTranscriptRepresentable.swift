import AppKit
import SumikaCore
import SwiftUI

struct AppKitChatTranscriptRepresentable: NSViewRepresentable {
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
    context.coordinator.updateCallbacks(
      onToggleSpeech: onToggleSpeech,
      onApproveToolCall: onApproveToolCall,
      onDenyToolCall: onDenyToolCall,
      onAnswerAskUser: onAnswerAskUser
    )
    context.coordinator.update(
      rows: NativeTranscriptRow.rows(
        for: items,
        showsGenerationIndicator: showsGenerationIndicator
      ),
      accessibilityValue: accessibilityValue,
      isSpeechEnabled: isSpeechEnabled,
      activeSpeechRowID: activeSpeechRowID,
      in: scrollView
    )
  }

  @MainActor
  final class Coordinator: NSObject, NSTableViewDelegate {
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

    func makeScrollView() -> NSScrollView {
      let tableView = NSTableView()
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

      applySnapshot(rowIDs: [], animatingDifferences: false)
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

    func update(
      rows: [NativeTranscriptRow],
      accessibilityValue: String,
      isSpeechEnabled: Bool,
      activeSpeechRowID: String?,
      in scrollView: NSScrollView
    ) {
      guard tableView != nil else {
        return
      }

      let newRowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
      let newRowIDs = rows.map(\.id)
      let newRevisionsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.revision) })
      let plan = NativeTranscriptDiffPlan.make(
        previousIDs: rowIDs,
        previousRevisions: revisionsByID,
        currentIDs: newRowIDs,
        currentRevisions: newRevisionsByID
      )
      let wasPinnedToBottom = isPinnedToBottom(scrollView)
      let speechStateChangedIDs = changedSpeechRowIDs(
        currentRowIDs: newRowIDs,
        isSpeechEnabled: isSpeechEnabled,
        activeSpeechRowID: activeSpeechRowID
      )
      let shouldScrollAfterAppend = NativeTranscriptScrollDecision.shouldScrollToBottomAfterAppend(
        previousIDs: rowIDs,
        currentRows: rows
      )

      rowsByID = newRowsByID
      rowIDs = newRowIDs
      revisionsByID = newRevisionsByID
      self.isSpeechEnabled = isSpeechEnabled
      self.activeSpeechRowID = activeSpeechRowID
      pruneCoordinatorState(activeRows: rows)
      scrollView.setAccessibilityValue(accessibilityValue)
      let didChangeColumnWidth = updateColumnWidth(in: scrollView)

      switch plan.action {
      case .snapshot:
        applySnapshot(rowIDs: newRowIDs, animatingDifferences: false)
        scheduleHeightInvalidation(
          for: IndexSet(integersIn: 0..<newRowIDs.count),
          scrollToBottomAfterFlush: wasPinnedToBottom || shouldScrollAfterAppend
        )
      case .reconfigureRows:
        reconfigureVisibleRows(changedIDs: plan.changedIDs.union(speechStateChangedIDs))
        var invalidationRows = rowIndexes(for: plan.changedIDs.union(speechStateChangedIDs))
        if didChangeColumnWidth {
          invalidationRows.formUnion(IndexSet(integersIn: 0..<newRowIDs.count))
        }
        scheduleHeightInvalidation(
          for: invalidationRows,
          scrollToBottomAfterFlush: wasPinnedToBottom && didChangeColumnWidth
        )
      }

      let hasRowChanges = plan.action == .snapshot || !plan.changedIDs.isEmpty
      if shouldScrollAfterAppend || (wasPinnedToBottom && hasRowChanges) {
        scrollToBottom(scrollView)
      }
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

    func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
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

    private func applySnapshot(rowIDs: [String], animatingDifferences: Bool) {
      var snapshot = NSDiffableDataSourceSnapshot<NativeTranscriptSection, String>()
      snapshot.appendSections([section])
      snapshot.appendItems(rowIDs, toSection: section)
      dataSource?.apply(snapshot, animatingDifferences: animatingDifferences)
    }

    private func configure(_ cell: NativeChatMessageCellView, with row: NativeTranscriptRow) {
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
              self?.reconfigureRows(ids: [updatedRowID])
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
      heightCache.invalidate(rowID: rowID)
      reconfigureRows(ids: [rowID])
      scheduleHeightInvalidation(for: rowIndexes(for: [rowID]), scrollToBottomAfterFlush: false)
    }

    private func toggleThinkingExpansion(rowID: String) {
      cellStateStore.toggleThinkingExpansion(rowID: rowID)
      heightCache.invalidate(rowID: rowID)
      reconfigureRows(ids: [rowID])
      scheduleHeightInvalidation(for: rowIndexes(for: [rowID]), scrollToBottomAfterFlush: false)
    }

    private func reconfigureRows(ids: [String]) {
      reconfigureVisibleRows(changedIDs: Set(ids))
    }

    private func reconfigureVisibleRows(changedIDs: Set<String>) {
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

    private func scheduleHeightInvalidation(
      for rowIndexes: IndexSet,
      scrollToBottomAfterFlush: Bool
    ) {
      guard !rowIndexes.isEmpty else {
        return
      }
      pendingHeightInvalidationRows.formUnion(rowIndexes)
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

    private func flushHeightInvalidation() {
      guard let tableView else {
        pendingHeightInvalidationRows.removeAll()
        pendingHeightInvalidationWorkItem = nil
        return
      }
      let rows = pendingHeightInvalidationRows
      let shouldScrollToBottom = shouldScrollAfterHeightInvalidation
      pendingHeightInvalidationRows.removeAll()
      shouldScrollAfterHeightInvalidation = false
      pendingHeightInvalidationWorkItem = nil
      tableView.noteHeightOfRows(withIndexesChanged: rows)
      if shouldScrollToBottom, let scrollView = tableView.enclosingScrollView {
        scrollToBottom(scrollView)
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
        guard let documentView = scrollView.documentView else {
          return
        }
        let targetY = max(documentView.bounds.height - scrollView.contentView.bounds.height, 0)
        guard abs(scrollView.contentView.bounds.origin.y - targetY) >= 0.5 else {
          self.pinnedToBottom = true
          return
        }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        self.pinnedToBottom = true
      }
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
}

enum NativeTranscriptSection: Hashable {
  case main
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

  var cachedEntryCount: Int {
    heightsByKey.count
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
      isToolExpanded: state.isToolExpanded
    )
    if let height = heightsByKey[key] {
      return height
    }
    let height = NativeTranscriptRowMeasurer.height(
      for: row,
      width: width,
      state: state,
      markdownBlocks: markdownBlocks
    )
    heightsByKey[key] = height
    return height
  }

  mutating func invalidate(rowID: String) {
    heightsByKey = heightsByKey.filter { $0.key.rowID != rowID }
  }

  mutating func prune(activeRows: [NativeTranscriptRow]) {
    let activeRevisions = Set(
      activeRows.map { ActiveRevision(rowID: $0.id, revision: $0.revision) }
    )
    heightsByKey = heightsByKey.filter {
      activeRevisions.contains(
        ActiveRevision(rowID: $0.key.rowID, revision: $0.key.revision)
      )
    }
  }

  struct Key: Hashable {
    let rowID: String
    let revision: Int
    let width: Int
    let isSpeechEnabled: Bool
    let isToolExpanded: Bool

    static func == (lhs: Key, rhs: Key) -> Bool {
      lhs.rowID == rhs.rowID
        && lhs.revision == rhs.revision
        && lhs.width == rhs.width
        && lhs.isSpeechEnabled == rhs.isSpeechEnabled
        && lhs.isToolExpanded == rhs.isToolExpanded
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(rowID)
      hasher.combine(revision)
      hasher.combine(width)
      hasher.combine(isSpeechEnabled)
      hasher.combine(isToolExpanded)
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
      NativeTranscriptMarkdownRenderer.blocks
  ) -> CGFloat {
    NativeChatMessageCellView.measuredHeight(
      for: row,
      width: width,
      state: state,
      actions: measuringActions(markdownBlocks: markdownBlocks)
    )
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
  private var alignmentConstraints: [NSLayoutConstraint] = []
  fileprivate var actions: NativeTranscriptCellActions?
  private var askUserPopUpButton: NSPopUpButton?

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
    actions: NativeTranscriptCellActions
  ) -> CGFloat {
    let constrainedWidth = max(width, 1)
    let cell = NativeChatMessageCellView(
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

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    actions = nil
    askUserPopUpButton = nil
  }

  func configure(
    row: NativeTranscriptRow,
    state: NativeTranscriptCellState,
    actions: NativeTranscriptCellActions
  ) {
    self.actions = actions
    askUserPopUpButton = nil

    let contentView: NSView
    switch row.body {
    case .generationIndicator:
      contentView = makeGenerationIndicator()
    case .item(let item):
      contentView = makeContentView(for: item, rowID: row.id, state: state)
    }

    replaceHostedContent(with: contentView)
    updateAlignment(for: row.body)

    setAccessibilityElement(true)
    setAccessibilityIdentifier(row.accessibilityIdentifier)
    setAccessibilityLabel(row.accessibilityLabel)
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
    hostedContentView?.removeFromSuperview()
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
      alignmentConstraints = [
        contentHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
        contentHost.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -80),
        contentHost.widthAnchor.constraint(lessThanOrEqualToConstant: 680),
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
    let stack = verticalStack(spacing: 6)
    let isExpanded = state.isThinkingExpanded || message.deliveryStatus == .streaming

    let header = horizontalStack(spacing: 7)
    header.addArrangedSubview(nativeThinkingStatusIndicator(status: message.deliveryStatus))
    let title = makeSecondaryLabel("Reasoning")
    title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
    header.addArrangedSubview(title)
    header.addArrangedSubview(spacer())
    header.addArrangedSubview(
      makeIconButton(
        systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
        accessibilityLabel: isExpanded ? "Hide reasoning" : "Show reasoning",
        tintColor: .tertiaryLabelColor
      ) { [weak self] in
        self?.actions?.toggleThinkingExpansion(rowID)
      }
    )
    stack.addArrangedSubview(header)

    if isExpanded, !message.content.isEmpty {
      let content = makeTextLabel(message.content, color: .secondaryLabelColor)
      stack.addArrangedSubview(content)
    }

    return borderedPaddedContainer(
      stack,
      fillColor: NSColor.secondaryLabelColor.withAlphaComponent(0.06),
      strokeColor: NSColor.secondaryLabelColor.withAlphaComponent(0.10),
      cornerRadius: 8
    )
  }

  private func makeAssistantMessageView(
    item: RenderedChatTurnItem,
    rowID: String,
    state: NativeTranscriptCellState
  ) -> NSView {
    let stack = verticalStack(spacing: 8)
    if item.shouldShowAssistantPlaceholder {
      stack.addArrangedSubview(makeGenerationIndicator(title: item.assistantPlaceholderTitle))
      return stack
    }

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
    if footer.arrangedSubviews.isEmpty == false {
      stack.addArrangedSubview(footer)
    }
    return stack
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
    header.addArrangedSubview(spacer())
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
    stack.addArrangedSubview(header)

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
    let stack = verticalStack(spacing: 4)
    if let language = codeBlock.language, !language.isEmpty {
      stack.addArrangedSubview(makeSecondaryLabel(language))
    }
    let language = CodeLanguage(fenceLanguage: codeBlock.language)
    let attributedCode =
      highlightedCode.map(NativeTranscriptCodeRenderer.attributedString)
      ?? NativeTranscriptCodeRenderer.plainAttributedString(
        code: codeBlock.text.isEmpty ? " " : codeBlock.text,
        language: language
      )
    stack.addArrangedSubview(
      borderedPaddedContainer(
        makeCodeAttributedLabel(attributedCode),
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

  override func draw(_ dirtyRect: NSRect) {
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
      separatorPath.move(to: NSPoint(x: NativeMarkdownTableMetrics.borderWidth, y: rowSeparatorY))
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
    case .userMessage(let message):
      "User message \(message.content)"
    case .assistantThinking(let message):
      "Assistant reasoning \(message.content)"
    case .assistantMessage(let message):
      shouldShowAssistantPlaceholder
        ? assistantPlaceholderTitle : "Assistant message \(message.content)"
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
