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
  case assistantMessageAppended(
    content: String,
    modelContextContent: String,
    messageID: ChatMessage.ID,
    turnID: ChatTurnRecord.ID
  )
  case turnStatusChanged(
    turnID: ChatTurnRecord.ID,
    status: ChatTurnStatus,
    modelContextPolicy: ChatTurnModelContextPolicy?
  )
  case focusedFileStateChanged(FocusedFileState)
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
    to state: inout ChatSessionState
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
    to state: inout ChatSessionState
  ) -> [ChatWorkflowEventApplicationDiagnostic] {
    let diagnostics = diagnostics(for: event, in: state)
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
      mutator.appendModelContextMessage(
        ChatModelContextMessage(
          turnID: turnID,
          sourceMessageID: messageID,
          role: toolResult.modelContextRole,
          content: toolResult.modelContextContent
        ),
        to: &state
      )
      if let entry = try? ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        sourceMessageID: messageID,
        toolResult: toolResult
      ) {
        mutator.appendModelFacingEntry(entry, to: &state)
      }
      mutator.appendMessageID(messageID, toTurn: turnID, in: &state)
    case .assistantPlaceholderAppended(let messageID, let turnID):
      mutator.appendAssistantPlaceholder(id: messageID, turnID: turnID, to: &state)
      mutator.appendMessageID(messageID, toTurn: turnID, in: &state)
    case .assistantMessageAppended(
      let content,
      let modelContextContent,
      let messageID,
      let turnID
    ):
      mutator.appendAssistantMessage(content, id: messageID, turnID: turnID, to: &state)
      mutator.appendModelContextMessage(
        ChatModelContextMessage(
          turnID: turnID,
          sourceMessageID: messageID,
          role: .assistant,
          content: modelContextContent
        ),
        to: &state
      )
      if let entry = try? ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        sourceMessageID: messageID,
        content: modelContextContent
      ) {
        mutator.appendModelFacingEntry(entry, to: &state)
      }
      mutator.appendMessageID(messageID, toTurn: turnID, in: &state)
    case .turnStatusChanged(let turnID, let status, let modelContextPolicy):
      mutator.updateTurnStatus(
        status,
        modelContextPolicy: modelContextPolicy,
        for: turnID,
        in: &state
      )
    case .focusedFileStateChanged(let focusedFileState):
      state.focusedFileState = focusedFileState
    case .streamingAssistantMessagesCancelled(let turnID):
      mutator.markStreamingAssistantMessagesCancelled(inTurn: turnID, in: &state)
    case .transientAssistantPlaceholdersRemoved:
      mutator.removeTransientAssistantPlaceholders(from: &state)
    }
    return diagnostics
  }

  private func diagnostics(
    for event: ChatWorkflowEvent,
    in state: ChatSessionState
  ) -> [ChatWorkflowEventApplicationDiagnostic] {
    switch event {
    case .assistantMessageAnnotatedAsToolCall(let assistantMessageID, _):
      return missingMessageDiagnostics([assistantMessageID], event: event, in: state)
    case .toolCallAppended(_, let turnID):
      return missingTurnDiagnostics([turnID], event: event, in: state)
    case .toolCallReplaced(let record):
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
    case .toolResultAppended(_, _, let turnID),
      .assistantPlaceholderAppended(_, let turnID),
      .assistantMessageAppended(_, _, _, let turnID),
      .turnStatusChanged(let turnID, _, _),
      .streamingAssistantMessagesCancelled(let turnID):
      return missingTurnDiagnostics([turnID], event: event, in: state)
    case .focusedFileStateChanged, .transientAssistantPlaceholdersRemoved:
      return []
    }
  }

  private func missingMessageDiagnostics(
    _ messageIDs: [ChatMessage.ID],
    event: ChatWorkflowEvent,
    in state: ChatSessionState
  ) -> [ChatWorkflowEventApplicationDiagnostic] {
    messageIDs.compactMap { messageID in
      guard !state.messages.contains(where: { $0.id == messageID }) else {
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
    _ turnIDs: [ChatTurnRecord.ID],
    event: ChatWorkflowEvent,
    in state: ChatSessionState
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
