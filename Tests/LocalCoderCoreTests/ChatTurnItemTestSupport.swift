import Foundation

@testable import LocalCoderCore

enum TranscriptItemKindForTesting {
  case user
  case assistant
  case toolCall
  case toolResult
}

struct TestTranscriptMessage: Equatable {
  var id: UUID
  var kind: TranscriptItemKindForTesting
  var content: String
  var attachments: [ChatAttachment]
  var generationMetrics: ChatGenerationMetrics?
  var deliveryStatus: AssistantTurnMessage.DeliveryStatus?
  var toolCall: ToolCallModelMessage?
  var toolResult: ToolResultModelMessage?

  init(
    id: UUID = UUID(),
    kind: TranscriptItemKindForTesting,
    content: String = "",
    attachments: [ChatAttachment] = [],
    generationMetrics: ChatGenerationMetrics? = nil,
    deliveryStatus: AssistantTurnMessage.DeliveryStatus? = nil,
    toolCall: ToolCallModelMessage? = nil,
    toolResult: ToolResultModelMessage? = nil
  ) {
    self.id = id
    self.kind = kind
    self.content = content
    self.attachments = attachments
    self.generationMetrics = generationMetrics
    self.deliveryStatus = deliveryStatus
    self.toolCall = toolCall
    self.toolResult = toolResult
  }

  init(
    id: UUID = UUID(),
    userContent: String,
    attachments: [ChatAttachment] = []
  ) {
    self.init(id: id, kind: .user, content: userContent, attachments: attachments)
  }

}

extension ChatSession {
  var transcriptItemsForTesting: [ChatTurnItem] {
    turns.flatMap(\.items)
  }

  var testMessages: [TestTranscriptMessage] {
    get {
      transcriptItemsForTesting.map { item in
        TestTranscriptMessage(
          id: item.messageID ?? UUID(),
          kind: item.kindForTesting,
          content: item.contentForTesting,
          attachments: item.attachmentsForTesting,
          generationMetrics: item.generationMetricsForTesting,
          deliveryStatus: item.deliveryStatusForTesting,
          toolCall: item.toolCallForTesting(records: toolCalls),
          toolResult: item.toolResultForTesting(records: toolCalls)
        )
      }
    }
    set {
      turns = [
        ChatTurn(
          status: .completed,
          items: newValue.map(\.turnItemForTesting)
        )
      ]
    }
  }
}

extension ChatTurnItem {
  var kindForTesting: TranscriptItemKindForTesting {
    switch self {
    case .userMessage:
      .user
    case .assistantMessage:
      .assistant
    case .toolCall:
      .toolCall
    case .toolResult:
      .toolResult
    }
  }

  var contentForTesting: String {
    switch self {
    case .userMessage(let message):
      message.content
    case .assistantMessage(let message):
      message.content
    case .toolCall, .toolResult:
      ""
    }
  }

  var attachmentsForTesting: [ChatAttachment] {
    switch self {
    case .userMessage(let message):
      message.attachments
    case .assistantMessage(let message):
      message.attachments
    case .toolCall, .toolResult:
      []
    }
  }

  var deliveryStatusForTesting: AssistantTurnMessage.DeliveryStatus? {
    guard case .assistantMessage(let message) = self else {
      return nil
    }
    return message.deliveryStatus
  }

  var generationMetricsForTesting: ChatGenerationMetrics? {
    guard case .assistantMessage(let message) = self else {
      return nil
    }
    return message.generationMetrics
  }

  func toolCallForTesting(records: [ToolCallRecord]) -> ToolCallModelMessage? {
    guard case .toolCall(let id) = self,
      let record = records.first(where: { $0.id == id })
    else {
      return nil
    }
    return ToolCallModelMessage(request: record.request)
  }

  func toolResultForTesting(records: [ToolCallRecord]) -> ToolResultModelMessage? {
    guard case .toolResult(let id) = self,
      let record = records.first(where: { $0.id == id }),
      let payload = record.resultPayload
    else {
      return nil
    }
    return ToolResultModelMessage(
      callID: id,
      toolName: record.request.raw.toolName,
      payload: payload
    )
  }
}

func testMessageID(from item: ChatTurnItem) -> UUID? {
  switch item {
  case .userMessage(let message):
    message.id
  case .assistantMessage(let message):
    message.id
  case .toolCall, .toolResult:
    nil
  }
}

extension TestTranscriptMessage {
  var turnItemForTesting: ChatTurnItem {
    switch kind {
    case .user:
      .userMessage(UserTurnMessage(id: id, content: content, attachments: attachments))
    case .assistant:
      .assistantMessage(
        AssistantTurnMessage(
          id: id,
          content: content,
          attachments: attachments,
          generationMetrics: generationMetrics,
          deliveryStatus: deliveryStatus ?? .complete
        ))
    case .toolCall:
      .toolCall(id)
    case .toolResult:
      .toolResult(id)
    }
  }
}
