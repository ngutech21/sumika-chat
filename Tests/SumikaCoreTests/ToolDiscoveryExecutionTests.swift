import Darwin
import Foundation
import SumikaTestSupport
import Testing

@testable import SumikaCore

@Suite(TemporaryDirectoryTrait(named: "sumika-tool-discovery-tests"))
struct ToolDiscoveryExecutionTests {
  @Test
  func globFilesFindsMatchingFilesAndSkipsBuildDirectories() async throws {
    let workspace = try makeWorkspace()
    try write("app", to: "Sources/App.swift", in: workspace)
    try write("test", to: "Tests/AppTests.swift", in: workspace)
    try write("ignored", to: ".git/hooks/pre-commit.swift", in: workspace)
    try write("ignored", to: "DerivedData/App.swift", in: workspace)
    try write("ignored", to: ".build/check.swift", in: workspace)
    try write("ignored", to: "build/generated.swift", in: workspace)
    try write("ignored", to: ".swiftpm/x.swift", in: workspace)

    let result = await GlobFilesToolExecutor().run(
      GlobFilesInput(pattern: "**/*.swift", path: nil),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(
      result.text.split(separator: "\n").map(String.init) == [
        "Sources/App.swift",
        "Tests/AppTests.swift",
      ])
    #expect(!result.text.contains("DerivedData"))
    #expect(!result.truncated)
  }

  @Test
  func globFilesSkipsExplicitExcludedRootPath() async throws {
    let workspace = try makeWorkspace()
    try write("ignored", to: ".git/hooks/pre-commit.swift", in: workspace)

    let result = await GlobFilesToolExecutor().run(
      GlobFilesInput(pattern: "**/*.swift", path: ".git"),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(result.text == "(no matches)")
    #expect(!result.truncated)
  }

  @Test
  func globFilesLimitsResultCount() async throws {
    let workspace = try makeWorkspace()
    try write("one", to: "A/One.swift", in: workspace)
    try write("two", to: "B/Two.swift", in: workspace)

    let result = await GlobFilesToolExecutor(maxResults: 1).run(
      GlobFilesInput(pattern: "**/*.swift", path: "."),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(result.text.split(separator: "\n").count == 1)
    #expect(result.truncated)
  }

  @Test
  func globFilesPermissionDeniesWorkspaceEscapes() async throws {
    let workspace = try makeWorkspace()
    let executor = GlobFilesToolExecutor()

    let parentEscape = executor.evaluatePermission(
      GlobFilesInput(pattern: "**/*.swift", path: "../secret"),
      context: ToolContext(workspace: workspace)
    )

    #expect(parentEscape.decision == .denied)
  }

  @Test
  func searchFilesFindsRegexMatchesWithIncludeFilterAndSnippets() async throws {
    let workspace = try makeWorkspace()
    try write(
      """
      import Foundation
      struct ToolDefinition {}
      let other = "ignored"
      """,
      to: "Sources/App.swift",
      in: workspace
    )
    try write("struct ToolDefinition {}", to: "Sources/App.txt", in: workspace)
    try write("struct ToolDefinition {}", to: ".git/config.swift", in: workspace)

    let result = await SearchFilesToolExecutor().run(
      SearchFilesInput(pattern: #"Tool\w+"#, path: ".", include: "*.swift"),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(result.text == "Sources/App.swift:2: struct ToolDefinition {}")
    #expect(!result.text.contains("App.txt"))
    #expect(!result.truncated)
  }

  @Test
  func searchFilesFindsMatchesInRegularFilePath() async throws {
    let workspace = try makeWorkspace()
    try write(
      """
      function initialize() {}
      function startFlight() {}
      """,
      to: "index.html",
      in: workspace
    )

    let result = await SearchFilesToolExecutor().run(
      SearchFilesInput(pattern: #"function startFlight\(\)"#, path: "index.html", include: nil),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(result.text == "index.html:2: function startFlight() {}")
    #expect(result.affectedPaths == ["index.html"])
    #expect(!result.truncated)
  }

  @Test
  func searchFilesReturnsNoMatchesForNonMatchingRegularFilePath() async throws {
    let workspace = try makeWorkspace()
    try write("function initialize() {}", to: "index.html", in: workspace)

    let result = await SearchFilesToolExecutor().run(
      SearchFilesInput(pattern: "startFlight", path: "index.html", include: nil),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(result.text == "(no matches)")
    #expect(result.affectedPaths == ["index.html"])
    #expect(!result.truncated)
  }

  @Test
  func searchFilesAppliesIncludeFilterToRegularFilePath() async throws {
    let workspace = try makeWorkspace()
    try write("let value = 1", to: "Sources/App.swift", in: workspace)
    let executor = SearchFilesToolExecutor()

    let matchingInclude = await executor.run(
      SearchFilesInput(pattern: "value", path: "Sources/App.swift", include: "*.swift"),
      context: ToolContext(workspace: workspace)
    )
    let nonMatchingInclude = await executor.run(
      SearchFilesInput(pattern: "value", path: "Sources/App.swift", include: "*.txt"),
      context: ToolContext(workspace: workspace)
    )

    #expect(matchingInclude.status == .success)
    #expect(matchingInclude.text == "Sources/App.swift:1: let value = 1")
    #expect(nonMatchingInclude.status == .success)
    #expect(nonMatchingInclude.text == "(no matches)")
  }

  @Test
  func searchFilesReportsMissingPath() async throws {
    let workspace = try makeWorkspace()

    let result = await SearchFilesToolExecutor().run(
      SearchFilesInput(pattern: "value", path: "missing.txt", include: nil),
      context: ToolContext(workspace: workspace)
    )

    guard case .failure(let failure) = result else {
      Issue.record("Expected missing path failure")
      return
    }
    #expect(failure.path == WorkspaceRelativePath(rawValue: "missing.txt"))
    #expect(failure.reason == .fileNotFound(path: nil, suggestions: []))
  }

  @Test
  func searchFilesRejectsUnsupportedFilesystemObject() async throws {
    let workspace = try makeWorkspace()
    let fifoURL = workspace.rootURL.appending(path: "events.pipe")
    try #require(Darwin.mkfifo(fifoURL.path(percentEncoded: false), 0o600) == 0)

    let result = await SearchFilesToolExecutor().run(
      SearchFilesInput(pattern: "value", path: "events.pipe", include: nil),
      context: ToolContext(workspace: workspace)
    )

    guard case .failure(let failure) = result else {
      Issue.record("Expected unsupported filesystem object failure")
      return
    }
    #expect(failure.path == WorkspaceRelativePath(rawValue: "events.pipe"))
    #expect(
      failure.reason
        == .executionError("Path must resolve to a regular file or directory."))
  }

  @Test
  func searchFilesSearchesExplicitFileInsideSkippedDirectory() async throws {
    let workspace = try makeWorkspace()
    try write("secret match", to: ".git/config", in: workspace)

    let result = await SearchFilesToolExecutor().run(
      SearchFilesInput(pattern: "match", path: ".git/config", include: nil),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(result.text == ".git/config:1: secret match")
    #expect(!result.truncated)
  }

  @Test
  func searchFilesFallsBackToLiteralForInvalidRegexAndLimitsMatches() async throws {
    let workspace = try makeWorkspace()
    try write(
      """
      alpha [
      beta [
      gamma [
      """,
      to: "notes.txt",
      in: workspace
    )

    let result = await SearchFilesToolExecutor(maxMatches: 2, maxSnippetLength: 20).run(
      SearchFilesInput(pattern: "[", path: nil, include: nil),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(
      result.text.split(separator: "\n").map(String.init) == [
        "notes.txt:1: alpha [",
        "notes.txt:2: beta [",
      ])
    #expect(result.truncated)
  }

  @Test
  func searchFilesSkipsLargeFilesAndReportsTruncation() async throws {
    let workspace = try makeWorkspace()
    try write(String(repeating: "match", count: 100), to: "large.txt", in: workspace)

    let result = await SearchFilesToolExecutor(maxFileBytes: 10).run(
      SearchFilesInput(pattern: "match", path: ".", include: nil),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(result.text == "(no matches)")
    #expect(result.truncated)
  }

  @Test
  func searchFilesSkipsExplicitExcludedRootPath() async throws {
    let workspace = try makeWorkspace()
    try write("secret match", to: "build/generated.txt", in: workspace)

    let result = await SearchFilesToolExecutor().run(
      SearchFilesInput(pattern: "match", path: "build", include: nil),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(result.text == "(no matches)")
    #expect(!result.truncated)
  }

  @Test
  func searchFilesPermissionDeniesWorkspaceEscapes() async throws {
    let workspace = try makeWorkspace()
    let executor = SearchFilesToolExecutor()

    let parentEscape = executor.evaluatePermission(
      SearchFilesInput(pattern: "secret", path: "../secret", include: nil),
      context: ToolContext(workspace: workspace)
    )

    #expect(parentEscape.decision == .denied)
  }

  @Test
  func orchestratorDecodesGlobAndSearchFileInputs() async throws {
    let workspace = try makeWorkspace()
    try write("let value = 1", to: "Sources/App.swift", in: workspace)

    let glob = await ToolOrchestrator().execute(
      request: request(
        .globFiles,
        workspace: workspace,
        arguments: [
          "pattern": .string("**/*.swift"),
          "path": .string("."),
        ]
      ),
      workspace: workspace
    )
    let search = await ToolOrchestrator().execute(
      request: request(
        .searchFiles,
        workspace: workspace,
        arguments: [
          "pattern": .string("value"),
          "include": .string("*.swift"),
        ]
      ),
      workspace: workspace
    )

    #expect(glob.status == .completed)
    #expect(glob.state.preview?.text == "Sources/App.swift")
    #expect(search.status == .completed)
    #expect(search.state.preview?.text == "Sources/App.swift:1: let value = 1")
  }

  private func request(
    _ toolName: ToolName,
    workspace: Workspace,
    arguments: ToolCallArguments
  ) -> RawToolCallRequest {
    RawToolCallRequest(
      workspaceID: workspace.id,
      sessionID: UUID(),
      toolName: toolName,
      arguments: arguments
    )
  }

  private func makeWorkspace() throws -> Workspace {
    let rootURL = try scopedTemporaryDirectory()
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
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
