import Foundation
import SumikaCore

@MainActor
final class ChatTranscriptRenderer {
  private let assistantBlocks: @MainActor (String) -> [AssistantRenderBlock]
  private var itemCache: [ChatTranscriptRenderItemKey: RenderedItemCacheEntry] = [:]
  private var nextRenderRevision = 0
  private var assistantBlockCache: [AssistantTurnMessage.ID: AssistantBlockCacheEntry] = [:]
  private var streamingBlockCache: [AssistantTurnMessage.ID: StreamingBlockCacheEntry] = [:]

  init(
    assistantBlocks: @escaping @MainActor (String) -> [AssistantRenderBlock] = {
      AssistantMessageRenderBlocks.blocks(for: $0)
    }
  ) {
    self.assistantBlocks = assistantBlocks
  }

  func items(
    for turns: [ChatTurn]
  ) -> [RenderedChatTurnItem] {
    ChatDiagnostics.measure("Transcript render items", category: .transcript) {
      var renderedItems: [RenderedChatTurnItem] = []
      var activeItemKeys = Set<ChatTranscriptRenderItemKey>()
      var activeAssistantIDs = Set<AssistantTurnMessage.ID>()
      var activeStreamingAssistantIDs = Set<AssistantTurnMessage.ID>()

      for turn in turns {
        let displayItems = displayItems(for: turn)
        let turnGenerationMetrics = turn.items.compactMap(\.generationMetrics).last
        let hidesAssistantPlaceholder = turn.hasStreamingAssistantThinking
        let completedDuration = turn.completedDuration
        let durationAssistantMessageID = completedDuration.flatMap { _ in
          displayItems.reversed().compactMap { item -> AssistantTurnMessage.ID? in
            guard case .assistantMessage(let message) = item,
              message.shouldRenderInTranscript(
                hidesPlaceholderForStreamingReasoning: hidesAssistantPlaceholder
              )
            else {
              return nil
            }
            return message.id
          }.first
        }
        let toolBatchPresentations = ToolApprovalBatchPresentation.presentations(
          for: turn
        )

        for item in displayItems {
          if case .assistantMessage(let message) = item {
            activeAssistantIDs.insert(message.id)
            if message.deliveryStatus == .streaming {
              activeStreamingAssistantIDs.insert(message.id)
            }
          }

          let key = ChatTranscriptRenderItemKey(turnID: turn.id, item: item)

          switch item {
          case .assistantThinking(let message):
            guard message.shouldRenderInTranscript else {
              continue
            }
            activeItemKeys.insert(key)
            let input = RenderedItemCacheInput(
              item: item,
              generationMetrics: nil,
              totalDuration: nil,
              toolBatchPresentation: nil
            )
            renderedItems.append(renderedItem(for: key, input: input))

          case .assistantMessage(let message):
            guard
              message.shouldRenderInTranscript(
                hidesPlaceholderForStreamingReasoning: hidesAssistantPlaceholder
              )
            else {
              continue
            }
            activeItemKeys.insert(key)
            let input = RenderedItemCacheInput(
              item: item,
              generationMetrics: message.generationMetrics,
              totalDuration: message.id == durationAssistantMessageID ? completedDuration : nil,
              toolBatchPresentation: nil
            )
            renderedItems.append(renderedItem(for: key, input: input))

          case .userMessage:
            activeItemKeys.insert(key)
            let input = RenderedItemCacheInput(
              item: item,
              generationMetrics: nil,
              totalDuration: nil,
              toolBatchPresentation: nil
            )
            renderedItems.append(renderedItem(for: key, input: input))

          case .tool(let record):
            guard !record.isSuccessfulFinishTask else {
              continue
            }
            activeItemKeys.insert(key)
            let input = RenderedItemCacheInput(
              item: item,
              generationMetrics: turnGenerationMetrics,
              totalDuration: nil,
              toolBatchPresentation: toolBatchPresentations[record.id]
            )
            renderedItems.append(renderedItem(for: key, input: input))
          }
        }
      }

      pruneCaches(
        activeItemKeys: activeItemKeys,
        activeAssistantIDs: activeAssistantIDs,
        activeStreamingAssistantIDs: activeStreamingAssistantIDs
      )
      return renderedItems
    }
  }

