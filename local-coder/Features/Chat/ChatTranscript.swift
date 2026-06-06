import AppKit
import LocalCoderCore
import MarkdownUI
import SwiftUI

struct ChatTranscript: View {
  let turns: [ChatTurn]
  let toolCalls: [ToolCallRecord]
  let selectedModel: ManagedModel
  let modelState: ModelLoadState
  let isGenerating: Bool
  let onApproveToolCall: (ToolCallRecord.ID) -> Void
  let onDenyToolCall: (ToolCallRecord.ID) -> Void

  var body: some View {
    if transcriptItems.isEmpty {
      ZStack {
        ContentUnavailableView(
          emptyStateTitle,
          systemImage: "bubble.left.and.bubble.right",
          description: Text(emptyStateDescription)
        )
        .frame(maxWidth: .infinity, minHeight: 360)
        .accessibilityIdentifier("chat.emptyState")
      }
      .accessibilityIdentifier("chat.transcript")
      .accessibilityValue(modelState.accessibilityValue)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ChatTranscriptTableRepresentable(
        items: transcriptItems,
        showsGenerationIndicator: shouldShowTranscriptGenerationIndicator,
        accessibilityValue: modelState.accessibilityValue,
        onApproveToolCall: onApproveToolCall,
        onDenyToolCall: onDenyToolCall
      )
    }
  }

  private var emptyStateTitle: String {
    switch modelState {
    case .ready:
      "\(selectedModel.displayName) Ready"
    case .loading:
      "Loading Model"
    case .failed:
      "Model Not Ready"
    case .notLoaded:
      "No Model Loaded"
    }
  }

  private var emptyStateDescription: String {
    switch modelState {
    case .ready:
      "Send a prompt with \(selectedModel.displayName) to start chatting."
    case .loading:
      "Loading \(selectedModel.displayName). You can write a prompt once it is ready."
    case .failed:
      "Loading failed. Select or load a model below before writing a prompt."
    case .notLoaded:
      "Select and load a Gemma model below before writing a prompt."
    }
  }

  private var transcriptItems: [RenderedChatTurnItem] {
    let recordsByID = Dictionary(toolCalls.map { ($0.id, $0) }) { _, latest in latest }
    return turns.flatMap { turn in
      let turnGenerationMetrics = turn.items.compactMap(\.generationMetrics).last
      return turn.items.enumerated().compactMap { offset, item in
        switch item {
        case .userMessage(let message):
          return RenderedChatTurnItem(
            id: "\(turn.id.uuidString):\(offset):message:\(message.id.uuidString)",
            item: item,
            toolCallRecord: nil,
            generationMetrics: nil
          )
        case .assistantMessage(let message):
          return RenderedChatTurnItem(
            id: "\(turn.id.uuidString):\(offset):message:\(message.id.uuidString)",
            item: item,
            toolCallRecord: nil,
            generationMetrics: message.generationMetrics
          )
        case .toolCall(let id):
          guard let record = recordsByID[id] else {
            return nil
          }
          return RenderedChatTurnItem(
            id: "\(turn.id.uuidString):\(offset):toolCall:\(id.uuidString)",
            item: item,
            toolCallRecord: record,
            generationMetrics: turnGenerationMetrics
          )
        case .toolResult(let id):
          guard let record = recordsByID[id] else {
            return nil
          }
          return RenderedChatTurnItem(
            id: "\(turn.id.uuidString):\(offset):toolResult:\(id.uuidString)",
            item: item,
            toolCallRecord: record,
            generationMetrics: turnGenerationMetrics
          )
        }
      }
    }
  }

  private var shouldShowTranscriptGenerationIndicator: Bool {
    isGenerating && !transcriptItems.contains { $0.shouldShowAssistantPlaceholder }
  }
}

private struct RenderedChatTurnItem: Identifiable, Equatable {
  let id: String
  let item: ChatTurnItem
  let toolCallRecord: ToolCallRecord?
  let generationMetrics: ChatGenerationMetrics?
}

