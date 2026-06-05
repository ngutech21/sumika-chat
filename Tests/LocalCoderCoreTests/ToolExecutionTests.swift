import Foundation
import Testing

@testable import LocalCoderCore

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
    #expect(result.events.map(\.kind).contains(.awaitingApproval))
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
    #expect(result.events.map(\.kind).contains(.approved))
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
      ])
    #expect(
      registry.toolRegistry.tools == [
        .readFile, .showFile, .listFiles, .globFiles, .searchFiles, .workspaceDiff,
      ])
    #expect(
      ToolExecutorRegistry.codingAgent.definitions == [
        .readFile,
        .showFile,
        .listFiles,
        .globFiles,
        .searchFiles,
        .workspaceDiff,
        .editFile,
        .writeFile,
      ])
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
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "local-coder-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return Workspace(
      name: "Project", rootURL: URL(filePath: Workspace.normalizedPath(for: rootURL)))
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "local-coder-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
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
          "-c", "user.name=Local Coder Test",
          "-c", "user.email=local-coder@example.invalid",
          "commit", "-m", "initial",
        ],
        in: workspace
      )
    }
  }

  private func runGit(_ arguments: [String], in workspace: Workspace) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/git")
    process.arguments = ["-C", workspace.rootURL.path(percentEncoded: false)] + arguments
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
