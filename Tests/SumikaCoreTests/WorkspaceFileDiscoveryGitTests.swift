import Foundation
import SumikaTestSupport
import Testing

@testable import SumikaCore

@Suite(TemporaryDirectoryTrait(named: "sumika-workspace-git-discovery-tests"))
struct WorkspaceFileDiscoveryGitTests {
  @Test
  func recursiveDiscoveryRespectsGitIgnoreAndKeepsTrackedFiles() async throws {
    let workspace = try makeWorkspace()
    try initializeGitRepository(in: workspace)
    try write("tracked", to: "Generated/Tracked.swift", in: workspace)
    try write("deleted", to: "Generated/Deleted.swift", in: workspace)
    try runGit(["add", "Generated/Tracked.swift", "Generated/Deleted.swift"], in: workspace)
    try FileManager.default.removeItem(
      at: workspace.rootURL.appending(path: "Generated/Deleted.swift"))
    try write("ignored", to: "Scratch/Ignored.swift", in: workspace)
    try write("visible", to: "Sources/App.swift", in: workspace)
    try write("noise", to: "Sources/.DS_Store", in: workspace)
    try write("Generated/\nScratch/\n", to: ".gitignore", in: workspace)

    let result = await GlobFilesToolExecutor().run(
      GlobFilesInput(pattern: "**/*.swift", path: nil),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(
      result.text.split(separator: "\n").map(String.init) == [
        "Generated/Tracked.swift",
        "Sources/App.swift",
      ])
    #expect(!result.text.contains("Deleted.swift"))
    #expect(!result.text.contains("Scratch"))
    #expect(!result.text.contains(".DS_Store"))
  }

  @Test
  func listFilesHidesIgnoredEntriesButKeepsTrackedAndEmptyEntries() async throws {
    let workspace = try makeWorkspace()
    try initializeGitRepository(in: workspace)
    try write("tracked", to: "tracked.txt", in: workspace)
    try runGit(["add", "tracked.txt"], in: workspace)
    try write("Ignored/\nignored.txt\ntracked.txt\n", to: ".gitignore", in: workspace)
    try write("ignored", to: "ignored.txt", in: workspace)
    try write("ignored", to: "Ignored/nested.txt", in: workspace)
    try write("visible", to: "visible.txt", in: workspace)
    try FileManager.default.createDirectory(
      at: workspace.rootURL.appending(path: "Empty"),
      withIntermediateDirectories: true
    )
    try write("fixed", to: "node_modules/pkg/index.js", in: workspace)

    let result = await ListFilesToolExecutor().run(
      ListFilesInput(path: nil),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(
      result.text.split(separator: "\n").map(String.init) == [
        ".gitignore",
        "Empty/",
        "tracked.txt",
        "visible.txt",
      ])
    #expect(!result.text.contains("Ignored"))
    #expect(!result.text.contains("ignored.txt"))
    #expect(!result.text.contains("node_modules"))
  }

  @Test
  func explicitIgnoredDirectoryBypassesGitIgnore() async throws {
    let workspace = try makeWorkspace()
    try initializeGitRepository(in: workspace)
    try write("Scratch/\n", to: ".gitignore", in: workspace)
    try write("needle", to: "Scratch/note.txt", in: workspace)

    let search = await SearchFilesToolExecutor().run(
      SearchFilesInput(pattern: "needle", path: "Scratch", include: nil),
      context: ToolContext(workspace: workspace)
    )
    let glob = await GlobFilesToolExecutor().run(
      GlobFilesInput(pattern: "**/*.txt", path: "Scratch"),
      context: ToolContext(workspace: workspace)
    )

    #expect(search.text == "Scratch/note.txt:1: needle")
    #expect(glob.text == "Scratch/note.txt")
  }

  @Test
  func nestedWorkspaceUsesParentRepositoryIgnoreRules() async throws {
    let parentWorkspace = try makeWorkspace()
    try initializeGitRepository(in: parentWorkspace)
    try write("Nested/ignored.txt\n", to: ".gitignore", in: parentWorkspace)
    try write("ignored", to: "Nested/ignored.txt", in: parentWorkspace)
    try write("visible", to: "Nested/visible.txt", in: parentWorkspace)
    let nestedWorkspace = Workspace(
      name: "Nested",
      rootURL: parentWorkspace.rootURL.appending(path: "Nested")
    )

    let result = await GlobFilesToolExecutor().run(
      GlobFilesInput(pattern: "**/*.txt", path: nil),
      context: ToolContext(workspace: nestedWorkspace)
    )

    #expect(result.status == .success)
    #expect(result.text == "visible.txt")
  }

  @Test
  func submodulesAreOpaqueUnlessExplicitlySelected() async throws {
    let outerWorkspace = try makeWorkspace()
    let sourceWorkspace = try makeWorkspace()
    try initializeGitRepository(in: outerWorkspace)
    try initializeGitRepository(in: sourceWorkspace)
    try write("inner", to: "Inner.swift", in: sourceWorkspace)
    try runGit(["add", "Inner.swift"], in: sourceWorkspace)
    try commit(in: sourceWorkspace)
    try runGit(
      [
        "-c", "protocol.file.allow=always", "submodule", "add",
        sourceWorkspace.rootURL.path(percentEncoded: false), "Vendor",
      ],
      in: outerWorkspace
    )
    try write("root", to: "Root.swift", in: outerWorkspace)

    let rootGlob = await GlobFilesToolExecutor().run(
      GlobFilesInput(pattern: "**/*.swift", path: nil),
      context: ToolContext(workspace: outerWorkspace)
    )
    let rootList = await ListFilesToolExecutor().run(
      ListFilesInput(path: nil),
      context: ToolContext(workspace: outerWorkspace)
    )
    let submoduleGlob = await GlobFilesToolExecutor().run(
      GlobFilesInput(pattern: "**/*.swift", path: "Vendor"),
      context: ToolContext(workspace: outerWorkspace)
    )

    #expect(rootGlob.text == "Root.swift")
    #expect(rootList.text.contains("Vendor/"))
    #expect(submoduleGlob.text == "Vendor/Inner.swift")
  }

  @Test
  func discoveryKeepsOnlySymlinksWhoseFileTargetIsInsideWorkspace() async throws {
    let workspace = try makeWorkspace()
    try initializeGitRepository(in: workspace)
    try write("inside", to: "target.txt", in: workspace)
    let outsideURL = workspace.rootURL.deletingLastPathComponent()
      .appending(path: UUID().uuidString + ".txt")
    try "outside".write(to: outsideURL, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: workspace.rootURL.appending(path: "inside-link.txt"),
      withDestinationURL: workspace.rootURL.appending(path: "target.txt")
    )
    try FileManager.default.createSymbolicLink(
      at: workspace.rootURL.appending(path: "outside-link.txt"),
      withDestinationURL: outsideURL
    )

    let glob = await GlobFilesToolExecutor().run(
      GlobFilesInput(pattern: "**/*.txt", path: nil),
      context: ToolContext(workspace: workspace)
    )
    let list = await ListFilesToolExecutor().run(
      ListFilesInput(path: nil),
      context: ToolContext(workspace: workspace)
    )

    #expect(
      glob.text.split(separator: "\n").map(String.init) == [
        "inside-link.txt", "target.txt",
      ])
    #expect(!list.text.contains("outside-link.txt"))
  }

  @Test
  func suggestionsUseTheGitAwareInventory() async throws {
    let workspace = try makeWorkspace()
    try initializeGitRepository(in: workspace)
    try write("Ignored/\n", to: ".gitignore", in: workspace)
    try write("ignored", to: "Ignored/page.html", in: workspace)
    try write("visible", to: "Sources/page.html", in: workspace)

    let suggestions = await WorkspacePathSuggestionResolver().suggestions(
      forMissingPath: "page.html",
      workspace: workspace
    )

    #expect(suggestions.map(\.path.rawValue) == ["Sources/page.html"])
  }

  @Test
  func inaccessibleGitMetadataFallsBackToFileManager() async throws {
    let workspace = try makeWorkspace()
    try write("visible", to: "Visible.swift", in: workspace)
    let runner = ScriptedDiscoveryProcessRunner([
      .result(CommandProcessResult(exitCode: 0, durationMs: 1, stdout: "true\n", stderr: "")),
      .result(
        CommandProcessResult(
          exitCode: 128,
          durationMs: 1,
          stdout: "",
          stderr: "fatal: Permission denied"
        )),
    ])
    let discovery = WorkspaceFileDiscovery(
      gitExecutableURL: URL(filePath: "/usr/bin/git"),
      processRunner: runner
    )

    let inventory = try await discovery.recursiveFiles(
      at: workspace.rootURL,
      relativeTo: workspace.rootURL
    )

    #expect(inventory.files.map(\.relativePath) == ["Visible.swift"])
    #expect(!inventory.truncated)
  }

  @Test
  func unexpectedGitIgnoreFailureAfterRepositoryRecognitionIsAnError() async throws {
    let workspace = try makeWorkspace()
    try write("visible", to: "Visible.swift", in: workspace)
    let runner = ScriptedDiscoveryProcessRunner([
      .result(CommandProcessResult(exitCode: 0, durationMs: 1, stdout: "true\n", stderr: ""))
    ])
    let discovery = WorkspaceFileDiscovery(
      gitExecutableURL: URL(filePath: "/usr/bin/git"),
      processRunner: runner
    )

    do {
      _ = try await discovery.recursiveFiles(
        at: workspace.rootURL,
        relativeTo: workspace.rootURL
      )
      Issue.record("Expected an unexpected Git ignore failure to fail discovery.")
    } catch {
      #expect(error.localizedDescription.contains("Git workspace discovery failed"))
      #expect(error.localizedDescription.contains("Unexpected process request"))
    }
  }

  @Test
  func fileManagerFallbackStopsWhenTheCallerHasEnoughFiles() async throws {
    let workspace = try makeWorkspace()
    try write("first", to: "A.swift", in: workspace)
    try write("second", to: "B.swift", in: workspace)
    let discovery = WorkspaceFileDiscovery(gitExecutableURL: nil)
    var visitedPaths: [String] = []

    let truncated = try await discovery.visitRecursiveFiles(
      at: workspace.rootURL,
      relativeTo: workspace.rootURL
    ) { file in
      visitedPaths.append(file.relativePath)
      return false
    }

    #expect(visitedPaths == ["A.swift"])
    #expect(truncated)
  }

  @Test
  func truncatedGitOutputKeepsOnlyCompleteNulTerminatedPaths() async throws {
    let workspace = try makeWorkspace()
    try write("complete", to: "Complete.swift", in: workspace)
    var truncatedOutput = Data("Complete.swift\0Partial-UTF8".utf8)
    truncatedOutput.append(0xC3)
    let runner = ScriptedDiscoveryProcessRunner([
      .result(CommandProcessResult(exitCode: 0, durationMs: 1, stdout: "true\n", stderr: "")),
      .result(CommandProcessResult(exitCode: 1, durationMs: 1, stdout: "", stderr: "")),
      .result(
        CommandProcessResult(
          exitCode: 0,
          durationMs: 1,
          stdout: "",
          stderr: "",
          stdoutData: truncatedOutput,
          stdoutTruncated: true
        )),
    ])
    let discovery = WorkspaceFileDiscovery(
      gitExecutableURL: URL(filePath: "/usr/bin/git"),
      processRunner: runner
    )

    let inventory = try await discovery.recursiveFiles(
      at: workspace.rootURL,
      relativeTo: workspace.rootURL
    )

    #expect(inventory.files.map(\.relativePath) == ["Complete.swift"])
    #expect(inventory.truncated)
  }

  @Test
  func timeoutInRecognizedRepositoryIsAnError() async throws {
    let workspace = try makeWorkspace()
    let runner = ScriptedDiscoveryProcessRunner([
      .result(CommandProcessResult(exitCode: 0, durationMs: 1, stdout: "true\n", stderr: "")),
      .result(CommandProcessResult(exitCode: 1, durationMs: 1, stdout: "", stderr: "")),
      .result(
        CommandProcessResult(
          exitCode: nil,
          durationMs: 5_000,
          stdout: "",
          stderr: "",
          timedOut: true
        )),
    ])
    let discovery = WorkspaceFileDiscovery(
      gitExecutableURL: URL(filePath: "/usr/bin/git"),
      processRunner: runner
    )

    do {
      _ = try await discovery.recursiveFiles(
        at: workspace.rootURL,
        relativeTo: workspace.rootURL
      )
      Issue.record("Expected recognized repository timeout to fail discovery.")
    } catch {
      #expect(error.localizedDescription.contains("timed out"))
    }
  }

  private func makeWorkspace() throws -> Workspace {
    let rootURL = try scopedTemporaryDirectory()
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return Workspace(
      name: "Project",
      rootURL: URL(filePath: Workspace.normalizedPath(for: rootURL))
    )
  }

  private func initializeGitRepository(in workspace: Workspace) throws {
    try runGit(["init", "--quiet"], in: workspace)
  }

  private func commit(in workspace: Workspace) throws {
    try runGit(
      [
        "-c", "user.name=Sumika Test",
        "-c", "user.email=sumika@example.invalid",
        "commit", "--quiet", "-m", "initial",
      ],
      in: workspace
    )
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
      throw DiscoveryTestGitError(arguments: arguments, errorText: errorText)
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

private actor ScriptedDiscoveryProcessRunner: CommandProcessRunning {
  enum Step: Sendable {
    case result(CommandProcessResult)
  }

  private var steps: [Step]

  init(_ steps: [Step]) {
    self.steps = steps
  }

  func run(_ request: CommandProcessRequest) async throws -> CommandProcessResult {
    guard !steps.isEmpty else {
      throw DiscoveryProcessRunnerError.unexpectedRequest(request.arguments)
    }
    switch steps.removeFirst() {
    case .result(let result):
      return result
    }
  }
}

private struct DiscoveryTestGitError: LocalizedError {
  var arguments: [String]
  var errorText: String

  var errorDescription: String? {
    "git \(arguments.joined(separator: " ")) failed: \(errorText)"
  }
}

private enum DiscoveryProcessRunnerError: LocalizedError {
  case unexpectedRequest([String])

  var errorDescription: String? {
    switch self {
    case .unexpectedRequest(let arguments):
      "Unexpected process request: \(arguments.joined(separator: " "))"
    }
  }
}
