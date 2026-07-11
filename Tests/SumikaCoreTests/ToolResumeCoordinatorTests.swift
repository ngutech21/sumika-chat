import Foundation
import Testing

@testable import SumikaCore

struct ToolResumeCoordinatorTests {
  @Test
  func approvedWriteFileResultOnlyEmitsResultAndUpdatesFocusedFile() throws {
    let turnID = UUID()
    let path = WorkspaceRelativePath(rawValue: "index.html")
    let record = makeRecord(
      toolName: .writeFile,
      payload: .writeFile(WriteFileInput(path: path.rawValue, content: "<h1>Hello</h1>")),
      state: .completed(.writeFile(.success(path: path, bytesWritten: 14)))
    )

    let result = ToolResumeCoordinator().approvedToolResult(
      record: record,
      focusedFileState: .empty,
      turnID: turnID
    )

    #expect(result.followUpPromptMode == nil)
    #expect(result.nextAssistantMessageID == nil)
    #expect(updatedToolCall(from: result.events)?.id == record.id)
    #expect(toolResultEvent(from: result.events)?.payload.status == .success)
    #expect(assistantPlaceholderID(from: result.events) == nil)
    #expect(focusedFileState(from: result.events)?.activePath == path)
  }

  @Test
  func answeredAskUserToolCompletesRecordAndCanContinue() throws {
    let turnID = UUID()
    let record = makeRecord(
      toolName: .askUser,
      payload: .askUser(AskUserInput(question: "Continue?", options: ["yes", "no"])),
      state: .awaitingUserAnswer
    )

    let result = ToolResumeCoordinator().answeredAskUserTool(
      record: record,
      answer: "yes",
      turnID: turnID
    )

    let updatedRecord = try #require(updatedToolCall(from: result.events))
    #expect(result.followUpPromptMode == .afterToolResultCanContinue)
    #expect(result.nextAssistantMessageID != nil)
    #expect(updatedRecord.status == .completed)
    #expect(toolResultEvent(from: result.events)?.payload == .askUser(AskUserResult(answer: "yes")))
    #expect(turnStatus(from: result.events) == .running)
  }

  @Test
  func deniedToolCreatesStableUserDeniedResultWithoutStartingFollowUp() throws {
    let turnID = UUID()
    let path = WorkspaceRelativePath(rawValue: "Sources/App.swift")
    let record = makeRecord(
      toolName: .editFile,
      payload: .editFile(EditFileInput(path: path.rawValue, oldText: "old", newText: "new")),
      evaluation: ToolPermissionEvaluation(
        decision: .requiresApproval,
        reason: "Writes require approval.",
        riskLevel: .high,
        workspaceRelativePaths: [path]
      ),
      state: .awaitingApproval(preview: nil)
    )

    let result = ToolResumeCoordinator().deniedTool(
      record: record,
      turnID: turnID
    )

    let updatedRecord = try #require(updatedToolCall(from: result.events))
    let resultMessage = try #require(toolResultEvent(from: result.events))
    #expect(result.followUpPromptMode == nil)
    #expect(result.nextAssistantMessageID == nil)
    #expect(updatedRecord.status == .denied)
    guard case .failure(let failure) = resultMessage.payload else {
      Issue.record("Expected a typed user-denied failure payload.")
      return
    }
    #expect(failure.reason == .userDenied)
    #expect(resultMessage.payload.preview.status == .denied)
    let projection = ToolResultProjector.project(
      payload: resultMessage.payload,
      request: updatedRecord.request
    )
    #expect(projection.metadata.kind == "user_denied")
    #expect(projection.observation.blocks == [.failure("Tool call denied by user.")])
    #expect(resultMessage.payload.preview.affectedPaths == [path.rawValue])
    #expect(turnStatus(from: result.events) == nil)
  }

  @Test
  func forceFinalRequestsAgentFinalFollowUp() throws {
    let result = ToolResumeCoordinator().followUpPromptMode(
      afterApprovedTool: failedRunCommandRecord(command: "git add."),
      toolProfile: .agent,
      forceFinal: true
    )

    #expect(result == .afterToolResultFinal)
  }

  @Test
  func forceFinalRequestsChatWebFinalFollowUpForChatWebProfile() throws {
    let result = ToolResumeCoordinator().followUpPromptMode(
      afterApprovedTool: failedRunCommandRecord(command: "git add."),
      toolProfile: .chatWeb,
      forceFinal: true
    )

    #expect(result == .afterChatWebToolResultFinal)
  }

  @Test
  func failedRunCommandWithoutForceFinalCanContinue() throws {
    let result = ToolResumeCoordinator().followUpPromptMode(
      afterApprovedTool: failedRunCommandRecord(command: "git add."),
      toolProfile: .agent
    )

    #expect(result == .afterToolResultCanContinue)
  }
}

private func failedRunCommandRecord(command: String) -> ToolCallRecord {
  makeRecord(
    toolName: .runCommand,
    payload: .runCommand(RunCommandInput(command: command, timeoutSeconds: 10)),
    state: .completed(
      .runCommand(
        RunCommandResult(
          command: command,
          timeoutSeconds: 10,
          exitCode: 1,
          durationMs: 5,
          stdout: ToolTextOutput(text: ""),
          stderr: ToolTextOutput(text: "failed")
        )))
  )
}

private func makeRecord(
  toolName: ToolName,
  payload: ToolCallPayload,
  evaluation: ToolPermissionEvaluation = ToolPermissionEvaluation(
    decision: .allowed,
    reason: "Allowed for test.",
    riskLevel: .low
  ),
  state: ToolCallState
) -> ToolCallRecord {
  let request = ToolCallRequest.validated(
    raw: RawToolCallRequest(
      workspaceID: UUID(),
      sessionID: UUID(),
      toolName: toolName
    ),
    payload: payload
  )
  return ToolCallRecord(
    request: request,
    evaluation: evaluation,
    state: state
  )
}

private func updatedToolCall(from events: [ChatWorkflowEvent]) -> ToolCallRecord? {
  for event in events {
    if case .toolCallUpdated(let record) = event {
      return record
    }
  }
  return nil
}

private func toolResultEvent(from events: [ChatWorkflowEvent]) -> ToolResultModelMessage? {
  for event in events {
    if case .toolResultAppended(let result, _) = event {
      return result
    }
  }
  return nil
}

private func assistantPlaceholderID(from events: [ChatWorkflowEvent]) -> UUID? {
  for event in events {
    if case .assistantPlaceholderAppended(let messageID, _) = event {
      return messageID
    }
  }
  return nil
}

private func focusedFileState(from events: [ChatWorkflowEvent]) -> FocusedFileState? {
  for event in events {
    if case .focusedFileStateChanged(let state) = event {
      return state
    }
  }
  return nil
}

private func turnStatus(from events: [ChatWorkflowEvent]) -> ChatTurnStatus? {
  for event in events {
    if case .turnStatusChanged(_, let status, _) = event {
      return status
    }
  }
  return nil
}
