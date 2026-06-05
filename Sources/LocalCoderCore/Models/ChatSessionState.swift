import Foundation

@dynamicMemberLookup
public struct ChatSessionState: Equatable, Sendable {
  public var transcript: ChatTranscriptState
  public var pendingAttachments: [ChatAttachment]

  public var messages: [ChatMessage] {
    get { transcript.projectedMessages }
    set { transcript.replaceMessageProjection(newValue) }
  }

  public var modelFacingTranscript: ModelFacingTranscript {
    get { transcript.modelFacingTranscript }
    set { transcript.modelFacingTranscript = newValue }
  }

  public var toolCalls: [ToolCallRecord] {
    get { transcript.toolCalls }
    set { transcript.toolCalls = newValue }
  }

  public var turns: [ChatTurn] {
    get { transcript.turns }
    set { transcript.turns = newValue }
  }

  public var focusedFileState: FocusedFileState {
    get { transcript.focusedFileState }
    set { transcript.focusedFileState = newValue }
  }

  public var systemPrompt: String {
    get { transcript.systemPrompt }
    set { transcript.systemPrompt = newValue }
  }

  public var generationSettings: ChatGenerationSettings {
    get { transcript.generationSettings }
    set { transcript.generationSettings = newValue }
  }

  public var interactionMode: WorkspaceInteractionMode {
    get { transcript.interactionMode }
    set { transcript.interactionMode = newValue }
  }

  public subscript<Value>(dynamicMember keyPath: WritableKeyPath<ChatTranscriptState, Value>)
    -> Value
  {
    get { transcript[keyPath: keyPath] }
    set { transcript[keyPath: keyPath] = newValue }
  }

  public init(
    transcript: ChatTranscriptState,
    pendingAttachments: [ChatAttachment] = []
  ) {
    self.transcript = transcript
    self.pendingAttachments = pendingAttachments
  }

  public init(
    messages: [ChatMessage] = [],
    modelFacingTranscript: ModelFacingTranscript = ModelFacingTranscript(),
    toolCalls: [ToolCallRecord] = [],
    turns: [ChatTurn] = [],
    pendingAttachments: [ChatAttachment],
    focusedFileState: FocusedFileState = .empty,
    systemPrompt: String,
    generationSettings: ChatGenerationSettings,
    interactionMode: WorkspaceInteractionMode = .chat
  ) {
    let projectedTurns: [ChatTurn]
    if turns.isEmpty, !messages.isEmpty {
      projectedTurns = [
        ChatTurn(status: .completed, items: messages.map(ChatTurnItem.init(projectedMessage:)))
      ]
    } else if !messages.isEmpty {
      projectedTurns = turns.enumerated().map { index, turn in
        guard index == 0 else {
          return turn
        }
        var updatedTurn = turn
        updatedTurn.items.append(contentsOf: messages.map(ChatTurnItem.init(projectedMessage:)))
        return updatedTurn
      }
    } else {
      projectedTurns = turns
    }
    self.transcript = ChatTranscriptState(
      modelFacingTranscript: modelFacingTranscript,
      toolCalls: toolCalls,
      turns: projectedTurns,
      focusedFileState: focusedFileState,
      systemPrompt: systemPrompt,
      generationSettings: generationSettings,
      interactionMode: interactionMode
    )
    self.pendingAttachments = pendingAttachments
  }

  public static let codingDefault = ChatSessionState(transcript: .codingDefault)

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
}

extension ChatTranscriptState {
  public var projectedMessages: [ChatMessage] {
    let recordsByID = Dictionary(toolCalls.map { ($0.id, $0) }) { _, latest in latest }
    return turns.flatMap { turn in
      turn.items.compactMap { item in
        switch item {
        case .userMessage(let message), .assistantMessage(let message):
          return message
        case .toolCall(let id):
          guard let record = recordsByID[id] else {
            return nil
          }
          return ChatMessage(id: id, toolCall: ToolCallModelMessage(request: record.request))
        case .toolResult(let id):
          guard let record = recordsByID[id] else {
            return nil
          }
          return ChatMessage(id: id, toolResult: ToolResultModelMessage(record: record))
        }
      }
    }
  }

  public mutating func replaceMessageProjection(_ messages: [ChatMessage]) {
    let items = messages.map(ChatTurnItem.init(projectedMessage:))
    if turns.isEmpty {
      turns = [ChatTurn(status: .completed, items: items)]
    } else {
      turns[turns.count - 1].items = items
    }
  }
}

extension ChatTurnItem {
  init(projectedMessage message: ChatMessage) {
    switch message.payload {
    case .user:
      self = .userMessage(message)
    case .assistant, .system:
      self = .assistantMessage(message)
    case .toolCall(let payload):
      self = .toolCall(payload.toolCall.callID)
    case .toolResult(let payload):
      self = .toolResult(payload.callID)
    }
  }
}
