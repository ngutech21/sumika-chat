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
      update.record.modelFollowUpNotice
        == "Use this tool result. Call another necessary tool, or finish_task if done.")
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

    #expect(update.record.modelFollowUpNotice?.contains("answer if done") == true)
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
  func exhaustedToolBudgetRequiresBlockedFinishTaskWhenIncomplete() throws {
    let record = completedReadRecord(id: UUID(), path: "README.md", content: "hi")

    let update = try #require(
      ToolFollowUpNoticePolicy().update(
        session: session(with: [record]),
        turnID: defaultTurnID,
        promptMode: .afterToolBudgetExhausted
      ))

    #expect(
      update.record.modelFollowUpNotice
        == """
        The action-tool budget is exhausted. Stop all remaining work and do not attempt another action.
        Call `finish_task` exactly once and alone.
        If the requested work is incomplete, call `finish_task` with `status: blocked` and explain what completed and what remains in `summary`.
        Put the complete user-visible final response in `summary`. Emit no visible prose and call no other tool.
        """)
  }

  @Test
  func toolBudgetWarningShowsEachOfLastTwoRemainingBatches() throws {
    let beforeLastTwo = try #require(
      ToolFollowUpNoticePolicy().update(
        session: sessionWithToolCallBatches(count: 9),
        turnID: defaultTurnID,
        promptMode: .afterToolResultCanContinue,
        maxToolLoopIterations: 12
      ))
    #expect(
      beforeLastTwo.record.modelFollowUpNotice?
        .contains("Remaining action-tool batch budget") == false)

    for remainingBatchCount in 1...2 {
      let update = try #require(
        ToolFollowUpNoticePolicy().update(
          session: sessionWithToolCallBatches(count: 12 - remainingBatchCount),
          turnID: defaultTurnID,
          promptMode: .afterToolResultCanContinue,
          maxToolLoopIterations: 12
        ))
      let notice = try #require(update.record.modelFollowUpNotice)
      #expect(
        notice.contains("Remaining action-tool batch budget: \(remainingBatchCount)."))
      #expect(notice.contains("Call another necessary tool, or finish_task if done."))
    }
  }

  @Test
  func toolBudgetWarningDoesNotApplyToChatWeb() throws {
    let update = try #require(
      ToolFollowUpNoticePolicy().update(
        session: sessionWithToolCallBatches(count: 10, interactionMode: .chat),
        turnID: defaultTurnID,
        promptMode: .afterChatWebToolResultCanContinue,
        maxToolLoopIterations: 12
      ))

    #expect(
      update.record.modelFollowUpNotice?
        .contains("Remaining action-tool batch budget") == false)
    #expect(update.record.modelFollowUpNotice?.contains("answer if done") == true)
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
  func readFileContinuationNoticeUsesNextOffsetWithoutRepeatingLimit() throws {
    let record = try completedReadPageRecord(
      path: "Sources/App.swift",
      startLine: 1,
      endLine: 20,
      continuation: .next(offset: 21, reason: .lineLimit),
      limit: 20
    )

    let update = try #require(
      ToolFollowUpNoticePolicy().update(
        session: session(with: [record]),
        turnID: defaultTurnID,
        promptMode: .afterToolResultCanContinue
      )
    )
    let notice = try #require(update.record.modelFollowUpNotice)

    #expect(
      notice.contains(
        #"continue with read_file(path: "Sources/App.swift", offset: 21)"#
      )
    )
    #expect(!notice.contains("limit"))
  }

  @Test
  func readFileBlockedNoticeDirectsTargetedSearch() throws {
    let record = try completedReadPageRecord(
      path: "minified.js",
      startLine: 1,
      endLine: 3,
      continuation: .blocked(line: 4, byteCount: 184_320)
    )

    let update = try #require(
      ToolFollowUpNoticePolicy().update(
        session: session(with: [record]),
        turnID: defaultTurnID,
        promptMode: .afterToolResultCanContinue
      )
    )
    let notice = try #require(update.record.modelFollowUpNotice)

    #expect(notice.contains("Line 4 is 184320 bytes"))
    #expect(notice.contains("use search_files"))
    #expect(!notice.contains("offset: 4"))
  }

  @Test
  func partialWorkspaceDiagnosticsSearchNoticeDoesNotClaimTotalMatches() throws {
    let record = completedWorkspaceDiagnosticsSearchRecord(
      startLine: 1,
      scannedThrough: 450,
      lineCount: 903,
      matchLines: [450],
      continuation: .next(offset: 451, reason: .matchLimit)
    )

    let update = try #require(
      ToolFollowUpNoticePolicy().update(
        session: session(with: [record]),
        turnID: defaultTurnID,
        promptMode: .afterToolResultCanContinue
      )
    )
    let notice = try #require(update.record.modelFollowUpNotice)

    #expect(notice.contains("This workspace_diagnostics search is incomplete."))
    #expect(notice.contains("Returned matches: 1. Scanned lines: 1-450."))
    #expect(notice.contains("This is not a total match count"))
    #expect(notice.contains("does not establish uniqueness or absence"))
    #expect(notice.contains("using offset 451"))
    #expect(notice.contains("finish_task if done"))
  }

  @Test
  func completedWorkspaceDiagnosticsSearchUsesGenericFollowUp() throws {
    let record = completedWorkspaceDiagnosticsSearchRecord(
      startLine: 1,
      scannedThrough: 903,
      lineCount: 903,
      matchLines: [450],
      continuation: .endOfOutput
    )

    let update = try #require(
      ToolFollowUpNoticePolicy().update(
        session: session(with: [record]),
        turnID: defaultTurnID,
        promptMode: .afterToolResultCanContinue
      )
    )
    let notice = try #require(update.record.modelFollowUpNotice)

    #expect(notice == "Use this tool result. Call another necessary tool, or finish_task if done.")
    #expect(!notice.contains("search is incomplete"))
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

