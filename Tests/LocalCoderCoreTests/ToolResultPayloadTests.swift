import Foundation
import Testing

@testable import LocalCoderCore

struct ToolResultPayloadTests {
  @Test
  func toolResultPayloadCodableRoundTripsBuiltInResults() throws {
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
          reason: .toolBudgetExceeded(requestedTool: .editFile, iterationLimit: 6),
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
  func budgetExceededFailurePreviewExplainsLimit() {
    let payload = ToolResultPayload.failure(
      ToolFailure(
        toolName: .editFile,
        path: nil,
        reason: .toolBudgetExceeded(requestedTool: .editFile, iterationLimit: 6)
      ))

    let preview = payload.preview

    #expect(preview.status == .failed)
    #expect(preview.text.contains("Tool budget exceeded for edit_file"))
    #expect(preview.text.contains("6 tool iterations"))
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

}
