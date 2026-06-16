import Foundation

public struct ChatTurn: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public internal(set) var events: [ChatTurnEvent]
  public var createdAt: Date
  public var updatedAt: Date {
    events.last?.timestamp ?? createdAt
  }

  public var status: ChatTurnStatus {
    events.reversed().compactMap(\.turnStatus).first ?? .running
  }

  public var modelContextPolicy: ChatTurnModelContextPolicy {
    events.reversed().compactMap(\.modelContextPolicy).first ?? .included
  }

  public var items: [ChatTurnItem] {
    ChatTranscriptProjector.items(from: events)
  }

  public init(
    id: UUID = UUID(),
    status: ChatTurnStatus,
    modelContextPolicy: ChatTurnModelContextPolicy = .included,
    items: [ChatTurnItem] = [],
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.createdAt = createdAt
    var events = items.map { item in
      ChatTurnEvent(
        timestamp: createdAt,
        payload: .transcriptItemAppended(item)
      )
    }
    events.append(
      ChatTurnEvent(
        timestamp: updatedAt,
        payload: .turnStatusChanged(
          TurnStatusChangedEvent(status: status, modelContextPolicy: modelContextPolicy)
        )
      ))
    self.events = events
  }

  public init(
    id: UUID = UUID(),
    events: [ChatTurnEvent] = [],
    createdAt: Date = Date()
  ) {
    self.id = id
    self.events = events
    self.createdAt = createdAt
  }

  mutating func appendEvent(_ event: ChatTurnEvent) {
    events.append(event)
  }
}

public struct ChatTurnEvent: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public var timestamp: Date
  public var payload: ChatTurnEventPayload

  public init(
    id: UUID = UUID(),
    timestamp: Date = Date(),
    payload: ChatTurnEventPayload
  ) {
    self.id = id
    self.timestamp = timestamp
    self.payload = payload
  }
}

public enum ChatTurnEventPayload: Codable, Equatable, Sendable {
  case transcriptItemAppended(ChatTurnItem)
  case assistantChunkAppended(AssistantChunkAppendedEvent)
  case assistantContentReplaced(AssistantContentReplacedEvent)
  case assistantDeliveryStatusUpdated(AssistantDeliveryStatusUpdatedEvent)
  case assistantGenerationMetricsUpdated(AssistantGenerationMetricsUpdatedEvent)
  case messageRemoved(MessageRemovedEvent)
  case transientAssistantPlaceholdersRemoved
  case streamingAssistantMessagesCancelled
  case toolCallRecorded(ToolCallRecord)
  case toolCallUpdated(ToolCallRecord)
  case assistantMessageAnnotatedAsToolCall(AssistantToolCallAnnotationEvent)
  case toolResultAppended(ToolResultModelMessage)
  case turnStatusChanged(TurnStatusChangedEvent)
}

public struct AssistantChunkAppendedEvent: Codable, Equatable, Sendable {
  public var messageID: UUID
  public var chunk: String

  public init(messageID: UUID, chunk: String) {
    self.messageID = messageID
    self.chunk = chunk
  }
}

public struct AssistantContentReplacedEvent: Codable, Equatable, Sendable {
  public var messageID: UUID
  public var content: String

  public init(messageID: UUID, content: String) {
    self.messageID = messageID
    self.content = content
  }
}

public struct AssistantDeliveryStatusUpdatedEvent: Codable, Equatable, Sendable {
  public var messageID: UUID
  public var status: AssistantTurnMessage.DeliveryStatus

  public init(messageID: UUID, status: AssistantTurnMessage.DeliveryStatus) {
    self.messageID = messageID
    self.status = status
  }
}

public struct AssistantGenerationMetricsUpdatedEvent: Codable, Equatable, Sendable {
  public var messageID: UUID
  public var metrics: ChatGenerationMetrics?

  public init(messageID: UUID, metrics: ChatGenerationMetrics?) {
    self.messageID = messageID
    self.metrics = metrics
  }
}

public struct MessageRemovedEvent: Codable, Equatable, Sendable {
  public var messageID: UUID

  public init(messageID: UUID) {
    self.messageID = messageID
  }
}