private struct ChatTranscriptTableRepresentable: NSViewRepresentable {
  let items: [RenderedChatTurnItem]
  let showsGenerationIndicator: Bool
  let accessibilityValue: String
  let onApproveToolCall: (ToolCallRecord.ID) -> Void
  let onDenyToolCall: (ToolCallRecord.ID) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      items: items,
      showsGenerationIndicator: showsGenerationIndicator,
      onApproveToolCall: onApproveToolCall,
      onDenyToolCall: onDenyToolCall
    )
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = ChatTranscriptScrollView()
    scrollView.onLayout = { [weak coordinator = context.coordinator] in
      coordinator?.scrollViewDidLayout()
    }
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.drawsBackground = false
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.setAccessibilityIdentifier("chat.transcript")
    scrollView.setAccessibilityValue(accessibilityValue)

    let tableView = NSTableView()
    tableView.headerView = nil
    tableView.backgroundColor = .clear
    tableView.gridStyleMask = []
    tableView.allowsColumnResizing = false
    tableView.allowsColumnSelection = false
    tableView.allowsEmptySelection = true
    tableView.allowsMultipleSelection = false
    tableView.selectionHighlightStyle = .none
    tableView.intercellSpacing = NSSize(width: 0, height: 0)
    tableView.usesAutomaticRowHeights = true
    tableView.dataSource = context.coordinator
    tableView.delegate = context.coordinator

    let column = NSTableColumn(identifier: Self.columnIdentifier)
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)

    scrollView.documentView = tableView
    context.coordinator.tableView = tableView
    context.coordinator.scrollView = scrollView
    context.coordinator.observeClipViewBounds(scrollView.contentView)
    context.coordinator.updateColumnWidth()
    context.coordinator.reloadAllRows()
    context.coordinator.scrollToBottom(animated: false)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    scrollView.setAccessibilityValue(accessibilityValue)
    context.coordinator.onApproveToolCall = onApproveToolCall
    context.coordinator.onDenyToolCall = onDenyToolCall
    context.coordinator.updateColumnWidth()
    context.coordinator.apply(
      items: items,
      showsGenerationIndicator: showsGenerationIndicator
    )
  }

  private static let columnIdentifier = NSUserInterfaceItemIdentifier(
    "chat.transcript.column"
  )

  final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var items: [RenderedChatTurnItem]
    var showsGenerationIndicator: Bool
    var onApproveToolCall: (ToolCallRecord.ID) -> Void
    var onDenyToolCall: (ToolCallRecord.ID) -> Void
    weak var tableView: NSTableView?
    weak var scrollView: NSScrollView?
    private let scrollAnchorManager = TranscriptScrollAnchorManager()
    private var bottomScrollScheduled = false
    private var scheduledBottomScrollAnimated = false

    init(
      items: [RenderedChatTurnItem],
      showsGenerationIndicator: Bool,
      onApproveToolCall: @escaping (ToolCallRecord.ID) -> Void,
      onDenyToolCall: @escaping (ToolCallRecord.ID) -> Void
    ) {
      self.items = items
      self.showsGenerationIndicator = showsGenerationIndicator
      self.onApproveToolCall = onApproveToolCall
      self.onDenyToolCall = onDenyToolCall
    }

    deinit {
      NotificationCenter.default.removeObserver(self)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
      rowCount
    }

    func tableView(
      _ tableView: NSTableView,
      viewFor tableColumn: NSTableColumn?,
      row: Int
    ) -> NSView? {
      guard let rowModel = model(for: row) else {
        return nil
      }

      let view =
        tableView.makeView(
          withIdentifier: ChatTranscriptHostingCell.reuseIdentifier,
          owner: self
        ) as? ChatTranscriptHostingCell
        ?? ChatTranscriptHostingCell()
      view.update(rootView: viewContent(for: rowModel))
      return view
    }

    func apply(
      items newItems: [RenderedChatTurnItem],
      showsGenerationIndicator newShowsGenerationIndicator: Bool
    ) {
      guard let tableView else {
        items = newItems
        showsGenerationIndicator = newShowsGenerationIndicator
        return
      }

      let oldRows = rows
      let wasPinnedToBottom = scrollAnchorManager.isPinnedToBottom(in: scrollView)
      let visibleAnchor =
        wasPinnedToBottom
        ? nil
        : scrollAnchorManager.captureVisibleAnchor(
          in: tableView,
          rows: oldRows
        )
      let newRows = Self.rows(
        items: newItems,
        showsGenerationIndicator: newShowsGenerationIndicator
      )
      let scrollAction = scrollAction(
        oldRows: oldRows,
        newRows: newRows,
        wasPinnedToBottom: wasPinnedToBottom,
        visibleAnchor: visibleAnchor
      )
      items = newItems
      showsGenerationIndicator = newShowsGenerationIndicator

      if oldRows == newRows {
        applyScrollAction(scrollAction, animated: false)
        return
      }

      if isAppendAtEnd(from: oldRows, to: newRows) {
        let insertedRange = oldRows.count..<newRows.count
        let reloadedIndexes = changedIndexes(in: oldRows, comparedTo: newRows)
        tableView.beginUpdates()
        if !reloadedIndexes.isEmpty {
          tableView.reloadData(forRowIndexes: reloadedIndexes, columnIndexes: [0])
        }
        if !insertedRange.isEmpty {
          tableView.insertRows(
            at: IndexSet(integersIn: insertedRange),
            withAnimation: .effectFade
          )
        }
        tableView.endUpdates()
      } else if let diff = simpleRowDiff(from: oldRows, to: newRows) {
        tableView.beginUpdates()
        if !diff.deletedIndexes.isEmpty {
          tableView.removeRows(at: diff.deletedIndexes, withAnimation: .effectFade)
        }
        if !diff.insertedIndexes.isEmpty {
          tableView.insertRows(at: diff.insertedIndexes, withAnimation: .effectFade)
        }
        if !diff.reloadedIndexes.isEmpty {
          tableView.reloadData(forRowIndexes: diff.reloadedIndexes, columnIndexes: [0])
        }
        tableView.endUpdates()
      } else {
        reloadAllRows()
      }

      tableView.layoutSubtreeIfNeeded()
      applyScrollAction(scrollAction, animated: true)
    }

    func reloadAllRows() {
      tableView?.reloadData()
    }

    func observeClipViewBounds(_ clipView: NSClipView) {
      clipView.postsBoundsChangedNotifications = true
      scrollAnchorManager.updatePinnedState(in: scrollView)
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(clipViewBoundsDidChange(_:)),
        name: NSView.boundsDidChangeNotification,
        object: clipView
      )
    }

    func scrollViewDidLayout() {
      let wasPinnedToBottom = scrollAnchorManager.pinnedToBottom
      updateColumnWidth()
      if wasPinnedToBottom {
        scrollToBottom(animated: false)
      } else {
        scrollAnchorManager.updatePinnedState(in: scrollView)
      }
    }

    func updateColumnWidth() {
      guard let tableView,
        let scrollView,
        let column = tableView.tableColumns.first
      else {
        return
      }
      column.width = max(0, scrollView.contentView.bounds.width)
    }

    func scrollToBottom(animated: Bool) {
      scheduledBottomScrollAnimated = scheduledBottomScrollAnimated || animated
      guard !bottomScrollScheduled else {
        return
      }
      bottomScrollScheduled = true
      DispatchQueue.main.async { [weak self] in
        self?.performScheduledBottomScroll()
      }
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
      scrollAnchorManager.updatePinnedState(in: scrollView)
    }

    private func performScheduledBottomScroll() {
      bottomScrollScheduled = false
      let animated = scheduledBottomScrollAnimated
      scheduledBottomScrollAnimated = false

      guard let tableView, rowCount > 0 else {
        return
      }

      if animated {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.18
          scrollAnchorManager.scrollToBottom(in: tableView.enclosingScrollView)
        }
      } else {
        scrollAnchorManager.scrollToBottom(in: tableView.enclosingScrollView)
      }
    }

    private var rowCount: Int {
      items.count + (showsGenerationIndicator ? 1 : 0)
    }

    private var rows: [RowModel] {
      Self.rows(items: items, showsGenerationIndicator: showsGenerationIndicator)
    }

    private static func rows(
      items: [RenderedChatTurnItem],
      showsGenerationIndicator: Bool
    ) -> [RowModel] {
      var rows = items.map(RowModel.item)
      if showsGenerationIndicator {
        rows.append(.generationIndicator)
      }
      return rows
    }

    private func model(for row: Int) -> RowModel? {
      guard row >= 0 else {
        return nil
      }
      if row < items.count {
        return .item(items[row])
      }
      if row == items.count, showsGenerationIndicator {
        return .generationIndicator
      }
      return nil
    }

    private func viewContent(for rowModel: RowModel) -> AnyView {
      switch rowModel {
      case .item(let item):
        AnyView(
          ChatBubble(
            item: item,
            onApproveToolCall: onApproveToolCall,
            onDenyToolCall: onDenyToolCall
          )
          .padding(.vertical, 6)
        )
      case .generationIndicator:
        AnyView(
          TranscriptGenerationIndicator()
            .padding(.vertical, 6)
        )
      }
    }

    private func scrollAction(
      oldRows: [RowModel],
      newRows: [RowModel],
      wasPinnedToBottom: Bool,
      visibleAnchor: TranscriptScrollAnchorManager.VisibleAnchor?
    ) -> ScrollAction {
      guard !newRows.isEmpty else {
        return .none
      }
      if oldRows == newRows {
        return .none
      }
      if oldRows.isEmpty {
        return .scrollToBottom
      }
      if isAppendAtEnd(from: oldRows, to: newRows) {
        let appendedRows = Array(newRows.dropFirst(oldRows.count))
        if appendedRows.contains(where: \.isUserMessage) {
          return .scrollToBottom
        }
        if wasPinnedToBottom {
          return .scrollToBottom
        }
        return restoreAction(for: visibleAnchor)
      }
      if wasPinnedToBottom {
        return .scrollToBottom
      }
      return restoreAction(for: visibleAnchor)
    }

    private func restoreAction(
      for visibleAnchor: TranscriptScrollAnchorManager.VisibleAnchor?
    ) -> ScrollAction {
      guard let visibleAnchor else {
        return .none
      }
      return .restoreAnchor(visibleAnchor)
    }

    private func applyScrollAction(_ action: ScrollAction, animated: Bool) {
      switch action {
      case .none:
        scrollAnchorManager.updatePinnedState(in: scrollView)
      case .scrollToBottom:
        scrollToBottom(animated: animated)
      case .restoreAnchor(let anchor):
        guard let tableView else {
          return
        }
        scrollAnchorManager.restore(anchor, in: tableView, rows: rows)
      }
    }

    private func isAppendAtEnd(from oldRows: [RowModel], to newRows: [RowModel]) -> Bool {
      guard newRows.count >= oldRows.count else {
        return false
      }
      return zip(oldRows, newRows).allSatisfy { oldRow, newRow in
        oldRow.id == newRow.id
      }
    }

    private func changedIndexes(in oldRows: [RowModel], comparedTo newRows: [RowModel]) -> IndexSet
    {
      IndexSet(
        oldRows.enumerated().compactMap { index, oldRow in
          guard index < newRows.count, oldRow != newRows[index] else {
            return nil
          }
          return index
        }
      )
    }

    private func simpleRowDiff(
      from oldRows: [RowModel],
      to newRows: [RowModel]
    ) -> RowDiff? {
      let oldIDs = oldRows.map(\.id)
      let newIDs = newRows.map(\.id)
      let oldIDSet = Set(oldIDs)
      let newIDSet = Set(newIDs)

      let commonIDs = oldIDSet.intersection(newIDSet)
      let oldCommonOrder = oldIDs.filter { commonIDs.contains($0) }
      let newCommonOrder = newIDs.filter { commonIDs.contains($0) }
      guard oldCommonOrder == newCommonOrder else {
        return nil
      }

      let deletedIndexes = IndexSet(
        oldIDs.enumerated().compactMap { index, id in
          newIDSet.contains(id) ? nil : index
        }
      )
      let insertedIndexes = IndexSet(
        newIDs.enumerated().compactMap { index, id in
          oldIDSet.contains(id) ? nil : index
        }
      )
      let oldRowsByID = Dictionary(uniqueKeysWithValues: oldRows.map { ($0.id, $0) })
      let reloadedIndexes = IndexSet(
        newRows.enumerated().compactMap { index, row in
          guard let oldRow = oldRowsByID[row.id], oldRow != row else {
            return nil
          }
          return index
        }
      )
      return RowDiff(
        insertedIndexes: insertedIndexes,
        deletedIndexes: deletedIndexes,
        reloadedIndexes: reloadedIndexes
      )
    }
  }

  fileprivate enum ScrollAction {
    case none
    case scrollToBottom
    case restoreAnchor(TranscriptScrollAnchorManager.VisibleAnchor)
  }

  private struct RowDiff {
    let insertedIndexes: IndexSet
    let deletedIndexes: IndexSet
    let reloadedIndexes: IndexSet
  }

  fileprivate enum RowModel: Equatable {
    case item(RenderedChatTurnItem)
    case generationIndicator

    var id: String {
      switch self {
      case .item(let item):
        item.id
      case .generationIndicator:
        "chat.transcript.generationIndicator"
      }
    }

    var isUserMessage: Bool {
      guard case .item(let item) = self,
        case .userMessage = item.item
      else {
        return false
      }
      return true
    }
  }
}

