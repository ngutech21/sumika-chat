import Foundation
import Testing

@testable import SumikaCore

struct ToolFollowUpNoticePolicyTests {
  @Test
  func genericNoticeTargetsLatestModelFacingToolRecord() throws {
    let first = completedReadRecord(id: UUID(), path: "README.md", content: "Project overview")
    let latest = completedListRecord(id: UUID(), entries: ["README.md"])
    let update = try #require(
      ToolFollowUpNoticePolicy().update(
        session: session(with: [first, latest]),
        turnID: defaultTurnID,
        promptMode: .afterToolResultCanContinue
      ))

    #expect(update.record.id == latest.id)
    #expect(
      update.record.modelFollowUpNotice?.contains("Continue using the latest tool observation")
        == true)
    #expect(update.record.modelFollowUpNotice?.contains("call finish_task") == true)
    #expect(first.modelFollowUpNotice == nil)
    #expect(latest.modelFollowUpNotice == nil)
  }

  @Test
  func chatWebContinuationKeepsDirectFinalAnswerWording() throws {
    let record = completedReadRecord(id: UUID(), path: "README.md", content: "Project overview")
    let update = try #require(
      ToolFollowUpNoticePolicy().update(
        session: session(with: [record], interactionMode: .chat),
        turnID: defaultTurnID,
        promptMode: .afterChatWebToolResultCanContinue
      ))

    #expect(update.record.modelFollowUpNotice?.contains("provide the final answer") == true)
    #expect(update.record.modelFollowUpNotice?.contains("finish_task") == false)
  }

  @Test
  func finalNoToolsNoticeHasHighestPriority() throws {
    let failedCommand = completedRunCommandRecord(
      id: UUID(),
      command: "just test",
      exitCode: 1
    )

    let update = try #require(
      ToolFollowUpNoticePolicy().update(
        session: session(with: [failedCommand]),
        turnID: defaultTurnID,
        promptMode: .afterToolResultFinal
      ))

    #expect(update.record.id == failedCommand.id)
    #expect(update.record.modelFollowUpNotice?.contains("No more tools are available") == true)
    #expect(update.record.modelFollowUpNotice?.contains("latest run_command failed") == false)
  }

  @Test
  func repeatedFailingRunCommandEscalatesToUserOnFinal() throws {
    // Two consecutive identical failing run_commands + a forced final generation must yield
    // an actionable escalation (names the command + error, asks the user to act) rather than
    // the generic "no more tools" close.
    let first = completedRunCommandRecord(id: UUID(), command: "git add.", exitCode: 1)
    let second = completedRunCommandRecord(id: UUID(), command: "git add.", exitCode: 1)

    let update = try #require(
      ToolFollowUpNoticePolicy().update(
        session: session(with: [first, second]),
        turnID: defaultTurnID,
        promptMode: .afterToolResultFinal
      ))

    let notice = try #require(update.record.modelFollowUpNotice)
    #expect(notice.contains("failed both times"))
    #expect(notice.contains("Command: git add."))
    #expect(notice.contains("run or fix the command manually"))
    #expect(!notice.contains("Mention completed changes"))
  }

  @Test
  func finalWithoutRepeatedRunCommandUsesGenericFinalNotice() throws {
    let record = completedReadRecord(id: UUID(), path: "README.md", content: "hi")

    let update = try #require(
      ToolFollowUpNoticePolicy().update(
        session: session(with: [record]),
        turnID: defaultTurnID,
        promptMode: .afterToolResultFinal
      ))

    #expect(update.record.modelFollowUpNotice?.contains("No more tools are available") == true)
    #expect(update.record.modelFollowUpNotice?.contains("failed both times") == false)
  }

  @Test
  func chatSessionFinalNoticeUsesWebWordingNotAgentRules() throws {
    // A chat (web) session must receive a follow-up notice at all (guard is no longer
    // agent-only), and the final notice must be web-flavored — no workspace/file wording.
    let record = completedReadRecord(id: UUID(), path: "README.md", content: "1: hi")

    let update = try #require(
      ToolFollowUpNoticePolicy().update(
        session: session(with: [record], interactionMode: .chat),
        turnID: defaultTurnID,
        promptMode: .afterChatWebToolResultFinal
      ))

    let notice = try #require(update.record.modelFollowUpNotice)
    #expect(notice.contains("No more tools are available"))
    #expect(notice.contains("web results already in context"))
    #expect(!notice.contains("write_file"))
    #expect(!notice.contains("workspace change"))
    #expect(!notice.contains("affected paths"))
  }

  @Test
  func failedRunCommandBeatsRunCommandResultNotice() throws {
    let command = "just test"
    let first = completedRunCommandRecord(id: UUID(), command: command, exitCode: 1)
    let second = completedRunCommandRecord(id: UUID(), command: command, exitCode: 1)

    let update = try #require(
      ToolFollowUpNoticePolicy().update(
        session: session(with: [first, second]),
        turnID: defaultTurnID,
        promptMode: .afterToolResultCanContinue
      ))

    #expect(update.record.id == second.id)
    #expect(update.record.modelFollowUpNotice?.contains("The latest run_command failed.") == true)
    #expect(update.record.modelFollowUpNotice?.contains("Command: just test") == true)
    #expect(
      update.record.modelFollowUpNotice?.contains("already available for this exact command")
        == false)
  }

  @Test
  func runCommandResultNoticeTargetsLatestCompletedCommandImmediately() throws {
    let command = completedRunCommandRecord(id: UUID(), command: "date", exitCode: 0)

    let update = try #require(
      ToolFollowUpNoticePolicy().update(
        session: session(with: [command]),
        turnID: defaultTurnID,
        promptMode: .afterToolResultCanContinue
      ))

    #expect(update.record.id == command.id)
    #expect(
      update.record.modelFollowUpNotice?.contains("already available for this exact command")
        == true)
  }

  @Test
  func listingWanderingBeatsGenericAndReplaysLatestEntries() throws {
    let first = completedListRecord(id: UUID(), entries: ["README.md"])
    let second = completedListRecord(id: UUID(), entries: ["Sources/"])

    let update = try #require(
      ToolFollowUpNoticePolicy().update(
        session: session(with: [first, second]),
        turnID: defaultTurnID,
        promptMode: .afterToolResultCanContinue
      ))

    #expect(update.record.id == second.id)
    #expect(
      update.record.modelFollowUpNotice?.contains("You are looping on listings/searches") == true)
    #expect(update.record.modelFollowUpNotice?.contains("- Sources/") == true)
    #expect(
      update.record.modelFollowUpNotice?.contains("Continue using the latest tool observation")
        == false)
  }

  @Test
  func repeatedReadReplayBeatsGenericDuplicateNotice() throws {
    let firstDuplicate = duplicateReadRecord(id: UUID(), previousCallID: UUID())
    let secondDuplicate = duplicateReadRecord(id: UUID(), previousCallID: UUID())

    let update = try #require(
      ToolFollowUpNoticePolicy().update(
        session: session(with: [firstDuplicate, secondDuplicate]),
        turnID: defaultTurnID,
        promptMode: .afterToolResultCanContinue
      ))

    #expect(update.record.id == secondDuplicate.id)
    #expect(
      update.record.modelFollowUpNotice?.contains("Repeated read_file replay detected") == true)
    #expect(update.record.modelFollowUpNotice?.contains("observation replays a result") == false)
  }

  @Test
  func duplicateReplayNoticeAppliesToSingleDuplicate() throws {
    let duplicate = duplicateReadRecord(id: UUID(), previousCallID: UUID())

    let update = try #require(
      ToolFollowUpNoticePolicy().update(
        session: session(with: [duplicate]),
        turnID: defaultTurnID,
        promptMode: .afterToolResultCanContinue
      ))

    #expect(update.record.id == duplicate.id)
    #expect(
      update.record.modelFollowUpNotice?.contains("read_file observation replays a result")
        == true)
  }

  @Test
  func noNoticeWithoutMatchingToolRecord() {
    let session = ChatSession(
      turns: [
        ChatTurn(
          id: defaultTurnID,
          status: .running,
          items: [.userMessage(UserTurnMessage(content: "hello"))]
        )
      ],
      interactionMode: .agent
    )

    let update = ToolFollowUpNoticePolicy().update(
      session: session,
      turnID: defaultTurnID,
      promptMode: .afterToolResultCanContinue
    )

    #expect(update == nil)
  }

  @Test
  func existingNoticeIsNotOverwritten() {
    let record = completedReadRecord(
      id: UUID(),
      path: "README.md",
      content: "Project overview",
      modelFollowUpNotice: "already cached"
    )

    let update = ToolFollowUpNoticePolicy().update(
      session: session(with: [record]),
      turnID: defaultTurnID,
      promptMode: .afterToolResultFinal
    )

    #expect(update == nil)
  }
}

