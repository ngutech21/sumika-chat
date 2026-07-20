import Foundation

struct ToolResumeResult: Equatable, Sendable {
  let events: [ChatWorkflowEvent]
  let followUpPromptMode: ToolPromptMode?
  let nextAssistantMessageID: UUID?
}

struct ToolResumeCoordinator: Sendable {
  private let focusedFileReducer: FocusedFileStateReducer

  init(focusedFileReducer: FocusedFileStateReducer = FocusedFileStateReducer()) {
    self.focusedFileReducer = focusedFileReducer
  }

  func approvedToolResult(
    record: ToolCallRecord,
    focusedFileState: FocusedFileState,
    turnID: ChatTurn.ID
  ) -> ToolResumeResult {
    var events: [ChatWorkflowEvent] = [
      .toolCallUpdated(record),
      .toolResultAppended(
        toolResultMessage(for: record),
        turnID: turnID
      ),
    ]
    events.append(contentsOf: focusEvents(for: record, from: focusedFileState))

    return ToolResumeResult(
      events: events,
      followUpPromptMode: nil,
      nextAssistantMessageID: nil
    )
  }

  func answeredAskUserTool(
    record: ToolCallRecord,
    answer: String,
    turnID: ChatTurn.ID
  ) -> ToolResumeResult {
    var answeredRecord = record
    answeredRecord.state = .completed(.askUser(AskUserResult(answer: answer)))
    let nextAssistantMessageID = UUID()
    let promptMode = ToolPromptMode.afterToolResultCanContinue
    return ToolResumeResult(
      events: resumedToolEvents(
        record: answeredRecord,
        toolResult: toolResultMessage(for: answeredRecord),
        nextAssistantMessageID: nextAssistantMessageID,
        turnID: turnID
      ),
      followUpPromptMode: promptMode,
      nextAssistantMessageID: nextAssistantMessageID
    )
  }

  func deniedTool(
    record: ToolCallRecord,
    turnID: ChatTurn.ID
  ) -> ToolResumeResult {
    var deniedRecord = record
    deniedRecord.state = .denied(
      .failure(
        ToolFailure(
          toolName: deniedRecord.request.toolName,
          path: deniedRecord.evaluation.firstModelFacingPath,
          reason: .userDenied
        ))
    )
    return ToolResumeResult(
      events: [
        .toolCallUpdated(deniedRecord),
        .toolResultAppended(toolResultMessage(for: deniedRecord), turnID: turnID),
      ],
      followUpPromptMode: nil,
      nextAssistantMessageID: nil
    )
  }

  private func resumedToolEvents(
    record: ToolCallRecord,
    toolResult: ToolResultModelMessage,
    nextAssistantMessageID: UUID,
    turnID: ChatTurn.ID
  ) -> [ChatWorkflowEvent] {
    [
      .toolCallUpdated(record),
      .toolResultAppended(toolResult, turnID: turnID),
      .assistantPlaceholderAppended(messageID: nextAssistantMessageID, turnID: turnID),
      .turnStatusChanged(
        turnID: turnID,
        status: .running,
        modelContextPolicy: nil
      ),
    ]
  }

  private func focusEvents(
    for record: ToolCallRecord,
    from focusedFileState: FocusedFileState
  ) -> [ChatWorkflowEvent] {
    let updatedState = focusedFileReducer.applyingToolResult(
      record.resultPayload,
      request: record.request,
      to: focusedFileState
    )
    guard updatedState != focusedFileState else {
      return []
    }
    return [.focusedFileStateChanged(updatedState)]
  }

  private func toolResultMessage(for record: ToolCallRecord) -> ToolResultModelMessage {
    toolResultMessage(for: record, fallback: .unavailable)
  }

  private func toolResultMessage(
    for record: ToolCallRecord,
    fallback: ToolResultFallback
  ) -> ToolResultModelMessage {
    ToolResultModelMessage(
      callID: record.id,
      toolName: record.request.toolName,
      payload: record.resultPayload ?? fallback.payload(for: record)
    )
  }

  private enum ToolResultFallback {
    case unavailable

    func payload(for record: ToolCallRecord) -> ToolResultPayload {
      switch self {
      case .unavailable:
        return .failure(
          ToolFailure(
            toolName: record.request.toolName,
            path: nil,
            reason: .executionError(
              "Tool result unavailable for \(record.request.toolName.rawValue)."
            )
          ))
      }
    }
  }
}