public struct AssistantToolCallAnnotationEvent: Codable, Equatable, Sendable {
  public var messageID: UUID
  public var toolCallID: ToolCallRecord.ID

  public init(messageID: UUID, toolCallID: ToolCallRecord.ID) {
    self.messageID = messageID
    self.toolCallID = toolCallID
  }
}

public struct TurnStatusChangedEvent: Codable, Equatable, Sendable {
  public var status: ChatTurnStatus
  public var modelContextPolicy: ChatTurnModelContextPolicy?

  public init(
    status: ChatTurnStatus,
    modelContextPolicy: ChatTurnModelContextPolicy? = nil
  ) {
    self.status = status
    self.modelContextPolicy = modelContextPolicy
  }
}

public enum ChatTurnItem: Codable, Equatable, Sendable {
  case userMessage(UserTurnMessage)
  case assistantMessage(AssistantTurnMessage)
  case toolCall(ToolCallRecord.ID)
  case toolResult(ToolCallRecord.ID)
}

public struct UserTurnMessage: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public var content: String
  public var attachments: [ChatAttachment]

  public init(
    id: UUID = UUID(),
    content: String,
    attachments: [ChatAttachment] = []
  ) {
    self.id = id
    self.content = content
    self.attachments = attachments
  }
}

nonisolated extension ChatTurnEvent {
  var turnStatus: ChatTurnStatus? {
    guard case .turnStatusChanged(let event) = payload else {
      return nil
    }
    return event.status
  }

  var modelContextPolicy: ChatTurnModelContextPolicy? {
    guard case .turnStatusChanged(let event) = payload else {
      return nil
    }
    return event.modelContextPolicy
  }
}

public enum ChatTranscriptProjector {
  public static func items(from turns: [ChatTurn]) -> [ChatTurnItem] {
    turns.flatMap(\.items)
  }

  public static func items(from events: [ChatTurnEvent]) -> [ChatTurnItem] {
    var items: [ChatTurnItem] = []

    for event in events {
      switch event.payload {
      case .transcriptItemAppended(let item):
        items.append(item)
      case .assistantChunkAppended(let update):
        updateAssistantMessage(update.messageID, in: &items) { message in
          var message = message
          message.content += update.chunk
          return message
        }
      case .assistantContentReplaced(let update):
        updateAssistantMessage(update.messageID, in: &items) { message in
          var message = message
          message.content = update.content
          message.deliveryStatus = .complete
          return message
        }
      case .assistantDeliveryStatusUpdated(let update):
        updateAssistantMessage(update.messageID, in: &items) { message in
          var message = message
          message.deliveryStatus = update.status
          return message
        }
      case .assistantGenerationMetricsUpdated(let update):
        updateAssistantMessage(update.messageID, in: &items) { message in
          var message = message
          message.generationMetrics = update.metrics
          return message
        }
      case .messageRemoved(let removal):
        items.removeAll { $0.messageID == removal.messageID }
      case .transientAssistantPlaceholdersRemoved:
        items.removeAll { item in
          guard case .assistantMessage(let message) = item else {
            return false
          }
          return message.content.isEmpty && message.deliveryStatus == .streaming
        }
      case .streamingAssistantMessagesCancelled:
        items = items.map { item in
          guard case .assistantMessage(var message) = item,
            message.deliveryStatus == .streaming,
            !message.content.isEmpty
          else {
            return item
          }
          message.deliveryStatus = .cancelled
          return .assistantMessage(message)
        }
      case .assistantMessageAnnotatedAsToolCall(let annotation):
        replaceItem(
          matchingMessageID: annotation.messageID,
          with: .toolCall(annotation.toolCallID),
          in: &items
        )
      case .toolCallRecorded:
        break
      case .toolResultAppended(let toolResult):
        items.append(.toolResult(toolResult.callID))
      case .toolCallUpdated, .turnStatusChanged:
        break
      }
    }

    return items
  }

