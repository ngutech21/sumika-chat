import AppKit
import SumikaCore

// Render-model value types for the AppKit transcript: the row/kind model,
// diff plan, height cache and row measurer, per-row and coordinator cell
// state, the tool-detail projection, and the cell action closures. These are
// pure/data types (plus small measurement helpers) consumed by the coordinator
// and cell; split out of AppKitChatTranscriptRepresentable.

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
  var telemetryLengthBucket: String {
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
  var telemetryRangeSummary: String {
    guard let first, let last else {
      return "none"
    }
    return count == 1 ? "\(first)" : "\(first)..<\(last + 1)"
  }
}

extension Array where Element == String {
  var telemetryIDListSummary: String {
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
