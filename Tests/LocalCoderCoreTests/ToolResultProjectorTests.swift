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
  func runCommandObservationIncludesExitAndOutput() {
    let result = RunCommandResult(
      command: "just test-core",
      timeoutSeconds: 120,
      exitCode: 1,
      durationMs: 42,
      stdout: ToolTextOutput(text: "build started\n"),
      stderr: ToolTextOutput(text: "Tests failed\n")
    )
    let projection = ToolResultProjector.project(
      payload: .runCommand(result),
      request: request(
        toolName: .runCommand,
        payload: .runCommand(RunCommandInput(command: "just test-core", timeoutSeconds: 120))
      )
    )

    #expect(projection.observation.blocks == [.commandResult(result)])
    let rendered = ToolModelObservationRenderer.render(projection.observation, callID: UUID())
    #expect(rendered.contains("Command: just test-core"))
    #expect(rendered.contains("Exit code: 1"))
    #expect(rendered.contains("Stdout:\nbuild started"))
    #expect(rendered.contains("Stderr:\nTests failed"))
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
