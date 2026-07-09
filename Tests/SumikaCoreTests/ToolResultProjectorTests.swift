import Foundation
import Testing

@testable import SumikaCore

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
    let rendered = ToolModelObservationRenderer.render(projection, callID: UUID())
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
  func listFilesRendersHybridToolResultWithEntriesAndNoCallID() {
    let callID = UUID()
    let projection = ToolResultProjector.project(
      payload: .listFiles(
        ListFilesResult(
          root: WorkspaceRelativePath(rawValue: "."),
          entries: [
            WorkspaceFileEntry(path: WorkspaceRelativePath(rawValue: ".gitignore"), kind: .file),
            WorkspaceFileEntry(
              path: WorkspaceRelativePath(rawValue: "snake_game"),
              kind: .directory
            ),
            WorkspaceFileEntry(
              path: WorkspaceRelativePath(rawValue: "snake_game/main.py"),
              kind: .file
            ),
          ],
          truncated: true
        )),
      request: request(toolName: .listFiles, payload: .listFiles(ListFilesInput(path: ".")))
    )

    let rendered = ToolModelObservationRenderer.render(projection, callID: callID)

    #expect(rendered.contains("TOOL_RESULT_JSON:"))
    #expect(rendered.contains("\"tool\": \"list_files\""))
    #expect(rendered.contains("\"kind\": \"listing\""))
    #expect(rendered.contains("\"entry_count\": 3"))
    #expect(rendered.contains("CONTENT:"))
    #expect(rendered.contains("Entries:\n.gitignore\nsnake_game/\nsnake_game/main.py"))
    #expect(rendered.contains(callID.uuidString) == false)
    #expect(rendered.contains(RuntimeToolCallID.string(for: callID)) == false)
  }

  @Test
  func hybridToolResultContractKeepsLongContentOutOfJSON() throws {
    let readSentinel = "READ_FILE_LONG_BODY_SENTINEL_alpha"
    let stdoutSentinel = "RUN_COMMAND_STDOUT_SENTINEL_beta"
    let stderrSentinel = "RUN_COMMAND_STDERR_SENTINEL_gamma"
    let webSentinel = "WEB_FETCH_HTML_BODY_SENTINEL_delta"
    let diffSentinel = "WORKSPACE_DIFF_SENTINEL_epsilon"

    let cases: [(projection: ToolResultProjection, kind: String, sentinels: [String])] = [
      (
        ToolResultProjector.project(
          payload: .readFile(
            .success(
              path: WorkspaceRelativePath(rawValue: "README.md"),
              content: ToolTextOutput(text: "intro\n\(readSentinel)\nend")
            )),
          request: request(
            toolName: .readFile,
            payload: .readFile(ReadFileInput(path: "README.md"))
          )
        ),
        "file_content",
        [readSentinel]
      ),
      (
        ToolResultProjector.project(
          payload: .runCommand(
            RunCommandResult(
              command: "just test-core",
              timeoutSeconds: 120,
              exitCode: 1,
              durationMs: 42,
              stdout: ToolTextOutput(text: "stdout\n\(stdoutSentinel)\n"),
              stderr: ToolTextOutput(text: "stderr\n\(stderrSentinel)\n")
            )),
          request: request(
            toolName: .runCommand,
            payload: .runCommand(RunCommandInput(command: "just test-core", timeoutSeconds: 120))
          )
        ),
        "command_result",
        [stdoutSentinel, stderrSentinel]
      ),
      (
        ToolResultProjector.project(
          payload: .webFetch(
            WebFetchToolResult(
              url: "https://example.com/article",
              provider: .builtIn,
              finalURL: "https://example.com/article",
              statusCode: 200,
              contentType: "text/html",
              content: ToolTextOutput(text: "<main>\(webSentinel)</main>"),
              byteCount: 128
            )),
          request: request(
            toolName: .webFetch,
            payload: .webFetch(WebFetchInput(url: "https://example.com/article"))
          )
        ),
        "web_fetch",
        [webSentinel]
      ),
      (
        ToolResultProjector.project(
          payload: .workspaceDiff(
            .success(
              path: WorkspaceRelativePath(rawValue: "Sources/App.swift"),
              content: ToolTextOutput(text: "diff --git\n+\(diffSentinel)\n")
            )),
          request: request(
            toolName: .workspaceDiff,
            payload: .workspaceDiff(WorkspaceDiffInput(path: "Sources/App.swift"))
          )
        ),
        "workspace_diff",
        [diffSentinel]
      ),
    ]

    for testCase in cases {
      let rendered = ToolModelObservationRenderer.render(testCase.projection, callID: UUID())
      let hybrid = try hybridToolResult(rendered)
      #expect(hybrid.json["kind"] as? String == testCase.kind)
      #expect(hybrid.json["result_kind"] == nil)
      for sentinel in testCase.sentinels {
        #expect(hybrid.jsonText.contains(sentinel) == false)
        #expect(hybrid.content.contains(sentinel))
      }
    }
  }

  @Test
  func duplicateListFilesRendersHybridReplayWithEntriesAndNoPreviousCallID() {
    let previousCallID = UUID()
    let duplicateCallID = UUID()
    let listRequest = request(
      toolName: .listFiles,
      payload: .listFiles(ListFilesInput(path: "."))
    )
    let listProjection = ToolResultProjector.project(
      payload: .listFiles(
        ListFilesResult(
          root: WorkspaceRelativePath(rawValue: "."),
          entries: [
            WorkspaceFileEntry(path: WorkspaceRelativePath(rawValue: ".gitignore"), kind: .file),
            WorkspaceFileEntry(
              path: WorkspaceRelativePath(rawValue: "snake_game"),
              kind: .directory
            ),
          ]
        )),
      request: listRequest
    )
    let duplicateProjection = ToolResultProjector.project(
      payload: .duplicateToolCall(
        DuplicateToolCallResult(
          previousCallID: previousCallID,
          message:
            "Duplicate of \(RuntimeToolCallID.string(for: previousCallID)): identical list_files already completed in this turn; not re-executed. Previous result is replayed below.",
          replayedObservation: listProjection.observation
        )),
      request: listRequest
    )

    let rendered = ToolModelObservationRenderer.render(duplicateProjection, callID: duplicateCallID)

    #expect(rendered.contains("\"kind\": \"duplicate_replay\""))
    #expect(rendered.contains("\"duplicate\": true"))
    #expect(rendered.contains("\"not_reexecuted\": true"))
    #expect(rendered.contains("\"replayed_result_kind\": \"listing\""))
    #expect(rendered.contains("\"forbidden_repeat\": true"))
    #expect(rendered.contains("Duplicate replay: identical list_files already completed"))
    #expect(rendered.contains("Entries:\n.gitignore\nsnake_game/"))
    #expect(rendered.contains(RuntimeToolCallID.string(for: previousCallID)) == false)
    #expect(rendered.contains(duplicateCallID.uuidString) == false)
  }

  @Test
  func blockedDuplicateWithholdsContentAndFramesNonSuccessForModel() {
    let previousCallID = UUID()
    let duplicateCallID = UUID()
    let listRequest = request(
      toolName: .listFiles,
      payload: .listFiles(ListFilesInput(path: "."))
    )
    let duplicateProjection = ToolResultProjector.project(
      payload: .duplicateToolCall(
        DuplicateToolCallResult(
          previousCallID: previousCallID,
          message:
            "Duplicate of \(RuntimeToolCallID.string(for: previousCallID)): identical list_files already completed in this turn; not re-executed. The result is not shown again — use the earlier result above, or provide the final answer.",
          replayedObservation: nil,
          blocked: true
        )),
      request: listRequest
    )

    // Model-facing observation is framed non-success to break the loop...
    #expect(duplicateProjection.observation.status == .denied)
    let rendered = ToolModelObservationRenderer.render(duplicateProjection, callID: duplicateCallID)
    #expect(rendered.contains("\"ok\": false"))
    #expect(rendered.contains("\"status\": \"denied\""))
    #expect(rendered.contains("\"forbidden_repeat\": true"))
    #expect(rendered.contains("\"duplicate\": true"))
    // ...with the replayed listing content withheld.
    #expect(rendered.contains("Entries:") == false)
    #expect(rendered.contains(".gitignore") == false)
  }

  @Test
  func duplicateReplayMetadataDoesNotDependOnSummaryMessage() throws {
    let previousCallID = UUID()
    let listRequest = request(
      toolName: .listFiles,
      payload: .listFiles(ListFilesInput(path: "."))
    )
    let listProjection = ToolResultProjector.project(
      payload: .listFiles(
        ListFilesResult(
          root: WorkspaceRelativePath(rawValue: "."),
          entries: [
            WorkspaceFileEntry(path: WorkspaceRelativePath(rawValue: "README.md"), kind: .file)
          ]
        )),
      request: listRequest
    )
    let duplicateProjection = ToolResultProjector.project(
      payload: .duplicateToolCall(
        DuplicateToolCallResult(
          previousCallID: previousCallID,
          message: "Already completed.",
          replayedObservation: listProjection.observation
        )),
      request: listRequest
    )

    let hybrid = try hybridToolResult(
      ToolModelObservationRenderer.render(duplicateProjection, callID: UUID())
    )

    #expect(hybrid.json["kind"] as? String == "duplicate_replay")
    #expect(hybrid.json["duplicate"] as? Bool == true)
    #expect(hybrid.json["not_reexecuted"] as? Bool == true)
    #expect(hybrid.json["forbidden_repeat"] as? Bool == true)
    #expect(hybrid.json["replayed_result_kind"] as? String == "listing")
    #expect(hybrid.content.contains("Already completed."))
  }

  @Test
  func duplicateReplayWithoutReplayedObservationOmitsReplayedKind() throws {
    let duplicateProjection = ToolResultProjector.project(
      payload: .duplicateToolCall(
        DuplicateToolCallResult(
          previousCallID: UUID(),
          message: "Already completed.",
          affectedPaths: [WorkspaceRelativePath(rawValue: ".")]
        )),
      request: request(toolName: .listFiles, payload: .listFiles(ListFilesInput(path: ".")))
    )

    let hybrid = try hybridToolResult(
      ToolModelObservationRenderer.render(duplicateProjection, callID: UUID())
    )

    #expect(hybrid.json["kind"] as? String == "duplicate_replay")
    #expect(hybrid.json["duplicate"] as? Bool == true)
    #expect(hybrid.json["not_reexecuted"] as? Bool == true)
    #expect(hybrid.json["forbidden_repeat"] as? Bool == true)
    #expect(hybrid.json["replayed_result_kind"] == nil)
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
    let rendered = ToolModelObservationRenderer.render(projection, callID: UUID())

    #expect(
      projection.display == .summary(status: .success, text: "Plan updated.", affectedPaths: []))
    #expect(rendered.contains("TOOL_RESULT_JSON:"))
    #expect(rendered.contains("\"tool\": \"todo_write\""))
    #expect(rendered.contains("\"kind\": \"plan_update\""))
    #expect(rendered.contains("CONTENT:\nPlan updated."))
    #expect(!rendered.contains("Inspect files"))
  }

  @Test
  func finishTaskProjectionCarriesTaskStatusAndHasNoNextAction() {
    for status in FinishTaskStatus.allCases {
      let projection = ToolResultProjector.project(
        payload: .finishTask(.success),
        request: request(
          toolName: .finishTask,
          payload: .finishTask(
            FinishTaskInput(status: status, summary: "Finished with \(status.rawValue).")
          )
        )
      )

      #expect(
        projection.display
          == .summary(
            status: .success,
            text: "Task completion accepted.",
            affectedPaths: []
          ))
      #expect(projection.observation.status == .success)
      #expect(projection.observation.blocks == [.summary("Task completion accepted.")])
      #expect(projection.metadata.kind == "task_completion")
      #expect(
        projection.metadata.fields == [
          .init(name: "task_status", value: .string(status.rawValue))
        ])
      #expect(projection.metadata.nextAllowedActions.isEmpty)
    }
  }

  @Test
  func projectionsRetainOnlyRealNextActions() {
    let readProjection = ToolResultProjector.project(
      payload: .readFile(
        .success(
          path: WorkspaceRelativePath(rawValue: "README.md"),
          content: ToolTextOutput(text: "notes")
        )),
      request: request(
        toolName: .readFile,
        payload: .readFile(ReadFileInput(path: "README.md"))
      )
    )
    let listProjection = ToolResultProjector.project(
      payload: .listFiles(
        ListFilesResult(root: WorkspaceRelativePath(rawValue: "."), entries: [])
      ),
      request: request(
        toolName: .listFiles,
        payload: .listFiles(ListFilesInput(path: "."))
      )
    )
    let commandProjection = ToolResultProjector.project(
      payload: .runCommand(
        RunCommandResult(
          command: "just test-core",
          timeoutSeconds: 120,
          exitCode: 0,
          durationMs: 10,
          stdout: ToolTextOutput(text: "ok"),
          stderr: ToolTextOutput(text: ""),
          outputRef: "cmd-output"
        )),
      request: request(
        toolName: .runCommand,
        payload: .runCommand(RunCommandInput(command: "just test-core", timeoutSeconds: 120))
      )
    )
    let diagnosticsProjection = ToolResultProjector.project(
      payload: .workspaceDiagnostics(
        WorkspaceDiagnosticsResult(outputRef: "cmd-output", diagnostics: [])
      ),
      request: request(
        toolName: .workspaceDiagnostics,
        payload: .workspaceDiagnostics(WorkspaceDiagnosticsInput(outputRef: "cmd-output"))
      )
    )
    let webSearchProjection = ToolResultProjector.project(
      payload: .webSearch(
        WebSearchToolResult(query: "Swift", provider: .duckDuckGo, results: [])
      ),
      request: request(
        toolName: .webSearch,
        payload: .webSearch(WebSearchInput(query: "Swift"))
      )
    )
    let finishProjection = ToolResultProjector.project(
      payload: .finishTask(.success),
      request: request(
        toolName: .finishTask,
        payload: .finishTask(FinishTaskInput(status: .done, summary: "Done."))
      )
    )

    #expect(readProjection.metadata.nextAllowedActions == ["edit_file"])
    #expect(listProjection.metadata.nextAllowedActions == ["read_file"])
    #expect(commandProjection.metadata.nextAllowedActions == ["workspace_diagnostics"])
    #expect(diagnosticsProjection.metadata.nextAllowedActions == ["read_file", "edit_file"])
    #expect(webSearchProjection.metadata.nextAllowedActions == ["web_fetch"])
    #expect(finishProjection.metadata.nextAllowedActions.isEmpty)
    let projections = [
      readProjection,
      listProjection,
      commandProjection,
      diagnosticsProjection,
      webSearchProjection,
      finishProjection,
    ]
    #expect(
      projections.allSatisfy { projection in
        !projection.metadata.nextAllowedActions.contains("final_answer")
      })
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
    #expect(rendered.contains("Command failed."))
    #expect(rendered.contains("Do not report the requested task as complete"))
    #expect(rendered.contains("Do not infer workspace state from this failure alone"))
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

    let rendered = ToolModelObservationRenderer.render(projection, callID: UUID())
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
  func invalidEditFileObservationSaysNoFileChangedAndHowToRetry() {
    let reason = InvalidToolCallReason.missingRequiredArgument("path")
    let projection = ToolResultProjector.project(
      payload: .invalidTool(
        InvalidToolResult(originalName: "edit_file", reason: reason)
      ),
      request: request(
        toolName: .editFile,
        payload: .invalid(
          InvalidToolInput(
            originalName: "edit_file",
            rawArguments: [:],
            reason: reason
          ))
      )
    )

    guard case .summary(let status, let text, let affectedPaths) = projection.display else {
      Issue.record("Expected invalid edit_file display summary.")
      return
    }
    #expect(status == .failed)
    #expect(affectedPaths.isEmpty)
    #expect(text.contains("The tool call was invalid: Missing required argument: path."))
    #expect(text.contains("No file was changed."))
    #expect(text.contains("Do not claim completion."))
    #expect(text.contains("Retry edit_file with path, old_text, and new_text"))
    #expect(text.contains("If old_text is unknown, call read_file first."))
    #expect(projection.observation.status == .failed)
    #expect(projection.observation.blocks == [.failure(text)])
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
        != ToolModelObservationRenderer.render(projection, callID: callID))
  }

  @Test
  func editFileOldTextNotFoundObservationIncludesRecoveryAndCurrentExcerpt() {
    let path = WorkspaceRelativePath(rawValue: "pong.py")
    let currentContent = ToolTextOutput(text: "20: clock = pygame.time.Clock()\n")
    let projection = ToolResultProjector.project(
      payload: .editFile(
        .oldTextNotFound(
          path: path,
          currentContent: currentContent,
          recovery: .readFile(path: path)
        )
      ),
      request: request(
        toolName: .editFile,
        payload: .editFile(
          EditFileInput(
            path: path.rawValue,
            oldText: "clock = pygame.Krotron(FPS)",
            newText: "clock = pygame.time.Clock()"
          ))
      )
    )

    let rendered = ToolModelObservationRenderer.render(projection, callID: UUID())
    #expect(rendered.contains("old_text was not found in pong.py"))
    #expect(rendered.contains("Do not retry edit_file from memory"))
    #expect(rendered.contains("First call read_file(path: \"pong.py\")"))
    #expect(rendered.contains("smallest exact current text span"))
    #expect(rendered.contains("20: clock = pygame.time.Clock()"))

    guard case .summary(let status, let displayText, let affectedPaths) = projection.display else {
      Issue.record("Expected edit_file mismatch display summary.")
      return
    }
    #expect(status == .failed)
    #expect(displayText.contains("Current file excerpt:"))
    #expect(displayText.contains(currentContent.text))
    #expect(affectedPaths == [path])
  }

  @Test
  func editFileOldTextNotFoundObservationLimitsLongCurrentExcerpt() {
    let path = WorkspaceRelativePath(rawValue: "pong.py")
    let longContent =
      String(repeating: "head-line\n", count: 300)
      + "middle should be omitted\n"
      + String(repeating: "tail-line\n", count: 300)
    let projection = ToolResultProjector.project(
      payload: .editFile(
        .oldTextNotFound(
          path: path,
          currentContent: ToolTextOutput(text: longContent),
          recovery: .readFile(path: path)
        )
      ),
      request: request(
        toolName: .editFile,
        payload: .editFile(EditFileInput(path: path.rawValue, oldText: "old", newText: "new"))
      )
    )

    let rendered = ToolModelObservationRenderer.render(projection, callID: UUID())
    #expect(rendered.contains("Current file excerpt (truncated):"))
    #expect(rendered.contains("[tool observation truncated]"))
    #expect(rendered.count < longContent.count)

    guard case .summary(_, let displayText, _) = projection.display else {
      Issue.record("Expected edit_file mismatch display summary.")
      return
    }
    #expect(displayText.contains(longContent))
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
    switch expectedStatus {
    case .success:
      #expect(projection.observation.blocks == [.commandResult(result)])
    case .failed:
      #expect(projection.observation.blocks.first == .commandResult(result))
      #expect(projection.observation.blocks.containsFailure)
    case .denied:
      Issue.record("run_command projections should not be denied.")
    }

    let rendered = ToolModelObservationRenderer.render(projection, callID: UUID())
    #expect(rendered.contains("TOOL_RESULT_JSON:"))
    #expect(rendered.contains("\"tool\": \"run_command\""))
    #expect(rendered.contains("\"status\": \"\(expectedStatus.rawValue)\""))
    #expect(rendered.contains("\"kind\": \"command_result\""))
    #expect(rendered.contains("CONTENT:\nCommand: \(result.command)"))
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

  private func hybridToolResult(_ rendered: String) throws -> HybridToolResult {
    #expect(occurrenceCount("TOOL_RESULT_JSON:", in: rendered) == 1)
    #expect(occurrenceCount("CONTENT:", in: rendered) == 1)

    guard let jsonMarkerRange = rendered.range(of: "TOOL_RESULT_JSON:\n") else {
      Issue.record("Expected TOOL_RESULT_JSON marker.")
      throw HybridToolResultParseError.missingJSONMarker
    }
    let remainder = rendered[jsonMarkerRange.upperBound...]
    guard let contentMarkerRange = remainder.range(of: "\n\nCONTENT:\n") else {
      Issue.record("Expected CONTENT marker.")
      throw HybridToolResultParseError.missingContentMarker
    }

    let jsonText = String(remainder[..<contentMarkerRange.lowerBound])
    let content = String(remainder[contentMarkerRange.upperBound...])
    let data = Data(jsonText.utf8)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return HybridToolResult(json: json, jsonText: jsonText, content: content)
  }

  private func occurrenceCount(_ needle: String, in haystack: String) -> Int {
    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let range = haystack.range(of: needle, range: searchRange) {
      count += 1
      searchRange = range.upperBound..<haystack.endIndex
    }
    return count
  }
}

private struct HybridToolResult {
  var json: [String: Any]
  var jsonText: String
  var content: String
}

private enum HybridToolResultParseError: Error {
  case missingJSONMarker
  case missingContentMarker
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