private final class TranscriptScrollAnchorManager {
  struct VisibleAnchor {
    let rowID: String
    let rowIndex: Int
    let offsetY: CGFloat
    let fallbackY: CGFloat
  }

  private static let bottomThreshold: CGFloat = 50

  private(set) var pinnedToBottom = true

  func isPinnedToBottom(in scrollView: NSScrollView?) -> Bool {
    guard let scrollView else {
      return pinnedToBottom
    }
    let pinned = distanceFromBottom(in: scrollView) <= Self.bottomThreshold
    pinnedToBottom = pinned
    return pinned
  }

  func updatePinnedState(in scrollView: NSScrollView?) {
    _ = isPinnedToBottom(in: scrollView)
  }

  func captureVisibleAnchor(
    in tableView: NSTableView,
    rows: [ChatTranscriptTableRepresentable.RowModel]
  ) -> VisibleAnchor? {
    guard let scrollView = tableView.enclosingScrollView else {
      return nil
    }
    let visibleRect = scrollView.contentView.bounds
    let visibleRows = tableView.rows(in: visibleRect)
    guard visibleRows.location != NSNotFound, visibleRows.length > 0 else {
      return nil
    }

    let rowIndex = visibleRows.location
    guard rowIndex >= 0, rowIndex < rows.count else {
      return nil
    }

    let rowRect = tableView.rect(ofRow: rowIndex)
    return VisibleAnchor(
      rowID: rows[rowIndex].id,
      rowIndex: rowIndex,
      offsetY: visibleRect.minY - rowRect.minY,
      fallbackY: visibleRect.minY
    )
  }