  private func renderedItem(
    for key: ChatTranscriptRenderItemKey,
    input: RenderedItemCacheInput
  ) -> RenderedChatTurnItem {
    if let cached = itemCache[key], cached.input == input {
      return cached.item
    }

    let renderRevision = nextRenderRevision
    nextRenderRevision += 1
    let item = makeRenderedItem(
      id: key.rawValue,
      input: input,
      renderRevision: renderRevision
    )
    itemCache[key] = RenderedItemCacheEntry(input: input, item: item)
    return item
  }

  private func displayItems(for turn: ChatTurn) -> [ChatTurnItem] {
    var orderedItems: [ChatTurnItem] = []
    var currentBoundaryStartIndex = 0

    for item in turn.items {
      switch item {
      case .assistantThinking:
        if let assistantIndex = orderedItems[currentBoundaryStartIndex...].lastIndex(where: {
          if case .assistantMessage = $0 {
            return true
          }
          return false
        }) {
          orderedItems.insert(item, at: assistantIndex)
        } else {
          orderedItems.append(item)
        }
      case .assistantMessage:
        orderedItems.append(item)
      case .userMessage, .tool:
        orderedItems.append(item)
        currentBoundaryStartIndex = orderedItems.count
      }
    }

    return orderedItems
  }

  private func makeRenderedItem(
    id: String,
    input: RenderedItemCacheInput,
    renderRevision: Int
  ) -> RenderedChatTurnItem {
    switch input.item {
    case .userMessage:
      return RenderedChatTurnItem(
        id: id,
        item: input.item,
        generationMetrics: nil,
        totalDuration: nil,
        assistantRenderBlocks: [],
        renderRevision: renderRevision,
        toolBatchPresentation: nil
      )

    case .assistantThinking:
      return RenderedChatTurnItem(
        id: id,
        item: input.item,
        generationMetrics: nil,
        totalDuration: nil,
        assistantRenderBlocks: [],
        renderRevision: renderRevision,
        toolBatchPresentation: nil
      )

    case .assistantMessage(let message):
      let blocks =
        message.deliveryStatus == .streaming
        ? streamingBlocks(for: message)
        : blocks(for: message)
      return RenderedChatTurnItem(
        id: id,
        item: input.item,
        generationMetrics: input.generationMetrics,
        totalDuration: input.totalDuration,
        assistantRenderBlocks: blocks,
        assistantSpokenText: Self.spokenText(for: message, blocks: blocks),
        renderRevision: renderRevision,
        toolBatchPresentation: nil
      )

    case .tool:
      return RenderedChatTurnItem(
        id: id,
        item: input.item,
        generationMetrics: input.generationMetrics,
        totalDuration: nil,
        assistantRenderBlocks: [],
        renderRevision: renderRevision,
        toolBatchPresentation: input.toolBatchPresentation
      )
    }
  }

  private func blocks(for message: AssistantTurnMessage) -> [AssistantRenderBlock] {
    if let cached = assistantBlockCache[message.id],
      cached.content == message.content
    {
      return cached.blocks
    }

    let blocks = ChatDiagnostics.measure("Transcript assistant blocks", category: .transcript) {
      assistantBlocks(message.content)
    }
    assistantBlockCache[message.id] = AssistantBlockCacheEntry(
      content: message.content, blocks: blocks)
    return blocks
  }

