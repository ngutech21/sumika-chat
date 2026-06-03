import Foundation

public enum ChatWorkflowEvent: Equatable, Sendable {
  case assistantMessageAnnotatedAsToolCall(
    assistantMessageID: ChatMessage.ID,
    toolCall: ToolCallModelMessage
  )
  case toolCallAppended(
    ToolCallRecord,
    turnID: ChatTurnRecord.ID
  )
  case toolCallReplaced(ToolCallRecord)
  case toolResultAppended(
    ToolResultModelMessage,
    messageID: ChatMessage.ID,
    turnID: ChatTurnRecord.ID
  )
  case assistantPlaceholderAppended(
    messageID: ChatMessage.ID,
    turnID: ChatTurnRecord.ID
  )
  case turnStatusChanged(
    turnID: ChatTurnRecord.ID,
    status: ChatTurnStatus,
    modelContextPolicy: ChatTurnModelContextPolicy?
  )
  case streamingAssistantMessagesCancelled(turnID: ChatTurnRecord.ID)
  case transientAssistantPlaceholdersRemoved
}

public enum ChatWorkflowContinuation: Equatable, Sendable {
  case none
  case awaitingApproval
  case resumeGeneration(
    assistantMessageID: ChatMessage.ID,
    promptMode: ToolPromptMode
  )
  case stopTurn
}

public struct ChatWorkflowStep: Equatable, Sendable {
  public let events: [ChatWorkflowEvent]
  public let continuation: ChatWorkflowContinuation

  public init(
    events: [ChatWorkflowEvent],
    continuation: ChatWorkflowContinuation
  ) {
    self.events = events
    self.continuation = continuation
  }
}

public struct ChatWorkflowEventApplier: Sendable {
  private let mutator: ChatTranscriptMutator

  public init(mutator: ChatTranscriptMutator = ChatTranscriptMutator()) {
    self.mutator = mutator
  }

  public func apply(
    _ events: [ChatWorkflowEvent],
    to state: inout ChatSessionState
  ) {
    for event in events {
      apply(event, to: &state)
    }
  }

  public func apply(
    _ event: ChatWorkflowEvent,
    to state: inout ChatSessionState
  ) {
    switch event {
    case .assistantMessageAnnotatedAsToolCall(let assistantMessageID, let toolCall):
      mutator.annotateToolCall(toolCall, for: assistantMessageID, in: &state)
    case .toolCallAppended(let record, let turnID):
      state.toolCalls.append(record)
      mutator.appendToolCallID(record.id, toTurn: turnID, in: &state)
    case .toolCallReplaced(let record):
      replaceToolCallRecord(record, in: &state)
    case .toolResultAppended(let toolResult, let messageID, let turnID):
      mutator.appendToolResult(toolResult, id: messageID, turnID: turnID, to: &state)
      mutator.appendMessageID(messageID, toTurn: turnID, in: &state)
    case .assistantPlaceholderAppended(let messageID, let turnID):
      mutator.appendAssistantPlaceholder(id: messageID, turnID: turnID, to: &state)
      mutator.appendMessageID(messageID, toTurn: turnID, in: &state)
    case .turnStatusChanged(let turnID, let status, let modelContextPolicy):
      mutator.updateTurnStatus(
        status,
        modelContextPolicy: modelContextPolicy,
        for: turnID,
        in: &state
      )
    case .streamingAssistantMessagesCancelled(let turnID):
      mutator.markStreamingAssistantMessagesCancelled(inTurn: turnID, in: &state)
    case .transientAssistantPlaceholdersRemoved:
      mutator.removeTransientAssistantPlaceholders(from: &state)
    }
  }

  private func replaceToolCallRecord(
    _ record: ToolCallRecord,
    in state: inout ChatSessionState
  ) {
    guard let index = state.toolCalls.firstIndex(where: { $0.id == record.id }) else {
      return
    }
    state.toolCalls[index] = record
  }
}
