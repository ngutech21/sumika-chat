import Foundation
import SumikaTestSupport
import Testing

@testable import SumikaCore

@Suite(TemporaryDirectoryTrait(named: "sumika-workspace-file-io"))
struct WorkspaceFileIOTests {
  @Test(arguments: [ToolName.readFile, .editFile, .writeFile])
  func cancellationDuringPermissionIsNotDenial(toolName: ToolName) async {
    let workspace = Workspace(name: "Remote", rootURL: URL(filePath: "/sumika-nonexistent-remote"))
    let fileIO = MemoryWorkspaceFileIO(data: Data("old".utf8), cancelAt: .resolve)
    let orchestrator = ToolOrchestrator(executorRegistry: .codingAgent, fileIO: fileIO)
    let arguments: ToolCallArguments =
      switch toolName {
      case .editFile:
        ["path": .string("notes.txt"), "old_text": .string("old"), "new_text": .string("new")]
      case .writeFile:
        ["path": .string("notes.txt"), "content": .string("new")]
      default:
        ["path": .string("notes.txt")]
      }
    let request = RawToolCallRequest(
      workspaceID: workspace.id, sessionID: UUID(), toolName: toolName, arguments: arguments)
    let task = Task { await orchestrator.executeApproved(request: request, workspace: workspace) }
    let result = await task.value
    #expect(result.status == .cancelled)
    #expect(await fileIO.writeCount == 0)
  }

  @Test(arguments: [false, true])
  func cancellationDuringEditReadStopsPreviewAndExecution(approved: Bool) async {
    let workspace = Workspace(name: "Remote", rootURL: URL(filePath: "/sumika-nonexistent-remote"))
    let fileIO = MemoryWorkspaceFileIO(data: Data("old".utf8), cancelAt: .read)
    let orchestrator = ToolOrchestrator(executorRegistry: .codingAgent, fileIO: fileIO)
    let request = RawToolCallRequest(
      workspaceID: workspace.id, sessionID: UUID(), toolName: .editFile,
      arguments: [
        "path": .string("notes.txt"), "old_text": .string("old"), "new_text": .string("new"),
      ])
    let task = Task {
      if approved {
        return await orchestrator.executeApproved(request: request, workspace: workspace)
      }
      return await orchestrator.execute(request: request, workspace: workspace)
    }
    #expect(await task.value.status == .cancelled)
    #expect(await fileIO.writeCount == 0)
  }

  @Test
  func nativeFileToolsUseInjectedIOWithoutAHostWorkspace() async throws {
    let workspace = Workspace(name: "Remote", rootURL: URL(filePath: "/sumika-nonexistent-remote"))
    let original = Data("one\ntwo\nthree\n".utf8)
    let fileIO = MemoryWorkspaceFileIO(data: original)
    let context = ToolContext(workspace: workspace, fileIO: fileIO)
    let reader = ReadFileToolExecutor()
    let permission = await reader.evaluatePermission(
      ReadFileInput(path: "notes.txt"), context: context)
    #expect(permission.normalizedPaths == ["/remote/notes.txt"])
    let read = await reader.run(
      ReadFileInput(path: "notes.txt", offset: 2, limit: 1), context: context)
    guard case .readFile(.page(let page)) = read else {
      Issue.record("Expected a page from the remote file.")
      return
    }
    #expect(page.content == "two")
    #expect(page.continuation == .next(offset: 3, reason: .lineLimit))

    let editor = EditFileToolExecutor()
    let edits = [
      EditFileInput(path: "notes.txt", oldText: "one", newText: "ONE"),
      EditFileInput(path: "./notes.txt", oldText: "three", newText: "THREE"),
    ]
    guard case .ready = await editor.prepareApprovalGroup(edits, context: context) else {
      Issue.record("Expected a remote edit preview.")
      return
    }
    #expect(await fileIO.writeCount == 0)
    guard case .completed(let results) = await editor.runGroup(edits, context: context) else {
      Issue.record("Expected one combined remote edit.")
      return
    }
    #expect(results.count == 2)
    #expect(results.allSatisfy { $0.status == .success })
    #expect(await fileIO.data == Data("ONE\ntwo\nTHREE\n".utf8))
    #expect(await fileIO.lastExpectedContents == original)
    #expect(await fileIO.writeCount == 1)

    let missingMatch = await editor.run(
      EditFileInput(path: "notes.txt", oldText: "missing", newText: "replacement"), context: context
    )
    guard case .editFile(.oldTextNotFound(_, let excerpt, _)) = missingMatch else {
      Issue.record("Expected the remote current-content recovery excerpt.")
      return
    }
    #expect(excerpt?.text == "ONE\ntwo\nTHREE\n")
    let write = await WriteFileToolExecutor().run(
      WriteFileInput(path: "notes.txt", content: "replacement"), context: context
    )
    #expect(write.status == .success)
    #expect(await fileIO.lastExpectedContents == nil)
    #expect(await fileIO.data == Data("replacement".utf8))
  }

