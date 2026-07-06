import Foundation
import Testing

@testable import SumikaCore

struct RunCommandRepeatPolicyTests {
  @Test
  func singleFailureDoesNotForceFinal() {
    let command = failedRunCommand(id: UUID(), command: "git add.")

    #expect(!RunCommandRepeatPolicy.forcesFinalAfterRepeatedFailure(command, priorItems: []))
    #expect(RunCommandRepeatPolicy.repeatedFailure(inTailOf: [.tool(command)]) == nil)
  }

  @Test
  func twoConsecutiveIdenticalFailuresForceFinalAndEscalate() {
    let first = failedRunCommand(id: UUID(), command: "git add.")
    let second = failedRunCommand(id: UUID(), command: "git add.")

    #expect(
      RunCommandRepeatPolicy.forcesFinalAfterRepeatedFailure(
        second, priorItems: [.tool(first), separator()]))

    let repeated = RunCommandRepeatPolicy.repeatedFailure(
      inTailOf: [.tool(first), separator(), .tool(second)])
    #expect(repeated?.command == "git add.")
  }

  @Test
  func priorSuccessDoesNotForceFinal() {
    let first = succeededRunCommand(id: UUID(), command: "git add.")
    let second = failedRunCommand(id: UUID(), command: "git add.")

    #expect(
      !RunCommandRepeatPolicy.forcesFinalAfterRepeatedFailure(second, priorItems: [.tool(first)]))
    #expect(
      RunCommandRepeatPolicy.repeatedFailure(inTailOf: [.tool(first), .tool(second)]) == nil)
  }

  @Test
  func differentCommandsDoNotForceFinal() {
    let first = failedRunCommand(id: UUID(), command: "git status")
    let second = failedRunCommand(id: UUID(), command: "git add.")

    #expect(
      !RunCommandRepeatPolicy.forcesFinalAfterRepeatedFailure(second, priorItems: [.tool(first)]))
  }

  @Test
  func nonRunCommandToolBetweenResetsStreak() {
    let first = failedRunCommand(id: UUID(), command: "git add.")
    let read = readFileRecord(id: UUID())
    let second = failedRunCommand(id: UUID(), command: "git add.")

    #expect(
      !RunCommandRepeatPolicy.forcesFinalAfterRepeatedFailure(
        second, priorItems: [.tool(first), .tool(read)]))
    #expect(
      RunCommandRepeatPolicy.repeatedFailure(
        inTailOf: [.tool(first), .tool(read), .tool(second)]) == nil)
  }

  @Test
  func currentSuccessDoesNotForceFinal() {
    let first = failedRunCommand(id: UUID(), command: "git add.")
    let second = succeededRunCommand(id: UUID(), command: "git add.")

    #expect(
      !RunCommandRepeatPolicy.forcesFinalAfterRepeatedFailure(second, priorItems: [.tool(first)]))
    #expect(
      RunCommandRepeatPolicy.repeatedFailure(inTailOf: [.tool(first), .tool(second)]) == nil)
  }

  @Test
  func awaitingApprovalCopyWithSameIDIsSkipped() {
    // At approve time the turn still holds the awaiting-approval version of the record that
    // just completed (same id). The policy must skip it and match the earlier failure.
    let secondID = UUID()
    let first = failedRunCommand(id: UUID(), command: "git add.")
    let awaiting = awaitingRunCommand(id: secondID, command: "git add.")
    let completedSecond = failedRunCommand(id: secondID, command: "git add.")

    #expect(
      RunCommandRepeatPolicy.forcesFinalAfterRepeatedFailure(
        completedSecond, priorItems: [.tool(first), separator(), .tool(awaiting)]))
  }
}

private func separator() -> ChatTurnItem {
  .userMessage(UserTurnMessage(content: "context"))
}

private func failedRunCommand(id: UUID, command: String) -> ToolCallRecord {
  runCommandRecord(
    id: id,
    command: command,
    state: .completed(
      .runCommand(
        RunCommandResult(
          command: command,
          timeoutSeconds: 10,
          exitCode: 1,
          durationMs: 5,
          stdout: ToolTextOutput(text: ""),
          stderr: ToolTextOutput(text: "failed")
        ))))
}

private func succeededRunCommand(id: UUID, command: String) -> ToolCallRecord {
  runCommandRecord(
    id: id,
    command: command,
    state: .completed(
      .runCommand(
        RunCommandResult(
          command: command,
          timeoutSeconds: 10,
          exitCode: 0,
          durationMs: 5,
          stdout: ToolTextOutput(text: "ok"),
          stderr: ToolTextOutput(text: "")
        ))))
}

private func awaitingRunCommand(id: UUID, command: String) -> ToolCallRecord {
  runCommandRecord(id: id, command: command, state: .awaitingApproval(preview: nil))
}

private func runCommandRecord(
  id: UUID,
  command: String,
  state: ToolCallState
) -> ToolCallRecord {
  ToolCallRecord(
    request: .validated(
      raw: RawToolCallRequest(
        id: id,
        workspaceID: UUID(),
        sessionID: UUID(),
        toolName: .runCommand
      ),
      payload: .runCommand(RunCommandInput(command: command, timeoutSeconds: 10))
    ),
    evaluation: ToolPermissionEvaluation(
      decision: .requiresApproval,
      reason: "Running commands requires approval.",
      riskLevel: .high
    ),
    state: state
  )
}

private func readFileRecord(id: UUID) -> ToolCallRecord {
  ToolCallRecord(
    request: .validated(
      raw: RawToolCallRequest(
        id: id,
        workspaceID: UUID(),
        sessionID: UUID(),
        toolName: .readFile
      ),
      payload: .readFile(ReadFileInput(path: "README.md"))
    ),
    evaluation: ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Allowed for test.",
      riskLevel: .low
    ),
    state: .completed(
      .readFile(
        .success(
          path: WorkspaceRelativePath(rawValue: "README.md"),
          content: ToolTextOutput(text: "hi")
        )))
  )
}