private func sessionWithToolCallBatches(
  count: Int,
  interactionMode: WorkspaceInteractionMode = .agent
) -> ChatSession {
  var items: [ChatTurnItem] = []
  for index in 0..<count {
    if index > 0 {
      items.append(.assistantMessage(AssistantTurnMessage(content: "")))
    }
    items.append(
      .tool(
        completedReadRecord(
          id: UUID(),
          path: "File\(index).swift",
          content: "content"
        )))
  }
  return ChatSession(
    turns: [
      ChatTurn(
        id: defaultTurnID,
        status: .running,
        items: items
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
      .legacySuccess(
        path: WorkspaceRelativePath(rawValue: path),
        content: ToolTextOutput(text: content)
      )),
    modelFollowUpNotice: modelFollowUpNotice
  )
}

private func completedReadPageRecord(
  path: String,
  startLine: Int,
  endLine: Int?,
  continuation: ReadFileContinuation,
  limit: Int? = nil
) throws -> ToolCallRecord {
  let content =
    endLine.map { endLine in
      (startLine...endLine).map { "line \($0)" }.joined(separator: "\n")
    } ?? ""
  return toolRecord(
    id: UUID(),
    toolName: .readFile,
    payload: .readFile(ReadFileInput(path: path, offset: startLine, limit: limit)),
    result: .readFile(
      .page(
        try ReadFilePage(
          path: WorkspaceRelativePath(rawValue: path),
          startLine: startLine,
          endLine: endLine,
          content: content,
          continuation: continuation
        )
      )
    )
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

private func completedWorkspaceDiagnosticsSearchRecord(
  startLine: Int,
  scannedThrough: Int?,
  lineCount: Int,
  matchLines: [Int],
  continuation: WorkspaceDiagnosticsContinuation
) -> ToolCallRecord {
  let outputRef = "cmd_search"
  return toolRecord(
    id: UUID(),
    toolName: .workspaceDiagnostics,
    payload: .workspaceDiagnostics(
      WorkspaceDiagnosticsInput(
        outputRef: outputRef,
        operation: .search,
        stream: .combined,
        offset: startLine,
        limit: 1,
        pattern: "^FAIL:"
      )
    ),
    result: .workspaceDiagnostics(
      .search(
        outputRef: outputRef,
        result: .page(
          CommandOutputSearchPage(
            stream: .combined,
            pattern: "^FAIL:",
            startLine: startLine,
            scannedThrough: scannedThrough,
            lineCount: lineCount,
            matches: matchLines.map { line in
              CommandOutputSearchMatch(
                origin: .stdout,
                streamLine: line,
                combinedLine: line,
                snippet: "FAIL: hidden-marker-\(line)",
                snippetTruncated: false
              )
            },
            continuation: continuation
          )
        )
      )
    )
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