  @Test
  func pagedReadsRetainBoundedChunksAndUTF8AcrossChunkBoundaries() async throws {
    let text = String(repeating: "x", count: 8_191) + "\u{00E4}\nlast\n"
    let fileIO = MemoryWorkspaceFileIO(data: Data(text.utf8))
    let workspace = Workspace(name: "Remote", rootURL: URL(filePath: "/sumika-nonexistent-remote"))
    let result = await ReadFileToolExecutor(maxBytes: 12_000).run(
      ReadFileInput(path: "notes.txt"), context: ToolContext(workspace: workspace, fileIO: fileIO)
    )
    guard case .readFile(.page(let page)) = result else {
      Issue.record("Expected UTF-8 decoding across a transport chunk boundary.")
      return
    }
    #expect(page.content == String(text.dropLast()))
    #expect(page.continuation == .endOfFile)
    #expect(await fileIO.largestRead == 8 * 1_024)
  }

  @Test
  func localPagedReadKeepsOriginalFileWhenItsPathIsAtomicallyReplaced() async throws {
    let root = try scopedTemporaryDirectory()
    let workspace = Workspace(name: "Local", rootURL: root)
    let original = String(repeating: "original\n", count: 1_200)
    let replacement = Data("replacement\n".utf8)
    let fileIO = LocalWorkspaceFileIO()
    try await fileIO.write(
      path: "notes.txt", in: workspace, data: Data(original.utf8), expectedContents: nil
    )
    let result = try await fileIO.withReader(path: "notes.txt", in: workspace) { readChunk in
      try await ReadFileToolExecutor.readPage(
        path: WorkspaceRelativePath(rawValue: "notes.txt"), startLine: 1,
        maxLines: nil, maxBytes: 30_000,
        readChunk: { offset, maxBytes in
          let chunk = try await readChunk(offset, maxBytes)
          if offset == 0 {
            try await fileIO.write(
              path: "notes.txt", in: workspace, data: replacement, expectedContents: nil
            )
          }
          return chunk
        }
      )
    }
    guard case .page(let page) = result else {
      Issue.record("Expected a stable page from the original open file.")
      return
    }
    #expect(page.content == String(original.dropLast()))
    #expect(page.continuation == .endOfFile)
    #expect(try Data(contentsOf: root.appending(path: "notes.txt")) == replacement)
  }

  @Test
  func localIOAllowsContainedSymlinksAndRefusesChangedContents() async throws {
    let root = try scopedTemporaryDirectory()
    let workspace = Workspace(name: "Local", rootURL: root)
    let original = root.appending(path: "original.txt")
    try Data("old".utf8).write(to: original)
    try FileManager.default.createSymbolicLink(
      at: root.appending(path: "alias.txt"), withDestinationURL: original
    )
    let fileIO = LocalWorkspaceFileIO()
    let location = try await fileIO.resolve(path: "alias.txt", in: workspace)
    #expect(location.relativePath.rawValue == "original.txt")
    #expect(location.isRegularFile)
    #expect(
      try await fileIO.read(path: "alias.txt", in: workspace, offset: 1, maxBytes: 1)
        == Data("l".utf8))
    await #expect(throws: WorkspaceFileIOError.self) {
      try await fileIO.write(
        path: "alias.txt", in: workspace, data: Data("new".utf8),
        expectedContents: Data("stale".utf8)
      )
    }
    #expect(try Data(contentsOf: original) == Data("old".utf8))
    try await fileIO.write(
      path: "alias.txt", in: workspace, data: Data("new".utf8), expectedContents: Data("old".utf8)
    )
    #expect(try Data(contentsOf: original) == Data("new".utf8))
  }
}

private actor MemoryWorkspaceFileIO: WorkspaceFileIO {
  enum CancellationPoint: Sendable { case resolve, read }

  var data: Data
  var writeCount = 0
  var lastExpectedContents: Data?
  var largestRead = 0
  let cancelAt: CancellationPoint?

  init(data: Data, cancelAt: CancellationPoint? = nil) {
    self.data = data
    self.cancelAt = cancelAt
  }

  func resolve(path _: String, in _: Workspace) throws -> WorkspaceFileLocation {
    try checkCancellation(at: .resolve)
    return WorkspaceFileLocation(
      absolutePath: "/remote/notes.txt", relativePath: WorkspaceRelativePath(rawValue: "notes.txt")
    )
  }

  func read(path _: String, in _: Workspace, offset: Int, maxBytes: Int?) throws -> Data {
    try checkCancellation(at: .read)
    largestRead = max(largestRead, maxBytes ?? 0)
    let start = min(offset, data.count)
    return data.subdata(in: start..<min(data.count, start + (maxBytes ?? data.count)))
  }

  func write(path _: String, in _: Workspace, data: Data, expectedContents: Data?) throws {
    if let expectedContents, self.data != expectedContents {
      throw WorkspaceFileIOError.contentChanged
    }
    lastExpectedContents = expectedContents
    self.data = data
    writeCount += 1
  }

  func listDirectory(path _: String, in _: Workspace) -> [String] { ["notes.txt"] }

  private func checkCancellation(at point: CancellationPoint) throws {
    guard cancelAt == point else { return }
    withUnsafeCurrentTask { $0?.cancel() }
    throw CancellationError()
  }
}