  func restore(
    _ anchor: VisibleAnchor,
    in tableView: NSTableView,
    rows: [ChatTranscriptTableRepresentable.RowModel]
  ) {
    guard let scrollView = tableView.enclosingScrollView, !rows.isEmpty else {
      updatePinnedState(in: tableView.enclosingScrollView)
      return
    }

    tableView.layoutSubtreeIfNeeded()
    let rowIndex =
      rows.firstIndex { $0.id == anchor.rowID }
      ?? min(anchor.rowIndex, rows.count - 1)
    let targetY: CGFloat
    if rowIndex >= 0, rowIndex < tableView.numberOfRows {
      targetY = tableView.rect(ofRow: rowIndex).minY + anchor.offsetY
    } else {
      targetY = anchor.fallbackY
    }
    scroll(toY: targetY, in: scrollView)
  }

  func scrollToBottom(in scrollView: NSScrollView?) {
    guard let scrollView else {
      return
    }
    let clipView = scrollView.contentView
    let documentHeight = scrollView.documentView?.bounds.height ?? 0
    scroll(toY: documentHeight - clipView.bounds.height, in: scrollView)
  }

  private func scroll(toY targetY: CGFloat, in scrollView: NSScrollView) {
    let clipView = scrollView.contentView
    let documentHeight = scrollView.documentView?.bounds.height ?? 0
    let maxY = max(0, documentHeight - clipView.bounds.height)
    let clampedTargetY = min(max(0, targetY), maxY)
    clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: clampedTargetY))
    scrollView.reflectScrolledClipView(clipView)
    updatePinnedState(in: scrollView)
  }

  private func distanceFromBottom(in scrollView: NSScrollView) -> CGFloat {
    let clipBounds = scrollView.contentView.bounds
    let documentHeight = scrollView.documentView?.bounds.height ?? 0
    guard documentHeight > clipBounds.height else {
      return 0
    }
    return max(0, documentHeight - clipBounds.maxY)
  }
}

