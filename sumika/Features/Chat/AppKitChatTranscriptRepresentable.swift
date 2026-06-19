import AppKit
import SumikaCore
import SwiftUI

struct AppKitChatTranscriptRepresentable: NSViewRepresentable {
  let items: [RenderedChatTurnItem]
  let showsGenerationIndicator: Bool
  let accessibilityValue: String
  let onApproveToolCall: (ToolCallRecord.ID) -> Void
  let onDenyToolCall: (ToolCallRecord.ID) -> Void
  let onAnswerAskUser: (ToolCallRecord.ID, String) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
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
      in: scrollView
    )
  }

  @MainActor
  final class Coordinator: NSObject, NSTableViewDelegate {
    private let section = NativeTranscriptSection.main
    private let cellIdentifier = NSUserInterfaceItemIdentifier("NativeChatMessageCellView")
    private var onApproveToolCall: (ToolCallRecord.ID) -> Void
    private var onDenyToolCall: (ToolCallRecord.ID) -> Void
    private var onAnswerAskUser: (ToolCallRecord.ID, String) -> Void
    private weak var tableView: NSTableView?
    private var dataSource: NSTableViewDiffableDataSource<NativeTranscriptSection, String>?
    private var rowsByID: [String: NativeTranscriptRow] = [:]
    private var rowIDs: [String] = []
    private var revisionsByID: [String: Int] = [:]
    private var cellStateStore = NativeTranscriptCoordinatorState()
    private var heightCache = NativeTranscriptHeightCache()
    private var pinnedToBottom = true
    private var pendingHeightInvalidationRows = IndexSet()
    private var pendingHeightInvalidationWorkItem: DispatchWorkItem?

    init(
      onApproveToolCall: @escaping (ToolCallRecord.ID) -> Void,
      onDenyToolCall: @escaping (ToolCallRecord.ID) -> Void,
      onAnswerAskUser: @escaping (ToolCallRecord.ID, String) -> Void
    ) {
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
      onApproveToolCall: @escaping (ToolCallRecord.ID) -> Void,
      onDenyToolCall: @escaping (ToolCallRecord.ID) -> Void,
      onAnswerAskUser: @escaping (ToolCallRecord.ID, String) -> Void
    ) {
      self.onApproveToolCall = onApproveToolCall
      self.onDenyToolCall = onDenyToolCall
      self.onAnswerAskUser = onAnswerAskUser
    }

    func update(
      rows: [NativeTranscriptRow],
      accessibilityValue: String,
      in scrollView: NSScrollView
    ) {
      guard let tableView else {
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
      let shouldScrollAfterAppend = NativeTranscriptScrollDecision.shouldScrollToBottomAfterAppend(
        previousIDs: rowIDs,
        currentRows: rows
      )

      rowsByID = newRowsByID
      rowIDs = newRowIDs
      revisionsByID = newRevisionsByID
      pruneCoordinatorState(activeRowIDs: Set(newRowIDs))
      scrollView.setAccessibilityValue(accessibilityValue)
      tableView.tableColumns.first?.width = max(scrollView.contentSize.width, 1)

      switch plan.action {
      case .snapshot:
        applySnapshot(rowIDs: newRowIDs, animatingDifferences: false)
        scheduleHeightInvalidation(for: IndexSet(integersIn: 0..<newRowIDs.count))
      case .reconfigureRows:
        reconfigureVisibleRows(changedIDs: plan.changedIDs)
        scheduleHeightInvalidation(for: rowIndexes(for: plan.changedIDs))
      }

      if wasPinnedToBottom || shouldScrollAfterAppend {
        scrollToBottom(scrollView)
      }
    }

    func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
      guard row >= 0, row < rowIDs.count, let rowModel = rowsByID[rowIDs[row]] else {
        return 44
      }
      let width = max(tableView?.bounds.width ?? 680, 320)
      return heightCache.height(
        for: rowModel,
        width: width,
        state: cellStateStore.state(for: rowModel.id)
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

    private func applySnapshot(rowIDs: [String], animatingDifferences: Bool) {
      var snapshot = NSDiffableDataSourceSnapshot<NativeTranscriptSection, String>()
      snapshot.appendSections([section])
      snapshot.appendItems(rowIDs, toSection: section)
      dataSource?.apply(snapshot, animatingDifferences: animatingDifferences)
    }

    private func configure(_ cell: NativeChatMessageCellView, with row: NativeTranscriptRow) {
      cell.configure(
        row: row,
        state: cellStateStore.state(for: row.id),
        actions: NativeTranscriptCellActions(
          copy: { [weak self] rowID, content in
            self?.copy(content: content, from: rowID)
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
          updateAskUserSelection: { [weak self] rowID, answer in
            self?.cellStateStore.updateAskUserSelection(answer, rowID: rowID)
          }
        )
      )
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
      scheduleHeightInvalidation(for: rowIndexes(for: [rowID]))
    }

    private func reconfigureRows(ids: Set<String>) {
      reconfigureRows(ids: Array(ids))
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

    private func scheduleHeightInvalidation(for rowIndexes: IndexSet) {
      guard !rowIndexes.isEmpty else {
        return
      }
      pendingHeightInvalidationRows.formUnion(rowIndexes)
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
      pendingHeightInvalidationRows.removeAll()
      pendingHeightInvalidationWorkItem = nil
      tableView.noteHeightOfRows(withIndexesChanged: rows)
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
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        self.pinnedToBottom = true
      }
    }

    private func pruneCoordinatorState(activeRowIDs: Set<String>) {
      cellStateStore.prune(activeRowIDs: activeRowIDs)
      heightCache.prune(activeRowIDs: activeRowIDs)
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

struct NativeTranscriptHeightCache {
  private var heightsByKey: [Key: CGFloat] = [:]

  var cachedEntryCount: Int {
    heightsByKey.count
  }

  mutating func height(
    for row: NativeTranscriptRow,
    width: CGFloat,
    state: NativeTranscriptCellState = NativeTranscriptCellState()
  ) -> CGFloat {
    let normalizedWidth = Int(width.rounded(.down))
    let key = Key(
      rowID: row.id,
      revision: row.revision,
      width: normalizedWidth,
      isToolExpanded: state.isToolExpanded
    )
    if let height = heightsByKey[key] {
      return height
    }
    let height = NativeTranscriptRowMeasurer.height(for: row, width: width, state: state)
    heightsByKey[key] = height
    return height
  }

  mutating func invalidate(rowID: String) {
    heightsByKey = heightsByKey.filter { $0.key.rowID != rowID }
  }

  mutating func prune(activeRowIDs: Set<String>) {
    heightsByKey = heightsByKey.filter { activeRowIDs.contains($0.key.rowID) }
  }

  struct Key: Hashable {
    let rowID: String
    let revision: Int
    let width: Int
    let isToolExpanded: Bool
  }
}

enum NativeTranscriptRowMeasurer {
  static func height(
    for row: NativeTranscriptRow,
    width: CGFloat,
    state: NativeTranscriptCellState = NativeTranscriptCellState()
  ) -> CGFloat {
    switch row.body {
    case .generationIndicator:
      return 54
    case .item(let item):
      return height(for: item, width: width, state: state)
    }
  }

  private static func height(
    for item: RenderedChatTurnItem,
    width: CGFloat,
    state: NativeTranscriptCellState
  ) -> CGFloat {
    let contentWidth = max(min(width - 140, item.nativeMaximumBubbleWidth), 220)
    switch item.item {
    case .userMessage(let message):
      let textHeight = measuredTextHeight(
        message.content,
        font: .systemFont(ofSize: NSFont.systemFontSize),
        width: contentWidth - 24
      )
      let attachmentHeight = CGFloat(message.attachments.count) * 24
      return max(44, textHeight + attachmentHeight + 34)

    case .assistantMessage:
      if item.shouldShowAssistantPlaceholder {
        return 48
      }
      let blocksHeight = item.assistantRenderBlocks.reduce(CGFloat(0)) { total, block in
        switch block {
        case .paragraph(let paragraph):
          return total
            + measuredTextHeight(
              paragraph.text,
              font: .systemFont(ofSize: NSFont.systemFontSize),
              width: contentWidth
            ) + 8
        case .codeBlock(let codeBlock):
          return total
            + measuredTextHeight(
              codeBlock.text.isEmpty ? " " : codeBlock.text,
              font: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
              width: contentWidth - 24
            ) + 34
        }
      }
      let metricsHeight: CGFloat = item.visibleGenerationMetrics == nil ? 0 : 18
      return max(44, blocksHeight + metricsHeight + 28)

    case .tool(let record):
      var height: CGFloat = 34
      if state.isToolExpanded {
        height += CGFloat(record.transcriptToolCall.arguments.count) * 18
        if let preview = record.resultPreview ?? record.approvalPreview, !preview.text.isEmpty {
          height +=
            measuredTextHeight(
              preview.text,
              font: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
              width: contentWidth - 24
            ) + 28
        }
      }
      if record.status == .awaitingApproval {
        height += 32
      }
      if record.status == .awaitingUserAnswer, record.nativeAskUserInput != nil {
        height += 58
      }
      if item.generationMetrics != nil {
        height += 18
      }
      return height
    }
  }

  private static func measuredTextHeight(
    _ text: String,
    font: NSFont,
    width: CGFloat
  ) -> CGFloat {
    let measuredText = text.isEmpty ? " " : text
    let attributedString = NSAttributedString(
      string: measuredText,
      attributes: [.font: font]
    )
    let rect = attributedString.boundingRect(
      with: NSSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    return ceil(rect.height)
  }
}

struct NativeTranscriptCellState: Equatable {
  var isCopied: Bool
  var isToolExpanded: Bool
  var askUserSelection: String?

  init(
    isCopied: Bool = false,
    isToolExpanded: Bool = false,
    askUserSelection: String? = nil
  ) {
    self.isCopied = isCopied
    self.isToolExpanded = isToolExpanded
    self.askUserSelection = askUserSelection
  }
}

struct NativeTranscriptCoordinatorState: Equatable {
  private var copiedRowIDs: Set<String> = []
  private var expandedToolRowIDs: Set<String> = []
  private var askUserSelections: [String: String] = [:]

  func state(for rowID: String) -> NativeTranscriptCellState {
    NativeTranscriptCellState(
      isCopied: copiedRowIDs.contains(rowID),
      isToolExpanded: expandedToolRowIDs.contains(rowID),
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

  mutating func updateAskUserSelection(_ answer: String, rowID: String) {
    askUserSelections[rowID] = answer
  }

  mutating func prune(activeRowIDs: Set<String>) {
    copiedRowIDs = copiedRowIDs.intersection(activeRowIDs)
    expandedToolRowIDs = expandedToolRowIDs.intersection(activeRowIDs)
    askUserSelections = askUserSelections.filter { activeRowIDs.contains($0.key) }
  }
}

struct NativeTranscriptCellActions {
  var copy: (String, String) -> Void
  var approve: (ToolCallRecord.ID) -> Void
  var deny: (ToolCallRecord.ID) -> Void
  var answerAskUser: (String, ToolCallRecord.ID, String) -> Void
  var toggleToolExpansion: (String) -> Void
  var updateAskUserSelection: (String, String) -> Void
}

final class NativeChatMessageCellView: NSTableCellView {
  private var currentRowID: String?
  private var actions: NativeTranscriptCellActions?
  private var askUserPopUpButton: NSPopUpButton?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    currentRowID = nil
    actions = nil
    askUserPopUpButton = nil
    subviews.forEach { $0.removeFromSuperview() }
  }

  func configure(
    row: NativeTranscriptRow,
    state: NativeTranscriptCellState,
    actions: NativeTranscriptCellActions
  ) {
    currentRowID = row.id
    self.actions = actions
    askUserPopUpButton = nil
    subviews.forEach { $0.removeFromSuperview() }

    let contentView: NSView
    switch row.body {
    case .generationIndicator:
      contentView = makeGenerationIndicator()
    case .item(let item):
      contentView = makeContentView(for: item, rowID: row.id, state: state)
    }

    addSubview(contentView)
    contentView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      contentView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      contentView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
    ])

    switch row.body {
    case .item(let item) where item.isNativeUserMessage:
      NSLayoutConstraint.activate([
        contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -44),
        contentView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 80),
        contentView.widthAnchor.constraint(
          lessThanOrEqualToConstant: item.nativeMaximumBubbleWidth),
      ])
    default:
      NSLayoutConstraint.activate([
        contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
        contentView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -80),
        contentView.widthAnchor.constraint(lessThanOrEqualToConstant: 680),
      ])
    }

    setAccessibilityElement(true)
    setAccessibilityIdentifier(row.accessibilityIdentifier)
    setAccessibilityLabel(row.accessibilityLabel)
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
    case .assistantMessage:
      return makeAssistantMessageView(
        item: item,
        rowID: rowID,
        isCopied: state.isCopied
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
    let stack = verticalStack(spacing: 7)
    if !message.attachments.isEmpty {
      stack.addArrangedSubview(makeAttachmentLabels(message.attachments))
    }
    stack.addArrangedSubview(makeTextLabel(message.content, color: .labelColor))
    stack.addArrangedSubview(
      makeCopyButton(
        rowID: rowID,
        content: message.content,
        isCopied: isCopied,
        alignment: .right
      )
    )
    return paddedContainer(
      stack,
      fillColor: NSColor.secondaryLabelColor.withAlphaComponent(0.12),
      cornerRadius: 10
    )
  }

  private func makeAssistantMessageView(
    item: RenderedChatTurnItem,
    rowID: String,
    isCopied: Bool
  ) -> NSView {
    let stack = verticalStack(spacing: 8)
    if item.shouldShowAssistantPlaceholder {
      stack.addArrangedSubview(makeSecondaryLabel(item.assistantPlaceholderTitle))
      return stack
    }

    if item.assistantRenderBlocks.isEmpty {
      stack.addArrangedSubview(makeTextLabel(item.content, color: .labelColor))
    } else {
      for block in item.assistantRenderBlocks {
        switch block {
        case .paragraph(let paragraph):
          stack.addArrangedSubview(makeTextLabel(paragraph.text, color: .labelColor))
        case .codeBlock(let codeBlock):
          stack.addArrangedSubview(makeCodeBlockView(codeBlock))
        }
      }
    }

    let footer = horizontalStack(spacing: 8)
    if item.canNativeCopyMessageContent {
      footer.addArrangedSubview(
        makeCopyButton(
          rowID: rowID,
          content: item.content,
          isCopied: isCopied,
          alignment: .left
        )
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

  private func makeToolView(
    record: ToolCallRecord,
    generationMetrics: ChatGenerationMetrics?,
    rowID: String,
    state: NativeTranscriptCellState
  ) -> NSView {
    let stack = verticalStack(spacing: 7)
    let toolCall = record.transcriptToolCall

    let header = horizontalStack(spacing: 7)
    header.addArrangedSubview(makeSecondaryLabel(record.status.nativeDisplayName))
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
        makeSmallButton(title: state.isToolExpanded ? "Hide" : "Details") { [weak self] in
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
    let toolCall = record.transcriptToolCall
    for argument in toolCall.arguments {
      stack.addArrangedSubview(makeSecondaryLabel("\(argument.name): \(argument.value)"))
    }
    if let preview = record.resultPreview ?? record.approvalPreview, !preview.text.isEmpty {
      stack.addArrangedSubview(
        paddedContainer(
          makeCodeLikeLabel(preview.text),
          fillColor: NSColor.secondaryLabelColor.withAlphaComponent(0.08),
          cornerRadius: 6
        )
      )
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

  private func makeGenerationIndicator() -> NSView {
    let row = horizontalStack(spacing: 8)
    let spinner = NSProgressIndicator()
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.startAnimation(nil)
    row.addArrangedSubview(spinner)
    row.addArrangedSubview(makeSecondaryLabel("Generating"))
    return row
  }

  private func makeAttachmentLabels(_ attachments: [ChatAttachment]) -> NSView {
    let stack = verticalStack(spacing: 4)
    for attachment in attachments {
      stack.addArrangedSubview(
        makeSecondaryLabel("\(attachment.kind.rawValue): \(attachment.displayName)")
      )
    }
    return stack
  }

  private func makeCodeBlockView(_ codeBlock: AssistantRenderBlock.CodeBlock) -> NSView {
    let stack = verticalStack(spacing: 4)
    if let language = codeBlock.language, !language.isEmpty {
      stack.addArrangedSubview(makeSecondaryLabel(language))
    }
    stack.addArrangedSubview(
      paddedContainer(
        makeCodeLikeLabel(codeBlock.text.isEmpty ? " " : codeBlock.text),
        fillColor: NSColor.secondaryLabelColor.withAlphaComponent(0.08),
        cornerRadius: 6
      )
    )
    return stack
  }

  private func makeTextLabel(_ text: String, color: NSColor) -> NSTextField {
    let label = NSTextField(labelWithAttributedString: nativeLinkedAttributedString(for: text))
    label.font = .systemFont(ofSize: NSFont.systemFontSize)
    label.textColor = color
    label.maximumNumberOfLines = 0
    label.lineBreakMode = .byWordWrapping
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }

  private func makeCodeLikeLabel(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    label.textColor = .labelColor
    label.maximumNumberOfLines = 0
    label.lineBreakMode = .byWordWrapping
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
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

  private func makeCopyButton(
    rowID: String,
    content: String,
    isCopied: Bool,
    alignment: NSLayoutConstraint.Attribute
  ) -> NSView {
    let row = horizontalStack(spacing: 0)
    let button = makeSmallButton(title: isCopied ? "Copied" : "Copy") { [weak self] in
      self?.actions?.copy(rowID, content)
    }
    if alignment == .right {
      row.addArrangedSubview(spacer())
      row.addArrangedSubview(button)
    } else {
      row.addArrangedSubview(button)
      row.addArrangedSubview(spacer())
    }
    return row
  }

  private func makeSmallButton(title: String, action: @escaping () -> Void) -> NSButton {
    let button = NativeActionButton(title: title)
    button.controlSize = .small
    button.bezelStyle = .rounded
    button.setButtonType(.momentaryPushIn)
    button.actionHandler = action
    return button
  }

  private func paddedContainer(
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

  private func verticalStack(spacing: CGFloat) -> NSStackView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.distribution = .gravityAreas
    stack.spacing = spacing
    return stack
  }

  private func horizontalStack(spacing: CGFloat) -> NSStackView {
    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.distribution = .gravityAreas
    stack.spacing = spacing
    return stack
  }

  private func spacer() -> NSView {
    let view = NSView()
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
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

private func nativeLinkedAttributedString(for text: String) -> NSAttributedString {
  let attributedString = NSMutableAttributedString(
    string: text,
    attributes: [
      .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
      .foregroundColor: NSColor.labelColor,
    ]
  )
  for link in URLTextLinkifier.links(in: text) {
    attributedString.addAttributes(
      [
        .foregroundColor: NSColor.linkColor,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
      ],
      range: NSRange(link.range, in: text)
    )
  }
  return attributedString
}

extension NativeTranscriptRow {
  fileprivate var accessibilityIdentifier: String {
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
  fileprivate var nativeAccessibilityIdentifier: String {
    switch item {
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
    case .assistantMessage, .userMessage:
      680
    }
  }

  fileprivate var canNativeCopyMessageContent: Bool {
    switch item {
    case .userMessage(let message):
      !message.content.isEmpty
    case .assistantMessage(let message):
      message.canCopyAssistantContent
    case .tool:
      false
    }
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
    !transcriptToolCall.arguments.isEmpty || resultPreview?.text.isEmpty == false
      || approvalPreview?.text.isEmpty == false
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
}

extension ChatGenerationMetrics {
  fileprivate var nativeTokenRateSummary: String {
    "\(tokensPerSecond.formatted(.number.precision(.fractionLength(1)))) tok/s"
  }
}
