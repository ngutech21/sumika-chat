import Foundation
import Testing

@testable import local_coder

struct ToolExecutionTests {
  @Test
  func readFileReadsUTF8TextInsideWorkspace() async throws {
    let workspace = try makeWorkspace()
    let fileURL = workspace.rootURL.appending(path: "Sources/App.swift")
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "let value = 1".write(to: fileURL, atomically: true, encoding: .utf8)

    let result = await ReadFileToolExecutor().execute(
      request: request(
        .readFile, workspace: workspace, arguments: ["path": .string("Sources/App.swift")]),
      workspace: workspace
    )

    #expect(result.status == .success)
    #expect(result.text == "let value = 1")
    #expect(result.truncated == false)
    #expect(result.affectedPaths == [fileURL.path(percentEncoded: false)])
  }

  @Test
  func readFileFailsForMissingPathNonUTF8AndWorkspaceEscape() async throws {
    let workspace = try makeWorkspace()
    let binaryURL = workspace.rootURL.appending(path: "binary.dat")
    try Data([0xff, 0xfe, 0xfd]).write(to: binaryURL)

    let missingPath = await ReadFileToolExecutor().execute(
      request: request(.readFile, workspace: workspace, arguments: [:]),
      workspace: workspace
    )
    let nonUTF8 = await ReadFileToolExecutor().execute(
      request: request(.readFile, workspace: workspace, arguments: ["path": .string("binary.dat")]),
      workspace: workspace
    )
    let outside = await ReadFileToolExecutor().execute(
      request: request(
        .readFile, workspace: workspace, arguments: ["path": .string("../secret.txt")]),
      workspace: workspace
    )

    #expect(missingPath.status == .failed)
    #expect(nonUTF8.status == .failed)
    #expect(outside.status == .failed)
  }

  @Test
  func readFileTruncatesLargeFilesForModelContext() async throws {
    let workspace = try makeWorkspace()
    let fileURL = workspace.rootURL.appending(path: "large.txt")
    try String(repeating: "a", count: 120).write(to: fileURL, atomically: true, encoding: .utf8)

    let result = await ReadFileToolExecutor(maxBytes: 40).execute(
      request: request(.readFile, workspace: workspace, arguments: ["path": .string("large.txt")]),
      workspace: workspace
    )

    #expect(result.status == .success)
    #expect(result.text.count == 40)
    #expect(result.truncated)
  }

  @Test
  func listFilesSortsSkipsAndTruncates() async throws {
    let workspace = try makeWorkspace()
    try write("root", to: "zeta.txt", in: workspace)
    try write("root", to: "alpha.txt", in: workspace)
    try write("skip", to: ".git/config", in: workspace)
    try write("skip", to: "node_modules/pkg/index.js", in: workspace)
    try write("nested", to: "Sources/App.swift", in: workspace)

    let result = await ListFilesToolExecutor(maxDepth: 4, maxEntries: 3).execute(
      request: request(.listFiles, workspace: workspace, arguments: [:]),
      workspace: workspace
    )

    #expect(result.status == .success)
    #expect(
      result.text.split(separator: "\n").map(String.init) == [
        "alpha.txt", "Sources/", "Sources/App.swift"
      ])
    #expect(!result.text.contains(".git"))
    #expect(!result.text.contains("node_modules"))
    #expect(result.truncated)
  }

  @Test
  func listFilesRespectsDepthLimit() async throws {
    let workspace = try makeWorkspace()
    try write("deep", to: "a/b/c/file.txt", in: workspace)

    let result = await ListFilesToolExecutor(maxDepth: 1, maxEntries: 300).execute(
      request: request(.listFiles, workspace: workspace, arguments: ["path": .string(".")]),
      workspace: workspace
    )

    #expect(result.status == .success)
    #expect(result.text.contains("a/"))
    #expect(result.text.contains("a/b/"))
    #expect(!result.text.contains("a/b/c/"))
    #expect(result.truncated)
  }

  @Test
  func orchestratorRunsAllowedToolAndSkipsDeniedOrUnknownExecutors() async throws {
    let workspace = try makeWorkspace()
    try write("hello", to: "README.md", in: workspace)

    let completed = await ToolOrchestrator().execute(
      request: request(.readFile, workspace: workspace, arguments: ["path": .string("README.md")]),
      workspace: workspace
    )
    let denied = await ToolOrchestrator().execute(
      request: request(
        .readFile, workspace: workspace, arguments: ["path": .string("../README.md")]),
      workspace: workspace
    )
    let requiresApproval = await ToolOrchestrator().execute(
      request: request(.writeFile, workspace: workspace, arguments: ["path": .string("README.md")]),
      workspace: workspace
    )
    let unknownExecutor = await ToolOrchestrator(
      executorRegistry: ToolExecutorRegistry(executors: [:])
    ).execute(
      request: request(.readFile, workspace: workspace, arguments: ["path": .string("README.md")]),
      workspace: workspace
    )

    #expect(completed.status == .completed)
    #expect(completed.resultPreview?.status == .success)
    #expect(denied.status == .denied)
    #expect(denied.resultPreview?.status == .denied)
    #expect(requiresApproval.status == .denied)
    #expect(unknownExecutor.status == .failed)
    #expect(unknownExecutor.resultPreview?.status == .failed)
  }

  private func request(
    _ toolName: ToolName,
    workspace: Workspace,
    arguments: ToolCallArguments
  ) -> ToolCallRequest {
    ToolCallRequest(
      workspaceID: workspace.id,
      sessionID: UUID(),
      toolName: toolName,
      arguments: arguments
    )
  }

  private func makeWorkspace() throws -> Workspace {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "local-coder-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return Workspace(
      name: "Project", rootURL: URL(filePath: Workspace.normalizedPath(for: rootURL)))
  }

  private func write(_ content: String, to path: String, in workspace: Workspace) throws {
    let url = workspace.rootURL.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try content.write(to: url, atomically: true, encoding: .utf8)
  }
}
