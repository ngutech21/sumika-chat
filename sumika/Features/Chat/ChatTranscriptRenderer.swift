import Foundation
import SumikaCore

@MainActor
final class ChatTranscriptRenderer {
  private let assistantBlocks: @MainActor (String) -> [AssistantRenderBlock]
  private var itemCache: [ChatTranscriptRenderItemKey: RenderedItemCacheEntry] = [:]
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
        let turnGenerationMetrics = turn.items.compactMap(\.generationMetrics).last
        let hidesAssistantPlaceholder = turn.hasStreamingAssistantThinking
        let toolBatchPresentations = ToolApprovalBatchPresentation.presentations(
          for: turn
        )

        for item in displayItems(for: turn) {
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
              toolBatchPresentation: nil
            )
            renderedItems.append(renderedItem(for: key, input: input))

          case .userMessage:
            activeItemKeys.insert(key)
            let input = RenderedItemCacheInput(
              item: item,
              generationMetrics: nil,
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

    TranscriptPerformanceDiagnostics.recordRenderedItemProjection(rowID: key.rawValue)
    let item = makeRenderedItem(id: key.rawValue, input: input)
    itemCache[key] = RenderedItemCacheEntry(input: input, item: item)
    return item
  }

  // Benchmark-only read model; normal transcript behavior does not depend on it.
  // swiftlint:disable:next unused_declaration
  func performanceCacheSnapshotForTesting()
    -> TranscriptPerformanceDiagnostics.RendererCacheSnapshot
  {
    TranscriptPerformanceDiagnostics.RendererCacheSnapshot(
      renderedItems: itemCache.count,
      assistantBlocks: assistantBlockCache.count,
      streamingBlocks: streamingBlockCache.count
    )
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
    input: RenderedItemCacheInput
  ) -> RenderedChatTurnItem {
    switch input.item {
    case .userMessage:
      return RenderedChatTurnItem(
        id: id,
        item: input.item,
        toolCallRecord: nil,
        generationMetrics: nil,
        assistantRenderBlocks: [],
        toolBatchPresentation: nil
      )

    case .assistantThinking:
      return RenderedChatTurnItem(
        id: id,
        item: input.item,
        toolCallRecord: nil,
        generationMetrics: nil,
        assistantRenderBlocks: [],
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
        toolCallRecord: nil,
        generationMetrics: input.generationMetrics,
        assistantRenderBlocks: blocks,
        assistantSpokenText: Self.spokenText(for: message, blocks: blocks),
        toolBatchPresentation: nil
      )

    case .tool(let record):
      return RenderedChatTurnItem(
        id: id,
        item: input.item,
        toolCallRecord: record,
        generationMetrics: input.generationMetrics,
        assistantRenderBlocks: [],
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

  // Streaming messages parse the raw content without the markdown
  // preprocessor: its code-wrapping heuristics are not stable under appends
  // and would make the rendering flip mid-stream. Content grows append-only,
  // so all blocks before the last one are immutable and only the tail is
  // reparsed per flush.
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

  static func presentations(
    for turn: ChatTurn
  ) -> [ToolCallRecord.ID: ToolApprovalBatchPresentation] {
    var presentations: [ToolCallRecord.ID: ToolApprovalBatchPresentation] = [:]
    var visitedAnchorIDs = Set<ToolCallRecord.ID>()

    for item in turn.items {
      guard case .tool(let record) = item,
        let batch = turn.toolCallBatch(containing: record.id),
        visitedAnchorIDs.insert(batch.anchorID).inserted
      else {
        continue
      }
      let pendingRecords = batch.pendingApprovalRecords
      guard pendingRecords.count >= 2, let firstPendingID = pendingRecords.first?.id else {
        continue
      }

      for batchRecord in batch.records {
        presentations[batchRecord.id] = ToolApprovalBatchPresentation(
          anchorID: batch.anchorID,
          pendingApprovalCount: pendingRecords.count,
          showsApproveAll: batchRecord.id == firstPendingID
        )
      }
    }
    return presentations
  }
}

struct RenderedChatTurnItem: Identifiable, Equatable {
  let id: String
  let item: ChatTurnItem
  let toolCallRecord: ToolCallRecord?
  let generationMetrics: ChatGenerationMetrics?
  let assistantRenderBlocks: [AssistantRenderBlock]
  let assistantSpokenText: String?
  let toolBatchPresentation: ToolApprovalBatchPresentation?
  // Stored, not computed: rows() reads the revision for every item on every
  // updateNSView pass (~20x/s while streaming). All fields are immutable and
  // the renderer only creates new items when their content changed, so hashing
  // once per creation replaces rehashing the whole transcript per flush.
  let renderRevision: Int

  init(
    id: String,
    item: ChatTurnItem,
    toolCallRecord: ToolCallRecord?,
    generationMetrics: ChatGenerationMetrics?,
    assistantRenderBlocks: [AssistantRenderBlock],
    assistantSpokenText: String? = nil,
    toolBatchPresentation: ToolApprovalBatchPresentation? = nil
  ) {
    self.id = id
    self.item = item
    self.toolCallRecord = toolCallRecord
    self.generationMetrics = generationMetrics
    self.assistantRenderBlocks = assistantRenderBlocks
    self.assistantSpokenText = assistantSpokenText
    self.toolBatchPresentation = toolBatchPresentation
    renderRevision = Self.computeRenderRevision(
      id: id,
      item: item,
      generationMetrics: generationMetrics,
      assistantRenderBlocks: assistantRenderBlocks,
      toolBatchPresentation: toolBatchPresentation
    )
  }

  private static func computeRenderRevision(
    id: String,
    item: ChatTurnItem,
    generationMetrics: ChatGenerationMetrics?,
    assistantRenderBlocks: [AssistantRenderBlock],
    toolBatchPresentation: ToolApprovalBatchPresentation?
  ) -> Int {
    var hasher = Hasher()
    hasher.combine(id)
    hasher.combine(generationMetrics?.generatedTokenCount)
    hasher.combine(generationMetrics?.tokensPerSecond)
    hasher.combine(generationMetrics?.durationMs)
    hasher.combine(toolBatchPresentation?.anchorID)
    hasher.combine(toolBatchPresentation?.pendingApprovalCount)
    hasher.combine(toolBatchPresentation?.showsApproveAll)

    switch item {
    case .userMessage(let message):
      hasher.combine("user")
      hasher.combine(message.content)
      hasher.combineAttachmentRevision(message.attachments)

    case .assistantThinking(let message):
      hasher.combine("thinking")
      hasher.combine(message.content)
      hasher.combine(message.deliveryStatus.rawValue)

    case .assistantMessage(let message):
      hasher.combine("assistant")
      hasher.combine(message.content)
      hasher.combine(message.deliveryStatus.rawValue)
      hasher.combineAttachmentRevision(message.attachments)
      for block in assistantRenderBlocks {
        hasher.combine(block.id.rawValue)
        switch block {
        case .paragraph(let paragraph):
          hasher.combine("paragraph")
          hasher.combine(paragraph.text)
        case .codeBlock(let codeBlock):
          hasher.combine("code")
          hasher.combine(codeBlock.language)
          hasher.combine(codeBlock.text)
          hasher.combine(codeBlock.isClosed)
        }
      }

    case .tool(let record):
      hasher.combine("tool")
      hasher.combine(record.status.rawValue)
      hasher.combine(record.request.toolName.rawValue)
      hasher.combine(record.request.raw.originalToolName)
      for argument in record.request.rawArguments.sorted(by: { $0.key < $1.key }) {
        hasher.combine(argument.key)
        hasher.combine(argument.value.displayValue)
      }
      hasher.combine(record.approvalPreview?.status.rawValue)
      hasher.combine(record.approvalPreview?.text)
      hasher.combine(record.approvalPreview?.truncated)
      hasher.combine(record.approvalPreview?.redacted)
      hasher.combine(record.approvalPreview?.affectedPaths.joined(separator: "\n"))
      hasher.combine(record.resultPreview?.status.rawValue)
      hasher.combine(record.resultPreview?.text)
      hasher.combine(record.resultPreview?.truncated)
      hasher.combine(record.resultPreview?.redacted)
      hasher.combine(record.resultPreview?.affectedPaths.joined(separator: "\n"))
      hasher.combine(record.resultPayload?.text)
      hasher.combine(record.resultPayload?.status.rawValue)
    }

    return hasher.finalize()
  }

}

extension Hasher {
  fileprivate mutating func combineAttachmentRevision(_ attachments: [ChatAttachment]) {
    for attachment in attachments {
      combine(attachment.id)
      combine(attachment.displayName)
      combine(attachment.kind.rawValue)
      combine(attachment.byteSize)
      combine(attachment.contentSignature)
      combine(attachment.mimeType)
    }
  }
}

private struct RenderedItemCacheEntry {
  let input: RenderedItemCacheInput
  let item: RenderedChatTurnItem
}

private struct RenderedItemCacheInput: Equatable {
  let item: ChatTurnItem
  let generationMetrics: ChatGenerationMetrics?
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
    return shouldShowAssistantPlaceholder || !content.isEmpty
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