private let defaultTurnID = UUID()

private func session(
  with records: [ToolCallRecord],
  interactionMode: WorkspaceInteractionMode = .agent
) -> ChatSession {
  ChatSession(
    turns: [
      ChatTurn(
        id: defaultTurnID,
        status: .running,
        items: records.map(ChatTurnItem.tool)
      )
    ],
    interactionMode: interactionMode
  )
}

private func completedReadRecord(
  id: UUID,
  path: String,
  content: String,
  modelFollowUpNotice: String? = nil
) -> ToolCallRecord {
  toolRecord(
    id: id,
    toolName: .readFile,
    payload: .readFile(ReadFileInput(path: path)),
    result: .readFile(
      .success(
        path: WorkspaceRelativePath(rawValue: path),
        content: ToolTextOutput(text: content)
      )),
    modelFollowUpNotice: modelFollowUpNotice
  )
}

private func completedListRecord(id: UUID, entries: [String]) -> ToolCallRecord {
  toolRecord(
    id: id,
    toolName: .listFiles,
    payload: .listFiles(ListFilesInput(path: nil)),
    result: .listFiles(
      ListFilesResult(
        root: WorkspaceRelativePath(rawValue: "."),
        entries: entries.map { entry in
          WorkspaceFileEntry(
            path: WorkspaceRelativePath(rawValue: entry.trimmingSuffix("/")),
            kind: entry.hasSuffix("/") ? .directory : .file
          )
        }
      ))
  )
}

