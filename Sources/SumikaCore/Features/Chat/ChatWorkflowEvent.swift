import Foundation

public enum ChatWorkflowEvent: Equatable, Sendable {
  case turnAppended(ChatTurn)
  case userMessageAppended(
    content: String,
    messageID: UUID,
    turnID: ChatTurn.ID,
    attachments: [ChatAttachment],
    promptContext: CurrentPromptContext
  )
  case userMessagePromptContextUpdated(
    messageID: UUID,
    promptContext: CurrentPromptContext
  )
  case assistantAnnotatedAsNativeToolCall(
    assistantMessageID: UUID,
    toolCall: ToolCallModelMessage
  )
  case toolCallAppended(
    ToolCallRecord,
    turnID: ChatTurn.ID
  )
  case toolCallUpdated(ToolCallRecord)
  case toolResultAppended(
    ToolResultModelMessage,
    turnID: ChatTurn.ID
  )
  case assistantPlaceholderAppended(
    messageID: UUID,
    turnID: ChatTurn.ID
  )
  case assistantThinkingPlaceholderAppended(
    messageID: UUID,
    turnID: ChatTurn.ID
  )
  case assistantChunkAppended(
    chunk: String,
    messageID: UUID
  )
  case assistantThinkingChunkAppended(
    chunk: String,
    messageID: UUID
  )
  case assistantThinkingCompleted(
    messageID: UUID
  )
  case assistantGenerationCompleted(
    messageID: UUID,
    metrics: ChatGenerationMetrics?
  )
  case assistantMessageAppended(
    content: String,
    modelProjectionPolicy: AssistantModelProjectionPolicy,
    messageID: UUID,
    turnID: ChatTurn.ID
  )
  case turnStatusChanged(
    turnID: ChatTurn.ID,
    status: ChatTurnStatus,
    modelContextPolicy: ChatTurnModelContextPolicy?
  )
  case focusedFileStateChanged(FocusedFileState)
  case todoStateChanged(TodoState)
  case streamingAssistantMessagesCancelled(turnID: ChatTurn.ID)
  case transientAssistantPlaceholdersRemoved
}