private final class ChatTranscriptScrollView: NSScrollView {
  var onLayout: (() -> Void)?

  override func layout() {
    super.layout()
    onLayout?()
  }
}

private final class ChatTranscriptHostingCell: NSTableCellView {
  static let reuseIdentifier = NSUserInterfaceItemIdentifier("chat.transcript.hostingCell")

  private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    identifier = Self.reuseIdentifier
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor

    hostingView.translatesAutoresizingMaskIntoConstraints = false
    hostingView.setContentHuggingPriority(.required, for: .vertical)
    hostingView.setContentCompressionResistancePriority(.required, for: .vertical)
    addSubview(hostingView)

    NSLayoutConstraint.activate([
      hostingView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
      hostingView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
      hostingView.topAnchor.constraint(equalTo: topAnchor),
      hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(rootView: AnyView) {
    hostingView.rootView = rootView
  }
}

private struct ChatBubble: View {
  let item: RenderedChatTurnItem
  let onApproveToolCall: (ToolCallRecord.ID) -> Void
  let onDenyToolCall: (ToolCallRecord.ID) -> Void
  @State private var didCopy = false

  var body: some View {
    HStack(alignment: .top) {
      if item.isDisplayedAsUser {
        Spacer(minLength: 80)
      }

      VStack(alignment: item.isDisplayedAsUser ? .trailing : .leading, spacing: item.stackSpacing) {
        if item.showsAuthorLabel {
          Label(item.displayTitle, systemImage: item.displaySystemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if item.shouldShowAssistantPlaceholder {
          AssistantPlaceholderView(item: item)
        } else {
          VStack(alignment: item.isDisplayedAsUser ? .trailing : .leading, spacing: 8) {
            MessageContentText(
              item: item.item,
              toolCallRecord: item.toolCallRecord,
              generationMetrics: item.generationMetrics,
              onApproveToolCall: onApproveToolCall,
              onDenyToolCall: onDenyToolCall
            )
            .textSelection(.enabled)

            if let metrics = item.visibleGenerationMetrics {
              GenerationMetricsView(metrics: metrics)
            }
          }
          .padding(item.contentPadding)
          .background(item.messageBubbleBackground)
          .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        if item.isDisplayedAsUser && !item.attachments.isEmpty {
          SentAttachmentList(attachments: item.attachments)
        }

        if item.canCopyMessageContent {
          HStack(spacing: 8) {
            Button {
              copyMessageToClipboard()
            } label: {
              Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(didCopy ? "Copied" : "Copy")
            .accessibilityLabel(item.copyAccessibilityLabel)
          }
        }
      }
      .frame(
        maxWidth: item.maximumBubbleWidth,
        alignment: item.isDisplayedAsUser ? .trailing : .leading
      )

      if item.isDisplayedAsUser {
        Color.clear
          .frame(width: 24)
      } else {
        Spacer(minLength: 80)
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityIdentifier(item.accessibilityIdentifier)
  }

  private func copyMessageToClipboard() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(item.content, forType: .string)
    didCopy = true

    Task {
      try? await Task.sleep(for: .seconds(1.2))
      didCopy = false
    }
  }
}

private struct AssistantPlaceholderView: View {
  let item: RenderedChatTurnItem

  var body: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)

      Label(
        item.assistantPlaceholderTitle,
        systemImage: item.assistantPlaceholderSystemImage
      )
      .labelStyle(.titleAndIcon)
    }
    .foregroundStyle(.secondary)
    .padding(10)
    .background(Color.secondary.opacity(0.12))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(item.assistantPlaceholderTitle)
    .accessibilityIdentifier("chat.generationSpinner")
  }
}

private struct TranscriptGenerationIndicator: View {
  var body: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 6) {
        Label("Local Coder", systemImage: "cpu")
          .font(.caption)
          .foregroundStyle(.secondary)

        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)

          Text("Generating")
        }
        .foregroundStyle(.secondary)
        .padding(10)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Generating")
        .accessibilityIdentifier("chat.generationSpinner")
      }
      .frame(maxWidth: 680, alignment: .leading)

      Spacer(minLength: 80)
    }
    .frame(maxWidth: .infinity)
  }
}

