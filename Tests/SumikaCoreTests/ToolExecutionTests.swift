import Foundation
import Testing

@testable import SumikaCore

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
    #expect(result.text == "1: let value = 1")
    #expect(result.truncated == false)
    #expect(result.affectedPaths == ["Sources/App.swift"])
    guard case .readFile(.success(let path, _)) = result else {
      Issue.record("Expected read_file success payload.")
      return
    }
    #expect(path.rawValue == "Sources/App.swift")
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
  func readFileMissingPathIncludesWorkspaceRelativeSuggestions() async throws {
    let workspace = try makeWorkspace()
    try write("html", to: "index.html", in: workspace)
    try write("swift", to: "Sources/ToolLoopCoordinator.swift", in: workspace)

    let missingHTML = await ReadFileToolExecutor().run(
      ReadFileInput(path: "landing.html"),
      context: ToolContext(workspace: workspace)
    )
    let outside = await ToolOrchestrator().execute(
      request: request(
        .readFile,
        workspace: workspace,
        arguments: ["path": .string("../landing.html")]
      ),
      workspace: workspace
    )

    #expect(missingHTML.status == .failed)
    #expect(missingHTML.text.contains("Did you mean one of these?"))
    #expect(missingHTML.text.contains("index.html"))
    #expect(missingHTML.affectedPaths == ["landing.html"])
    guard
      case .readFile(.failed(let path, .fileNotFound(_, let suggestions))) = missingHTML
    else {
      Issue.record("Expected read_file missing path payload with suggestions.")
      return
    }
    #expect(path == WorkspaceRelativePath(rawValue: "landing.html"))
    #expect(suggestions.first?.path == WorkspaceRelativePath(rawValue: "index.html"))
    #expect(outside.status == .denied)
    #expect(outside.resultPreview?.text.contains("Did you mean one of these?") == false)
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
    #expect(result.text.hasPrefix("1: "))
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
    #expect(result.text == "1: " + String(repeating: "a", count: 37))
    #expect(result.truncated)
  }

  @Test
  func readFileDoesNotBufferLongLinePastPreviewLimit() async throws {
    let workspace = try makeWorkspace()
    let fileURL = workspace.rootURL.appending(path: "minified.txt")
    var data = Data(String(repeating: "a", count: 1_000_000).utf8)
    data.append(0xff)
    try data.write(to: fileURL)

    let result = await ReadFileToolExecutor(maxBytes: 40).run(
      ReadFileInput(path: "minified.txt"),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(result.text == "1: " + String(repeating: "a", count: 37))
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
    #expect(result.text == "1: ab")
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
  func readFileReadsFocusedLineWindow() async throws {
    let workspace = try makeWorkspace()
    let fileURL = workspace.rootURL.appending(path: "notes.txt")
    try """
    one
    two
    three
    four
    """.write(to: fileURL, atomically: true, encoding: .utf8)

    let result = await ReadFileToolExecutor().run(
      ReadFileInput(path: "notes.txt", offset: 2, limit: 2),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(result.text == "2: two\n3: three")
    #expect(result.truncated)
  }

  @Test
  func readFileDeduplicatesRepeatedUnchangedReadsThroughOrchestrator() async throws {
    let workspace = try makeWorkspace()
    try write("hello", to: "README.md", in: workspace)
    let orchestrator = ToolOrchestrator()

    let first = await orchestrator.execute(
      request: request(.readFile, workspace: workspace, arguments: ["path": .string("README.md")]),
      workspace: workspace
    )
    let second = await orchestrator.execute(
      request: request(.readFile, workspace: workspace, arguments: ["path": .string("README.md")]),
      workspace: workspace
    )

    guard case .readFile(.success(let firstPath, _)) = first.resultPayload else {
      Issue.record("Expected first read_file to return content.")
      return
    }
    guard case .readFile(.unchanged(let secondPath, let readKey)) = second.resultPayload else {
      Issue.record("Expected second read_file to return unchanged.")
      return
    }

    #expect(firstPath.rawValue == "README.md")
    #expect(secondPath.rawValue == "README.md")
    #expect(readKey == ReadKey(path: WorkspaceRelativePath(rawValue: "README.md")))
    #expect(second.resultPreview?.text.contains("Use the existing context") == true)
  }

  @Test
  func readFileWarnsAfterRepeatedUnchangedReadLoop() async throws {
    let workspace = try makeWorkspace()
    try write("hello", to: "README.md", in: workspace)
    let orchestrator = ToolOrchestrator()

    for _ in 0..<3 {
      _ = await orchestrator.execute(
        request: request(
          .readFile, workspace: workspace, arguments: ["path": .string("README.md")]),
        workspace: workspace
      )
    }

    let fourth = await orchestrator.execute(
      request: request(.readFile, workspace: workspace, arguments: ["path": .string("README.md")]),
      workspace: workspace
    )

    guard case .readFile(.repeatedReadWarning(let path, let count)) = fourth.resultPayload else {
      Issue.record("Expected fourth read_file to return a repeated read warning.")
      return
    }

    #expect(path.rawValue == "README.md")
    #expect(count == 4)
    #expect(fourth.resultPreview?.text.contains("Repeated read_file loop detected") == true)
  }

  @Test
  func readFileDedupResetsAfterContentChanges() async throws {
    let workspace = try makeWorkspace()
    try write("hello", to: "README.md", in: workspace)
    let orchestrator = ToolOrchestrator()

    _ = await orchestrator.execute(
      request: request(.readFile, workspace: workspace, arguments: ["path": .string("README.md")]),
      workspace: workspace
    )
    let repeated = await orchestrator.execute(
      request: request(.readFile, workspace: workspace, arguments: ["path": .string("README.md")]),
      workspace: workspace
    )

    try write("changed", to: "README.md", in: workspace)
    let changed = await orchestrator.execute(
      request: request(.readFile, workspace: workspace, arguments: ["path": .string("README.md")]),
      workspace: workspace
    )

    guard case .readFile(.unchanged) = repeated.resultPayload else {
      Issue.record("Expected second read_file to return unchanged.")
      return
    }
    guard case .readFile(.success(_, let content)) = changed.resultPayload else {
      Issue.record("Expected changed file to return fresh content.")
      return
    }

    #expect(content.text == "1: changed")
  }

  @Test
  func readFileDedupTracksLineRangesSeparately() async throws {
    let workspace = try makeWorkspace()
    try write(
      """
      one
      two
      three
      """,
      to: "notes.txt",
      in: workspace
    )
    let orchestrator = ToolOrchestrator()

    _ = await orchestrator.execute(
      request: request(
        .readFile,
        workspace: workspace,
        arguments: [
          "path": .string("notes.txt"),
          "offset": .number(1),
          "limit": .number(1),
        ]
      ),
      workspace: workspace
    )
    let differentRange = await orchestrator.execute(
      request: request(
        .readFile,
        workspace: workspace,
        arguments: [
          "path": .string("notes.txt"),
          "offset": .number(2),
          "limit": .number(1),
        ]
      ),
      workspace: workspace
    )
    let firstRangeAfterDifferentRange = await orchestrator.execute(
      request: request(
        .readFile,
        workspace: workspace,
        arguments: [
          "path": .string("notes.txt"),
          "offset": .number(1),
          "limit": .number(1),
        ]
      ),
      workspace: workspace
    )
    let repeatedFirstRange = await orchestrator.execute(
      request: request(
        .readFile,
        workspace: workspace,
        arguments: [
          "path": .string("notes.txt"),
          "offset": .number(1),
          "limit": .number(1),
        ]
      ),
      workspace: workspace
    )

    guard case .readFile(.success(_, let content)) = differentRange.resultPayload else {
      Issue.record("Expected different line range to return fresh content.")
      return
    }
    guard
      case .readFile(.success(_, let firstRangeContent)) =
        firstRangeAfterDifferentRange.resultPayload
    else {
      Issue.record("Expected non-consecutive repeated line range to return fresh content.")
      return
    }
    guard case .readFile(.unchanged(_, let readKey)) = repeatedFirstRange.resultPayload else {
      Issue.record("Expected repeated line range to return unchanged.")
      return
    }

    #expect(content.text == "2: two")
    #expect(firstRangeContent.text == "1: one")
    #expect(readKey.range == "offset=1,limit=1")
  }

  @Test
  func readFileDedupResetsWhenDifferentPathIsReadBetweenRepeats() async throws {
    let workspace = try makeWorkspace()
    try write("a", to: "a.txt", in: workspace)
    try write("b", to: "b.txt", in: workspace)
    let orchestrator = ToolOrchestrator()

    _ = await orchestrator.execute(
      request: request(.readFile, workspace: workspace, arguments: ["path": .string("a.txt")]),
      workspace: workspace
    )
    _ = await orchestrator.execute(
      request: request(.readFile, workspace: workspace, arguments: ["path": .string("b.txt")]),
      workspace: workspace
    )
    let repeatedAfterDifferentPath = await orchestrator.execute(
      request: request(.readFile, workspace: workspace, arguments: ["path": .string("a.txt")]),
      workspace: workspace
    )

    guard case .readFile(.success(_, let content)) = repeatedAfterDifferentPath.resultPayload else {
      Issue.record("Expected non-consecutive repeated read_file to return fresh content.")
      return
    }

    #expect(content.text == "1: a")
  }

  @Test
  func directReadFileExecutorDoesNotDeduplicateWithoutTracker() async throws {
    let workspace = try makeWorkspace()
    try write("hello", to: "README.md", in: workspace)
    let executor = ReadFileToolExecutor()

    let first = await executor.run(
      ReadFileInput(path: "README.md"),
      context: ToolContext(workspace: workspace)
    )
    let second = await executor.run(
      ReadFileInput(path: "README.md"),
      context: ToolContext(workspace: workspace)
    )

    guard case .readFile(.success) = first else {
      Issue.record("Expected first direct read_file to return content.")
      return
    }
    guard case .readFile(.success) = second else {
      Issue.record("Expected second direct read_file to return content.")
      return
    }
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
  func readFileDefinitionIncludesPaginationArguments() {
    let definition = ToolDefinition.readFile

    #expect(definition.name == .readFile)
    #expect(definition.parameters.map(\.name) == ["path", "offset", "limit"])
    #expect(definition.parameters.first(where: { $0.name == "path" })?.isRequired == true)
    #expect(definition.parameters.first(where: { $0.name == "offset" })?.isRequired == false)
    #expect(definition.parameters.first(where: { $0.name == "limit" })?.isRequired == false)
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
    #expect(
      ToolExecutorRegistry.readOnly.definitions == [
        .readFile,
        .showFile,
        .listFiles,
        .globFiles,
        .searchFiles,
        .workspaceDiff,
        .workspaceDiagnostics,
      ])
  }

  @Test
  func chatWebRegistryContainsOnlyWebTools() {
    #expect(
      ToolExecutorRegistry.chatWeb.definitions == [
        .webSearch,
        .webFetch,
      ])
    #expect(!ToolExecutorRegistry.chatWeb.definitions.map(\.name).contains(.readFile))
    #expect(!ToolExecutorRegistry.chatWeb.definitions.map(\.name).contains(.writeFile))
    #expect(!ToolExecutorRegistry.chatWeb.definitions.map(\.name).contains(.runCommand))
    #expect(!ToolExecutorRegistry.chatWeb.definitions.map(\.name).contains(.askUser))
  }

  @Test
  func runCommandDefinitionIsAvailableOnlyInCodingAgentRegistry() {
    let definition = ToolDefinition.runCommand

    #expect(definition.name == .runCommand)
    #expect(definition.parameters.map(\.name) == ["command", "timeoutSeconds", "reason"])
    #expect(definition.parameters.first { $0.name == "timeoutSeconds" }?.minimum == 1)
    #expect(definition.parameters.first { $0.name == "timeoutSeconds" }?.maximum == 120)
    #expect(definition.capabilities == [.runCommand])
    #expect(definition.riskLevel == .high)
    #expect(!ToolExecutorRegistry.readOnly.definitions.map(\.name).contains(.runCommand))
    #expect(ToolExecutorRegistry.codingAgent.definitions.map(\.name).contains(.runCommand))
  }

  @Test
  func browserToolsAreAvailableOnlyInCodingAgentRegistry() async throws {
    let workspace = try makeWorkspace()
    let refresh = await BrowserRefreshToolExecutor().run(
      BrowserRefreshInput(hard: true),
      context: ToolContext(workspace: workspace)
    )
    let inspect = await BrowserInspectToolExecutor().run(
      BrowserInspectInput(selector: nil, maxLength: nil, includeHTML: nil),
      context: ToolContext(workspace: workspace)
    )

    #expect(!ToolExecutorRegistry.readOnly.definitions.map(\.name).contains(.browserRefresh))
    #expect(!ToolExecutorRegistry.readOnly.definitions.map(\.name).contains(.browserInspect))
    #expect(ToolExecutorRegistry.codingAgent.definitions.map(\.name).contains(.browserRefresh))
    #expect(ToolExecutorRegistry.codingAgent.definitions.map(\.name).contains(.browserInspect))
    #expect(refresh.status == .failed)
    #expect(inspect.status == .failed)
    #expect(refresh.text.contains("/preview <path-to-html-file>"))
    #expect(inspect.text.contains("/preview <path-to-html-file>"))
  }

  @Test
  func todoWriteDefinitionIsAvailableOnlyInCodingAgentRegistry() async throws {
    let definition = ToolDefinition.todoWrite
    let workspace = try makeWorkspace()
    let input = TodoWriteInput(items: [
      TodoItem(id: "inspect", content: "Inspect affected files", status: .completed),
      TodoItem(id: "core", content: "Add todo state", status: .pending),
    ])

    let result = await TodoWriteToolExecutor().run(
      input, context: ToolContext(workspace: workspace))

    #expect(definition.name == .todoWrite)
    #expect(
      definition.parameters.map(\.name)
        == [
          "item1", "item2", "item3", "item4", "item5", "item6",
          "done1", "done2", "done3", "done4", "done5", "done6",
        ])
    #expect(definition.parameters.first { $0.name == "item1" }?.isRequired == true)
    #expect(definition.parameters.first { $0.name == "item3" }?.isRequired == false)
    #expect(definition.parameters.first { $0.name == "done1" }?.valueType == .boolean)
    #expect(definition.capabilities.isEmpty)
    #expect(definition.riskLevel == .low)
    #expect(!ToolExecutorRegistry.readOnly.definitions.map(\.name).contains(.todoWrite))
    #expect(ToolExecutorRegistry.codingAgent.definitions.map(\.name).contains(.todoWrite))
    #expect(result.preview.text == "Plan updated.")
    guard case .todoWrite(.success) = result else {
      Issue.record("Expected todo_write success payload.")
      return
    }
  }

  @Test
  func todoWriteRejectsStatusesOutsideNumberedDoneContract() async throws {
    let workspace = try makeWorkspace()
    let input = TodoWriteInput(items: [
      TodoItem(id: "inspect", content: "Inspect affected files", status: .completed),
      TodoItem(id: "core", content: "Add todo state", status: .inProgress),
    ])

    let result = await TodoWriteToolExecutor().run(
      input,
      context: ToolContext(workspace: workspace)
    )

    guard case .todoWrite(.failed(let reason)) = result else {
      Issue.record("Expected todo_write unsupported status failure.")
      return
    }
    #expect(reason.message.contains("status must be pending or completed"))
  }

  @Test
  func codingAgentRegistryCanDisableTodoWrite() {
    let enabledDefinitions = ToolExecutorRegistry.codingAgentRegistry(todoWriteEnabled: true)
      .definitions
    let disabledDefinitions = ToolExecutorRegistry.codingAgentRegistry(todoWriteEnabled: false)
      .definitions

    #expect(enabledDefinitions.map(\.name).contains(.todoWrite))
    #expect(!disabledDefinitions.map(\.name).contains(.todoWrite))
    #expect(
      disabledDefinitions == [
        .readFile,
        .showFile,
        .listFiles,
        .globFiles,
        .searchFiles,
        .workspaceDiff,
        .workspaceDiagnostics,
        .browserRefresh,
        .browserInspect,
        .editFile,
        .writeFile,
        .runCommand,
        .askUser,
        .webSearch,
        .webFetch,
      ])
  }

  @Test
  func workspaceDiffReturnsCleanWorkspaceMessage() async throws {
    let workspace = try makeWorkspace()
    try initializeGitRepository(in: workspace)

    let result = await WorkspaceDiffToolExecutor().run(
      WorkspaceDiffInput(),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(result.text == "No workspace changes.")
    #expect(result.truncated == false)
    #expect(result.affectedPaths == ["."])
  }

  @Test
  func gitPathEnvironmentPrependsConfiguredDirectories() throws {
    let binDirectory = try makeTemporaryDirectory()
    let existingDirectory = try makeTemporaryDirectory()

    let path = GitPathEnvironment(
      environment: ["PATH": existingDirectory.path(percentEncoded: false)],
      prefixDirectories: [binDirectory]
    ).resolvedPath()

    #expect(
      path
        == [
          binDirectory.path(percentEncoded: false),
          existingDirectory.path(percentEncoded: false),
        ].joined(separator: ":"))
  }

  @Test
  func gitPathEnvironmentDeduplicatesConfiguredDirectories() throws {
    let binDirectory = try makeTemporaryDirectory()

    let path = GitPathEnvironment(
      environment: ["PATH": binDirectory.path(percentEncoded: false)],
      prefixDirectories: [binDirectory]
    ).resolvedPath()

    #expect(path == binDirectory.path(percentEncoded: false))
  }

  @Test
  func workspaceDiffExplainsXcrunSandboxFailure() async throws {
    let binDirectory = try makeTemporaryDirectory()
    _ = try writeExecutable(
      "git",
      content: """
        #!/bin/sh
        echo "xcrun: error: cannot be used within an App Sandbox." >&2
        exit 1

        """,
      in: binDirectory
    )
    let workspace = try makeWorkspace()

    let result = await WorkspaceDiffToolExecutor(
      directGitExecutableURLs: [],
      gitEnvironment: ["PATH": binDirectory.path(percentEncoded: false)],
      gitPathPrefixDirectories: []
    ).run(
      WorkspaceDiffInput(),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .failed)
    #expect(result.text.contains("invokes xcrun"))
    #expect(result.text.contains("App Sandbox"))
    #expect(result.text.contains("app PATH"))
  }

  @Test
  func workspaceDiffCanUseDirectGitExecutableBeforePathGit() async throws {
    let directGitDirectory = try makeTemporaryDirectory()
    let pathGitDirectory = try makeTemporaryDirectory()
    let markerPath = "direct git was used"
    let directGitURL = try writeExecutable(
      "git",
      content: """
        #!/bin/sh
        echo "\(markerPath)"
        exit 1

        """,
      in: directGitDirectory
    )
    _ = try writeExecutable(
      "git",
      content: """
        #!/bin/sh
        echo "path git was used"
        exit 1

        """,
      in: pathGitDirectory
    )
    let workspace = try makeWorkspace()

    let result = await WorkspaceDiffToolExecutor(
      directGitExecutableURLs: [directGitURL],
      gitEnvironment: ["PATH": pathGitDirectory.path(percentEncoded: false)],
      gitPathPrefixDirectories: []
    ).run(
      WorkspaceDiffInput(),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .failed)
    #expect(result.text.contains(markerPath))
    #expect(!result.text.contains("path git was used"))
  }

  @Test
  func workspaceDiffShowsTrackedModifications() async throws {
    let workspace = try makeWorkspace()
    try write("old\n", to: "README.md", in: workspace)
    try initializeGitRepository(in: workspace, trackedPaths: ["README.md"])
    try write("new\n", to: "README.md", in: workspace)

    let result = await WorkspaceDiffToolExecutor().run(
      WorkspaceDiffInput(),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(result.text.contains("Status:\nModified:\n  README.md"))
    #expect(result.text.contains("Diff stat:"))
    #expect(result.text.contains("README.md"))
    #expect(result.text.contains("Diff:\n"))
    #expect(result.text.contains("-old"))
    #expect(result.text.contains("+new"))
  }

  @Test
  func workspaceDiffScopesOptionalPath() async throws {
    let workspace = try makeWorkspace()
    try write("old app\n", to: "Sources/App.swift", in: workspace)
    try write("old readme\n", to: "README.md", in: workspace)
    try initializeGitRepository(in: workspace, trackedPaths: ["Sources/App.swift", "README.md"])
    try write("new app\n", to: "Sources/App.swift", in: workspace)
    try write("new readme\n", to: "README.md", in: workspace)

    let result = await WorkspaceDiffToolExecutor().run(
      WorkspaceDiffInput(path: "Sources/App.swift"),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(result.text.contains("Sources/App.swift"))
    #expect(result.text.contains("+new app"))
    #expect(!result.text.contains("README.md"))
    #expect(!result.text.contains("+new readme"))
    #expect(result.affectedPaths == ["Sources/App.swift"])
  }

  @Test
  func workspaceDiffShowsUntrackedStatusWithoutContents() async throws {
    let workspace = try makeWorkspace()
    try initializeGitRepository(in: workspace)
    try write("secret untracked content\n", to: "notes.txt", in: workspace)

    let result = await WorkspaceDiffToolExecutor().run(
      WorkspaceDiffInput(),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(result.text.contains("Status:\nUntracked:\n  notes.txt"))
    #expect(!result.text.contains("?? notes.txt"))
    #expect(!result.text.contains("secret untracked content"))
    #expect(!result.text.contains("Diff:\n"))
  }

  @Test
  func workspaceDiffFailsClearlyOutsideGitRepository() async throws {
    let workspace = try makeWorkspace()

    let result = await WorkspaceDiffToolExecutor().run(
      WorkspaceDiffInput(),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .failed)
    #expect(result.text.contains("This workspace is not inside a Git repository."))
  }

  @Test
  func workspaceDiffCapsLargeOutput() async throws {
    let workspace = try makeWorkspace()
    try write("old\n", to: "large.txt", in: workspace)
    try initializeGitRepository(in: workspace, trackedPaths: ["large.txt"])
    try write(String(repeating: "new line\n", count: 80), to: "large.txt", in: workspace)

    let result = await WorkspaceDiffToolExecutor(maxBytes: 220).run(
      WorkspaceDiffInput(),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(result.truncated)
    #expect(result.text.contains("[workspace_diff output truncated]"))
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
    #expect(
      evaluation.workspaceRelativePaths == [
        WorkspaceRelativePath(rawValue: "Sources/App.swift")
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
    #expect(
      result.evaluation.normalizedPaths == [
        workspace.rootURL.appending(path: "README.md").path(percentEncoded: false)
      ])
    #expect(
      result.evaluation.workspaceRelativePaths == [WorkspaceRelativePath(rawValue: "README.md")])
    #expect(result.resultPreview == nil)
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "README.md"), encoding: .utf8)
        == "old")
  }

  @Test
  func orchestratorRunsApprovedWriteFileAfterRevalidatingPermission() async throws {
    let workspace = try makeWorkspace()
    let registry = ToolExecutorRegistry.codingAgent

    let result = await ToolOrchestrator(executorRegistry: registry).executeApproved(
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

    #expect(result.status == .completed)
    #expect(result.evaluation.decision == .requiresApproval)
    #expect(result.resultPreview?.status == .success)
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "README.md"), encoding: .utf8)
        == "new")
  }

  @Test
  func approvedWriteFileStillDeniesWorkspaceEscapes() async throws {
    let workspace = try makeWorkspace()
    let registry = ToolExecutorRegistry.codingAgent

    let result = await ToolOrchestrator(executorRegistry: registry).executeApproved(
      request: request(
        .writeFile,
        workspace: workspace,
        arguments: [
          "path": .string("../README.md"),
          "content": .string("new"),
        ]
      ),
      workspace: workspace
    )

    #expect(result.status == .denied)
    #expect(result.evaluation.decision == .denied)
    #expect(result.resultPreview?.status == .denied)
    #expect(result.resultPreview?.affectedPaths.isEmpty == true)
    guard case .failure(let failure) = result.resultPayload else {
      Issue.record("Expected permission-denied failure payload.")
      return
    }
    #expect(failure.path == nil)
  }

  @Test
  func writeFileRunWritesApprovedContent() async throws {
    let workspace = try makeWorkspace()

    let result = await WriteFileToolExecutor().run(
      WriteFileInput(path: "Sources/App.swift", content: "let value = 2"),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(result.affectedPaths == ["Sources/App.swift"])
    guard case .writeFile(.success(let path, let bytesWritten)) = result else {
      Issue.record("Expected write_file success payload.")
      return
    }
    #expect(path.rawValue == "Sources/App.swift")
    #expect(bytesWritten == "let value = 2".utf8.count)
    #expect(
      try String(
        contentsOf: workspace.rootURL.appending(path: "Sources/App.swift"), encoding: .utf8)
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
  func runCommandRequiresApprovalWithoutSpawningProcess() async throws {
    let workspace = try makeWorkspace()
    let runner = SpyCommandProcessRunner()
    let registry = ToolExecutorRegistry([
      AnyToolExecutor(RunCommandToolExecutor(processRunner: runner))
    ])
    let command = "printf 'hello'"

    let result = await ToolOrchestrator(executorRegistry: registry).execute(
      request: request(
        .runCommand,
        workspace: workspace,
        arguments: [
          "command": .string(command),
          "timeoutSeconds": .number(10),
          "reason": .string("Verify command approval preview."),
        ]
      ),
      workspace: workspace
    )

    #expect(result.status == .awaitingApproval)
    #expect(result.evaluation.decision == .requiresApproval)
    #expect(result.resultPreview?.text.contains(command) == true)
    #expect(result.resultPreview?.text.contains("Timeout: 10 seconds") == true)
    #expect(await runner.spawnCount == 0)
    guard case .runCommand(let input) = result.request.payload else {
      Issue.record("Expected run_command typed input.")
      return
    }
    #expect(input.command == command)
  }

  @Test
  func approvedRunCommandSpawnsExactCommandAndStoresLatestResult() async throws {
    let workspace = try makeWorkspace()
    let sessionID = UUID()
    let runner = SpyCommandProcessRunner(
      result: CommandProcessResult(
        exitCode: 0,
        durationMs: 25,
        stdout: "ok\n",
        stderr: ""
      )
    )
    let store = LatestCommandResultStore()
    let registry = ToolExecutorRegistry([
      AnyToolExecutor(RunCommandToolExecutor(processRunner: runner))
    ])
    let command = "printf 'ok\\n'"

    let result = await ToolOrchestrator(
      executorRegistry: registry,
      latestCommandResultStore: store
    ).executeApproved(
      request: request(
        .runCommand,
        workspace: workspace,
        sessionID: sessionID,
        arguments: [
          "command": .string(command),
          "timeoutSeconds": .number(10),
        ]
      ),
      workspace: workspace
    )

    #expect(result.status == .completed)
    #expect(await runner.spawnCount == 1)
    #expect(await runner.lastRequest?.executableURL.path(percentEncoded: false) == "/bin/bash")
    #expect(await runner.lastRequest?.arguments == ["-c", command])
    #expect(await runner.lastRequest?.workingDirectoryURL == workspace.rootURL)
    #expect(
      await runner.lastRequest?.environment["PWD"] == workspace.rootURL.path(percentEncoded: false))
    guard case .runCommand(let payload) = result.resultPayload else {
      Issue.record("Expected run_command result payload.")
      return
    }
    #expect(payload.command == command)
    #expect(payload.exitCode == 0)
    #expect(payload.stdout.text == "ok\n")
    #expect(await store.result(workspaceID: workspace.id, sessionID: sessionID) == payload)
  }

  @Test
  func runCommandNonZeroExitIsStructuredCompletedResult() async throws {
    let workspace = try makeWorkspace()
    let runner = SpyCommandProcessRunner(
      result: CommandProcessResult(
        exitCode: 2,
        durationMs: 30,
        stdout: "",
        stderr: "tests failed\n"
      )
    )
    let registry = ToolExecutorRegistry([
      AnyToolExecutor(RunCommandToolExecutor(processRunner: runner))
    ])

    let result = await ToolOrchestrator(executorRegistry: registry).executeApproved(
      request: request(
        .runCommand,
        workspace: workspace,
        arguments: [
          "command": .string("false"),
          "timeoutSeconds": .number(5),
        ]
      ),
      workspace: workspace
    )

    #expect(result.status == .completed)
    guard case .runCommand(let payload) = result.resultPayload else {
      Issue.record("Expected run_command result payload.")
      return
    }
    #expect(payload.exitCode == 2)
    #expect(payload.stderr.text == "tests failed\n")
    #expect(result.resultPreview?.status == .failed)
    #expect(result.resultPreview?.text.contains("Exit code: 2") == true)
  }

  @Test
  func runCommandRecordsTimeoutCancellationAndOutputLimits() async throws {
    let workspace = try makeWorkspace()
    let runner = SpyCommandProcessRunner(
      result: CommandProcessResult(
        exitCode: nil,
        durationMs: 120_000,
        stdout: "abc🙂def",
        stderr: "cancelled",
        timedOut: true,
        cancelled: true
      )
    )
    let registry = ToolExecutorRegistry([
      AnyToolExecutor(RunCommandToolExecutor(maxOutputBytes: 8, processRunner: runner))
    ])

    let result = await ToolOrchestrator(executorRegistry: registry).executeApproved(
      request: request(
        .runCommand,
        workspace: workspace,
        arguments: [
          "command": .string("sleep 999"),
          "timeoutSeconds": .number(999),
        ]
      ),
      workspace: workspace
    )

    guard case .runCommand(let payload) = result.resultPayload else {
      Issue.record("Expected run_command result payload.")
      return
    }
    #expect(await runner.lastRequest?.timeoutSeconds == 120)
    #expect(payload.timeoutSeconds == 120)
    #expect(payload.timedOut)
    #expect(payload.cancelled)
    #expect(payload.stdout.truncated)
    #expect(payload.outputTruncated)
    #expect(payload.stdout.text.contains("... truncated"))
    #expect(payload.stdoutOmittedChars > 0)
  }

  @Test
  func defaultCommandProcessRunnerReturnsTimeoutResult() async throws {
    let runner = DefaultCommandProcessRunner()
    let startedAt = Date()
    let result = try await runner.run(
      CommandProcessRequest(
        executableURL: URL(filePath: "/bin/bash"),
        arguments: ["-c", "sleep 5"],
        environment: [:],
        workingDirectoryURL: try makeTemporaryDirectory(),
        timeoutSeconds: 1
      )
    )
    let elapsedMs = max(Int(Date().timeIntervalSince(startedAt) * 1000), 0)

    #expect(result.timedOut)
    #expect(!result.cancelled)
    #expect(result.durationMs < 5_000)
    #expect(elapsedMs < 3_000)
  }

  @Test
  func defaultCommandProcessRunnerCapturesOutput() async throws {
    let runner = DefaultCommandProcessRunner()
    let result = try await runner.run(
      CommandProcessRequest(
        executableURL: URL(filePath: "/bin/bash"),
        arguments: ["-c", "printf 'out'; printf 'err' >&2"],
        environment: [:],
        workingDirectoryURL: try makeTemporaryDirectory(),
        timeoutSeconds: 5
      )
    )

    #expect(result.exitCode == 0)
    #expect(result.stdout == "out")
    #expect(result.stderr == "err")
    #expect(!result.timedOut)
    #expect(!result.cancelled)
  }

  @Test
  func defaultCommandProcessRunnerReturnsCancelledResult() async throws {
    let runner = DefaultCommandProcessRunner()
    let task = Task {
      try await runner.run(
        CommandProcessRequest(
          executableURL: URL(filePath: "/bin/bash"),
          arguments: ["-c", "sleep 30"],
          environment: [:],
          workingDirectoryURL: try makeTemporaryDirectory(),
          timeoutSeconds: 120
        )
      )
    }

    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    let result = try await task.value

    #expect(!result.timedOut)
    #expect(result.cancelled)
    #expect(result.durationMs < 5_000)
  }

  @Test
  func runCommandStoresFullOutputBehindOutputRefAndReturnsHeadTailPreview() async throws {
    let workspace = try makeWorkspace()
    let sessionID = UUID()
    let store = LatestCommandResultStore()
    let stdout = String(repeating: "A", count: 20) + "middle" + String(repeating: "Z", count: 20)
    let runner = SpyCommandProcessRunner(
      result: CommandProcessResult(
        exitCode: 1,
        durationMs: 10,
        stdout: stdout,
        stderr: ""
      )
    )
    let registry = ToolExecutorRegistry([
      AnyToolExecutor(
        RunCommandToolExecutor(
          maxOutputBytes: 32,
          outputRefGenerator: { "cmd_test123" },
          processRunner: runner
        ))
    ])

    let result = await ToolOrchestrator(
      executorRegistry: registry,
      latestCommandResultStore: store
    ).executeApproved(
      request: request(
        .runCommand,
        workspace: workspace,
        sessionID: sessionID,
        arguments: [
          "command": .string("make test"),
          "timeoutSeconds": .number(10),
        ]
      ),
      workspace: workspace
    )

    guard case .runCommand(let payload) = result.resultPayload else {
      Issue.record("Expected run_command result payload.")
      return
    }
    #expect(payload.outputRef == "cmd_test123")
    #expect(payload.stdout.truncated)
    #expect(payload.stdout.text.contains("... truncated"))
    #expect(payload.stdout.text.hasPrefix("A"))
    #expect(payload.stdout.text.hasSuffix("Z"))
    #expect(!payload.stdout.text.contains("middle"))
    #expect(payload.stdoutOmittedChars > 0)
    #expect(
      await store.output(outputRef: "cmd_test123", workspaceID: workspace.id, sessionID: sessionID)?
        .stdout == stdout)
  }

  @Test
  func workspaceDiagnosticsParsesGenericDiagnosticsFromStoredCommandOutput() async throws {
    let workspace = try makeWorkspace()
    let sessionID = UUID()
    let store = LatestCommandResultStore()
    let sourceURL = workspace.rootURL.appending(path: "Sources/App.code")
    try FileManager.default.createDirectory(
      at: sourceURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "".write(to: sourceURL, atomically: true, encoding: .utf8)
    let outsideURL = try makeTemporaryDirectory().appending(path: "Other.code")
    let stdout = """
      Sources/App.code:12:4: error: broken value
      noise line
      Sources/App.code:13: warning: unused value
      \(outsideURL.path(percentEncoded: false)):1:1: error: outside
      """
    let stderr = "Sources/App.code:14:2: note: declared here\n"
    await store.record(
      RunCommandResult(
        command: "build",
        timeoutSeconds: 10,
        exitCode: 1,
        durationMs: 10,
        stdout: ToolTextOutput(text: "preview", truncated: true),
        stderr: ToolTextOutput(text: ""),
        outputRef: "cmd_diag"
      ),
      output: CommandOutputRecord(outputRef: "cmd_diag", stdout: stdout, stderr: stderr),
      workspaceID: workspace.id,
      sessionID: sessionID
    )

    let result = await ToolOrchestrator(
      executorRegistry: ToolExecutorRegistry([
        AnyToolExecutor(WorkspaceDiagnosticsToolExecutor())
      ]),
      latestCommandResultStore: store
    ).execute(
      request: request(
        .workspaceDiagnostics,
        workspace: workspace,
        sessionID: sessionID,
        arguments: ["outputRef": .string("cmd_diag")]
      ),
      workspace: workspace
    )

    guard case .workspaceDiagnostics(let payload) = result.resultPayload else {
      Issue.record("Expected workspace_diagnostics result payload.")
      return
    }
    #expect(payload.diagnostics.count == 3)
    #expect(
      payload.diagnostics[0]
        == WorkspaceDiagnostic(
          path: WorkspaceRelativePath(rawValue: "Sources/App.code"),
          line: 12,
          column: 4,
          severity: .error,
          message: "broken value"
        ))
    #expect(payload.diagnostics[1].column == nil)
    #expect(payload.diagnostics[1].severity == .warning)
    #expect(payload.diagnostics[2].severity == .note)
  }

  @Test
  func workspaceDiagnosticsReturnsEmptyResultForNoMatches() async throws {
    let workspace = try makeWorkspace()
    let sessionID = UUID()
    let store = LatestCommandResultStore()
    await store.record(
      RunCommandResult(
        command: "build",
        timeoutSeconds: 10,
        exitCode: 0,
        durationMs: 10,
        stdout: ToolTextOutput(text: "ok"),
        stderr: ToolTextOutput(text: ""),
        outputRef: "cmd_empty"
      ),
      output: CommandOutputRecord(outputRef: "cmd_empty", stdout: "ok", stderr: ""),
      workspaceID: workspace.id,
      sessionID: sessionID
    )

    let result = await ToolOrchestrator(
      executorRegistry: ToolExecutorRegistry([
        AnyToolExecutor(WorkspaceDiagnosticsToolExecutor())
      ]),
      latestCommandResultStore: store
    ).execute(
      request: request(
        .workspaceDiagnostics,
        workspace: workspace,
        sessionID: sessionID,
        arguments: ["outputRef": .string("cmd_empty")]
      ),
      workspace: workspace
    )

    guard case .workspaceDiagnostics(let payload) = result.resultPayload else {
      Issue.record("Expected workspace_diagnostics result payload.")
      return
    }
    #expect(payload.diagnostics.isEmpty)
    #expect(result.resultPreview?.text == "No diagnostics found for cmd_empty.")
  }

  @Test
  func latestCommandResultStorePrunesOldOutputRefs() async throws {
    let workspace = try makeWorkspace()
    let sessionID = UUID()
    let store = LatestCommandResultStore(maxOutputRefsPerSession: 2)

    for index in 1...3 {
      await store.record(
        RunCommandResult(
          command: "cmd \(index)",
          timeoutSeconds: 10,
          exitCode: 0,
          durationMs: 1,
          stdout: ToolTextOutput(text: "preview"),
          stderr: ToolTextOutput(text: ""),
          outputRef: "cmd_\(index)"
        ),
        output: CommandOutputRecord(
          outputRef: "cmd_\(index)", stdout: "stdout \(index)", stderr: ""),
        workspaceID: workspace.id,
        sessionID: sessionID
      )
    }

    #expect(
      await store.output(outputRef: "cmd_1", workspaceID: workspace.id, sessionID: sessionID) == nil
    )
    #expect(
      await store.output(outputRef: "cmd_2", workspaceID: workspace.id, sessionID: sessionID) != nil
    )
    #expect(
      await store.output(outputRef: "cmd_3", workspaceID: workspace.id, sessionID: sessionID) != nil
    )
    #expect(
      await store.result(workspaceID: workspace.id, sessionID: sessionID)?.outputRef == "cmd_3")
  }

  @Test
  func latestCommandResultStorePrunesOutputRefsByByteBudget() async throws {
    let workspace = try makeWorkspace()
    let sessionID = UUID()
    let store = LatestCommandResultStore(maxOutputRefsPerSession: 10, maxOutputBytesPerSession: 30)

    await store.record(
      RunCommandResult(
        command: "first",
        timeoutSeconds: 10,
        exitCode: 0,
        durationMs: 1,
        stdout: ToolTextOutput(text: "preview"),
        stderr: ToolTextOutput(text: ""),
        outputRef: "cmd_1"
      ),
      output: CommandOutputRecord(outputRef: "cmd_1", stdout: "1234567890", stderr: ""),
      workspaceID: workspace.id,
      sessionID: sessionID
    )
    await store.record(
      RunCommandResult(
        command: "second",
        timeoutSeconds: 10,
        exitCode: 0,
        durationMs: 1,
        stdout: ToolTextOutput(text: "preview"),
        stderr: ToolTextOutput(text: ""),
        outputRef: "cmd_2"
      ),
      output: CommandOutputRecord(outputRef: "cmd_2", stdout: "12345678901234567890", stderr: ""),
      workspaceID: workspace.id,
      sessionID: sessionID
    )

    #expect(
      await store.output(outputRef: "cmd_1", workspaceID: workspace.id, sessionID: sessionID) == nil
    )
    #expect(
      await store.output(outputRef: "cmd_2", workspaceID: workspace.id, sessionID: sessionID) != nil
    )
  }

  @Test
  func workspaceDiagnosticsFailsForMissingOutputRefWithoutRunningCommands() async throws {
    let workspace = try makeWorkspace()
    let result = await ToolOrchestrator(
      executorRegistry: ToolExecutorRegistry([
        AnyToolExecutor(WorkspaceDiagnosticsToolExecutor())
      ])
    ).execute(
      request: request(
        .workspaceDiagnostics,
        workspace: workspace,
        arguments: ["outputRef": .string("cmd_missing")]
      ),
      workspace: workspace
    )

    guard case .failure(let failure) = result.resultPayload else {
      Issue.record("Expected missing output ref failure.")
      return
    }
    #expect(result.evaluation.decision == .allowed)
    #expect(failure.message.contains("Command output not found: cmd_missing."))
  }

  @Test
  func runCommandDefaultsMissingTimeoutBeforeApproval() async throws {
    let workspace = try makeWorkspace()
    let registry = ToolExecutorRegistry([
      AnyToolExecutor(RunCommandToolExecutor(processRunner: SpyCommandProcessRunner()))
    ])

    let result = await ToolOrchestrator(executorRegistry: registry).execute(
      request: request(
        .runCommand,
        workspace: workspace,
        arguments: ["command": .string("just test-core")]
      ),
      workspace: workspace
    )

    #expect(result.status == .awaitingApproval)
    #expect(result.resultPreview?.text.contains("Timeout: 120 seconds") == true)
  }

  @Test
  func invalidRunCommandArgumentsFailBeforeApproval() async throws {
    let workspace = try makeWorkspace()
    let registry = ToolExecutorRegistry([
      AnyToolExecutor(RunCommandToolExecutor(processRunner: SpyCommandProcessRunner()))
    ])

    let invalidTimeout = await ToolOrchestrator(executorRegistry: registry).execute(
      request: request(
        .runCommand,
        workspace: workspace,
        arguments: [
          "command": .string("just test-core"),
          "timeoutSeconds": .string("soon"),
        ]
      ),
      workspace: workspace
    )
    let unknownArgument = await ToolOrchestrator(executorRegistry: registry).execute(
      request: request(
        .runCommand,
        workspace: workspace,
        arguments: [
          "command": .string("just test-core"),
          "timeoutSeconds": .number(10),
          "cwd": .string("/tmp"),
        ]
      ),
      workspace: workspace
    )

    #expect(invalidTimeout.status == .failed)
    #expect(
      invalidTimeout.resultPreview?.text.contains("timeoutSeconds must be an integer") == true)
    #expect(unknownArgument.status == .failed)
    #expect(unknownArgument.resultPreview?.text.contains("Unknown argument") == true)
  }

  @Test
  func deniedRunCommandDoesNotOverwriteLatestCommandResult() async throws {
    let workspace = try makeWorkspace()
    let sessionID = UUID()
    let store = LatestCommandResultStore()
    let existing = RunCommandResult(
      command: "just test-core",
      timeoutSeconds: 10,
      exitCode: 0,
      durationMs: 1,
      stdout: ToolTextOutput(text: "ok"),
      stderr: ToolTextOutput(text: "")
    )
    await store.record(existing, workspaceID: workspace.id, sessionID: sessionID)

    _ = await ToolOrchestrator(
      executorRegistry: ToolExecutorRegistry([
        AnyToolExecutor(RunCommandToolExecutor(processRunner: SpyCommandProcessRunner()))
      ]),
      latestCommandResultStore: store
    ).execute(
      request: request(
        .runCommand,
        workspace: workspace,
        sessionID: sessionID,
        arguments: [
          "command": .string("just test"),
          "timeoutSeconds": .number(120),
        ]
      ),
      workspace: workspace
    )

    #expect(await store.result(workspaceID: workspace.id, sessionID: sessionID) == existing)
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
    let invalidOffset = await ToolOrchestrator().execute(
      request: request(
        .readFile,
        workspace: workspace,
        arguments: [
          "path": .string("README.md"),
          "offset": .number(0),
        ]
      ),
      workspace: workspace
    )
    let invalidLimit = await ToolOrchestrator().execute(
      request: request(
        .readFile,
        workspace: workspace,
        arguments: [
          "path": .string("README.md"),
          "limit": .number(0),
        ]
      ),
      workspace: workspace
    )
    let stringPagination = await ToolOrchestrator().execute(
      request: request(
        .readFile,
        workspace: workspace,
        arguments: [
          "path": .string("README.md"),
          "offset": .string("1"),
          "limit": .string("1"),
        ]
      ),
      workspace: workspace
    )
    let invalidStringLimit = await ToolOrchestrator().execute(
      request: request(
        .readFile,
        workspace: workspace,
        arguments: [
          "path": .string("README.md"),
          "limit": .string("many"),
        ]
      ),
      workspace: workspace
    )

    #expect(valid.status == .completed)
    #expect(missingPath.status == .failed)
    #expect(missingPath.resultPreview?.text.contains("Missing required argument: path") == true)
    #expect(wrongPathType.status == .failed)
    #expect(wrongPathType.resultPreview?.text.contains("Invalid argument type for path") == true)
    #expect(unknownArgument.status == .failed)
    #expect(unknownArgument.resultPreview?.text.contains("Unknown argument") == true)
    #expect(invalidOffset.status == .failed)
    #expect(invalidOffset.resultPreview?.text.contains("offset must be greater") == true)
    #expect(invalidLimit.status == .failed)
    #expect(invalidLimit.resultPreview?.text.contains("limit must be greater") == true)
    #expect(stringPagination.status == .completed)
    #expect(stringPagination.resultPreview?.text == "1: hello")
    #expect(invalidStringLimit.status == .failed)
    #expect(invalidStringLimit.resultPreview?.text.contains("limit must be greater") == true)
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

    let staleRequest = RawToolCallRequest(
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
      result.resultPreview?.text
        == "read_file failed: Permission denied. Tool call workspace does not match the active workspace."
    )
  }

  @Test
  func registryDefinitionsComeFromRegisteredExecutors() {
    let registry = ToolExecutorRegistry.readOnly

    #expect(
      registry.definitions == [
        .readFile, .showFile, .listFiles, .globFiles, .searchFiles, .workspaceDiff,
        .workspaceDiagnostics,
      ])
    #expect(
      registry.toolRegistry.tools == [
        .readFile, .showFile, .listFiles, .globFiles, .searchFiles, .workspaceDiff,
        .workspaceDiagnostics,
      ])
    #expect(
      ToolExecutorRegistry.codingAgent.definitions == [
        .readFile,
        .showFile,
        .listFiles,
        .globFiles,
        .searchFiles,
        .workspaceDiff,
        .workspaceDiagnostics,
        .browserRefresh,
        .browserInspect,
        .editFile,
        .writeFile,
        .runCommand,
        .todoWrite,
        .askUser,
        .webSearch,
        .webFetch,
      ])
  }

  private func request(
    _ toolName: ToolName,
    workspace: Workspace,
    sessionID: ChatSession.ID = UUID(),
    arguments: ToolCallArguments
  ) -> RawToolCallRequest {
    RawToolCallRequest(
      workspaceID: workspace.id,
      sessionID: sessionID,
      toolName: toolName,
      arguments: arguments
    )
  }

  private func makeWorkspace() throws -> Workspace {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "sumika-chat-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return Workspace(
      name: "Project", rootURL: URL(filePath: Workspace.normalizedPath(for: rootURL)))
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "sumika-chat-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func writeExecutable(_ name: String, content: String, in directory: URL) throws -> URL {
    let url = directory.appending(path: name)
    try content.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: url.path(percentEncoded: false)
    )
    return url
  }

  private func initializeGitRepository(
    in workspace: Workspace,
    trackedPaths: [String] = []
  ) throws {
    try runGit(["init"], in: workspace)
    if !trackedPaths.isEmpty {
      try runGit(["add"] + trackedPaths, in: workspace)
      try runGit(
        [
          "-c", "user.name=Sumika Chat Test",
          "-c", "user.email=sumika-chat@example.invalid",
          "commit", "-m", "initial",
        ],
        in: workspace
      )
    }
  }

  private func runGit(_ arguments: [String], in workspace: Workspace) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/git")
    process.arguments =
      ["-c", "core.fsmonitor=false", "-C", workspace.rootURL.path(percentEncoded: false)]
      + arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      let errorText =
        String(
          data: stderr.fileHandleForReading.readDataToEndOfFile(),
          encoding: .utf8
        ) ?? ""
      throw TestGitError(arguments: arguments, errorText: errorText)
    }
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

private struct TestGitError: Error, CustomStringConvertible {
  var arguments: [String]
  var errorText: String

  var description: String {
    "git \(arguments.joined(separator: " ")) failed: \(errorText)"
  }
}

private actor SpyCommandProcessRunner: CommandProcessRunning {
  private(set) var requests: [CommandProcessRequest] = []
  private let result: CommandProcessResult

  init(
    result: CommandProcessResult = CommandProcessResult(
      exitCode: 0,
      durationMs: 1,
      stdout: "",
      stderr: ""
    )
  ) {
    self.result = result
  }

  var spawnCount: Int {
    requests.count
  }

  var lastRequest: CommandProcessRequest? {
    requests.last
  }

  func run(_ request: CommandProcessRequest) async throws -> CommandProcessResult {
    requests.append(request)
    return result
  }
}
