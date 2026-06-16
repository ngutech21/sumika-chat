import Foundation

public struct ChatSession: Codable, Identifiable, Equatable, Sendable {
  public static let defaultTitle = "New Session"

  public let id: UUID
  public var title: String
  public var selectedModelID: ManagedModel.ID
  public var modelContextSnapshot: ModelContextSnapshot
  public var toolCalls: [ToolCallRecord] {
    ChatTranscriptProjector.toolCallRecords(from: turns)
  }
  public internal(set) var turns: [ChatTurn]
  public var focusedFileState: FocusedFileState
  public var systemPrompt: String
  public var generationSettings: ChatGenerationSettings
  public var interactionMode: WorkspaceInteractionMode
  public var todoState: TodoState?
  public var pendingAttachments: [ChatAttachment]
  public var activeAttachmentContext: ActiveAttachmentContext
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    title: String = ChatSession.defaultTitle,
    selectedModelID: ManagedModel.ID = ManagedModelCatalog.defaultModelID,
    modelContextSnapshot: ModelContextSnapshot = ModelContextSnapshot(),
    toolCalls: [ToolCallRecord] = [],
    turns: [ChatTurn] = [],
    pendingAttachments: [ChatAttachment] = [],
    focusedFileState: FocusedFileState = .empty,
    systemPrompt: String = ChatPromptDefaults.codingSystemPrompt,
    generationSettings: ChatGenerationSettings = .codingDefault,
    interactionMode: WorkspaceInteractionMode = .chat,
    todoState: TodoState? = nil,
    activeAttachmentContext: ActiveAttachmentContext = .empty,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.selectedModelID = selectedModelID
    self.modelContextSnapshot = modelContextSnapshot
    self.turns = Self.turns(turns, recording: toolCalls)
    self.focusedFileState = focusedFileState
    self.systemPrompt = systemPrompt
    self.generationSettings = generationSettings
    self.interactionMode = interactionMode
    self.todoState = todoState
    self.pendingAttachments = pendingAttachments
    self.activeAttachmentContext = activeAttachmentContext
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public static let codingDefault = ChatSession()

  public static func == (lhs: ChatSession, rhs: ChatSession) -> Bool {
    lhs.id == rhs.id
      && lhs.title == rhs.title
      && lhs.selectedModelID == rhs.selectedModelID
      && lhs.modelContextSnapshot == rhs.modelContextSnapshot
      && lhs.turns == rhs.turns
      && lhs.focusedFileState == rhs.focusedFileState
      && lhs.systemPrompt == rhs.systemPrompt
      && lhs.generationSettings == rhs.generationSettings
      && lhs.interactionMode == rhs.interactionMode
      && lhs.todoState == rhs.todoState
      && lhs.activeAttachmentContext == rhs.activeAttachmentContext
      && lhs.createdAt == rhs.createdAt
      && lhs.updatedAt == rhs.updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case title
    case selectedModelID
    case modelContextSnapshot
    case turns
    case focusedFileState
    case systemPrompt
    case generationSettings
    case interactionMode
    case todoState
    case activeAttachmentContext
    case createdAt
    case updatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    selectedModelID = try container.decode(ManagedModel.ID.self, forKey: .selectedModelID)
    modelContextSnapshot = try container.decode(
      ModelContextSnapshot.self,
      forKey: .modelContextSnapshot
    )
    turns = Self.resolvingInterruptedStreams(
      in: try container.decode([ChatTurn].self, forKey: .turns)
    )
    focusedFileState = try container.decode(FocusedFileState.self, forKey: .focusedFileState)
    systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
    generationSettings = try container.decode(
      ChatGenerationSettings.self,
      forKey: .generationSettings
    )
    interactionMode = try container.decode(
      WorkspaceInteractionMode.self,
      forKey: .interactionMode
    )
    todoState = try container.decode(TodoState?.self, forKey: .todoState)
    pendingAttachments = []
    activeAttachmentContext = try container.decode(
      ActiveAttachmentContext.self,
      forKey: .activeAttachmentContext
    )
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(title, forKey: .title)
    try container.encode(selectedModelID, forKey: .selectedModelID)
    try container.encode(modelContextSnapshot, forKey: .modelContextSnapshot)
    try container.encode(turns, forKey: .turns)
    try container.encode(focusedFileState, forKey: .focusedFileState)
    try container.encode(systemPrompt, forKey: .systemPrompt)
    try container.encode(generationSettings, forKey: .generationSettings)
    try container.encode(interactionMode, forKey: .interactionMode)
    try container.encode(todoState, forKey: .todoState)
    try container.encode(activeAttachmentContext, forKey: .activeAttachmentContext)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(updatedAt, forKey: .updatedAt)
  }