private struct GenerationMetricsView: View {
  let metrics: ChatGenerationMetrics

  var body: some View {
    Text(metrics.visibleSummary)
      .font(.caption2)
      .foregroundStyle(.secondary)
      .help(metrics.detailSummary)
      .accessibilityLabel(metrics.accessibilitySummary)
      .accessibilityIdentifier("chat.generationMetrics")
  }
}

private struct SentAttachmentList: View {
  let attachments: [ChatAttachment]

  var body: some View {
    VStack(alignment: .trailing, spacing: 4) {
      ForEach(attachments) { attachment in
        Label(attachment.displayName, systemImage: "doc.text")
          .font(.caption)
          .lineLimit(1)
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(Color.secondary.opacity(0.12))
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .help(attachment.displayPath)
      }
    }
  }
}

private struct MessageContentText: View {
  let item: ChatTurnItem
  let toolCallRecord: ToolCallRecord?
  let generationMetrics: ChatGenerationMetrics?
  let onApproveToolCall: (ToolCallRecord.ID) -> Void
  let onDenyToolCall: (ToolCallRecord.ID) -> Void

  @ViewBuilder
  var body: some View {
    switch item {
    case .toolCall:
      if let toolCallRecord {
        ToolCallSummaryView(
          toolCall: ToolCallModelMessage(request: toolCallRecord.request),
          toolCallRecord: toolCallRecord,
          generationMetrics: generationMetrics,
          onApprove: onApproveToolCall,
          onDeny: onDenyToolCall
        )
      }
    case .toolResult:
      if let toolCallRecord {
        ToolResultSummaryView(
          toolResult: ToolResultModelMessage(record: toolCallRecord),
          toolCallRecord: toolCallRecord,
          generationMetrics: generationMetrics
        )
      }
    case .assistantMessage(let message):
      AssistantMessageContent(message: message)
    case .userMessage(let message):
      Text(message.content)
    }
  }
}

