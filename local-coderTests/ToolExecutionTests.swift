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
      request: request(
        .readFile, workspace: workspace, arguments: ["path": .string("../secret.txt")]),
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
  func readFileDropsPartialUTF8SuffixWhenTruncating() async throws {
    let workspace = try makeWorkspace()
    let fileURL = workspace.rootURL.appending(path: "emoji.txt")
    let content = "abc🙂def"
    try content.write(to: fileURL, atomically: true, encoding: .utf8)

    let result = await ReadFileToolExecutor(maxBytes: 5).run(
      ReadFileInput(path: "emoji.txt"),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(result.text == "abc")
    #expect(result.truncated)
  }

  @Test
  func readFileDropsEntirePartialUTF8CharacterWhenPreviewHasNoValidPrefix() async throws {
    let workspace = try makeWorkspace()
    let fileURL = workspace.rootURL.appending(path: "emoji.txt")
    try "🙂".write(to: fileURL, atomically: true, encoding: .utf8)

    let result = await ReadFileToolExecutor(maxBytes: 2).run(
      ReadFileInput(path: "emoji.txt"),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(result.text == "")
    #expect(result.truncated)
  }

  @Test
  func listFilesPermissionAllowsDefaultAndNestedWorkspacePaths() async throws {
    let workspace = try makeWorkspace()
    let executor = ListFilesToolExecutor()

    let defaultEvaluation = executor.evaluatePermission(
      ListFilesInput(path: nil),
      context: ToolContext(workspace: workspace)
    )
    let nestedEvaluation = executor.evaluatePermission(
      ListFilesInput(path: "Sources"),
      context: ToolContext(workspace: workspace)
    )

    #expect(defaultEvaluation.decision == .allowed)
    #expect(defaultEvaluation.normalizedPaths == [workspace.rootURL.path(percentEncoded: false)])
    #expect(nestedEvaluation.decision == .allowed)
    #expect(
      nestedEvaluation.normalizedPaths == [
        workspace.rootURL.appending(path: "Sources").path(percentEncoded: false)
      ])
  }

  @Test
  func listFilesPermissionDeniesWorkspaceEscapesAndUnsupportedURLs() async throws {
    let workspace = try makeWorkspace()
    let executor = ListFilesToolExecutor()

    let parentEscape = executor.evaluatePermission(
      ListFilesInput(path: "../secret"),
      context: ToolContext(workspace: workspace)
    )
    let absoluteEscape = executor.evaluatePermission(
      ListFilesInput(path: "/tmp/secret"),
      context: ToolContext(workspace: workspace)
    )
    let unsupportedURL = executor.evaluatePermission(
      ListFilesInput(path: "https://example.com/project"),
      context: ToolContext(workspace: workspace)
    )

    #expect(parentEscape.decision == .denied)
    #expect(absoluteEscape.decision == .denied)
    #expect(unsupportedURL.decision == .denied)
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
    let unregisteredWriteFile = await ToolOrchestrator().execute(
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
    #expect(unregisteredWriteFile.status == .failed)
    #expect(unknownExecutor.status == .failed)
    #expect(unknownExecutor.resultPreview?.status == .failed)
  }

  @Test
  func writeFileDefinitionIsAvailableButNotInReadOnlyRegistry() {
    let definition = ToolDefinition.writeFile

    #expect(definition.name == .writeFile)
    #expect(definition.parameters.map(\.name) == ["path", "content"])
    #expect(
      definition.parameters.first(where: { $0.name == "content" })?.supportsHeredocPayload
        == true)
    #expect(definition.capabilities == [.writeWorkspace])
    #expect(definition.riskLevel == .high)
    #expect(ToolExecutorRegistry.readOnly.definitions == [.readFile, .listFiles])
  }

  @Test
  func writeFileRequiresApprovalForWorkspacePath() async throws {
    let workspace = try makeWorkspace()
    let executor = WriteFileToolExecutor()

    let evaluation = executor.evaluatePermission(
      WriteFileInput(path: "Sources/App.swift", content: "let value = 1"),
      context: ToolContext(workspace: workspace)
    )

    #expect(evaluation.decision == .requiresApproval)
    #expect(evaluation.riskLevel == .high)
    #expect(
      evaluation.normalizedPaths == [
        workspace.rootURL.appending(path: "Sources/App.swift").path(percentEncoded: false)
      ])
  }

  @Test
  func writeFileDeniesWorkspaceEscapesBeforeApproval() async throws {
    let workspace = try makeWorkspace()
    let executor = WriteFileToolExecutor()

    let parentEscape = executor.evaluatePermission(
      WriteFileInput(path: "../secret.txt", content: "secret"),
      context: ToolContext(workspace: workspace)
    )
    let absoluteEscape = executor.evaluatePermission(
      WriteFileInput(path: "/tmp/secret.txt", content: "secret"),
      context: ToolContext(workspace: workspace)
    )

    #expect(parentEscape.decision == .denied)
    #expect(absoluteEscape.decision == .denied)
  }

  @Test
  func orchestratorMarksWriteFileAwaitingApprovalWithoutWriting() async throws {
    let workspace = try makeWorkspace()
    try write("old", to: "README.md", in: workspace)
    let registry = ToolExecutorRegistry([
      AnyToolExecutor(ReadFileToolExecutor()),
      AnyToolExecutor(ListFilesToolExecutor()),
      AnyToolExecutor(WriteFileToolExecutor()),
    ])

    let result = await ToolOrchestrator(executorRegistry: registry).execute(
      request: request(
        .writeFile,
        workspace: workspace,
        arguments: [
          "path": .string("README.md"),
          "content": .string("new"),
        ]
      ),
      workspace: workspace
    )

    #expect(result.status == .awaitingApproval)
    #expect(result.evaluation.decision == .requiresApproval)
    #expect(result.resultPreview == nil)
    #expect(result.events.map(\.kind).contains(.awaitingApproval))
    #expect(try String(contentsOf: workspace.rootURL.appending(path: "README.md")) == "old")
  }

  @Test
  func writeFileRunWritesApprovedContent() async throws {
    let workspace = try makeWorkspace()

    let result = await WriteFileToolExecutor().run(
      WriteFileInput(path: "Sources/App.swift", content: "let value = 2"),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(
      result.affectedPaths == [
        workspace.rootURL.appending(path: "Sources/App.swift").path(percentEncoded: false)
      ])
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "Sources/App.swift"))
        == "let value = 2")
  }

  @Test
  func writeFileInvalidArgumentsFailBeforeApproval() async throws {
    let workspace = try makeWorkspace()
    let registry = ToolExecutorRegistry([
      AnyToolExecutor(WriteFileToolExecutor())
    ])

    let missingContent = await ToolOrchestrator(executorRegistry: registry).execute(
      request: request(
        .writeFile,
        workspace: workspace,
        arguments: ["path": .string("README.md")]
      ),
      workspace: workspace
    )
    let unknownArgument = await ToolOrchestrator(executorRegistry: registry).execute(
      request: request(
        .writeFile,
        workspace: workspace,
        arguments: [
          "path": .string("README.md"),
          "content": .string("new"),
          "mode": .string("append"),
        ]
      ),
      workspace: workspace
    )

    #expect(missingContent.status == .failed)
    #expect(unknownArgument.status == .failed)
    #expect(unknownArgument.resultPreview?.text.contains("Unknown argument") == true)
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