  /// A persisted `.streaming` delivery status means generation was interrupted
  /// by a crash or hard quit — there is no live stream after a reload, so a
  /// loaded turn must never resurface as "Generating…". Mirror the runtime
  /// cancel path (`ChatTranscriptMutator.removeTransientAssistantPlaceholders`
  /// and `markStreamingAssistantMessagesCancelled`): drop empty placeholders and
  /// mark partial content as cancelled.
  private static func resolvingInterruptedStreams(in turns: [ChatTurn]) -> [ChatTurn] {
    turns.map { turn in
      var turn = turn
      let recoveryTimestamp = turn.updatedAt
      for item in turn.items {
        guard case .assistantMessage(let message) = item,
          message.deliveryStatus == .streaming
        else {
          continue
        }
        if message.content.isEmpty {
          turn.appendEvent(
            ChatTurnEvent(
              id: interruptedStreamRecoveryEventID(
                messageID: message.id,
                kind: .emptyPlaceholderRemoved
              ),
              timestamp: recoveryTimestamp,
              payload: .messageRemoved(MessageRemovedEvent(messageID: message.id))
            ))
        } else {
          turn.appendEvent(
            ChatTurnEvent(
              id: interruptedStreamRecoveryEventID(
                messageID: message.id,
                kind: .partialMessageCancelled
              ),
              timestamp: recoveryTimestamp,
              payload: .assistantDeliveryStatusUpdated(
                AssistantDeliveryStatusUpdatedEvent(messageID: message.id, status: .cancelled)
              )
            ))
        }
      }
      return turn
    }
  }

  private enum InterruptedStreamRecoveryEventKind: UInt8 {
    case emptyPlaceholderRemoved = 0x71
    case partialMessageCancelled = 0x72
  }

  private static func interruptedStreamRecoveryEventID(
    messageID: UUID,
    kind: InterruptedStreamRecoveryEventKind
  ) -> UUID {
    var uuid = messageID.uuid
    uuid.0 ^= 0x4C
    uuid.1 ^= 0x43
    uuid.2 ^= kind.rawValue
    uuid.6 = (uuid.6 & 0x0F) | 0x50
    uuid.8 = (uuid.8 & 0x3F) | 0x80
    return UUID(uuid: uuid)
  }

  private static func turns(
    _ turns: [ChatTurn],
    recording toolCalls: [ToolCallRecord]
  ) -> [ChatTurn] {
    guard !toolCalls.isEmpty else {
      return turns
    }
    var remainingRecordsByID = Dictionary(uniqueKeysWithValues: toolCalls.map { ($0.id, $0) })
    var updatedTurns = turns.map { turn in
      var turn = turn
      for item in turn.items {
        let id: ToolCallRecord.ID?
        switch item {
        case .toolCall(let toolCallID), .toolResult(let toolCallID):
          id = toolCallID
        case .userMessage, .assistantMessage:
          id = nil
        }
        guard let id, let record = remainingRecordsByID.removeValue(forKey: id) else {
          continue
        }
        turn.appendEvent(ChatTurnEvent(payload: .toolCallRecorded(record)))
      }
      return turn
    }
    for record in toolCalls where remainingRecordsByID[record.id] != nil {
      if updatedTurns.isEmpty {
        updatedTurns.append(ChatTurn(status: .completed))
      }
      updatedTurns[updatedTurns.count - 1].appendEvent(
        ChatTurnEvent(payload: .toolCallRecorded(record))
      )
    }
    return updatedTurns
  }

  public func turnID(containingToolCall toolCallID: ToolCallRecord.ID) -> ChatTurn.ID? {
    turns.first { turn in
      turn.items.contains { item in
        switch item {
        case .toolCall(let id), .toolResult(let id):
          id == toolCallID
        case .userMessage, .assistantMessage:
          false
        }
      }
    }?.id
  }

  public func toolCallRecord(id: ToolCallRecord.ID) -> ToolCallRecord? {
    ChatTranscriptProjector.toolCallRecord(id: id, from: turns)
  }
}