private struct AssistantMessageContent: View {
  let message: AssistantTurnMessage

  private var blocks: [AssistantRenderBlock] {
    AssistantRenderBlockParser().parse(
      AssistantMarkdownPreprocessor.renderableContent(for: message.content)
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(blocks) { block in
        switch block {
        case .paragraph(let paragraph):
          Markdown(paragraph.text)
            .markdownTheme(.chatMessage)
        case .codeBlock(let codeBlock):
          CodeBlockView(codeBlock: codeBlock)
        }
      }
    }
  }
}

private struct CodeBlockView: View {
  let codeBlock: AssistantRenderBlock.CodeBlock

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let language = codeBlock.language, !language.isEmpty {
        Text(language)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.secondary.opacity(0.12))
      }

      ScrollView(.horizontal, showsIndicators: false) {
        Text(visibleCodeText)
          .font(.system(.body, design: .monospaced))
          .foregroundStyle(.primary)
          .textSelection(.enabled)
          .fixedSize(horizontal: true, vertical: false)
          .padding(10)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Color.secondary.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
    }
  }

  private var visibleCodeText: String {
    if codeBlock.text.isEmpty {
      return " "
    }
    return codeBlock.text
  }
}

extension Theme {
  static let chatMessage = Theme()
    .text {
      ForegroundColor(.primary)
      FontSize(13)
    }
    .code {
      FontFamilyVariant(.monospaced)
      FontSize(.em(0.92))
      ForegroundColor(.primary)
      BackgroundColor(.secondary.opacity(0.16))
    }
    .link {
      ForegroundColor(.accentColor)
      UnderlineStyle(.single)
    }
    .paragraph { configuration in
      configuration.label
        .relativeLineSpacing(.em(0.2))
        .markdownMargin(top: 0, bottom: 8)
    }
    .listItem { configuration in
      configuration.label
        .markdownMargin(top: 2, bottom: 2)
    }
    .blockquote { configuration in
      HStack(spacing: 0) {
        Rectangle()
          .fill(Color.secondary.opacity(0.45))
          .frame(width: 3)
        configuration.label
          .padding(.leading, 8)
          .markdownTextStyle {
            ForegroundColor(.secondary)
          }
      }
      .markdownMargin(top: 4, bottom: 8)
    }
    .codeBlock { configuration in
      ScrollView(.horizontal, showsIndicators: true) {
        configuration.label
          .markdownTextStyle {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
            BackgroundColor(nil)
          }
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .markdownMargin(top: 4, bottom: 8)
    }
}

extension ChatGenerationMetrics {
  var visibleSummary: String {
    return "\(generatedTokenCount) tokens · \(formattedDuration(durationMs))"
  }

