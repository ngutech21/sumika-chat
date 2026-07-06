import Foundation
import Testing

@testable import SumikaCore

struct ToolResultPayloadTests {
  @Test
  func toolResultPayloadCodableRoundTripsBuiltInResults() throws {
    let duplicatePreviousCallID = try #require(
      UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    let payloads: [ToolResultPayload] = [
      .readFile(
        .success(
          path: WorkspaceRelativePath(rawValue: "README.md"),
          content: ToolTextOutput(text: "1: hello", truncated: true)
        )),
      .writeFile(
        .success(path: WorkspaceRelativePath(rawValue: "Sources/App.swift"), bytesWritten: 12)),
      .editFile(
        .oldTextNotFound(
          path: WorkspaceRelativePath(rawValue: "Sources/App.swift"),
          currentContent: ToolTextOutput(text: "let value = 1"),
          recovery: .readFile(path: WorkspaceRelativePath(rawValue: "Sources/App.swift"))
        )),
      .workspaceDiff(
        .success(
          path: nil,
          content: ToolTextOutput(text: "No workspace changes.")
        )),
      .runCommand(
        RunCommandResult(
          command: "just test-core",
          timeoutSeconds: 120,
          exitCode: 1,
          durationMs: 42,
          stdout: ToolTextOutput(text: ""),
          stderr: ToolTextOutput(text: "failed")
        )),
      .todoWrite(.success),
      .duplicateToolCall(
        DuplicateToolCallResult(
          previousCallID: duplicatePreviousCallID,
          message: "Duplicate of call_old.",
          affectedPaths: [WorkspaceRelativePath(rawValue: "README.md")],
          replayedObservation: ToolModelObservation.success(
            toolName: .readFile,
            affectedPaths: [WorkspaceRelativePath(rawValue: "README.md")],
            blocks: [
              .fileContent(
                path: WorkspaceRelativePath(rawValue: "README.md"),
                content: ToolTextOutput(text: "1: hello", truncated: true)
              )
            ]
          )
        )),
      .invalidTool(
        InvalidToolResult(
          originalName: "deploy",
          reason: .unknownToolName("deploy")
        )),
      .failure(
        ToolFailure(
          toolName: .readFile,
          path: WorkspaceRelativePath(rawValue: "missing.swift"),
          reason: .fileNotFound(
            path: WorkspaceRelativePath(rawValue: "missing.swift"),
            suggestions: [
              MissingPathSuggestion(
                path: WorkspaceRelativePath(rawValue: "Sources/App.swift"),
                reason: "same extension",
                confidence: 0.8
              )
            ]
          ),
          recovery: .chooseOneOf(paths: [WorkspaceRelativePath(rawValue: "Sources/App.swift")])
        )),
      .failure(
        ToolFailure(
          toolName: .editFile,
          path: nil,
          reason: .finalModeToolAttempt(requestedTool: .editFile),
          recovery: .askUser(message: "Send another message to continue.")
        )),
      .failure(
        ToolFailure(
          toolName: .editFile,
          path: nil,
          reason: .toolBudgetExceeded(
            requestedTool: .editFile,
            iterationLimit: ChatToolLoopLimits.defaultMaxToolLoopIterations
          ),
          recovery: .askUser(message: "Send another message to continue.")
        )),
    ]

    let decoded = try JSONDecoder().decode(
      [ToolResultPayload].self,
      from: JSONEncoder().encode(payloads)
    )

    #expect(decoded == payloads)
  }

  @Test
  func duplicateBlockedFlagRoundTrips() throws {
    let blocked = DuplicateToolCallResult(
      previousCallID: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
      message: "Duplicate of call_old.",
      blocked: true
    )
    let decoded = try JSONDecoder().decode(
      DuplicateToolCallResult.self, from: JSONEncoder().encode(blocked))
    #expect(decoded == blocked)
    #expect(decoded.blocked)
  }

  @Test
  func blockedDuplicatePreviewStaysBenignSuccess() {
    let payload = ToolResultPayload.duplicateToolCall(
      DuplicateToolCallResult(
        previousCallID: UUID(),
        message: "Duplicate of call_old.",
        replayedObservation: nil,
        blocked: true
      ))
    // The persisted/UI preview must not look like a tool failure.
    #expect(payload.preview.status == .success)
  }