private func completedRunCommandRecord(
  id: UUID,
  command: String,
  exitCode: Int32
) -> ToolCallRecord {
  toolRecord(
    id: id,
    toolName: .runCommand,
    payload: .runCommand(RunCommandInput(command: command, timeoutSeconds: 10)),
    result: .runCommand(
      RunCommandResult(
        command: command,
        timeoutSeconds: 10,
        exitCode: exitCode,
        durationMs: 10,
        stdout: ToolTextOutput(text: exitCode == 0 ? "ok" : ""),
        stderr: ToolTextOutput(text: exitCode == 0 ? "" : "failed")
      ))
  )
}

private func duplicateReadRecord(id: UUID, previousCallID: UUID) -> ToolCallRecord {
  toolRecord(
    id: id,
    toolName: .readFile,
    payload: .readFile(ReadFileInput(path: "README.md")),
    result: .duplicateToolCall(
      DuplicateToolCallResult(
        previousCallID: previousCallID,
        message: "Duplicate read_file call.",
        affectedPaths: [WorkspaceRelativePath(rawValue: "README.md")]
      ))
  )
}

private func toolRecord(
  id: UUID,
  toolName: ToolName,
  payload: ToolCallPayload,
  result: ToolResultPayload,
  modelFollowUpNotice: String? = nil
) -> ToolCallRecord {
  ToolCallRecord(
    request: .validated(
      raw: RawToolCallRequest(
        id: id,
        workspaceID: UUID(),
        sessionID: UUID(),
        toolName: toolName
      ),
      payload: payload
    ),
    evaluation: ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Allowed for test.",
      riskLevel: .low
    ),
    state: .completed(result),
    modelFollowUpNotice: modelFollowUpNotice
  )
}

extension String {
  fileprivate func trimmingSuffix(_ suffix: String) -> String {
    guard hasSuffix(suffix) else {
      return self
    }
    return String(dropLast(suffix.count))
  }
}