  public static func toolCallRecords(from turns: [ChatTurn]) -> [ToolCallRecord] {
    var records: [ToolCallRecord.ID: ToolCallRecord] = [:]
    var orderedIDs: [ToolCallRecord.ID] = []

    for event in turns.flatMap(\.events) {
      switch event.payload {
      case .toolCallRecorded(let record):
        if records[record.id] == nil {
          orderedIDs.append(record.id)
        }
        records[record.id] = record
      case .toolCallUpdated(let record):
        guard records[record.id] != nil else {
          continue
        }
        records[record.id] = record
      case .transcriptItemAppended, .assistantChunkAppended, .assistantContentReplaced,
        .assistantDeliveryStatusUpdated, .assistantGenerationMetricsUpdated, .messageRemoved,
        .transientAssistantPlaceholdersRemoved, .streamingAssistantMessagesCancelled,
        .assistantMessageAnnotatedAsToolCall, .toolResultAppended, .turnStatusChanged:
        continue
      }
    }

    return orderedIDs.compactMap { records[$0] }
  }

  public static func toolCallRecord(
    id: ToolCallRecord.ID,
    from turns: [ChatTurn]
  ) -> ToolCallRecord? {
    var currentRecord: ToolCallRecord?
    for event in turns.flatMap(\.events) {
      switch event.payload {
      case .toolCallRecorded(let record):
        guard record.id == id else {
          continue
        }
        currentRecord = record
      case .toolCallUpdated(let record):
        guard record.id == id, currentRecord != nil else {
          continue
        }
        currentRecord = record
      case .transcriptItemAppended, .assistantChunkAppended, .assistantContentReplaced,
        .assistantDeliveryStatusUpdated, .assistantGenerationMetricsUpdated, .messageRemoved,
        .transientAssistantPlaceholdersRemoved, .streamingAssistantMessagesCancelled,
        .assistantMessageAnnotatedAsToolCall, .toolResultAppended, .turnStatusChanged:
        continue
      }
    }
    return currentRecord
  }

  private static func updateAssistantMessage(
    _ messageID: UUID,
    in items: inout [ChatTurnItem],
    transform: (AssistantTurnMessage) -> AssistantTurnMessage
  ) {
    guard
      let index = items.firstIndex(where: { item in
        guard case .assistantMessage(let message) = item else {
          return false
        }
        return message.id == messageID
      })
    else {
      return
    }
    guard case .assistantMessage(let message) = items[index] else {
      return
    }
    items[index] = .assistantMessage(transform(message))
  }

  private static func replaceItem(
    matchingMessageID messageID: UUID,
    with replacement: ChatTurnItem,
    in items: inout [ChatTurnItem]
  ) {
    guard let index = items.firstIndex(where: { $0.messageID == messageID }) else {
      return
    }
    items[index] = replacement
  }
}

public struct AssistantTurnMessage: Codable, Identifiable, Equatable, Sendable {
  public enum DeliveryStatus: String, Codable, Equatable, Sendable {
    case complete
    case streaming
    case cancelled
  }

  public let id: UUID
  public var content: String
  public var attachments: [ChatAttachment]
  public var generationMetrics: ChatGenerationMetrics?
  public var deliveryStatus: DeliveryStatus

  public init(
    id: UUID = UUID(),
    content: String,
    attachments: [ChatAttachment] = [],
    generationMetrics: ChatGenerationMetrics? = nil,
    deliveryStatus: DeliveryStatus = .complete
  ) {
    self.id = id
    self.content = content
    self.attachments = attachments
    self.generationMetrics = generationMetrics
    self.deliveryStatus = deliveryStatus
  }
}

public enum ChatTurnStatus: String, Codable, Equatable, Sendable {
  case running
  case awaitingApproval
  case awaitingUserAnswer
  case completed
  case cancelled
  case failed
}

public enum ChatTurnModelContextPolicy: String, Codable, Equatable, Sendable {
  case included
  case excluded
}

nonisolated extension ChatTurnItem {
  public var messageID: UUID? {
    switch self {
    case .userMessage(let message):
      message.id
    case .assistantMessage(let message):
      message.id
    case .toolCall(let id), .toolResult(let id):
      id
    }
  }

  public var userContent: String? {
    guard case .userMessage(let message) = self else {
      return nil
    }
    return message.content
  }
}