  // Streaming messages parse raw content without final presentation
  // classification. Content grows append-only, so all blocks before the last
  // one are immutable and only the tail is reparsed per flush.
  private func streamingBlocks(for message: AssistantTurnMessage) -> [AssistantRenderBlock] {
    if let cached = streamingBlockCache[message.id], cached.content == message.content {
      return cached.blocks
    }

    let parser = AssistantRenderBlockParser()
    let blocks: [AssistantRenderBlock]
    let lastBlockUTF16Offset: Int?
    if let cached = streamingBlockCache[message.id],
      let resumeOffset = cached.lastBlockUTF16Offset,
      !cached.blocks.isEmpty,
      message.content.hasPrefix(cached.content)
    {
      let tail = parser.parseTail(
        of: message.content,
        fromUTF16Offset: resumeOffset,
        nextBlockOrdinal: cached.blocks.count - 1
      )
      blocks = Array(cached.blocks.dropLast()) + tail.blocks
      lastBlockUTF16Offset = tail.lastBlockUTF16Offset ?? resumeOffset
    } else {
      let parse = parser.parseTail(of: message.content, fromUTF16Offset: 0, nextBlockOrdinal: 0)
      blocks = parse.blocks
      lastBlockUTF16Offset = parse.lastBlockUTF16Offset
    }

    streamingBlockCache[message.id] = StreamingBlockCacheEntry(
      content: message.content,
      blocks: blocks,
      lastBlockUTF16Offset: lastBlockUTF16Offset
    )
    return blocks
  }

  private func pruneCaches(
    activeItemKeys: Set<ChatTranscriptRenderItemKey>,
    activeAssistantIDs: Set<AssistantTurnMessage.ID>,
    activeStreamingAssistantIDs: Set<AssistantTurnMessage.ID>
  ) {
    itemCache = itemCache.filter { activeItemKeys.contains($0.key) }
    assistantBlockCache = assistantBlockCache.filter { activeAssistantIDs.contains($0.key) }
    streamingBlockCache = streamingBlockCache.filter {
      activeStreamingAssistantIDs.contains($0.key)
    }
  }

  private static func spokenText(
    for message: AssistantTurnMessage,
    blocks: [AssistantRenderBlock]
  ) -> String? {
    guard message.deliveryStatus == .complete else {
      return nil
    }

    let paragraphs: [String]
    if blocks.isEmpty {
      paragraphs = [message.content]
    } else {
      paragraphs = blocks.compactMap { block in
        guard case .paragraph(let paragraph) = block else {
          return nil
        }
        return paragraph.text
      }
    }

    let text =
      paragraphs
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")

    return text.isEmpty ? nil : text
  }
}

struct ToolApprovalBatchPresentation: Equatable {
  let anchorID: ToolCallRecord.ID
  let pendingApprovalCount: Int
  let showsApproveAll: Bool
  let approvalGroupCount: Int
  let showsApprovalActions: Bool

  var showsResumeAutomation: Bool {
    showsApproveAll
      || (showsApprovalActions && approvalGroupCount == pendingApprovalCount)
  }

  init(
    anchorID: ToolCallRecord.ID,
    pendingApprovalCount: Int,
    showsApproveAll: Bool,
    approvalGroupCount: Int = 1,
    showsApprovalActions: Bool = true
  ) {
    self.anchorID = anchorID
    self.pendingApprovalCount = pendingApprovalCount
    self.showsApproveAll = showsApproveAll
    self.approvalGroupCount = approvalGroupCount
    self.showsApprovalActions = showsApprovalActions
  }

  static func presentations(
    for turn: ChatTurn
  ) -> [ToolCallRecord.ID: ToolApprovalBatchPresentation] {
    var presentations: [ToolCallRecord.ID: ToolApprovalBatchPresentation] = [:]

    for batch in turn.toolCallBatches {
      let pendingRecords = batch.pendingApprovalRecords
      guard let firstPendingID = pendingRecords.first?.id else {
        continue
      }

      for batchRecord in batch.records {
        let approvalGroup = batch.pendingApprovalGroup(containing: batchRecord.id)
        let isOnlyAtomicGroup =
          approvalGroup?.isAtomicSameFileEdit == true
          && approvalGroup?.records.count == pendingRecords.count
        presentations[batchRecord.id] = ToolApprovalBatchPresentation(
          anchorID: batch.anchorID,
          pendingApprovalCount: pendingRecords.count,
          showsApproveAll: pendingRecords.count >= 2
            && batchRecord.id == firstPendingID
            && !isOnlyAtomicGroup,
          approvalGroupCount: approvalGroup?.records.count ?? 1,
          showsApprovalActions: approvalGroup.map { group in
            !group.isAtomicSameFileEdit || group.anchorID == batchRecord.id
          } ?? true
        )
      }
    }
    return presentations
  }
}