  var detailSummary: String {
    "\(visibleSummary) · \(tokensPerSecond.formatted(.number.precision(.fractionLength(1)))) tokens/s"
  }

  var accessibilitySummary: String {
    return "\(generatedTokenCount) generated tokens in \(formattedDuration(durationMs))"
  }

  private func formattedDuration(_ durationMs: Double) -> String {
    let durationSeconds = durationMs / 1000
    if durationSeconds < 10 {
      return "\(durationSeconds.formatted(.number.precision(.fractionLength(1)))) s"
    }
    return "\(durationSeconds.formatted(.number.precision(.fractionLength(0)))) s"
  }
}

extension RenderedChatTurnItem {
  var messageBubbleBackground: Color {
    isDisplayedAsUser ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.12)
  }

  var stackSpacing: CGFloat {
    isToolItem ? 2 : 6
  }

  var contentPadding: CGFloat {
    isToolItem ? 6 : 10
  }

  var maximumBubbleWidth: CGFloat {
    isToolItem ? 520 : 680
  }

  var showsAuthorLabel: Bool {
    !isToolItem
  }

  fileprivate var accessibilityIdentifier: String {
    switch item {
    case .assistantMessage:
      "chat.assistantMessage"
    case .userMessage:
      "chat.userMessage"
    case .toolCall:
      "chat.toolCallMessage"
    case .toolResult:
      "chat.toolResultMessage"
    }
  }

  var isDisplayedAsUser: Bool {
    if case .userMessage = item {
      return true
    }
    return false
  }

  var displayTitle: String {
    switch item {
    case .userMessage:
      "You"
    case .assistantMessage, .toolCall, .toolResult:
      "Local Coder"
    }
  }

  var displaySystemImage: String {
    switch item {
    case .userMessage:
      "person.crop.circle"
    case .assistantMessage:
      "cpu"
    case .toolCall:
      "wrench.and.screwdriver"
    case .toolResult:
      "checkmark.circle"
    }
  }

  var shouldShowAssistantPlaceholder: Bool {
    assistantMessage?.shouldShowAssistantPlaceholder ?? false
  }

  var assistantPlaceholderTitle: String {
    assistantMessage?.assistantPlaceholderTitle ?? "Generating"
  }

  var assistantPlaceholderSystemImage: String {
    assistantMessage?.assistantPlaceholderSystemImage ?? "sparkles"
  }

  var visibleGenerationMetrics: ChatGenerationMetrics? {
    isToolItem ? nil : generationMetrics
  }

  var attachments: [ChatAttachment] {
    guard case .userMessage(let message) = item else {
      return []
    }
    return message.attachments
  }

  var canCopyMessageContent: Bool {
    switch item {
    case .userMessage(let message):
      !message.content.isEmpty
    case .assistantMessage(let message):
      message.canCopyAssistantContent
    case .toolCall, .toolResult:
      false
    }
  }

  var copyAccessibilityLabel: String {
    isDisplayedAsUser ? "Copy user message" : "Copy assistant message"
  }

  var content: String {
    switch item {
    case .userMessage(let message):
      message.content
    case .assistantMessage(let message):
      message.content
    case .toolCall, .toolResult:
      ""
    }
  }

  private var assistantMessage: AssistantTurnMessage? {
    guard case .assistantMessage(let message) = item else {
      return nil
    }
    return message
  }

  private var isToolItem: Bool {
    switch item {
    case .toolCall, .toolResult:
      true
    case .assistantMessage, .userMessage:
      false
    }
  }
}

extension ChatTurnItem {
  fileprivate var generationMetrics: ChatGenerationMetrics? {
    guard case .assistantMessage(let message) = self else {
      return nil
    }
    return message.generationMetrics
  }
}

extension ModelLoadState {
  fileprivate var accessibilityValue: String {
    switch self {
    case .notLoaded:
      "notLoaded"
    case .loading:
      "loading"
    case .ready:
      "ready"
    case .failed:
      "failed"
    }
  }
}
