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

    let result = await ReadFileToolExecutor().run(
      ReadFileInput(path: "Sources/App.swift"),
      context: ToolContext(workspace: workspace)
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

    let missingPath = await ToolOrchestrator().execute(
      request: request(.readFile, workspace: workspace, arguments: [:]),
      workspace: workspace
    )
    let nonUTF8 = await ReadFileToolExecutor().run(
      ReadFileInput(path: "binary.dat"),
      context: ToolContext(workspace: workspace)
    )
    let outside = await ToolOrchestrator().execute(
      request: request(.readFile, workspace: workspace, arguments: ["path": .string("../secret.txt")]),
      workspace: workspace
    )

    #expect(missingPath.status == .failed)
    #expect(nonUTF8.status == .failed)
    #expect(outside.status == .denied)
  }

  @Test
  func readFileTruncatesLargeFilesForModelContext() async throws {
    let workspace = try makeWorkspace()
    let fileURL = workspace.rootURL.appending(path: "large.txt")
    try String(repeating: "a", count: 120).write(to: fileURL, atomically: true, encoding: .utf8)

    let result = await ReadFileToolExecutor(maxBytes: 40).run(
      ReadFileInput(path: "large.txt"),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(result.text.count == 40)
    #expect(result.truncated)
  }

  @Test
  func readFileDoesNotDecodeBytesPastPreviewLimit() async throws {
    let workspace = try makeWorkspace()
    let fileURL = workspace.rootURL.appending(path: "mixed.txt")
    let validPreview = String(repeating: "a", count: 40)
    var data = Data(validPreview.utf8)
    data.append(0xff)
    try data.write(to: fileURL)

    let result = await ReadFileToolExecutor(maxBytes: 40).run(
      ReadFileInput(path: "mixed.txt"),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(result.text == validPreview)
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

    let result = await ListFilesToolExecutor(maxDepth: 4, maxEntries: 3).run(
      ListFilesInput(path: nil),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(
      result.text.split(separator: "\n").map(String.init) == [
        "alpha.txt", "Sources/", "Sources/App.swift",
      ])
    #expect(!result.text.contains(".git"))
    #expect(!result.text.contains("node_modules"))
    #expect(result.truncated)
  }

  @Test
  func listFilesRespectsDepthLimit() async throws {
    let workspace = try makeWorkspace()
    try write("deep", to: "a/b/c/file.txt", in: workspace)

    let result = await ListFilesToolExecutor(maxDepth: 1, maxEntries: 300).run(
      ListFilesInput(path: "."),
      context: ToolContext(workspace: workspace)
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
    #expect(requiresApproval.status == .failed)
    #expect(unknownExecutor.status == .failed)
    #expect(unknownExecutor.resultPreview?.status == .failed)
  }

  @Test
  func orchestratorDecodesTypedInputsBeforeExecution() async throws {
    let workspace = try makeWorkspace()
    try write("hello", to: "README.md", in: workspace)

    let valid = await ToolOrchestrator().execute(
      request: request(.readFile, workspace: workspace, arguments: ["path": .string("README.md")]),
      workspace: workspace
    )
    let missingPath = await ToolOrchestrator().execute(
      request: request(.readFile, workspace: workspace, arguments: [:]),
      workspace: workspace
    )
    let wrongPathType = await ToolOrchestrator().execute(
      request: request(.readFile, workspace: workspace, arguments: ["path": .number(1)]),
      workspace: workspace
    )
    let unknownArgument = await ToolOrchestrator().execute(
      request: request(
        .readFile,
        workspace: workspace,
        arguments: ["path": .string("README.md"), "extra": .string("ignored")]
      ),
      workspace: workspace
    )

    #expect(valid.status == .completed)
    #expect(missingPath.status == .failed)
    #expect(missingPath.resultPreview?.text.contains("Invalid arguments for read_file") == true)
    #expect(wrongPathType.status == .failed)
    #expect(wrongPathType.resultPreview?.text.contains("Invalid arguments for read_file") == true)
    #expect(unknownArgument.status == .failed)
    #expect(unknownArgument.resultPreview?.text.contains("Unknown argument") == true)
  }

  @Test
  func orchestratorDecodesOptionalListFilesPath() async throws {
    let workspace = try makeWorkspace()
    try write("hello", to: "README.md", in: workspace)

    let withoutPath = await ToolOrchestrator().execute(
      request: request(.listFiles, workspace: workspace, arguments: [:]),
      workspace: workspace
    )

    #expect(withoutPath.status == .completed)
    #expect(withoutPath.resultPreview?.text.contains("README.md") == true)
  }

  @Test
  func orchestratorDeniesToolCallsFromDifferentWorkspace() async throws {
    let activeWorkspace = try makeWorkspace()
    let staleWorkspace = try makeWorkspace()
    try write("active", to: "README.md", in: activeWorkspace)

    let staleRequest = ToolCallRequest(
      workspaceID: staleWorkspace.id,
      sessionID: UUID(),
      toolName: .readFile,
      arguments: ["path": .string("README.md")]
    )

    let result = await ToolOrchestrator().execute(
      request: staleRequest,
      workspace: activeWorkspace
    )

    #expect(result.status == .denied)
    #expect(result.evaluation.decision == .denied)
    #expect(result.evaluation.riskLevel == .high)
    #expect(result.resultPreview?.status == .denied)
    #expect(
      result.resultPreview?.text == "Tool call workspace does not match the active workspace."
    )
  }

  @Test
  func registryDefinitionsComeFromRegisteredExecutors() {
    let registry = ToolExecutorRegistry.readOnly

    #expect(registry.definitions == [.readFile, .listFiles])
    #expect(registry.toolRegistry.tools == [.readFile, .listFiles])
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
