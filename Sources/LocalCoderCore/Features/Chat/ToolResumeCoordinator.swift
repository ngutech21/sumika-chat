import Foundation

public struct ToolResumeResult: Equatable, Sendable {
  public let events: [ChatWorkflowEvent]
  public let followUpPromptMode: ToolPromptMode?
  public let nextAssistantMessageID: UUID?

  public init(
    events: [ChatWorkflowEvent],
    followUpPromptMode: ToolPromptMode?,
    nextAssistantMessageID: UUID?
  ) {
    self.events = events
    self.followUpPromptMode = followUpPromptMode
    self.nextAssistantMessageID = nextAssistantMessageID
  }
}

public struct ToolResumeCoordinator: Sendable {
  private let focusedFileReducer: FocusedFileStateReducer

  public init(focusedFileReducer: FocusedFileStateReducer = FocusedFileStateReducer()) {
    self.focusedFileReducer = focusedFileReducer
  }

  public func approvedToolResult(
    record: ToolCallRecord,
    focusedFileState: FocusedFileState,
    turnID: ChatTurn.ID
  ) -> ToolResumeResult {
    var events: [ChatWorkflowEvent] = [
      .toolCallReplaced(record),
      .toolResultAppended(
        toolResultMessage(for: record),
        turnID: turnID
      ),
    ]
    events.append(contentsOf: focusEvents(for: record, from: focusedFileState))

    guard record.status == .completed else {
      return ToolResumeResult(
        events: events,
        followUpPromptMode: nil,
        nextAssistantMessageID: nil
      )
    }

    let nextAssistantMessageID = UUID()
    let promptMode = followUpPromptMode(afterApprovedTool: record)
    events.append(
      .assistantPlaceholderAppended(
        messageID: nextAssistantMessageID,
        turnID: turnID
      ))

    return ToolResumeResult(
      events: events,
      followUpPromptMode: promptMode,
      nextAssistantMessageID: nextAssistantMessageID
    )
  }

  public func answeredAskUserTool(
    record: ToolCallRecord,
    answer: String,
    turnID: ChatTurn.ID
  ) -> ToolResumeResult {
    var answeredRecord = record
    answeredRecord.state = .completed(.askUser(AskUserResult(answer: answer)))
    answeredRecord.events.append(
      ToolCallEvent(actor: .user, kind: .answered, message: "Answered: \(answer)"))

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

  public func deniedTool(
    record: ToolCallRecord,
    message: String,
    turnID: ChatTurn.ID
  ) -> ToolResumeResult {
    var deniedRecord = record
    deniedRecord.state = .denied(
      .failure(
        ToolFailure(
          toolName: deniedRecord.request.toolName,
          path: deniedRecord.evaluation.firstModelFacingPath,
          reason: .permissionDenied,
          recovery: .askUser(message: message)
        ))
    )
    deniedRecord.events.append(ToolCallEvent(actor: .user, kind: .denied, message: message))

    let nextAssistantMessageID = UUID()
    let promptMode = ToolPromptMode.afterToolResultFinal
    return ToolResumeResult(
      events: resumedToolEvents(
        record: deniedRecord,
        toolResult: toolResultMessage(
          for: deniedRecord,
          fallback: .permissionDenied(message: message)
        ),
        nextAssistantMessageID: nextAssistantMessageID,
        turnID: turnID
      ),
      followUpPromptMode: promptMode,
      nextAssistantMessageID: nextAssistantMessageID
    )
  }

  public func followUpPromptMode(afterApprovedTool record: ToolCallRecord) -> ToolPromptMode {
    isFinalApprovedToolFollowUp(record) ? .afterToolResultFinal : .afterToolResultCanContinue
  }

  public func isFinalApprovedToolFollowUp(_ record: ToolCallRecord) -> Bool {
    guard record.resultPayload?.status == .success else {
      return false
    }
    return record.request.toolName == .writeFile || record.request.toolName == .editFile
  }

  private func resumedToolEvents(
    record: ToolCallRecord,
    toolResult: ToolResultModelMessage,
    nextAssistantMessageID: UUID,
    turnID: ChatTurn.ID
  ) -> [ChatWorkflowEvent] {
    [
      .toolCallReplaced(record),
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
    case permissionDenied(message: String)

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
      case .permissionDenied(let message):
        return .failure(
          ToolFailure(
            toolName: record.request.toolName,
            path: record.evaluation.firstModelFacingPath,
            reason: .permissionDenied,
            recovery: .askUser(message: message)
          ))
      }
    }
  }
}
