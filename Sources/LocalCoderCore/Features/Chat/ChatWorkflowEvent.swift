import Foundation

public enum ChatWorkflowEvent: Equatable, Sendable {
  case nativeAssistantBoundaryAppended(
    content: String,
    sourceMessageID: UUID,
    turnID: ChatTurn.ID
  )
  case assistantMessageAnnotatedAsToolCall(
    assistantMessageID: UUID,
    toolCall: ToolCallModelMessage
  )
  case toolCallAppended(
    ToolCallRecord,
    turnID: ChatTurn.ID
  )
  case toolCallReplaced(ToolCallRecord)
  case toolResultAppended(
    ToolResultModelMessage,
    turnID: ChatTurn.ID
  )
  case assistantPlaceholderAppended(
    messageID: UUID,
    turnID: ChatTurn.ID
  )
  case assistantMessageAppended(
    content: String,
    modelContextContent: String,
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
  case resumeGeneration(
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
    case .nativeAssistantBoundaryAppended(let content, let sourceMessageID, let turnID):
      if let entry = try? ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        sourceMessageID: sourceMessageID,
        content: content
      ) {
        mutator.appendModelContextEntry(entry, to: &state)
      }
    case .assistantMessageAnnotatedAsToolCall(let assistantMessageID, let toolCall):
      mutator.annotateToolCall(toolCall, for: assistantMessageID, in: &state)
    case .toolCallAppended(let record, let turnID):
      var turnRecord = record
      if turnRecord.turnID == nil {
        turnRecord.turnID = turnID
      }
      if let existingIndex = state.toolCalls.firstIndex(where: { $0.id == record.id }) {
        state.toolCalls[existingIndex] = turnRecord
      } else {
        state.toolCalls.append(turnRecord)
      }
      if !state.turns.containsToolItem(record.id, inTurn: turnID) {
        mutator.appendItem(.toolCall(record.id), toTurn: turnID, in: &state)
      }
    case .toolCallReplaced(let record):
      replaceToolCallRecord(record, in: &state)
    case .toolResultAppended(let toolResult, let turnID):
      mutator.appendToolResult(toolResult, turnID: turnID, to: &state)
      if let request = state.toolCalls.first(where: { $0.id == toolResult.callID })?.request {
        if let entry = try? ModelFacingPromptRenderer.toolResultEntry(
          turnID: turnID,
          sourceMessageID: toolResult.callID,
          toolResult: toolResult,
          request: request
        ) {
          mutator.appendModelContextEntry(entry, to: &state)
        }
      }
    case .assistantPlaceholderAppended(let messageID, let turnID):
      mutator.appendAssistantPlaceholder(id: messageID, turnID: turnID, to: &state)
    case .assistantMessageAppended(
      let content,
      let modelContextContent,
      let messageID,
      let turnID
    ):
      mutator.appendAssistantMessage(content, id: messageID, turnID: turnID, to: &state)
      if let entry = try? ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        sourceMessageID: messageID,
        content: modelContextContent
      ) {
        mutator.appendModelContextEntry(entry, to: &state)
      }
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
    case .nativeAssistantBoundaryAppended(_, let sourceMessageID, let turnID):
      return missingMessageDiagnostics([sourceMessageID], event: event, in: state)
        + missingTurnDiagnostics([turnID], event: event, in: state)
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
    case .toolResultAppended(_, let turnID),
      .assistantPlaceholderAppended(_, let turnID),
      .assistantMessageAppended(_, _, _, let turnID),
      .turnStatusChanged(let turnID, _, _),
      .streamingAssistantMessagesCancelled(let turnID):
      return missingTurnDiagnostics([turnID], event: event, in: state)
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

  private func replaceToolCallRecord(
    _ record: ToolCallRecord,
    in state: inout ChatSession
  ) {
    guard let index = state.toolCalls.firstIndex(where: { $0.id == record.id }) else {
      return
    }
    var replacement = record
    if replacement.turnID == nil {
      replacement.turnID = state.toolCalls[index].turnID
    }
    state.toolCalls[index] = replacement
  }
}

extension [ChatTurn] {
  fileprivate func containsToolItem(_ toolCallID: ToolCallRecord.ID, inTurn turnID: ChatTurn.ID)
    -> Bool
  {
    guard let turn = first(where: { $0.id == turnID }) else {
      return false
    }
    return turn.items.contains { item in
      if case .toolCall(let id) = item {
        return id == toolCallID
      }
      return false
    }
  }
}
