import Foundation
import SumikaTestSupport
import Testing

@testable import SumikaCore

@Suite(TemporaryDirectoryTrait(named: "sumika-tool-execution-tests"))
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
    guard case .readFile(.page(let page)) = result else {
      Issue.record("Expected read_file page payload.")
      return
    }
    #expect(page.path.rawValue == "Sources/App.swift")
    #expect(page.content == "let value = 1")
    #expect(page.startLine == 1)
    #expect(page.endLine == 1)
    #expect(page.continuation == .endOfFile)
  }

  @Test
  func readFileNumberedContentUsesUnambiguousColonSpaceGutter() throws {
    let content = "| Feature | Effort | Impact |\n: label\n123\n  indented\n"
    let page = try ReadFilePage(
      path: WorkspaceRelativePath(rawValue: "README.md"),
      startLine: 84,
      endLine: 88,
      content: content,
      continuation: .endOfFile
    )

    #expect(page.content == content)
    #expect(
      page.numberedContent
        == [
          "84: | Feature | Effort | Impact |",
          "85: : label",
          "86: 123",
          "87:   indented",
          "88: ",
        ].joined(separator: "\n")
    )
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
    #expect(outside.state.preview?.text.contains("Did you mean one of these?") == false)
  }

  @Test
  func readFileRejectsFirstLineThatCannotFitPage() async throws {
    let workspace = try makeWorkspace()
    let fileURL = workspace.rootURL.appending(path: "large.txt")
    try String(repeating: "a", count: 120).write(to: fileURL, atomically: true, encoding: .utf8)

    let result = await ReadFileToolExecutor(maxBytes: 40).run(
      ReadFileInput(path: "large.txt"),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .failed)
    guard case .readFile(.lineTooLong(let path, let line, let byteCount)) = result else {
      Issue.record("Expected a typed oversized-line result.")
      return
    }
    #expect(path.rawValue == "large.txt")
    #expect(line == 1)
    #expect(byteCount == 120)
  }

  @Test
  func readFileReturnsOnlyCompleteLinesAndSafeNextOffset() async throws {
    let workspace = try makeWorkspace()
    try write("alpha\nbravo", to: "lines.txt", in: workspace)

    let result = await ReadFileToolExecutor(maxBytes: 10).run(
      ReadFileInput(path: "lines.txt"),
      context: ToolContext(workspace: workspace)
    )

    guard case .readFile(.page(let page)) = result else {
      Issue.record("Expected a complete first-line page.")
      return
    }
    #expect(page.content == "alpha")
    #expect(page.numberedContent == "1: alpha")
    #expect(page.continuation == .next(offset: 2, reason: .byteLimit))
  }

  @Test
  func readFilePaginationCountsCompleteColonSpaceGutter() async throws {
    let workspace = try makeWorkspace()
    try write("a\n12345", to: "lines.txt", in: workspace)
    try write("alpha", to: "oversized.txt", in: workspace)

    let paged = await ReadFileToolExecutor(maxBytes: 12).run(
      ReadFileInput(path: "lines.txt"),
      context: ToolContext(workspace: workspace)
    )
    let oversized = await ReadFileToolExecutor(maxBytes: 7).run(
      ReadFileInput(path: "oversized.txt"),
      context: ToolContext(workspace: workspace)
    )

    guard case .readFile(.page(let page)) = paged else {
      Issue.record("Expected a page containing only the complete first rendered line.")
      return
    }
    #expect(page.content == "a")
    #expect(page.numberedContent == "1: a")
    #expect(page.continuation == .next(offset: 2, reason: .byteLimit))
    #expect(
      oversized
        == .readFile(
          .lineTooLong(
            path: WorkspaceRelativePath(rawValue: "oversized.txt"),
            line: 1,
            byteCount: 5
          ))
    )
  }

  @Test
  func readFileDefaultPageUsesFixedSixteenKiBRenderedContentBudget() async throws {
    let workspace = try makeWorkspace()
    let content = (1...1_000)
      .map { "line \($0) \(String(repeating: "x", count: 60))" }
      .joined(separator: "\n")
    try write(content, to: "many-lines.txt", in: workspace)

    let result = await ReadFileToolExecutor().run(
      ReadFileInput(path: "many-lines.txt"),
      context: ToolContext(workspace: workspace)
    )

    guard case .readFile(.page(let page)) = result else {
      Issue.record("Expected a budget-limited page.")
      return
    }
    #expect(page.numberedContent.utf8.count > 6 * 1024)
    #expect(page.numberedContent.utf8.count <= 16 * 1024)
    guard case .next(let offset, .byteLimit) = page.continuation else {
      Issue.record("Expected a safe byte-limit continuation.")
      return
    }
    #expect(offset == (page.endLine ?? 0) + 1)
  }

  @Test
  func readFileDefaultAndRequestedLimitsAreCappedAtFiveHundredLines() async throws {
    let workspace = try makeWorkspace()
    let content = Array(repeating: "x", count: 1_000).joined(separator: "\n")
    try write(content, to: "short-lines.txt", in: workspace)
    let executor = ReadFileToolExecutor()

    let defaultResult = await executor.run(
      ReadFileInput(path: "short-lines.txt"),
      context: ToolContext(workspace: workspace)
    )
    let oversizedRequestResult = await executor.run(
      ReadFileInput(path: "short-lines.txt", limit: 800),
      context: ToolContext(workspace: workspace)
    )

    for result in [defaultResult, oversizedRequestResult] {
      guard case .readFile(.page(let page)) = result else {
        Issue.record("Expected a line-limited read_file page.")
        continue
      }
      #expect(page.returnedLineCount == 500)
      #expect(page.endLine == 500)
      #expect(page.continuation == .next(offset: 501, reason: .lineLimit))
    }
  }

  @Test
  func showFileKeepsItsIndependentLineAndByteBudget() async throws {
    let workspace = try makeWorkspace()
    let content = Array(repeating: "x", count: 600).joined(separator: "\n")
    try write(content, to: "display.txt", in: workspace)

    let result = await ShowFileToolExecutor().run(
      ReadFileInput(path: "display.txt"),
      context: ToolContext(workspace: workspace)
    )

    guard case .readFile(.page(let page)) = result else {
      Issue.record("Expected show_file to return a complete page.")
      return
    }
    #expect(page.returnedLineCount == 600)
    #expect(page.continuation == .endOfFile)
  }

  @Test
  func readFileBlocksAtOversizedLineAfterReturningCompleteLines() async throws {
    let workspace = try makeWorkspace()
    try write("a\n\(String(repeating: "b", count: 50))", to: "mixed.txt", in: workspace)

    let result = await ReadFileToolExecutor(maxBytes: 10).run(
      ReadFileInput(path: "mixed.txt"),
      context: ToolContext(workspace: workspace)
    )

    guard case .readFile(.page(let page)) = result else {
      Issue.record("Expected a page blocked by the second line.")
      return
    }
    #expect(page.content == "a")
    #expect(page.continuation == .blocked(line: 2, byteCount: 50))
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
    guard case .readFile(.page(let page)) = result else {
      Issue.record("Expected a line-limited page.")
      return
    }
    #expect(page.continuation == .next(offset: 4, reason: .lineLimit))
  }

  @Test
  func readFileNormalizesLineEndingsAndDoesNotInventTrailingLine() async throws {
    let workspace = try makeWorkspace()
    try Data("alpha\r\n\r\n".utf8).write(
      to: workspace.rootURL.appending(path: "lines.txt")
    )

    let result = await ReadFileToolExecutor().run(
      ReadFileInput(path: "lines.txt"),
      context: ToolContext(workspace: workspace)
    )

    guard case .readFile(.page(let page)) = result else {
      Issue.record("Expected normalized file page.")
      return
    }
    #expect(page.content == "alpha\n")
    #expect(page.numberedContent == "1: alpha\n2: ")
    #expect(page.endLine == 2)
    #expect(page.continuation == .endOfFile)
  }

  @Test
  func readFileReturnsEmptyFileAndRejectsOffsetPastEnd() async throws {
    let workspace = try makeWorkspace()
    try write("", to: "empty.txt", in: workspace)
    try write("one\ntwo\n", to: "two-lines.txt", in: workspace)

    let empty = await ReadFileToolExecutor().run(
      ReadFileInput(path: "empty.txt"),
      context: ToolContext(workspace: workspace)
    )
    let pastEnd = await ReadFileToolExecutor().run(
      ReadFileInput(path: "two-lines.txt", offset: 3),
      context: ToolContext(workspace: workspace)
    )

    #expect(
      empty
        == .readFile(
          .page(
            try ReadFilePage(
              path: WorkspaceRelativePath(rawValue: "empty.txt"),
              startLine: 1,
              endLine: nil,
              content: "",
              continuation: .endOfFile
            )
          )
        )
    )
    #expect(
      pastEnd
        == .readFile(
          .offsetOutOfRange(
            path: WorkspaceRelativePath(rawValue: "two-lines.txt"),
            requestedOffset: 3,
            lineCount: 2
          )
        )
    )
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

    guard case .readFile(.page(let firstPage)) = first.resultPayload else {
      Issue.record("Expected first read_file to return content.")
      return
    }
    guard case .readFile(.unchanged(let secondPath, let readKey)) = second.resultPayload else {
      Issue.record("Expected second read_file to return unchanged.")
      return
    }

    #expect(firstPage.path.rawValue == "README.md")
    #expect(secondPath.rawValue == "README.md")
    #expect(readKey == ReadKey(path: WorkspaceRelativePath(rawValue: "README.md")))
    #expect(second.state.preview?.text.contains("Use the existing context") == true)
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
    #expect(fourth.state.preview?.text.contains("Repeated read_file loop detected") == true)
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
    guard case .readFile(.page(let page)) = changed.resultPayload else {
      Issue.record("Expected changed file to return fresh content.")
      return
    }

    #expect(page.numberedContent == "1: changed")
  }

  @Test
  func readFileDedupResetsWhenContinuationChanges() async throws {
    let workspace = try makeWorkspace()
    try write("a\nbravo", to: "mixed.txt", in: workspace)
    let registry = ToolExecutorRegistry([
      AnyToolExecutor(ReadFileToolExecutor(maxBytes: 10))
    ])
    let orchestrator = ToolOrchestrator(executorRegistry: registry)
    let request = request(
      .readFile,
      workspace: workspace,
      arguments: ["path": .string("mixed.txt")]
    )

    let first = await orchestrator.execute(request: request, workspace: workspace)
    try write("a\n\(String(repeating: "b", count: 50))", to: "mixed.txt", in: workspace)
    let changed = await orchestrator.execute(request: request, workspace: workspace)

    guard case .readFile(.page(let firstPage)) = first.resultPayload else {
      Issue.record("Expected the initial read_file page.")
      return
    }
    guard case .readFile(.page(let changedPage)) = changed.resultPayload else {
      Issue.record("Expected changed continuation metadata to return a fresh page.")
      return
    }

    #expect(firstPage.numberedContent == changedPage.numberedContent)
    #expect(firstPage.continuation == .next(offset: 2, reason: .byteLimit))
    #expect(changedPage.continuation == .blocked(line: 2, byteCount: 50))
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

    guard case .readFile(.page(let page)) = differentRange.resultPayload else {
      Issue.record("Expected different line range to return fresh content.")
      return
    }
    guard
      case .readFile(.page(let firstRangePage)) =
        firstRangeAfterDifferentRange.resultPayload
    else {
      Issue.record("Expected non-consecutive repeated line range to return fresh content.")
      return
    }
    guard case .readFile(.unchanged(_, let readKey)) = repeatedFirstRange.resultPayload else {
      Issue.record("Expected repeated line range to return unchanged.")
      return
    }

    #expect(page.numberedContent == "2: two")
    #expect(firstRangePage.numberedContent == "1: one")
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

    guard case .readFile(.page(let page)) = repeatedAfterDifferentPath.resultPayload else {
      Issue.record("Expected non-consecutive repeated read_file to return fresh content.")
      return
    }

    #expect(page.numberedContent == "1: a")
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

    guard case .readFile(.page) = first else {
      Issue.record("Expected first direct read_file to return content.")
      return
    }
    guard case .readFile(.page) = second else {
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
  func listFilesSortsSkipsAndTruncatesFlatDefault() async throws {
    let workspace = try makeWorkspace()
    try write("root", to: "zeta.txt", in: workspace)
    try write("root", to: "zzzz.txt", in: workspace)
    try write("root", to: "alpha.txt", in: workspace)
    try write("skip", to: ".DS_Store", in: workspace)
    try write("skip", to: ".git/config", in: workspace)
    try write("skip", to: "node_modules/pkg/index.js", in: workspace)
    try write("nested", to: "Sources/App.swift", in: workspace)

    let result = await ListFilesToolExecutor(maxEntries: 3).run(
      ListFilesInput(path: nil),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(
      result.text.split(separator: "\n").map(String.init) == [
        "alpha.txt", "Sources/", "zeta.txt",
      ])
    #expect(!result.text.contains(".DS_Store"))
    #expect(!result.text.contains(".git/config"))
    #expect(!result.text.contains(".git/"))
    #expect(!result.text.contains("node_modules/pkg/index.js"))
    #expect(!result.text.contains("node_modules/"))
    #expect(!result.text.contains("Sources/App.swift"))
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
    // The unexpanded `a/b/c/` is visible as the `a/b/` entry, so nothing is omitted:
    // a depth-limited listing is complete, not truncated. `truncated` is reserved for
    // the maxEntries cap (exercised by listFilesSortsSkipsAndTruncatesFlatDefault).
    #expect(!result.truncated)
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
    #expect(completed.state.preview?.status == .success)
    #expect(denied.status == .denied)
    #expect(denied.state.preview?.status == .denied)
    #expect(unregisteredWriteFile.status == .failed)
    #expect(unknownExecutor.status == .failed)
    #expect(unknownExecutor.state.preview?.status == .failed)
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
        .finishTask,
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
  func workspaceDiffDefaultsToNestedWorkspaceRoot() async throws {
    let repository = try makeWorkspace()
    try write("old app\n", to: "Sources/App.swift", in: repository)
    try write("old guide\n", to: "docs/Guide.md", in: repository)
    try initializeGitRepository(
      in: repository,
      trackedPaths: ["Sources/App.swift", "docs/Guide.md"]
    )
    try write("new app\n", to: "Sources/App.swift", in: repository)
    try write("new guide\n", to: "docs/Guide.md", in: repository)
    let workspace = Workspace(
      name: "Sources",
      rootURL: repository.rootURL.appending(path: "Sources", directoryHint: .isDirectory)
    )
    let executor = WorkspaceDiffToolExecutor()

    let defaultResult = await executor.run(
      WorkspaceDiffInput(),
      context: ToolContext(workspace: workspace)
    )
    let explicitRootResult = await executor.run(
      WorkspaceDiffInput(path: "."),
      context: ToolContext(workspace: workspace)
    )

    #expect(defaultResult.text == explicitRootResult.text)
    #expect(defaultResult.status == .success)
    #expect(defaultResult.text.contains("Sources/App.swift"))
    #expect(defaultResult.text.contains("+new app"))
    #expect(!defaultResult.text.contains("docs/Guide.md"))
    #expect(!defaultResult.text.contains("+new guide"))
    #expect(defaultResult.affectedPaths == ["."])
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
  func workspaceDiffBoundsEveryCaptureAndReportsCaptureTruncation() async throws {
    let workspace = try makeWorkspace()
    let runner = SpyCommandProcessRunner(
      result: CommandProcessResult(
        exitCode: 0,
        durationMs: 1,
        stdout: " M README.md\n",
        stderr: "",
        stdoutOmittedBytes: 900_000
      )
    )
    let result = await WorkspaceDiffToolExecutor(maxBytes: 120, processRunner: runner).run(
      WorkspaceDiffInput(),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status == .success)
    #expect(result.truncated)
    #expect(result.text.contains("capture truncated; retained output only"))
    #expect(result.text.utf8.count <= 120)
    let requests = await runner.requests
    #expect(requests.count == 3)
    #expect(requests.allSatisfy { $0.maxStdoutBytes == 48 * 1024 })
    #expect(requests.allSatisfy { $0.maxStderrBytes == 8 * 1024 })
    #expect(requests.allSatisfy { $0.stdoutRetention == .prefix && $0.stderrRetention == .prefix })
    #expect(requests.allSatisfy { $0.workingDirectoryURL == workspace.rootURL })
  }

  @Test(arguments: [8, 220])
  func workspaceDiffBoundsFailedOutputIncludingCaptureMarker(maxBytes: Int) async throws {
    let workspace = try makeWorkspace()
    let runner = SpyCommandProcessRunner(
      result: CommandProcessResult(
        exitCode: 1, durationMs: 1, stdout: "",
        stderr: String(repeating: "error detail\n", count: 500),
        stderrOmittedBytes: 900_000
      )
    )
    let result = await WorkspaceDiffToolExecutor(
      maxBytes: maxBytes, processRunner: runner
    ).run(WorkspaceDiffInput(), context: ToolContext(workspace: workspace))

    #expect(result.status == .failed)
    #expect(result.text.utf8.count <= maxBytes)
    #expect(await runner.spawnCount == 1)
    if maxBytes == 220 {
      #expect(result.text.contains("git status exited with status 1"))
      #expect(result.text.contains("capture truncated; retained output only"))
    }
  }

  @Test(arguments: [false, true])
  func workspaceDiffStopsAfterCancelledOrTimedOutStatus(cancelled: Bool) async throws {
    let workspace = try makeWorkspace()
    let runner = SpyCommandProcessRunner(
      result: CommandProcessResult(
        exitCode: nil,
        durationMs: 1,
        stdout: "",
        stderr: "",
        timedOut: !cancelled,
        cancelled: cancelled
      )
    )
    let result = await WorkspaceDiffToolExecutor(processRunner: runner).run(
      WorkspaceDiffInput(),
      context: ToolContext(workspace: workspace)
    )

    #expect(result.status != .success)
    #expect(await runner.spawnCount == 1)
    if !cancelled {
      #expect(result.text.contains("timed out"))
    }
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
    #expect(result.state.preview == nil)
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
    #expect(result.state.preview?.status == .success)
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "README.md"), encoding: .utf8)
        == "new")
  }

  @Test
  func approvedWriteFileRequiresFreshApprovalWhenResolvedTargetChanges() async throws {
    let workspace = try makeWorkspace()
    let firstTarget = workspace.rootURL.appending(path: "first", directoryHint: .isDirectory)
    let secondTarget = workspace.rootURL.appending(path: "second", directoryHint: .isDirectory)
    let link = workspace.rootURL.appending(path: "current")
    try FileManager.default.createDirectory(at: firstTarget, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondTarget, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: firstTarget)
    let orchestrator = ToolOrchestrator(executorRegistry: .codingAgent)
    let pending = await orchestrator.execute(
      request: request(
        .writeFile,
        workspace: workspace,
        arguments: [
          "path": .string("current/value.txt"),
          "content": .string("new"),
        ]
      ),
      workspace: workspace
    )
    #expect(pending.status == .awaitingApproval)

    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secondTarget)
    let revalidated = await orchestrator.executeApproved(
      request: pending.request,
      approvedEvaluation: pending.evaluation,
      workspace: workspace
    )

    #expect(revalidated.status == .awaitingApproval)
    #expect(revalidated.evaluation.normalizedPaths != pending.evaluation.normalizedPaths)
    #expect(!FileManager.default.fileExists(atPath: secondTarget.appending(path: "value.txt").path))
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
    #expect(result.state.preview?.status == .denied)
    #expect(result.state.preview?.affectedPaths.isEmpty == true)
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
    #expect(unknownArgument.state.preview?.text.contains("Unknown argument") == true)
  }

  @Test
  func executorInputExtractionFailureFailsBeforePermissionAndRun() async throws {
    let workspace = try makeWorkspace()
    let registry = ToolExecutorRegistry([
      AnyToolExecutor(MismatchedWriteFileToolExecutor())
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

    #expect(result.status == .failed)
    #expect(result.evaluation.decision == .denied)
    guard case .failure(let failure) = result.resultPayload else {
      Issue.record("Expected failed payload mismatch result.")
      return
    }
    guard case .invalidArguments(.parserError(let message)) = failure.reason else {
      Issue.record("Expected parserError invalid-arguments reason.")
      return
    }
    #expect(message.contains("Tool input extraction failed for write_file."))
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
    #expect(result.state.preview?.text.contains(command) == true)
    #expect(result.state.preview?.text.contains("Timeout: 10 seconds") == true)
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
    #expect(await runner.lastRequest?.maxStdoutBytes == 512 * 1024)
    #expect(await runner.lastRequest?.maxStderrBytes == 512 * 1024)
    #expect(await runner.lastRequest?.stdoutRetention == .headTail)
    #expect(await runner.lastRequest?.stderrRetention == .headTail)
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
    #expect(result.state.preview?.status == .failed)
    #expect(result.state.preview?.text.contains("Exit code: 2") == true)
  }

  @Test(arguments: [false, true])
  func runCommandRecordsTimeoutCancellationAndOutputLimits(cancelled: Bool) async throws {
    let workspace = try makeWorkspace()
    let runner = SpyCommandProcessRunner(
      result: CommandProcessResult(
        exitCode: nil,
        durationMs: 120_000,
        stdout: "abc🙂def",
        stderr: "interrupted",
        timedOut: !cancelled,
        cancelled: cancelled
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
    #expect(payload.timedOut == !cancelled)
    #expect(payload.cancelled == cancelled)
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
        timeoutSeconds: 1,
        maxStdoutBytes: 64 * 1024,
        maxStderrBytes: 64 * 1024
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
        timeoutSeconds: 5,
        maxStdoutBytes: 64 * 1024,
        maxStderrBytes: 64 * 1024
      )
    )

    #expect(result.exitCode == 0)
    #expect(result.stdout == "out")
    #expect(result.stderr == "err")
    #expect(!result.timedOut)
    #expect(!result.cancelled)
  }

  @Test
  func defaultCommandProcessRunnerBoundsOutputAndWritesStandardInput() async throws {
    let runner = DefaultCommandProcessRunner()
    let result = try await runner.run(
      CommandProcessRequest(
        executableURL: URL(filePath: "/bin/bash"),
        arguments: ["-c", "read -r value; printf '%s-abcdefghij' \"$value\""],
        environment: [:],
        workingDirectoryURL: try makeTemporaryDirectory(),
        timeoutSeconds: 5,
        standardInput: Data("input\n".utf8),
        maxStdoutBytes: 8,
        maxStderrBytes: 64 * 1024
      )
    )

    #expect(result.stdout == "input-ab")
    #expect(result.stdoutTruncated)
    #expect(!result.stderrTruncated)
  }

  @Test
  func defaultCommandProcessRunnerPreservesBytesWhenLimitSplitsUTF8() async throws {
    let runner = DefaultCommandProcessRunner()
    let completeRecord = Data("Complete.swift\0".utf8)
    let result = try await runner.run(
      CommandProcessRequest(
        executableURL: URL(filePath: "/bin/bash"),
        arguments: ["-c", "printf 'Complete.swift\\0\\303\\251'"],
        environment: [:],
        workingDirectoryURL: try makeTemporaryDirectory(),
        timeoutSeconds: 5,
        maxStdoutBytes: completeRecord.count + 1,
        maxStderrBytes: 64 * 1024
      )
    )

    var expected = completeRecord
    expected.append(0xC3)
    #expect(result.stdoutData == expected)
    #expect(result.stdoutTruncated)
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
          timeoutSeconds: 120,
          maxStdoutBytes: 64 * 1024,
          maxStderrBytes: 64 * 1024
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
  func commandCaptureLossRemainsVisibleWhenPreviewsFitAndDiagnosticsSearchMisses() async throws {
    let workspace = try makeWorkspace()
    let sessionID = UUID()
    let store = LatestCommandResultStore()
    let runner = SpyCommandProcessRunner(
      result: CommandProcessResult(
        exitCode: 0,
        durationMs: 1,
        stdout: "head\n[... 123 bytes omitted during capture ...]\ntail\n",
        stderr: "error tail\n",
        stdoutOmittedBytes: 123,
        stderrOmittedBytes: 45
      )
    )
    let result = await RunCommandToolExecutor(
      outputRefGenerator: { "cmd_capture" }, processRunner: runner
    ).run(
      RunCommandInput(command: "capture", timeoutSeconds: 10),
      context: ToolContext(
        workspace: workspace,
        sessionID: sessionID,
        latestCommandResultStore: store
      )
    )
    guard case .runCommand(let command) = result else {
      Issue.record("Expected command result.")
      return
    }
    #expect(command.outputRef == "cmd_capture")
    #expect(command.stdoutCaptureOmittedBytes == 123)
    #expect(command.stderrCaptureOmittedBytes == 45)
    #expect(command.stdoutOmittedChars == 0)
    #expect(!command.stdout.truncated)
    #expect(command.outputTruncated)
    #expect(command.previewText.contains("Stdout capture omitted bytes: 123"))
    let retained = await store.output(
      outputRef: "cmd_capture", workspaceID: workspace.id, sessionID: sessionID)
    #expect(retained?.stdoutOmittedBytes == 123)
    #expect(retained?.stderrOmittedBytes == 45)

    let read = await executeWorkspaceDiagnostics(
      arguments: [
        "outputRef": .string("cmd_capture"), "operation": .string("read"),
        "stream": .string("combined"),
      ],
      store: store, workspace: workspace, sessionID: sessionID
    )
    guard case .workspaceDiagnostics(.read(_, .page(let readPage))) = read.resultPayload else {
      Issue.record("Expected retained read page.")
      return
    }
    #expect(readPage.captureOmittedBytes == 168)
    #expect(read.state.preview?.truncated == true)
    #expect(read.state.preview?.text.contains("End of retained output") == true)

    let search = await executeWorkspaceDiagnostics(
      arguments: [
        "outputRef": .string("cmd_capture"), "operation": .string("search"),
        "stream": .string("stdout"), "pattern": .string("missing needle"),
      ],
      store: store, workspace: workspace, sessionID: sessionID
    )
    guard case .workspaceDiagnostics(.search(_, .page(let page))) = search.resultPayload else {
      Issue.record("Expected retained search page.")
      return
    }
    #expect(page.captureOmittedBytes == 123)
    #expect(page.matches.isEmpty)
    #expect(page.continuation == .endOfOutput)
    #expect(search.state.preview?.truncated == true)
    #expect(search.state.preview?.text.contains("Search complete: false") == true)
    #expect(search.state.preview?.text.contains("Retained output search complete: true") == true)
  }

  @Test
  func runCommandDoesNotAdvertiseOutputRefWhenOutputCannotBeRetained() async throws {
    let workspace = try makeWorkspace()
    let sessionID = UUID()
    let store = LatestCommandResultStore(
      maxOutputRefsPerSession: 4,
      maxOutputBytesPerSession: 16
    )
    let runner = SpyCommandProcessRunner(
      result: CommandProcessResult(
        exitCode: 1,
        durationMs: 10,
        stdout: String(repeating: "failure", count: 20),
        stderr: ""
      )
    )
    let executor = RunCommandToolExecutor(
      maxOutputBytes: 8,
      outputRefGenerator: { "cmd_pruned" },
      processRunner: runner
    )

    let record = await ToolOrchestrator(
      executorRegistry: ToolExecutorRegistry([AnyToolExecutor(executor)]),
      latestCommandResultStore: store
    ).executeApproved(
      request: request(
        .runCommand,
        workspace: workspace,
        sessionID: sessionID,
        arguments: ["command": .string("make test")]
      ),
      workspace: workspace
    )

    guard case .runCommand(let payload) = record.resultPayload else {
      Issue.record("Expected run_command result payload.")
      return
    }
    #expect(payload.outputRef == nil)
    #expect(payload.stdout.truncated)
    #expect(!payload.previewText.contains("Output ref:"))
    #expect(!payload.previewText.contains("workspace_diagnostics"))
    #expect(
      await store.output(
        outputRef: "cmd_pruned",
        workspaceID: workspace.id,
        sessionID: sessionID
      ) == nil
    )
    #expect(
      await store.result(workspaceID: workspace.id, sessionID: sessionID)?.outputRef == nil
    )
  }

  @Test
  func workspaceDiagnosticsReadsNumberedOutputAndPreservesBlankLinesAndCRLF() async throws {
    let workspace = try makeWorkspace()
    let sessionID = UUID()
    let store = LatestCommandResultStore()
    await recordCommandOutput(
      outputRef: "cmd_read",
      stdout: "first\r\n\r\nthird\n",
      stderr: "",
      store: store,
      workspace: workspace,
      sessionID: sessionID
    )

    let record = await executeWorkspaceDiagnostics(
      arguments: [
        "outputRef": .string("cmd_read"),
        "operation": .string("read"),
        "stream": .string("stdout"),
      ],
      store: store,
      workspace: workspace,
      sessionID: sessionID
    )

    guard
      case .workspaceDiagnostics(.read(let outputRef, .page(let page))) =
        record.resultPayload
    else {
      Issue.record("Expected workspace_diagnostics read page.")
      return
    }
    #expect(outputRef == "cmd_read")
    #expect(page.startLine == 1)
    #expect(page.endLine == 3)
    #expect(page.lines.map(\.content) == ["first", "", "third"])
    #expect(page.continuation == .endOfOutput)
    #expect(record.state.preview?.text.contains("1: first\n2: \n3: third") == true)
    #expect(record.state.preview?.text.contains("4: ") == false)
  }

  @Test
  func workspaceDiagnosticsCombinedReadUsesStdoutThenStderrWithOriginLines() async throws {
    let workspace = try makeWorkspace()
    let sessionID = UUID()
    let store = LatestCommandResultStore()
    await recordCommandOutput(
      outputRef: "cmd_combined",
      stdout: "out-1\nout-2\n",
      stderr: "err-1\n",
      store: store,
      workspace: workspace,
      sessionID: sessionID
    )

    let record = await executeWorkspaceDiagnostics(
      arguments: [
        "outputRef": .string("cmd_combined"),
        "operation": .string("read"),
        "stream": .string("combined"),
        "offset": .number(2),
        "limit": .number(2),
      ],
      store: store,
      workspace: workspace,
      sessionID: sessionID
    )

    guard case .workspaceDiagnostics(.read(_, .page(let page))) = record.resultPayload else {
      Issue.record("Expected combined workspace_diagnostics read page.")
      return
    }
    #expect(page.lines.map(\.line) == [2, 3])
    #expect(page.lines.map(\.origin) == [.stdout, .stderr])
    #expect(page.lines.map(\.streamLine) == [2, 1])
    #expect(page.lines.map(\.content) == ["out-2", "err-1"])
    #expect(page.continuation == .endOfOutput)
    #expect(record.state.preview?.text.contains("2: [stdout:2] out-2") == true)
    #expect(record.state.preview?.text.contains("3: [stderr:1] err-1") == true)
  }

  @Test
  func workspaceDiagnosticsSearchesNodeFailuresWithMatchContinuation() async throws {
    let workspace = try makeWorkspace()
    let sessionID = UUID()
    let store = LatestCommandResultStore()
    await recordCommandOutput(
      outputRef: "cmd_failures",
      stdout: "36/39 passed, 3 failed\n",
      stderr: [
        "FAIL: countNeighbors: single neighbor, no wrap",
        "FAIL: stepGeneration: birth",
        "FAIL: stepGeneration: still life",
      ].joined(separator: "\n") + "\n",
      store: store,
      workspace: workspace,
      sessionID: sessionID
    )

    let firstRecord = await executeWorkspaceDiagnostics(
      arguments: [
        "outputRef": .string("cmd_failures"),
        "operation": .string("search"),
        "stream": .string("combined"),
        "pattern": .string("^FAIL:"),
        "limit": .number(2),
      ],
      store: store,
      workspace: workspace,
      sessionID: sessionID
    )

    guard
      case .workspaceDiagnostics(.search(_, .page(let firstPage))) =
        firstRecord.resultPayload
    else {
      Issue.record("Expected workspace_diagnostics search page.")
      return
    }
    #expect(firstPage.matches.count == 2)
    #expect(firstPage.matches.map(\.origin) == [.stderr, .stderr])
    #expect(firstPage.matches.map(\.streamLine) == [1, 2])
    #expect(firstPage.matches.map(\.combinedLine) == [2, 3])
    #expect(firstPage.continuation == .next(offset: 4, reason: .matchLimit))
    let firstPreview = try #require(firstRecord.state.preview?.text)
    #expect(firstPreview.contains("Returned matches: 2"))
    #expect(firstPreview.contains("Search complete: false"))
    #expect(firstPreview.contains("Unscanned lines: 4-4"))

    let secondRecord = await executeWorkspaceDiagnostics(
      arguments: [
        "outputRef": .string("cmd_failures"),
        "operation": .string("search"),
        "stream": .string("combined"),
        "pattern": .string("^FAIL:"),
        "offset": .number(4),
        "limit": .number(2),
      ],
      store: store,
      workspace: workspace,
      sessionID: sessionID
    )
    guard
      case .workspaceDiagnostics(.search(_, .page(let secondPage))) =
        secondRecord.resultPayload
    else {
      Issue.record("Expected continued workspace_diagnostics search page.")
      return
    }
    #expect(secondPage.matches.map(\.combinedLine) == [4])
    #expect(secondPage.continuation == .endOfOutput)
    let secondPreview = try #require(secondRecord.state.preview?.text)
    #expect(secondPreview.contains("Returned matches: 1"))
    #expect(secondPreview.contains("Search complete: true"))
    #expect(!secondPreview.contains("Unscanned lines:"))
  }

  @Test
  func workspaceDiagnosticsSearchFallsBackToLiteralForInvalidRegex() async throws {
    let workspace = try makeWorkspace()
    let sessionID = UUID()
    let store = LatestCommandResultStore()
    await recordCommandOutput(
      outputRef: "cmd_literal",
      stdout: "prefix [ broken\nother\n",
      stderr: "",
      store: store,
      workspace: workspace,
      sessionID: sessionID
    )

    let record = await executeWorkspaceDiagnostics(
      arguments: [
        "outputRef": .string("cmd_literal"),
        "operation": .string("search"),
        "stream": .string("stdout"),
        "pattern": .string("["),
      ],
      store: store,
      workspace: workspace,
      sessionID: sessionID
    )
    guard case .workspaceDiagnostics(.search(_, .page(let page))) = record.resultPayload else {
      Issue.record("Expected literal-fallback workspace_diagnostics search page.")
      return
    }
    #expect(page.matches.map(\.snippet) == ["prefix [ broken"])
    #expect(page.continuation == .endOfOutput)
  }

  @Test
  func workspaceDiagnosticsSearchCentersSnippetOnMatchInOverlongLine() async throws {
    let workspace = try makeWorkspace()
    let sessionID = UUID()
    let store = LatestCommandResultStore()
    let line =
      String(repeating: "x", count: 9_000)
      + " NEEDLE failure context "
      + String(repeating: "y", count: 9_000)
    await recordCommandOutput(
      outputRef: "cmd_late_match",
      stdout: line,
      stderr: "",
      store: store,
      workspace: workspace,
      sessionID: sessionID
    )

    let readRecord = await executeWorkspaceDiagnostics(
      arguments: [
        "outputRef": .string("cmd_late_match"),
        "operation": .string("read"),
        "stream": .string("stdout"),
      ],
      store: store,
      workspace: workspace,
      sessionID: sessionID
    )
    guard case .workspaceDiagnostics(.read(_, .lineTooLong)) = readRecord.resultPayload else {
      Issue.record("Expected the overlong line to require search recovery.")
      return
    }

    let searchRecord = await executeWorkspaceDiagnostics(
      arguments: [
        "outputRef": .string("cmd_late_match"),
        "operation": .string("search"),
        "stream": .string("stdout"),
        "pattern": .string("NEEDLE"),
      ],
      store: store,
      workspace: workspace,
      sessionID: sessionID
    )
    guard
      case .workspaceDiagnostics(.search(_, .page(let page))) = searchRecord.resultPayload,
      let match = page.matches.first
    else {
      Issue.record("Expected a workspace_diagnostics search match.")
      return
    }
    #expect(match.snippet.contains("NEEDLE failure context"))
    #expect(match.snippet.hasPrefix("…"))
    #expect(match.snippet.hasSuffix("…"))
    #expect(match.snippet.count <= WorkspaceDiagnosticsLimits.maximumSnippetCharacters)
    #expect(match.snippetTruncated)
  }

  @Test
  func workspaceDiagnosticsDistinguishesEmptyOffsetAndUniformUnavailableOutput() async throws {
    let workspace = try makeWorkspace()
    let sessionID = UUID()
    let store = LatestCommandResultStore()
    await recordCommandOutput(
      outputRef: "cmd_empty",
      stdout: "",
      stderr: "",
      store: store,
      workspace: workspace,
      sessionID: sessionID
    )
    let baseArguments: ToolCallArguments = [
      "outputRef": .string("cmd_empty"),
      "operation": .string("read"),
      "stream": .string("stdout"),
    ]

    let empty = await executeWorkspaceDiagnostics(
      arguments: baseArguments,
      store: store,
      workspace: workspace,
      sessionID: sessionID
    )
    guard case .workspaceDiagnostics(.read(_, .empty(let stream))) = empty.resultPayload else {
      Issue.record("Expected empty command output.")
      return
    }
    #expect(stream == .stdout)

    var pastEndArguments = baseArguments
    pastEndArguments["offset"] = .number(2)
    let pastEnd = await executeWorkspaceDiagnostics(
      arguments: pastEndArguments,
      store: store,
      workspace: workspace,
      sessionID: sessionID
    )
    guard
      case .workspaceDiagnostics(.read(_, .offsetOutOfRange(_, let offset, let count))) =
        pastEnd.resultPayload
    else {
      Issue.record("Expected command output offset-out-of-range result.")
      return
    }
    #expect(offset == 2)
    #expect(count == 0)
    #expect(pastEnd.state.preview?.status == .failed)

    let wrongSession = await executeWorkspaceDiagnostics(
      arguments: baseArguments,
      store: store,
      workspace: workspace,
      sessionID: UUID()
    )
    let missing = await executeWorkspaceDiagnostics(
      arguments: baseArguments,
      store: LatestCommandResultStore(),
      workspace: workspace,
      sessionID: sessionID
    )
    #expect(wrongSession.state.preview?.text == missing.state.preview?.text)
    #expect(wrongSession.state.preview?.text.contains("unknown, expired, pruned") == true)
  }

  @Test
  func workspaceDiagnosticsBlocksOverlongReadLinesWithoutReturningPartialContent() async throws {
    let workspace = try makeWorkspace()
    let sessionID = UUID()
    let store = LatestCommandResultStore()
    await recordCommandOutput(
      outputRef: "cmd_long",
      stdout: "ok\n" + String(repeating: "x", count: 50),
      stderr: "",
      store: store,
      workspace: workspace,
      sessionID: sessionID
    )
    let executor = WorkspaceDiagnosticsToolExecutor(renderedContentBytes: 10)

    let first = await executeWorkspaceDiagnostics(
      arguments: [
        "outputRef": .string("cmd_long"),
        "operation": .string("read"),
        "stream": .string("stdout"),
      ],
      store: store,
      workspace: workspace,
      sessionID: sessionID,
      executor: executor
    )
    guard case .workspaceDiagnostics(.read(_, .page(let page))) = first.resultPayload else {
      Issue.record("Expected read page before overlong line.")
      return
    }
    #expect(page.lines.map(\.content) == ["ok"])
    #expect(page.continuation == .blocked(line: 2, byteCount: 50))

    let blocked = await executeWorkspaceDiagnostics(
      arguments: [
        "outputRef": .string("cmd_long"),
        "operation": .string("read"),
        "stream": .string("stdout"),
        "offset": .number(2),
      ],
      store: store,
      workspace: workspace,
      sessionID: sessionID,
      executor: executor
    )
    guard
      case .workspaceDiagnostics(.read(_, .lineTooLong(_, let line, let byteCount))) =
        blocked.resultPayload
    else {
      Issue.record("Expected overlong-line result.")
      return
    }
    #expect(line == 2)
    #expect(byteCount == 50)
    #expect(blocked.state.preview?.text.contains(String(repeating: "x", count: 10)) == false)
  }

  @Test
  func workspaceDiagnosticsEnforcesDefaultReadSearchAndSnippetBounds() async throws {
    let workspace = try makeWorkspace()
    let sessionID = UUID()
    let store = LatestCommandResultStore()
    let shortLines = (1...600).map { String(format: "output%04d", $0) }.joined(separator: "\n")
    await recordCommandOutput(
      outputRef: "cmd_line_limit",
      stdout: shortLines,
      stderr: "",
      store: store,
      workspace: workspace,
      sessionID: sessionID
    )

    let lineLimited = await executeWorkspaceDiagnostics(
      arguments: [
        "outputRef": .string("cmd_line_limit"),
        "operation": .string("read"),
        "stream": .string("stdout"),
      ],
      store: store,
      workspace: workspace,
      sessionID: sessionID
    )
    guard
      case .workspaceDiagnostics(.read(_, .page(let linePage))) =
        lineLimited.resultPayload
    else {
      Issue.record("Expected default line-limited read page.")
      return
    }
    #expect(linePage.lines.count == 500)
    #expect(linePage.continuation == .next(offset: 501, reason: .lineLimit))

    let wideLines = (1...200).map { _ in String(repeating: "x", count: 100) }
      .joined(separator: "\n")
    await recordCommandOutput(
      outputRef: "cmd_byte_limit",
      stdout: wideLines,
      stderr: "",
      store: store,
      workspace: workspace,
      sessionID: sessionID
    )
    let byteLimited = await executeWorkspaceDiagnostics(
      arguments: [
        "outputRef": .string("cmd_byte_limit"),
        "operation": .string("read"),
        "stream": .string("stdout"),
      ],
      store: store,
      workspace: workspace,
      sessionID: sessionID
    )
    guard case .workspaceDiagnostics(.read(_, .page(let bytePage))) = byteLimited.resultPayload,
      case .next(let nextOffset, .byteLimit) = bytePage.continuation
    else {
      Issue.record("Expected default byte-limited read page.")
      return
    }
    let renderedBody = bytePage.lines
      .map { "\($0.line): \($0.content)" }
      .joined(separator: "\n")
    let nextRenderedLine = "\(nextOffset): " + String(repeating: "x", count: 100)
    #expect(renderedBody.utf8.count <= 8 * 1_024)
    #expect(renderedBody.utf8.count + 1 + nextRenderedLine.utf8.count > 8 * 1_024)

    let searchLines =
      ["needle " + String(repeating: "z", count: 500)]
      + (2...100).map { "needle match \($0)" }
    await recordCommandOutput(
      outputRef: "cmd_search_limits",
      stdout: "",
      stderr: searchLines.joined(separator: "\n"),
      store: store,
      workspace: workspace,
      sessionID: sessionID
    )
    let searchLimited = await executeWorkspaceDiagnostics(
      arguments: [
        "outputRef": .string("cmd_search_limits"),
        "operation": .string("search"),
        "stream": .string("stderr"),
        "pattern": .string("needle"),
      ],
      store: store,
      workspace: workspace,
      sessionID: sessionID
    )
    guard
      case .workspaceDiagnostics(.search(_, .page(let searchPage))) =
        searchLimited.resultPayload
    else {
      Issue.record("Expected default match-limited search page.")
      return
    }
    #expect(searchPage.matches.count == 50)
    #expect(searchPage.matches[0].snippet.count == 240)
    #expect(searchPage.matches[0].snippetTruncated)
    #expect(searchPage.continuation == .next(offset: 51, reason: .matchLimit))
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
    let result = await executeWorkspaceDiagnostics(
      arguments: [
        "outputRef": .string("cmd_missing"),
        "operation": .string("read"),
        "stream": .string("combined"),
      ],
      store: LatestCommandResultStore(),
      workspace: workspace,
      sessionID: UUID()
    )

    guard case .failure(let failure) = result.resultPayload else {
      Issue.record("Expected missing output ref failure.")
      return
    }
    #expect(result.evaluation.decision == .allowed)
    #expect(
      failure.message.contains(
        "Command output is unavailable for this workspace and session: cmd_missing."
      )
    )
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
    #expect(result.state.preview?.text.contains("Timeout: 120 seconds") == true)
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
      invalidTimeout.state.preview?.text.contains("timeoutSeconds must be an integer") == true)
    #expect(unknownArgument.status == .failed)
    #expect(unknownArgument.state.preview?.text.contains("Unknown argument") == true)
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
    #expect(missingPath.state.preview?.text.contains("Missing required argument: path") == true)
    #expect(wrongPathType.status == .failed)
    #expect(wrongPathType.state.preview?.text.contains("Invalid argument type for path") == true)
    #expect(unknownArgument.status == .failed)
    #expect(unknownArgument.state.preview?.text.contains("Unknown argument") == true)
    #expect(invalidOffset.status == .failed)
    #expect(invalidOffset.state.preview?.text.contains("offset must be greater") == true)
    #expect(invalidLimit.status == .failed)
    #expect(invalidLimit.state.preview?.text.contains("limit must be greater") == true)
    #expect(stringPagination.status == .completed)
    #expect(stringPagination.state.preview?.text == "1: hello")
    #expect(invalidStringLimit.status == .failed)
    #expect(invalidStringLimit.state.preview?.text.contains("limit must be greater") == true)
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
    #expect(withoutPath.state.preview?.text.contains("README.md") == true)
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
    #expect(result.state.preview?.status == .denied)
    #expect(
      result.state.preview?.text
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
        .finishTask,
        .webSearch,
        .webFetch,
      ])
  }

  private func recordCommandOutput(
    outputRef: String,
    stdout: String,
    stderr: String,
    store: LatestCommandResultStore,
    workspace: Workspace,
    sessionID: ChatSession.ID
  ) async {
    await store.record(
      RunCommandResult(
        command: "test command",
        timeoutSeconds: 10,
        exitCode: 1,
        durationMs: 10,
        stdout: ToolTextOutput(text: "preview", truncated: true),
        stderr: ToolTextOutput(text: ""),
        outputRef: outputRef
      ),
      output: CommandOutputRecord(outputRef: outputRef, stdout: stdout, stderr: stderr),
      workspaceID: workspace.id,
      sessionID: sessionID
    )
  }

  private func executeWorkspaceDiagnostics(
    arguments: ToolCallArguments,
    store: LatestCommandResultStore,
    workspace: Workspace,
    sessionID: ChatSession.ID,
    executor: WorkspaceDiagnosticsToolExecutor = WorkspaceDiagnosticsToolExecutor()
  ) async -> ToolCallRecord {
    await ToolOrchestrator(
      executorRegistry: ToolExecutorRegistry([AnyToolExecutor(executor)]),
      latestCommandResultStore: store
    ).execute(
      request: request(
        .workspaceDiagnostics,
        workspace: workspace,
        sessionID: sessionID,
        arguments: arguments
      ),
      workspace: workspace
    )
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
    let rootURL = try scopedTemporaryDirectory()
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return Workspace(
      name: "Project", rootURL: URL(filePath: Workspace.normalizedPath(for: rootURL)))
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = try scopedTemporaryDirectory()
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
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
          "-c", "user.name=Sumika Test",
          "-c", "user.email=sumika@example.invalid",
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

private struct MismatchedWriteFileToolExecutor: TypedToolExecutor {
  static let codec = ToolCodec<ReadFileInput>(
    definition: ToolDefinition.writeFile,
    decodeArguments: { _ in
      throw ToolInputDecodingError.inputExtractionFailed(
        toolName: ToolDefinition.writeFile.name.rawValue)
    },
    makePayload: ToolCallPayload.readFile,
    extractInput: { _ in
      throw ToolInputDecodingError.inputExtractionFailed(
        toolName: ToolDefinition.writeFile.name.rawValue)
    }
  )

  func evaluatePermission(
    _ input: ReadFileInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    _ = input
    _ = context
    Issue.record("Input extraction failure should fail before permission evaluation.")
    return ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Unexpected permission evaluation.",
      riskLevel: .low
    )
  }

  func run(_ input: ReadFileInput, context: ToolContext) async -> ToolResultPayload {
    _ = input
    _ = context
    Issue.record("Input extraction failure should fail before execution.")
    return .failure(
      ToolFailure(
        toolName: .writeFile,
        path: nil,
        reason: .executionError("Unexpected execution.")
      )
    )
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
