import Foundation
import Testing

@testable import LocalCoderCore

struct ToolResultProjectorTests {
  @Test
  func showFileDisplaysContentButOmitsBodyFromDefaultObservation() {
    let request = request(
      toolName: .showFile,
      payload: .showFile(ReadFileInput(path: "Sources/App.swift", offset: 10, limit: 5))
    )
    let payload = ToolResultPayload.readFile(
      .success(
        path: WorkspaceRelativePath(rawValue: "Sources/App.swift"),
        content: ToolTextOutput(text: "10: let secret = true")
      ))

    let projection = ToolResultProjector.project(payload: payload, request: request)

    #expect(
      projection.display
        == .fileContent(
          path: WorkspaceRelativePath(rawValue: "Sources/App.swift"),
          content: ToolTextOutput(text: "10: let secret = true")
        ))
    #expect(
      projection.observation.blocks == [
        .fileDisplayedToUser(
          path: WorkspaceRelativePath(rawValue: "Sources/App.swift"),
          range: "offset=10,limit=5",
          lineCount: 1,
          byteCount: 21,
          truncated: false,
          redacted: false,
        )
      ])
    let rendered = ToolModelObservationRenderer.render(projection.observation, callID: UUID())
    #expect(rendered.contains("Displayed file to user: Sources/App.swift"))
    #expect(!rendered.contains("let secret = true"))
  }

  @Test
  func readFileIncludesBodyInDefaultObservation() {
    let request = request(
      toolName: .readFile,
      payload: .readFile(ReadFileInput(path: "README.md", offset: nil, limit: nil))
    )
    let payload = ToolResultPayload.readFile(
      .success(
        path: WorkspaceRelativePath(rawValue: "README.md"),
        content: ToolTextOutput(text: "1: project notes")
      ))

    let projection = ToolResultProjector.project(payload: payload, request: request)

    #expect(
      projection.observation.blocks == [
        .fileContent(
          path: WorkspaceRelativePath(rawValue: "README.md"),
          content: ToolTextOutput(text: "1: project notes")
        )
      ])
  }

  @Test
  func listAndSearchObservationsAreCappedByPolicy() {
    let listPayload = ToolResultPayload.listFiles(
      ListFilesResult(
        root: WorkspaceRelativePath(rawValue: "."),
        entries: [
          WorkspaceFileEntry(path: WorkspaceRelativePath(rawValue: "A.swift"), kind: .file),
          WorkspaceFileEntry(path: WorkspaceRelativePath(rawValue: "B.swift"), kind: .file),
        ]
      ))
    let listProjection = ToolResultProjector.project(
      payload: listPayload,
      request: request(toolName: .listFiles, payload: .listFiles(ListFilesInput(path: "."))),
      policy: ToolResultProjectionPolicy(maxListObservationEntries: 1)
    )

    #expect(
      listProjection.observation.blocks == [
        .fileList(
          root: WorkspaceRelativePath(rawValue: "."),
          entries: [
            WorkspaceFileEntry(path: WorkspaceRelativePath(rawValue: "A.swift"), kind: .file)
          ],
          totalCount: 2,
          truncated: true,
        )
      ])

    let searchPayload = ToolResultPayload.searchFiles(
      SearchFilesResult(
        root: WorkspaceRelativePath(rawValue: "."),
        pattern: "value",
        matches: [
          SearchFileMatch(
            path: WorkspaceRelativePath(rawValue: "A.swift"), line: 1, snippet: "value 1"),
          SearchFileMatch(
            path: WorkspaceRelativePath(rawValue: "B.swift"), line: 2, snippet: "value 2"),
        ]
      ))
    let searchProjection = ToolResultProjector.project(
      payload: searchPayload,
      request: request(
        toolName: .searchFiles,
        payload: .searchFiles(SearchFilesInput(pattern: "value", path: ".", include: nil))
      ),
      policy: ToolResultProjectionPolicy(maxSearchObservationSnippets: 1)
    )

    let expectedSearchBlocks: [ToolObservationBlock] = [
      .searchSnippets(
        root: WorkspaceRelativePath(rawValue: "."),
        pattern: "value",
        matches: [
          SearchFileMatch(
            path: WorkspaceRelativePath(rawValue: "A.swift"),
            line: 1,
            snippet: "value 1"
          )
        ],
        totalCount: 2,
        truncated: true
      )
    ]
    #expect(
      searchProjection.observation.blocks == expectedSearchBlocks)
  }

  @Test
  func writeAndEditUseCompactReceipts() {
    let writeProjection = ToolResultProjector.project(
      payload: .writeFile(
        .success(path: WorkspaceRelativePath(rawValue: "README.md"), bytesWritten: 12)
      ),
      request: request(
        toolName: .writeFile,
        payload: .writeFile(WriteFileInput(path: "README.md", content: "hello"))
      )
    )
    #expect(writeProjection.observation.blocks == [.summary("Wrote 12 bytes to README.md.")])

    let editProjection = ToolResultProjector.project(
      payload: .editFile(
        .success(
          path: WorkspaceRelativePath(rawValue: "README.md"),
          diff: "-old\n+new",
          matchStrategy: .exact
        )
      ),
      request: request(
        toolName: .editFile,
        payload: .editFile(EditFileInput(path: "README.md", oldText: "old", newText: "new"))
      )
    )
    #expect(
      editProjection.observation.blocks == [
        .editReceipt(
          path: WorkspaceRelativePath(rawValue: "README.md"),
          diffSummary: "-old\n+new",
          matchStrategy: .exact
        )
      ])
  }

  @Test
  func todoWriteObservationIsOnlyPlanUpdated() {
    let projection = ToolResultProjector.project(
      payload: .todoWrite(.success),
      request: request(
        toolName: .todoWrite,
        payload: .todoWrite(
          TodoWriteInput(items: [
            TodoItem(id: "inspect", content: "Inspect files", status: .completed),
            TodoItem(id: "verify", content: "Run tests", status: .pending),
          ]))
      )
    )
    let rendered = ToolModelObservationRenderer.render(projection.observation, callID: UUID())

    #expect(
      projection.display == .summary(status: .success, text: "Plan updated.", affectedPaths: []))
    #expect(rendered == "Plan updated.")
    #expect(!rendered.contains("Inspect files"))
  }

  @Test
  func runCommandProjectionReportsSuccessForZeroExit() {
    assertRunCommandProjection(
      runCommandResult(exitCode: 0),
      expectedStatus: .success
    )
  }

  @Test
  func runCommandProjectionReportsFailureForNonZeroExitAndKeepsOutputDetails() {
    let result = RunCommandResult(
      command: "just test-core",
      timeoutSeconds: 120,
      exitCode: 1,
      durationMs: 42,
      stdout: ToolTextOutput(text: "build started\n"),
      stderr: ToolTextOutput(text: "Tests failed\n")
    )

    let rendered = assertRunCommandProjection(
      result,
      expectedStatus: .failed
    )

    #expect(rendered.contains("Command: just test-core"))
    #expect(rendered.contains("Exit code: 1"))
    #expect(rendered.contains("Stdout preview:\nbuild started"))
    #expect(rendered.contains("Stderr preview:\nTests failed"))
  }

  @Test
  func runCommandProjectionReportsFailureForTimedOutCommand() {
    let rendered = assertRunCommandProjection(
      runCommandResult(exitCode: 0, timedOut: true),
      expectedStatus: .failed
    )

    #expect(rendered.contains("Timed out: true"))
  }

  @Test
  func runCommandProjectionReportsFailureForCancelledCommand() {
    let rendered = assertRunCommandProjection(
      runCommandResult(exitCode: 0, cancelled: true),
      expectedStatus: .failed
    )

    #expect(rendered.contains("Cancelled: true"))
  }

  @Test
  func runCommandProjectionReportsFailureForMissingExitCode() {
    let rendered = assertRunCommandProjection(
      runCommandResult(exitCode: nil),
      expectedStatus: .failed
    )

    #expect(rendered.contains("Exit code: none"))
  }

  @Test
  func workspaceDiagnosticsObservationStaysStructuredAndCompact() {
    let result = WorkspaceDiagnosticsResult(
      outputRef: "cmd_diag",
      diagnostics: [
        WorkspaceDiagnostic(
          path: WorkspaceRelativePath(rawValue: "Sources/App.code"),
          line: 7,
          column: 2,
          severity: .error,
          message: "broken"
        )
      ]
    )
    let projection = ToolResultProjector.project(
      payload: .workspaceDiagnostics(result),
      request: request(
        toolName: .workspaceDiagnostics,
        payload: .workspaceDiagnostics(WorkspaceDiagnosticsInput(outputRef: "cmd_diag"))
      )
    )

    let rendered = ToolModelObservationRenderer.render(projection.observation, callID: UUID())
    #expect(rendered.contains("Sources/App.code:7:2: error: broken"))
    #expect(!rendered.contains("stdout"))
    #expect(!rendered.contains("stderr"))
  }

  @Test
  func successProjectionsDoNotContainFailureBlocks() {
    let projections = [
      ToolResultProjector.project(
        payload: .readFile(
          .success(
            path: WorkspaceRelativePath(rawValue: "README.md"),
            content: ToolTextOutput(text: "notes")
          )),
        request: request(toolName: .readFile, payload: .readFile(ReadFileInput(path: "README.md")))
      ),
      ToolResultProjector.project(
        payload: .listFiles(
          ListFilesResult(
            root: WorkspaceRelativePath(rawValue: "."),
            entries: []
          )),
        request: request(toolName: .listFiles, payload: .listFiles(ListFilesInput(path: ".")))
      ),
      ToolResultProjector.project(
        payload: .searchFiles(
          SearchFilesResult(
            root: WorkspaceRelativePath(rawValue: "."),
            pattern: "value",
            matches: []
          )
        ),
        request: request(
          toolName: .searchFiles,
          payload: .searchFiles(SearchFilesInput(pattern: "value", path: ".", include: nil))
        )
      ),
      ToolResultProjector.project(
        payload: .workspaceDiff(
          .success(
            path: nil,
            content: ToolTextOutput(text: "No workspace changes.")
          )
        ),
        request: request(toolName: .workspaceDiff, payload: .workspaceDiff(WorkspaceDiffInput()))
      ),
      ToolResultProjector.project(
        payload: .writeFile(
          .success(path: WorkspaceRelativePath(rawValue: "README.md"), bytesWritten: 5)
        ),
        request: request(
          toolName: .writeFile,
          payload: .writeFile(WriteFileInput(path: "README.md", content: "hello"))
        )
      ),
      ToolResultProjector.project(
        payload: .editFile(
          .success(
            path: WorkspaceRelativePath(rawValue: "README.md"),
            diff: nil,
            matchStrategy: .exact
          )
        ),
        request: request(
          toolName: .editFile,
          payload: .editFile(EditFileInput(path: "README.md", oldText: "old", newText: "new"))
        )
      ),
    ]

    for projection in projections {
      #expect(projection.observation.status == .success)
      #expect(!projection.observation.blocks.containsFailure)
    }
  }

  @Test
  func failureProjectionUsesFailureBlock() {
    let projection = ToolResultProjector.project(
      payload: .failure(
        ToolFailure(
          toolName: .readFile,
          path: WorkspaceRelativePath(rawValue: "missing.swift"),
          reason: .executionError("No such file")
        )),
      request: request(
        toolName: .readFile,
        payload: .readFile(ReadFileInput(path: "missing.swift", offset: nil, limit: nil))
      )
    )

    guard case .summary(let status, _, _) = projection.display else {
      Issue.record("Expected failed display summary.")
      return
    }
    #expect(status == .failed)
    #expect(projection.observation.status == .failed)
    #expect(
      projection.observation.blocks == [
        .failure("read_file failed for missing.swift: No such file")
      ])
  }

  @Test
  func askUserProjectionUsesCompactAnswerReceipt() {
    let projection = ToolResultProjector.project(
      payload: .askUser(AskUserResult(answer: "Minimal fix")),
      request: request(
        toolName: .askUser,
        payload: .askUser(
          AskUserInput(
            question: "Which implementation should I use?",
            options: ["Minimal fix", "Broader refactor"]
          ))
      )
    )

    guard case .summary(let status, let text, let affectedPaths) = projection.display else {
      Issue.record("Expected ask_user display summary.")
      return
    }
    #expect(status == .success)
    #expect(text == "User answered: Minimal fix")
    #expect(affectedPaths.isEmpty)
    #expect(projection.observation.status == .success)
    #expect(projection.observation.blocks == [.summary("User answered: Minimal fix")])
  }

  @Test
  func deniedFailureProjectionPreservesRecoveryMessage() {
    let projection = ToolResultProjector.project(
      payload: .failure(
        ToolFailure(
          toolName: .writeFile,
          path: WorkspaceRelativePath(rawValue: "README.md"),
          reason: .permissionDenied,
          recovery: .askUser(message: "Tool call denied by user.")
        )),
      request: request(
        toolName: .writeFile,
        payload: .writeFile(WriteFileInput(path: "README.md", content: "hello"))
      )
    )

    guard case .summary(let status, let text, _) = projection.display else {
      Issue.record("Expected denied display summary.")
      return
    }
    #expect(status == .denied)
    #expect(projection.observation.status == .denied)
    #expect(text.contains("Permission denied. Tool call denied by user."))
    #expect(
      projection.observation.blocks == [
        .failure("write_file failed for README.md: Permission denied. Tool call denied by user.")
      ])
  }

  @Test
  func projectionLimiterLeavesTextBelowLimitUnchanged() {
    let result = ProjectionLimiter.limit(
      "short observation",
      limit: ProjectionLimit(maxCharacters: 80, strategy: .headTail)
    )

    #expect(result.text == "short observation")
    #expect(!result.wasLimited)
    #expect(!result.text.contains("tool observation truncated"))
  }

  @Test
  func projectionLimiterSupportsHeadTruncation() {
    let text = String(repeating: "a", count: 40) + String(repeating: "z", count: 40)
    let result = ProjectionLimiter.limit(
      text,
      limit: ProjectionLimit(maxCharacters: 50, strategy: .head)
    )

    #expect(result.wasLimited)
    #expect(result.text.count <= 50)
    #expect(result.text.hasPrefix(String(repeating: "a", count: 20)))
    #expect(result.text.contains("tool observation truncated"))
    #expect(!result.text.contains(String(repeating: "z", count: 20)))
  }

  @Test
  func projectionLimiterSupportsTailTruncation() {
    let text = String(repeating: "a", count: 40) + String(repeating: "z", count: 40)
    let result = ProjectionLimiter.limit(
      text,
      limit: ProjectionLimit(maxCharacters: 50, strategy: .tail)
    )

    #expect(result.wasLimited)
    #expect(result.text.count <= 50)
    #expect(result.text.hasSuffix(String(repeating: "z", count: 20)))
    #expect(result.text.contains("tool observation truncated"))
    #expect(!result.text.contains(String(repeating: "a", count: 20)))
  }

  @Test
  func projectionLimiterSupportsHeadTailTruncation() {
    let text = String(repeating: "a", count: 40) + String(repeating: "z", count: 40)
    let result = ProjectionLimiter.limit(
      text,
      limit: ProjectionLimit(maxCharacters: 50, strategy: .headTail)
    )

    #expect(result.wasLimited)
    #expect(result.text.count <= 50)
    #expect(result.text.hasPrefix(String(repeating: "a", count: 10)))
    #expect(result.text.hasSuffix(String(repeating: "z", count: 10)))
    #expect(result.text.contains("tool observation truncated"))
  }

  @Test
  func modelFacingObservationLimitPreservesDisplayPayload() throws {
    let fullContent = String(repeating: "0123456789", count: 40)
    let path = WorkspaceRelativePath(rawValue: "README.md")
    let payload = ToolResultPayload.readFile(
      .success(path: path, content: ToolTextOutput(text: fullContent))
    )
    let request = request(
      toolName: .readFile,
      payload: .readFile(ReadFileInput(path: "README.md", offset: nil, limit: nil))
    )

    let projection = ToolResultProjector.project(payload: payload, request: request)
    guard case .fileContent(_, let displayContent) = projection.display else {
      Issue.record("Expected full file display payload.")
      return
    }
    #expect(displayContent.text == fullContent)

    let callID = UUID()
    let entry = try ModelFacingPromptRenderer.toolResultEntry(
      toolResult: ToolResultModelMessage(
        callID: callID,
        toolName: .readFile,
        payload: payload
      ),
      request: request,
      originalUserRequest: nil,
      policy: ToolResultProjectionPolicy(
        modelObservationLimit: ProjectionLimit(maxCharacters: 160, strategy: .headTail)
      )
    )

    guard case .toolObservation(let context) = entry.body else {
      Issue.record("Expected model-facing tool observation.")
      return
    }
    #expect(context.content.count <= 160)
    #expect(context.content.contains("tool observation truncated"))
    #expect(!context.content.contains(fullContent))
    #expect(
      context.content
        != ToolModelObservationRenderer.render(
          projection.observation,
          callID: callID
        ))
  }

  private func request(toolName: ToolName, payload: ToolCallPayload) -> ToolCallRequest {
    ToolCallRequest.validated(
      raw: RawToolCallRequest(
        workspaceID: UUID(),
        sessionID: UUID(),
        toolName: toolName
      ),
      payload: payload
    )
  }

  @discardableResult
  private func assertRunCommandProjection(
    _ result: RunCommandResult,
    expectedStatus: ToolResultStatus
  ) -> String {
    let projection = ToolResultProjector.project(
      payload: .runCommand(result),
      request: request(
        toolName: .runCommand,
        payload: .runCommand(
          RunCommandInput(command: result.command, timeoutSeconds: result.timeoutSeconds)
        )
      )
    )

    guard case .summary(let displayStatus, let text, let affectedPaths) = projection.display else {
      Issue.record("Expected run_command display summary.")
      return ""
    }
    #expect(displayStatus == expectedStatus)
    #expect(text == result.previewText)
    #expect(affectedPaths == [WorkspaceRelativePath(rawValue: ".")])
    #expect(projection.observation.status == expectedStatus)
    #expect(projection.observation.blocks == [.commandResult(result)])

    let rendered = ToolModelObservationRenderer.render(projection.observation, callID: UUID())
    #expect(
      rendered.contains(
        "tool=\"run_command\" status=\"\(expectedStatus.rawValue)\""
      ))
    return rendered
  }

  private func runCommandResult(
    exitCode: Int32?,
    timedOut: Bool = false,
    cancelled: Bool = false
  ) -> RunCommandResult {
    RunCommandResult(
      command: "just test-core",
      timeoutSeconds: 120,
      exitCode: exitCode,
      durationMs: 42,
      stdout: ToolTextOutput(text: ""),
      stderr: ToolTextOutput(text: ""),
      timedOut: timedOut,
      cancelled: cancelled
    )
  }
}

extension [ToolObservationBlock] {
  fileprivate var containsFailure: Bool {
    contains { block in
      if case .failure = block {
        return true
      }
      return false
    }
  }
}
