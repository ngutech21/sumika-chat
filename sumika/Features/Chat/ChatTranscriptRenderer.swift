import Foundation
import SumikaCore

@MainActor
final class ChatTranscriptRenderer {
  private let assistantBlocks: @MainActor (String) -> [AssistantRenderBlock]
  private var itemCache: [ChatTranscriptRenderItemKey: RenderedItemCacheEntry] = [:]
  private var assistantBlockCache: [AssistantTurnMessage.ID: AssistantBlockCacheEntry] = [:]

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
    var renderedItems: [RenderedChatTurnItem] = []
    var activeItemKeys = Set<ChatTranscriptRenderItemKey>()
    var activeAssistantIDs = Set<AssistantTurnMessage.ID>()

    for turn in turns {
      let turnGenerationMetrics = turn.items.compactMap(\.generationMetrics).last

      for item in turn.items {
        if case .assistantMessage(let message) = item {
          activeAssistantIDs.insert(message.id)
        }

        let key = ChatTranscriptRenderItemKey(turnID: turn.id, item: item)

        switch item {
        case .assistantMessage(let message):
          guard message.shouldRenderInTranscript else {
            continue
          }
          activeItemKeys.insert(key)
          let input = RenderedItemCacheInput(
            item: item, generationMetrics: message.generationMetrics)
          renderedItems.append(renderedItem(for: key, input: input))

        case .userMessage:
          activeItemKeys.insert(key)
          let input = RenderedItemCacheInput(item: item, generationMetrics: nil)
          renderedItems.append(renderedItem(for: key, input: input))

        case .tool:
          activeItemKeys.insert(key)
          let input = RenderedItemCacheInput(item: item, generationMetrics: turnGenerationMetrics)
          renderedItems.append(renderedItem(for: key, input: input))
        }
      }
    }

    pruneCaches(activeItemKeys: activeItemKeys, activeAssistantIDs: activeAssistantIDs)
    return renderedItems
  }

  private func renderedItem(
    for key: ChatTranscriptRenderItemKey,
    input: RenderedItemCacheInput
  ) -> RenderedChatTurnItem {
    if let cached = itemCache[key], cached.input == input {
      return cached.item
    }

    let item = makeRenderedItem(id: key.rawValue, input: input)
    itemCache[key] = RenderedItemCacheEntry(input: input, item: item)
    return item
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
        assistantRenderBlocks: []
      )

    case .assistantMessage(let message):
      return RenderedChatTurnItem(
        id: id,
        item: input.item,
        toolCallRecord: nil,
        generationMetrics: input.generationMetrics,
        assistantRenderBlocks: blocks(for: message)
      )

    case .tool(let record):
      return RenderedChatTurnItem(
        id: id,
        item: input.item,
        toolCallRecord: record,
        generationMetrics: input.generationMetrics,
        assistantRenderBlocks: []
      )
    }
  }

  private func blocks(for message: AssistantTurnMessage) -> [AssistantRenderBlock] {
    if let cached = assistantBlockCache[message.id],
      cached.content == message.content
    {
      return cached.blocks
    }

    let blocks = assistantBlocks(message.content)
    assistantBlockCache[message.id] = AssistantBlockCacheEntry(
      content: message.content, blocks: blocks)
    return blocks
  }

  private func pruneCaches(
    activeItemKeys: Set<ChatTranscriptRenderItemKey>,
    activeAssistantIDs: Set<AssistantTurnMessage.ID>
  ) {
    itemCache = itemCache.filter { activeItemKeys.contains($0.key) }
    assistantBlockCache = assistantBlockCache.filter { activeAssistantIDs.contains($0.key) }
  }
}

struct RenderedChatTurnItem: Identifiable, Equatable {
  let id: String
  let item: ChatTurnItem
  let toolCallRecord: ToolCallRecord?
  let generationMetrics: ChatGenerationMetrics?
  let assistantRenderBlocks: [AssistantRenderBlock]

  var renderRevision: Int {
    var hasher = Hasher()
    hasher.combine(id)
    hasher.combine(generationMetrics?.generatedTokenCount)
    hasher.combine(generationMetrics?.tokensPerSecond)
    hasher.combine(generationMetrics?.durationMs)

    switch item {
    case .userMessage(let message):
      hasher.combine("user")
      hasher.combine(message.content)
      hasher.combineAttachmentRevision(message.attachments)

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
      hasher.combine(record.request.raw.rawText)
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

  var scrollRevision: Int {
    renderRevision
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
}

private struct AssistantBlockCacheEntry {
  let content: String
  let blocks: [AssistantRenderBlock]
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
    case assistantMessage = "assistant"
    case tool = "tool"
  }
}

extension ToolCallStatus {
  fileprivate var scrollRevision: Int {
    switch self {
    case .pending:
      0
    case .awaitingApproval:
      1
    case .awaitingUserAnswer:
      2
    case .denied:
      3
    case .running:
      4
    case .completed:
      5
    case .failed:
      6
    case .cancelled:
      7
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

extension AssistantTurnMessage {
  fileprivate var shouldRenderInTranscript: Bool {
    shouldShowAssistantPlaceholder || !content.isEmpty
  }
}