struct RenderedChatTurnItem: Identifiable, Equatable {
  let id: String
  let item: ChatTurnItem
  let generationMetrics: ChatGenerationMetrics?
  let totalDuration: TimeInterval?
  let assistantRenderBlocks: [AssistantRenderBlock]
  let assistantSpokenText: String?
  let toolBatchPresentation: ToolApprovalBatchPresentation?
  let renderRevision: Int

  init(
    id: String,
    item: ChatTurnItem,
    generationMetrics: ChatGenerationMetrics?,
    totalDuration: TimeInterval? = nil,
    assistantRenderBlocks: [AssistantRenderBlock],
    assistantSpokenText: String? = nil,
    renderRevision: Int,
    toolBatchPresentation: ToolApprovalBatchPresentation? = nil
  ) {
    self.id = id
    self.item = item
    self.generationMetrics = generationMetrics
    self.totalDuration = totalDuration
    self.assistantRenderBlocks = assistantRenderBlocks
    self.assistantSpokenText = assistantSpokenText
    self.renderRevision = renderRevision
    self.toolBatchPresentation = toolBatchPresentation
  }
}

private struct RenderedItemCacheEntry {
  let input: RenderedItemCacheInput
  let item: RenderedChatTurnItem
}

private struct RenderedItemCacheInput: Equatable {
  let item: ChatTurnItem
  let generationMetrics: ChatGenerationMetrics?
  let totalDuration: TimeInterval?
  let toolBatchPresentation: ToolApprovalBatchPresentation?
}

private struct AssistantBlockCacheEntry {
  let content: String
  let blocks: [AssistantRenderBlock]
}

private struct StreamingBlockCacheEntry {
  let content: String
  let blocks: [AssistantRenderBlock]
  let lastBlockUTF16Offset: Int?
}

private struct ChatTranscriptRenderItemKey: Hashable {
  let turnID: ChatTurn.ID
  let kind: Kind
  let itemID: UUID

  var rawValue: String {
    "\(turnID.uuidString):\(kind.rawValue):\(itemID.uuidString)"
  }

  init(turnID: ChatTurn.ID, item: ChatTurnItem) {
    self.turnID = turnID
    switch item {
    case .userMessage(let message):
      kind = .userMessage
      itemID = message.id
    case .assistantThinking(let message):
      kind = .assistantThinking
      itemID = message.id
    case .assistantMessage(let message):
      kind = .assistantMessage
      itemID = message.id
    case .tool(let record):
      kind = .tool
      itemID = record.id
    }
  }

  enum Kind: String {
    case userMessage = "user"
    case assistantThinking = "thinking"
    case assistantMessage = "assistant"
    case tool = "tool"
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

extension ChatTurn {
  fileprivate var hasStreamingAssistantThinking: Bool {
    items.contains { item in
      guard case .assistantThinking(let message) = item else {
        return false
      }
      return message.deliveryStatus == .streaming
    }
  }
}

extension AssistantThinkingMessage {
  fileprivate var shouldRenderInTranscript: Bool {
    deliveryStatus == .streaming || !content.isEmpty
  }
}

extension AssistantTurnMessage {
  fileprivate func shouldRenderInTranscript(
    hidesPlaceholderForStreamingReasoning: Bool = false
  ) -> Bool {
    if hidesPlaceholderForStreamingReasoning, shouldShowAssistantPlaceholder {
      return false
    }
    return shouldShowAssistantPlaceholder
      || !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

extension ToolCallRecord {
  fileprivate var isSuccessfulFinishTask: Bool {
    guard request.toolName == .finishTask,
      case .finishTask = request.payload,
      status == .completed,
      case .finishTask(.success) = resultPayload
    else {
      return false
    }
    return true
  }
}
