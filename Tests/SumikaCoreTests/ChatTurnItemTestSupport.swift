import Foundation

@testable import SumikaCore

func testModeSettings(
  mode: WorkspaceInteractionMode = .chat,
  systemPrompt: String,
  generationSettings: ChatGenerationSettings
) -> ChatModeSettingsSet {
  var modeSettings = ChatModeSettingsSet.defaultSettings
  modeSettings[mode] = ChatModeSettings(
    systemPrompt: systemPrompt,
    generationSettings: generationSettings
  )
  return modeSettings
}

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
      transcriptItemsForTesting.filter { $0.isVisibleForTesting }.map { item in
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
  var isVisibleForTesting: Bool {
    switch self {
    case .assistantThinking(let message):
      message.deliveryStatus == .streaming || !message.content.isEmpty
    case .assistantMessage(let message):
      message.shouldShowAssistantPlaceholder || !message.content.isEmpty
    case .userMessage, .tool:
      true
    }
  }

  var kindForTesting: TranscriptItemKindForTesting {
    switch self {
    case .userMessage:
      .user
    case .assistantThinking:
      .assistant
    case .assistantMessage:
      .assistant
    case .tool(let record):
      record.resultPayload == nil ? .toolCall : .toolResult
    }
  }

  var contentForTesting: String {
    switch self {
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

  var attachmentsForTesting: [ChatAttachment] {
    switch self {
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
    guard case .tool(let record) = self else {
      return nil
    }
    _ = records
    return ToolCallModelMessage(request: record.request)
  }

  func toolResultForTesting(records: [ToolCallRecord]) -> ToolResultModelMessage? {
    guard case .tool(let record) = self,
      let payload = record.resultPayload
    else {
      return nil
    }
    _ = records
    return ToolResultModelMessage(
      callID: record.id,
      toolName: record.request.raw.toolName,
      payload: payload
    )
  }
}

func testMessageID(from item: ChatTurnItem) -> UUID? {
  switch item {
  case .userMessage(let message):
    message.id
  case .assistantThinking(let message):
    message.id
  case .assistantMessage(let message):
    message.id
  case .tool:
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
      .tool(makeTestingToolCallRecord(id: id, toolCall: toolCall, toolResult: nil))
    case .toolResult:
      .tool(makeTestingToolCallRecord(id: id, toolCall: toolCall, toolResult: toolResult))
    }
  }
}

private func makeTestingToolCallRecord(
  id: UUID,
  toolCall: ToolCallModelMessage?,
  toolResult: ToolResultModelMessage?
) -> ToolCallRecord {
  let toolName = toolCall?.toolName ?? toolResult?.toolName ?? .invalid
  let arguments = Dictionary(
    uniqueKeysWithValues: (toolCall?.arguments ?? []).map { argument in
      (argument.name, ToolArgumentValue.string(argument.value))
    }
  )
  let raw = RawToolCallRequest(
    id: id,
    workspaceID: UUID(),
    sessionID: UUID(),
    toolName: toolName,
    arguments: arguments,
    rawText: toolCall?.rawText
  )
  let request = ToolCallRequest.invalid(
    raw: raw,
    input: InvalidToolInput(
      originalName: toolName.rawValue,
      rawArguments: arguments,
      reason: .parserError("Synthetic testing tool record.")
    )
  )
  return ToolCallRecord(
    request: request,
    evaluation: ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Synthetic testing tool record.",
      riskLevel: .low
    ),
    state: toolResult.map { $0.completedState } ?? .pending
  )
}