  @Test
  func runCommandResultDecodesStoredResultsBeforeOutputRefs() throws {
    let json = """
      {
        "command": "just test-core",
        "timeoutSeconds": 120,
        "exitCode": 1,
        "durationMs": 42,
        "stdout": {
          "text": "building",
          "truncated": false,
          "redacted": false
        },
        "stderr": {
          "text": "failed",
          "truncated": false,
          "redacted": false
        }
      }
      """

    let decoded = try JSONDecoder().decode(RunCommandResult.self, from: Data(json.utf8))

    #expect(decoded.command == "just test-core")
    #expect(decoded.outputRef == nil)
    #expect(decoded.stdoutOmittedChars == 0)
    #expect(decoded.stderrOmittedChars == 0)
    #expect(!decoded.timedOut)
    #expect(!decoded.cancelled)
  }

  @Test
  func previewRendersFromStructuredPayload() {
    let payload = ToolResultPayload.editFile(
      .multipleMatches(
        path: WorkspaceRelativePath(rawValue: "Sources/App.swift"),
        matchCount: 2,
        recovery: .retryWithMoreContext(path: WorkspaceRelativePath(rawValue: "Sources/App.swift"))
      ))

    let preview = payload.preview

    #expect(preview.status == .failed)
    #expect(preview.text.contains("matched more than once"))
    #expect(preview.text.contains("Retry with a larger exact old_text block"))
    #expect(preview.affectedPaths == ["Sources/App.swift"])
  }

  @Test
  func todoWritePreviewStaysMinimal() {
    let payload = ToolResultPayload.todoWrite(.success)

    let preview = payload.preview

    #expect(preview.status == .success)
    #expect(preview.text == "Plan updated.")
    #expect(preview.affectedPaths.isEmpty)
  }

  @Test
  func duplicateToolCallPreviewReferencesPreviousResult() {
    let previousCallID = UUID()
    let payload = ToolResultPayload.duplicateToolCall(
      DuplicateToolCallResult(
        previousCallID: previousCallID,
        message: "Duplicate of \(RuntimeToolCallID.string(for: previousCallID)).",
        affectedPaths: [WorkspaceRelativePath(rawValue: "README.md")]
      ))

    let preview = payload.preview

    #expect(preview.status == .success)
    #expect(preview.text.contains(RuntimeToolCallID.string(for: previousCallID)))
    #expect(preview.affectedPaths == ["README.md"])
  }

  @Test
  func runCommandPreviewStatusFollowsCommandOutcome() {
    #expect(runCommandPayload(exitCode: 0).preview.status == .success)
    #expect(runCommandPayload(exitCode: 1).preview.status == .failed)
    #expect(runCommandPayload(exitCode: 0, timedOut: true).preview.status == .failed)
    #expect(runCommandPayload(exitCode: 0, cancelled: true).preview.status == .failed)
    #expect(runCommandPayload(exitCode: nil).preview.status == .failed)
    #expect(runCommandPayload(exitCode: 0).preview.affectedPaths == ["."])
  }

  @Test
  func budgetExceededFailurePreviewExplainsLimit() {
    let budget = ChatToolLoopLimits.defaultMaxToolLoopIterations
    let payload = ToolResultPayload.failure(
      ToolFailure(
        toolName: .editFile,
        path: nil,
        reason: .toolBudgetExceeded(requestedTool: .editFile, iterationLimit: budget)
      ))

    let preview = payload.preview

    #expect(preview.status == .failed)
    #expect(preview.text.contains("Tool budget exceeded for edit_file"))
    #expect(preview.text.contains("\(budget) tool iterations"))
    #expect(preview.affectedPaths.isEmpty)
  }

  @Test
  func finalModeToolAttemptFailurePreviewExplainsIgnoredAttempt() {
    let payload = ToolResultPayload.failure(
      ToolFailure(
        toolName: .editFile,
        path: nil,
        reason: .finalModeToolAttempt(requestedTool: .editFile)
      ))

    let preview = payload.preview

    #expect(preview.status == .failed)
    #expect(preview.text.contains("Tool attempt ignored for edit_file"))
    #expect(preview.text.contains("final for the current turn"))
    #expect(preview.affectedPaths.isEmpty)
  }

  private func runCommandPayload(
    exitCode: Int32?,
    timedOut: Bool = false,
    cancelled: Bool = false
  ) -> ToolResultPayload {
    .runCommand(
      RunCommandResult(
        command: "just test-core",
        timeoutSeconds: 120,
        exitCode: exitCode,
        durationMs: 42,
        stdout: ToolTextOutput(text: ""),
        stderr: ToolTextOutput(text: ""),
        timedOut: timedOut,
        cancelled: cancelled
      ))
  }

}
