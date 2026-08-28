import Foundation
import Testing

@testable import SumikaCore

struct FocusedFileStateReducerTests {
  @Test
  func writeFileSuccessSetsActivePathAndSnapshot() {
    let reducer = FocusedFileStateReducer()
    let request = makeRequest(
      toolName: .writeFile,
      payload: .writeFile(WriteFileInput(path: "index.html", content: "<h1>Hello</h1>"))
    )

    let state = reducer.applyingToolResult(
      .writeFile(.success(path: WorkspaceRelativePath(rawValue: "index.html"), bytesWritten: 14)),
      request: request,
      to: .empty,
      updatedAt: Date(timeIntervalSinceReferenceDate: 1)
    )

    #expect(state.activePath == WorkspaceRelativePath(rawValue: "index.html"))
    #expect(state.recentPaths.first?.source == .writeFile)
    #expect(state.recentPaths.first?.confidence == .active)
    #expect(
      state.snapshots[WorkspaceRelativePath(rawValue: "index.html")]?.excerpt == "<h1>Hello</h1>")
    #expect(
      state.snapshots[WorkspaceRelativePath(rawValue: "index.html")]?.fullContentAvailable == true)
  }

  @Test
  func writeFileSnapshotUsesStableSHA256ContentHash() {
    let reducer = FocusedFileStateReducer()
    let path = WorkspaceRelativePath(rawValue: "notes.txt")

    let state = reducer.applyingToolResult(
      .writeFile(.success(path: path, bytesWritten: 13)),
      request: makeRequest(
        toolName: .writeFile,
        payload: .writeFile(WriteFileInput(path: path.rawValue, content: "Project notes"))
      ),
      to: .empty,
      updatedAt: Date(timeIntervalSinceReferenceDate: 1)
    )

    #expect(
      state.snapshots[path]?.contentHash
        == "6bffbde03eca5b2cc9c85375b2ac251abcd83e6e53058b49365c04c0ede8b2fb")
  }

  @Test
  func readFileSuccessRecordsRecentPathAndSnapshot() throws {
    let reducer = FocusedFileStateReducer()
    let path = WorkspaceRelativePath(rawValue: "README.md")

    let state = reducer.applyingToolResult(
      .readFile(
        .page(
          try ReadFilePage(
            path: path,
            startLine: 1,
            endLine: 1,
            content: "Project notes",
            continuation: .endOfFile
          )
        )
      ),
      request: makeRequest(
        toolName: .readFile, payload: .readFile(ReadFileInput(path: "README.md"))),
      to: .empty,
      updatedAt: Date(timeIntervalSinceReferenceDate: 1)
    )

    #expect(state.activePath == path)
    #expect(state.recentPaths.first?.path == path)
    #expect(state.recentPaths.first?.source == .readFile)
    #expect(state.snapshots[path]?.excerpt == "Project notes")
    #expect(state.snapshots[path]?.fullContentAvailable == true)
  }

  @Test
  func paginatedReadFileSnapshotsAreNotMarkedAsFullContent() {
    let reducer = FocusedFileStateReducer()
    let path = WorkspaceRelativePath(rawValue: "README.md")

    for input in [
      ReadFileInput(path: path.rawValue, offset: 1),
      ReadFileInput(path: path.rawValue, limit: 20),
    ] {
      let state = reducer.applyingToolResult(
        .readFile(.legacySuccess(path: path, content: ToolTextOutput(text: "Project notes"))),
        request: makeRequest(toolName: .readFile, payload: .readFile(input)),
        to: .empty,
        updatedAt: Date(timeIntervalSinceReferenceDate: 1)
      )

      #expect(state.snapshots[path]?.fullContentAvailable == false)
    }
  }

  @Test
  func continuedReadFilePageStoresRawContentButNotFullSnapshot() throws {
    let reducer = FocusedFileStateReducer()
    let path = WorkspaceRelativePath(rawValue: "README.md")
    let state = reducer.applyingToolResult(
      .readFile(
        .page(
          try ReadFilePage(
            path: path,
            startLine: 21,
            endLine: 21,
            content: "Project notes",
            continuation: .next(offset: 22, reason: .byteLimit)
          )
        )
      ),
      request: makeRequest(
        toolName: .readFile,
        payload: .readFile(ReadFileInput(path: path.rawValue, offset: 21))
      ),
      to: .empty
    )

    #expect(state.snapshots[path]?.excerpt == "Project notes")
    #expect(state.snapshots[path]?.fullContentAvailable == false)
  }

  @Test
  func truncatedOrRedactedReadFileSnapshotsAreNotMarkedAsFullContent() {
    let reducer = FocusedFileStateReducer()
    let path = WorkspaceRelativePath(rawValue: "README.md")

    for content in [
      ToolTextOutput(text: "Project notes", truncated: true),
      ToolTextOutput(text: "Project notes", redacted: true),
    ] {
      let state = reducer.applyingToolResult(
        .readFile(.legacySuccess(path: path, content: content)),
        request: makeRequest(
          toolName: .readFile,
          payload: .readFile(ReadFileInput(path: path.rawValue))
        ),
        to: .empty,
        updatedAt: Date(timeIntervalSinceReferenceDate: 1)
      )

      #expect(state.snapshots[path]?.fullContentAvailable == false)
    }
  }

  @Test
  func showFileSuccessDoesNotRecordFocusedSnapshot() {
    let reducer = FocusedFileStateReducer()
    let path = WorkspaceRelativePath(rawValue: "README.md")

    let state = reducer.applyingToolResult(
      .readFile(.legacySuccess(path: path, content: ToolTextOutput(text: "Project notes"))),
      request: makeRequest(
        toolName: .showFile, payload: .showFile(ReadFileInput(path: "README.md"))),
      to: .empty,
      updatedAt: Date(timeIntervalSinceReferenceDate: 1)
    )

    #expect(state == .empty)
  }

  @Test
  func editFileSuccessUpdatesExistingFullSnapshot() {
    let reducer = FocusedFileStateReducer()
    let path = WorkspaceRelativePath(rawValue: "Sources/App.swift")
    let initialState = FocusedFileState(
      activePath: nil,
      recentPaths: [],
      snapshots: [
        path: FocusedFileSnapshot(
          contentHash: "hash",
          excerpt: "let title = \"Old\"\n",
          fullContentAvailable: true
        )
      ]
    )

    let state = reducer.applyingToolResult(
      .editFile(
        .success(
          receipt: AppliedEditReceipt(
            path: path,
            matchStrategy: .exact,
            oldRange: AppliedEditLineRange(startLine: 1, lineCount: 1),
            newRange: AppliedEditLineRange(startLine: 1, lineCount: 1),
            diff: ToolTextOutput(text: "-old\n+new")
          )
        )),
      request: makeRequest(
        toolName: .editFile,
        payload: .editFile(
          EditFileInput(
            path: "Sources/App.swift",
            oldText: "let title = \"Old\"",
            newText: "let title = \"New\""
          )
        )
      ),
      to: initialState,
      updatedAt: Date(timeIntervalSinceReferenceDate: 1)
    )

    #expect(state.activePath == path)
    #expect(state.recentPaths.first?.source == .editFile)
    #expect(state.snapshots[path]?.excerpt == "let title = \"New\"\n")
    #expect(state.snapshots[path]?.fullContentAvailable == true)
  }

  @Test
  func legacyEditFileSuccessRemovesStaleSnapshotWhenItCannotBeUpdated() {
    let reducer = FocusedFileStateReducer()
    let path = WorkspaceRelativePath(rawValue: "Sources/App.swift")
    let initialState = FocusedFileState(
      activePath: nil,
      recentPaths: [],
      snapshots: [
        path: FocusedFileSnapshot(
          contentHash: "hash",
          excerpt: "let title = \"Old\"\n",
          fullContentAvailable: false
        )
      ]
    )

    let state = reducer.applyingToolResult(
      .editFile(.legacySuccess(path: path, diff: nil, matchStrategy: .exact)),
      request: makeRequest(
        toolName: .editFile,
        payload: .editFile(
          EditFileInput(
            path: "Sources/App.swift",
            oldText: "let title = \"Old\"",
            newText: "let title = \"New\""
          )
        )
      ),
      to: initialState,
      updatedAt: Date(timeIntervalSinceReferenceDate: 1)
    )

    #expect(state.activePath == path)
    #expect(state.recentPaths.first?.source == .editFile)
    #expect(state.snapshots[path] == nil)
  }

  @Test
  func recentPathsAreDeduplicatedAndLimited() {
    let reducer = FocusedFileStateReducer(maxRecentPaths: 3)
    var state = FocusedFileState.empty

    for index in 0..<4 {
      let path = WorkspaceRelativePath(rawValue: "File\(index).swift")
      state = reducer.applyingToolResult(
        .readFile(.legacySuccess(path: path, content: ToolTextOutput(text: "\(index)"))),
        request: makeRequest(
          toolName: .readFile,
          payload: .readFile(ReadFileInput(path: path.rawValue))
        ),
        to: state,
        updatedAt: Date(timeIntervalSinceReferenceDate: TimeInterval(index))
      )
    }

    state = reducer.applyingToolResult(
      .readFile(
        .legacySuccess(
          path: WorkspaceRelativePath(rawValue: "File2.swift"),
          content: ToolTextOutput(text: "updated")
        )),
      request: makeRequest(
        toolName: .readFile,
        payload: .readFile(ReadFileInput(path: "File2.swift"))
      ),
      to: state,
      updatedAt: Date(timeIntervalSinceReferenceDate: 5)
    )

    #expect(
      state.recentPaths.map(\.path.rawValue) == ["File2.swift", "File3.swift", "File1.swift"])
    #expect(
      state.snapshots.keys.map(\.rawValue).sorted() == [
        "File1.swift", "File2.swift", "File3.swift",
      ])
  }

  @Test
  func longSnapshotExcerptIsNotMarkedAsFullContent() {
    let reducer = FocusedFileStateReducer(maxSnapshotCharacters: 10)
    let path = WorkspaceRelativePath(rawValue: "index.html")

    let state = reducer.applyingToolResult(
      .writeFile(.success(path: path, bytesWritten: 20)),
      request: makeRequest(
        toolName: .writeFile,
        payload: .writeFile(
          WriteFileInput(path: "index.html", content: "01234567890123456789")
        )
      ),
      to: .empty,
      updatedAt: Date(timeIntervalSinceReferenceDate: 1)
    )

    #expect(state.snapshots[path]?.excerpt == "0123456789")
    #expect(state.snapshots[path]?.fullContentAvailable == false)
  }

  @Test
  func readFileContentBeyondSnapshotBudgetIsNotMarkedAsFullContent() {
    let reducer = FocusedFileStateReducer(maxSnapshotCharacters: 10)
    let path = WorkspaceRelativePath(rawValue: "README.md")

    let state = reducer.applyingToolResult(
      .readFile(.legacySuccess(path: path, content: ToolTextOutput(text: "01234567890"))),
      request: makeRequest(
        toolName: .readFile,
        payload: .readFile(ReadFileInput(path: path.rawValue))
      ),
      to: .empty,
      updatedAt: Date(timeIntervalSinceReferenceDate: 1)
    )

    #expect(state.snapshots[path]?.excerpt == "0123456789")
    #expect(state.snapshots[path]?.fullContentAvailable == false)
  }

  private func makeRequest(
    toolName: ToolName,
    payload: ToolCallPayload
  ) -> ToolCallRequest {
    ToolCallRequest.validated(
      raw: RawToolCallRequest(
        workspaceID: UUID(),
        sessionID: UUID(),
        toolName: toolName,
        arguments: [:],
        createdAt: Date(timeIntervalSinceReferenceDate: 1)
      ),
      payload: payload
    )
  }
}