public enum ChatWorkflowContinuation: Equatable, Sendable {
  case none
  case awaitingApproval
  case awaitingUserAnswer
  case resumeAutomaticApproval(batchAnchorID: ToolCallRecord.ID)
  case resumeGeneration(
    assistantMessageID: UUID,
    promptMode: ToolPromptMode
  )
  case resumeCorrectionGeneration(
    assistantMessageID: UUID,
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

public enum ChatWorkflowMissingTargetKind: String, Equatable, Sendable {
  case message
  case turn
  case toolCall
}

public struct ChatWorkflowEventApplicationDiagnostic: Equatable, Sendable {
  public var event: ChatWorkflowEvent
  public var missingTargetKind: ChatWorkflowMissingTargetKind
  public var missingTargetID: UUID

  public init(
    event: ChatWorkflowEvent,
    missingTargetKind: ChatWorkflowMissingTargetKind,
    missingTargetID: UUID
  ) {
    self.event = event
    self.missingTargetKind = missingTargetKind
    self.missingTargetID = missingTargetID
  }
}

public struct ChatWorkflowEventApplier: Sendable {
  private let mutator: ChatTranscriptMutator

  public init(mutator: ChatTranscriptMutator = ChatTranscriptMutator()) {
    self.mutator = mutator
  }

  @discardableResult
  public func apply(
    _ events: [ChatWorkflowEvent],
    to state: inout ChatSession
  ) -> [ChatWorkflowEventApplicationDiagnostic] {
    var diagnostics: [ChatWorkflowEventApplicationDiagnostic] = []
    for event in events {
      diagnostics.append(contentsOf: apply(event, to: &state))
    }
    return diagnostics
  }

  @discardableResult
  public func apply(
    _ event: ChatWorkflowEvent,
    to state: inout ChatSession
  ) -> [ChatWorkflowEventApplicationDiagnostic] {
    let diagnostics = diagnostics(for: event, in: state)
    switch event {
    case .turnAppended(let turn):
      mutator.appendTurn(turn, to: &state)
    case .userMessageAppended(
      let content,
      let messageID,
      let turnID,
      let attachments,
      let promptContext
    ):
      mutator.appendUserMessage(
        content,
        id: messageID,
        turnID: turnID,
        attachments: attachments,
        promptContext: promptContext,
        to: &state
      )
    case .userMessagePromptContextUpdated(let messageID, let promptContext):
      mutator.updateUserMessagePromptContext(
        promptContext,
        for: messageID,
        in: &state
      )
    case .assistantAnnotatedAsNativeToolCall(let assistantMessageID, let toolCall):
      mutator.annotateToolCall(toolCall, for: assistantMessageID, in: &state)
    case .toolCallAppended(let record, let turnID):
      mutator.recordToolCall(record, turnID: turnID, in: &state)
    case .toolCallUpdated(let record):
      mutator.updateToolCallRecord(record, in: &state)
    case .toolResultAppended(let toolResult, let turnID):
      mutator.appendToolResult(toolResult, turnID: turnID, to: &state)
    case .assistantPlaceholderAppended(let messageID, let turnID):
      mutator.appendAssistantPlaceholder(id: messageID, turnID: turnID, to: &state)
    case .assistantThinkingPlaceholderAppended(let messageID, let turnID):
      mutator.appendAssistantThinkingPlaceholder(id: messageID, turnID: turnID, to: &state)
    case .assistantChunkAppended(let chunk, let messageID):
      mutator.appendChunk(chunk, to: messageID, in: &state)
    case .assistantThinkingChunkAppended(let chunk, let messageID):
      mutator.appendThinkingChunk(chunk, to: messageID, in: &state)
    case .assistantThinkingCompleted(let messageID):
      mutator.updateThinkingDeliveryStatus(.complete, for: messageID, in: &state)
    case .assistantGenerationCompleted(let messageID, let metrics):
      mutator.updateGenerationMetrics(metrics, for: messageID, in: &state)
      mutator.updateDeliveryStatus(.complete, for: messageID, in: &state)
    case .assistantMessageAppended(
      let content,
      let modelProjectionPolicy,
      let messageID,
      let turnID
    ):
      mutator.appendAssistantMessage(
        content,
        id: messageID,
        turnID: turnID,
        modelProjectionPolicy: modelProjectionPolicy,
        to: &state
      )
    case .turnStatusChanged(let turnID, let status, let modelContextPolicy):
      mutator.updateTurnStatus(
        status,
        modelContextPolicy: modelContextPolicy,
        for: turnID,
        in: &state
      )
    case .focusedFileStateChanged(let focusedFileState):
      state.focusedFileState = focusedFileState
    case .todoStateChanged(let todoState):
      state.todoState = todoState
    case .streamingAssistantMessagesCancelled(let turnID):
      mutator.markStreamingAssistantMessagesCancelled(inTurn: turnID, in: &state)
    case .transientAssistantPlaceholdersRemoved:
      mutator.removeTransientAssistantPlaceholders(from: &state)
    }
    return diagnostics
  }

  private func diagnostics(
    for event: ChatWorkflowEvent,
    in state: ChatSession
  ) -> [ChatWorkflowEventApplicationDiagnostic] {
    switch event {
    case .turnAppended:
      return []
    case .userMessageAppended(_, _, let turnID, _, _):
      return missingTurnDiagnostics([turnID], event: event, in: state)
    case .userMessagePromptContextUpdated(let messageID, _):
      return missingMessageDiagnostics([messageID], event: event, in: state)
    case .assistantAnnotatedAsNativeToolCall(let assistantMessageID, _):
      return missingMessageDiagnostics([assistantMessageID], event: event, in: state)
    case .toolCallAppended(_, let turnID):
      return missingTurnDiagnostics([turnID], event: event, in: state)
    case .toolCallUpdated(let record):
      guard state.toolCalls.contains(where: { $0.id == record.id }) else {
        return [
          ChatWorkflowEventApplicationDiagnostic(
            event: event,
            missingTargetKind: .toolCall,
            missingTargetID: record.id
          )
        ]
      }
      return []
    case .toolResultAppended(_, let turnID),
      .assistantPlaceholderAppended(_, let turnID),
      .assistantThinkingPlaceholderAppended(_, let turnID),
      .assistantMessageAppended(_, _, _, let turnID),
      .turnStatusChanged(let turnID, _, _),
      .streamingAssistantMessagesCancelled(let turnID):
      return missingTurnDiagnostics([turnID], event: event, in: state)
    case .assistantChunkAppended(_, let messageID),
      .assistantThinkingChunkAppended(_, let messageID),
      .assistantThinkingCompleted(let messageID),
      .assistantGenerationCompleted(let messageID, _):
      return missingMessageDiagnostics([messageID], event: event, in: state)
    case .focusedFileStateChanged, .todoStateChanged, .transientAssistantPlaceholdersRemoved:
      return []
    }
  }

  private func missingMessageDiagnostics(
    _ messageIDs: [UUID],
    event: ChatWorkflowEvent,
    in state: ChatSession
  ) -> [ChatWorkflowEventApplicationDiagnostic] {
    messageIDs.compactMap { messageID in
      guard
        !state.turns.contains(where: { turn in
          turn.items.contains { $0.messageID == messageID }
        })
      else {
        return nil
      }
      return ChatWorkflowEventApplicationDiagnostic(
        event: event,
        missingTargetKind: .message,
        missingTargetID: messageID
      )
    }
  }

  private func missingTurnDiagnostics(
    _ turnIDs: [ChatTurn.ID],
    event: ChatWorkflowEvent,
    in state: ChatSession
  ) -> [ChatWorkflowEventApplicationDiagnostic] {
    turnIDs.compactMap { turnID in
      guard !state.turns.contains(where: { $0.id == turnID }) else {
        return nil
      }
      return ChatWorkflowEventApplicationDiagnostic(
        event: event,
        missingTargetKind: .turn,
        missingTargetID: turnID
      )
    }
  }

}
