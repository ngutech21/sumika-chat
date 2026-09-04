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
        .page(
          try ReadFilePage(
            path: WorkspaceRelativePath(rawValue: "Sources/App.swift"),
            startLine: 41,
            endLine: 42,
            content: "let a = 1\nlet b = 2",
            continuation: .next(offset: 43, reason: .byteLimit)
          )
        )
      ),
      .readFile(
        .legacySuccess(
          path: WorkspaceRelativePath(rawValue: "README.md"),
          content: ToolTextOutput(text: "1: hello", truncated: true)
        )),
      .readFile(
        .lineTooLong(
          path: WorkspaceRelativePath(rawValue: "minified.js"),
          line: 1,
          byteCount: 120_000
        )
      ),
      .readFile(
        .offsetOutOfRange(
          path: WorkspaceRelativePath(rawValue: "README.md"),
          requestedOffset: 99,
          lineCount: 10
        )
      ),
      .writeFile(
        .success(path: WorkspaceRelativePath(rawValue: "Sources/App.swift"), bytesWritten: 12)),
      .editFile(
        .success(
          receipt: AppliedEditReceipt(
            path: WorkspaceRelativePath(rawValue: "Sources/App.swift"),
            matchStrategy: .exact,
            oldRange: AppliedEditLineRange(startLine: 1, lineCount: 1),
            newRange: AppliedEditLineRange(startLine: 1, lineCount: 1),
            diff: ToolTextOutput(text: "-old\n+new")
          )
        )),
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
      .workspaceDiagnostics(
        .read(
          outputRef: "cmd_read",
          result: .page(
            CommandOutputReadPage(
              stream: .combined,
              startLine: 2,
              endLine: 3,
              lines: [
                CommandOutputReadLine(
                  line: 2,
                  origin: .stdout,
                  streamLine: 2,
                  content: "building"
                ),
                CommandOutputReadLine(
                  line: 3,
                  origin: .stderr,
                  streamLine: 1,
                  content: "failed"
                ),
              ],
              continuation: .next(offset: 4, reason: .byteLimit)
            )
          )
        )
      ),
      .workspaceDiagnostics(
        .search(
          outputRef: "cmd_search",
          result: .page(
            CommandOutputSearchPage(
              stream: .stderr,
              pattern: "FAIL:",
              startLine: 1,
              scannedThrough: 12,
              lineCount: 20,
              matches: [
                CommandOutputSearchMatch(
                  origin: .stderr,
                  streamLine: 7,
                  combinedLine: nil,
                  snippet: "FAIL: expected true",
                  snippetTruncated: false
                )
              ],
              continuation: .next(offset: 13, reason: .matchLimit)
            )
          )
        )
      ),
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
              ),
              .diagnostics(
                .legacyDiagnostics(
                  outputRef: "cmd_legacy",
                  diagnostics: [
                    WorkspaceDiagnostic(
                      path: WorkspaceRelativePath(rawValue: "Sources/App.swift"),
                      line: 9,
                      column: 3,
                      severity: .error,
                      message: "legacy failure"
                    )
                  ]
                )
              ),
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
            iterationLimit: ManagedModelCatalog.defaultModel.maxToolLoopIterations
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
  func readFileContinuationUsesStableDiscriminatorSchema() throws {
    let values: [(ReadFileContinuation, String)] = [
      (.endOfFile, #"{"kind":"end_of_file"}"#),
      (
        .next(offset: 241, reason: .byteLimit),
        #"{"kind":"next","offset":241,"reason":"byte_limit"}"#
      ),
      (
        .blocked(line: 121, byteCount: 184_320),
        #"{"byte_count":184320,"kind":"blocked","line":121}"#
      ),
    ]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    for (value, expectedJSON) in values {
      let data = try encoder.encode(value)
      #expect(try #require(String(data: data, encoding: .utf8)) == expectedJSON)
      #expect(try JSONDecoder().decode(ReadFileContinuation.self, from: data) == value)
    }
  }

  @Test
  func readFilePageRejectsInconsistentConstruction() {
    let path = WorkspaceRelativePath(rawValue: "README.md")

    #expect(throws: ReadFilePageValidationError.invalidStartLine(0)) {
      try ReadFilePage(
        path: path,
        startLine: 0,
        endLine: 1,
        content: "line",
        continuation: .endOfFile
      )
    }
    #expect(
      throws: ReadFilePageValidationError.endLineBeforeStart(startLine: 2, endLine: 1)
    ) {
      try ReadFilePage(
        path: path,
        startLine: 2,
        endLine: 1,
        content: "line",
        continuation: .endOfFile
      )
    }
    #expect(
      throws: ReadFilePageValidationError.contentLineCountMismatch(expected: 2, actual: 1)
    ) {
      try ReadFilePage(
        path: path,
        startLine: 1,
        endLine: 2,
        content: "one line",
        continuation: .endOfFile
      )
    }
    #expect(
      throws: ReadFilePageValidationError.continuationLineMismatch(expected: 2, actual: 9)
    ) {
      try ReadFilePage(
        path: path,
        startLine: 1,
        endLine: 1,
        content: "line",
        continuation: .next(offset: 9, reason: .byteLimit)
      )
    }
    #expect(throws: ReadFilePageValidationError.invalidBlockedLineByteCount(0)) {
      try ReadFilePage(
        path: path,
        startLine: 1,
        endLine: 1,
        content: "line",
        continuation: .blocked(line: 2, byteCount: 0)
      )
    }
    #expect(throws: ReadFilePageValidationError.invalidEmptyPage) {
      try ReadFilePage(
        path: path,
        startLine: 1,
        endLine: nil,
        content: "unexpected",
        continuation: .endOfFile
      )
    }
  }

  @Test
  func readFilePageDecodeRejectsInconsistentPersistedMetadata() {
    let invalidPages = [
      """
      {
        "path": "README.md",
        "startLine": 1,
        "endLine": 2,
        "content": "one line",
        "continuation": {"kind": "end_of_file"}
      }
      """,
      """
      {
        "path": "README.md",
        "startLine": 1,
        "endLine": 1,
        "content": "line",
        "continuation": {"kind": "next", "offset": 9, "reason": "byte_limit"}
      }
      """,
      """
      {
        "path": "README.md",
        "startLine": 1,
        "content": "unexpected",
        "continuation": {"kind": "end_of_file"}
      }
      """,
    ]

    for json in invalidPages {
      #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ReadFilePage.self, from: Data(json.utf8))
      }
    }
  }

  @Test
  func legacyReadFileSuccessDecodesAndReencodesWithoutInventingContinuation() throws {
    let json = """
      {
        "success": {
          "path": "README.md",
          "content": {
            "text": "1: stored",
            "truncated": true,
            "redacted": false
          }
        }
      }
      """
    let originalObject = try #require(
      JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary
    )
    let result = try JSONDecoder().decode(ReadFileResult.self, from: Data(json.utf8))

    guard case .legacySuccess(let path, let content) = result else {
      Issue.record("Expected the stored read_file success shape to decode as legacy success.")
      return
    }
    #expect(path == WorkspaceRelativePath(rawValue: "README.md"))
    #expect(content == ToolTextOutput(text: "1: stored", truncated: true))

    let reencodedObject = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? NSDictionary
    )
    #expect(reencodedObject == originalObject)
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
    #expect(decoded.stdoutCaptureOmittedBytes == 0)
    #expect(decoded.stderrCaptureOmittedBytes == 0)
    #expect(!decoded.timedOut)
    #expect(!decoded.cancelled)
  }

  @Test
  func commandCaptureMetadataRoundTripsSeparatelyFromPreviewTruncation() throws {
    let result = RunCommandResult(
      command: "build", timeoutSeconds: 120, exitCode: 0, durationMs: 42,
      stdout: ToolTextOutput(text: "head and tail"), stderr: ToolTextOutput(text: ""),
      stdoutCaptureOmittedBytes: 123, stderrCaptureOmittedBytes: 45
    )
    let decoded = try JSONDecoder().decode(
      RunCommandResult.self, from: JSONEncoder().encode(result))

    #expect(decoded == result)
    #expect(decoded.outputTruncated)
    #expect(!decoded.stdout.truncated)
    #expect(decoded.stdoutOmittedChars == 0)
  }

  @Test
  func diagnosticsCaptureMetadataRoundTripsAndOldPagesDefaultToCompleteCapture() throws {
    let read = CommandOutputReadPage(
      stream: .stdout, startLine: 1, endLine: 1,
      lines: [CommandOutputReadLine(line: 1, origin: .stdout, streamLine: 1, content: "tail")],
      continuation: .endOfOutput, captureOmittedBytes: 123
    )
    let search = CommandOutputSearchPage(
      stream: .stdout, pattern: "missing", startLine: 1, scannedThrough: 1,
      lineCount: 1, matches: [], continuation: .endOfOutput, captureOmittedBytes: 123
    )
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    #expect(try decoder.decode(CommandOutputReadPage.self, from: encoder.encode(read)) == read)
    #expect(
      try decoder.decode(CommandOutputSearchPage.self, from: encoder.encode(search)) == search)

    var oldRead = try #require(
      JSONSerialization.jsonObject(with: encoder.encode(read)) as? [String: Any])
    oldRead.removeValue(forKey: "captureOmittedBytes")
    var oldSearch = try #require(
      JSONSerialization.jsonObject(with: encoder.encode(search)) as? [String: Any])
    oldSearch.removeValue(forKey: "captureOmittedBytes")
    #expect(
      try decoder.decode(
        CommandOutputReadPage.self, from: JSONSerialization.data(withJSONObject: oldRead)
      ).captureOmittedBytes == 0)
    #expect(
      try decoder.decode(
        CommandOutputSearchPage.self, from: JSONSerialization.data(withJSONObject: oldSearch)
      ).captureOmittedBytes == 0)
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
  func legacyEditFileSuccessDecodesReencodesAndKeepsFrozenRendering() throws {
    let json = """
      {
        "success": {
          "path": "README.md",
          "diff": "-old\\n+new",
          "matchStrategy": "exact"
        }
      }
      """
    let originalObject = try #require(
      JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary
    )
    let result = try JSONDecoder().decode(EditFileResult.self, from: Data(json.utf8))

    guard case .legacySuccess(let path, let diff, let matchStrategy) = result else {
      Issue.record("Expected the stored edit_file success shape to decode as legacy success.")
      return
    }
    #expect(path == WorkspaceRelativePath(rawValue: "README.md"))
    #expect(diff == "-old\n+new")
    #expect(matchStrategy == .exact)
    #expect(
      result.preview.text == """
        -old
        +new
        """)

    let reencodedObject = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? NSDictionary
    )
    #expect(reencodedObject == originalObject)
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
    let budget = ManagedModelCatalog.defaultModel.maxToolLoopIterations
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
