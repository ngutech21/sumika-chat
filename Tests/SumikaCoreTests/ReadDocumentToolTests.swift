import Foundation
import SumikaTestSupport
import Testing

@testable import SumikaCore

@Suite(TemporaryDirectoryTrait(named: "read-document"))
struct ReadDocumentToolTests {
  @Test
  func readsCompleteMarkdownAndPreservesItInHistory() async throws {
    let workspace = try workspace()
    let url = workspace.rootURL.appending(path: "report.pdf")
    try Data("source".utf8).write(to: url)
    let text =
      "BEGIN" + String(repeating: "x", count: 15_990) + "MIDDLE"
      + String(repeating: "y", count: 15_996) + "END"
    #expect(text.count == 32_000)
    let executor = ReadDocumentToolExecutor(converter: DocumentMarkdownConverterStub(text: text))
    let payload = await executor.run(
      .init(path: "report.pdf"), context: ToolContext(workspace: workspace))
    let request = request(workspace: workspace)
    let projection = ToolResultProjector.project(payload: payload, request: request)
    #expect(projection.metadata.nextAllowedActions.isEmpty)
    guard case .documentContent(let content) = projection.display else {
      Issue.record("Expected converted document content")
      return
    }
    #expect(content.markdown == text)
    let entry = try ModelFacingPromptRenderer.toolResultEntry(
      toolResult: .init(callID: request.id, toolName: .readDocument, payload: payload),
      request: request, originalUserRequest: nil,
      policy: .init(modelObservationLimit: .init(maxCharacters: 1, strategy: .head))
    )
    #expect(entry.frozenContent.content.contains(text))
    #expect(!entry.frozenContent.content.contains("[tool observation truncated]"))
    #expect(
      FocusedFileStateReducer().applyingToolResult(payload, request: request, to: .empty) == .empty)
    let focusedPath = WorkspaceRelativePath(rawValue: "notes.txt")
    let focused = FocusedFileState(
      activePath: focusedPath,
      recentPaths: [.init(path: focusedPath, source: .readFile, confidence: .active)],
      snapshots: [
        focusedPath: .init(contentHash: "hash", excerpt: "source text", fullContentAvailable: true)
      ]
    )
    #expect(
      FocusedFileStateReducer().applyingToolResult(payload, request: request, to: focused)
        == focused)
    let record = ToolCallRecord(
      request: request,
      evaluation: executor.evaluatePermission(
        .init(path: "report.pdf"), context: ToolContext(workspace: workspace)),
      state: .completed(payload))
    let session = ChatSession(
      turns: [ChatTurn(status: .completed, items: [.tool(record)])], interactionMode: .agent)
    var persistedWorkspace = workspace
    persistedWorkspace.sessions = [session]
    let library = WorkspaceLibrary(
      workspaces: [persistedWorkspace], activeWorkspaceID: workspace.id, activeSessionID: session.id
    )
    let storage = try scopedTemporaryDirectory().appending(path: "store")
    try await WorkspaceStore(baseURL: storage).saveLibrary(library)
    try Data("changed source".utf8).write(to: url)
    let changedSourceLoad = await WorkspaceStore(baseURL: storage).loadLibrary()
    #expect(changedSourceLoad.issues.isEmpty)
    #expect(
      changedSourceLoad.library.workspaces.first?.sessions.first?.toolCalls.first?.resultPayload
        == payload)
    try FileManager.default.removeItem(at: url)
    let reloaded = await WorkspaceStore(baseURL: storage).loadLibrary()
    #expect(reloaded.issues.isEmpty)
    let restored = try #require(reloaded.library.workspaces.first?.sessions.first)
    #expect(restored.toolCalls.first?.resultPayload == payload)
    let history = ChatModelContextBuilder().transcript(from: restored)
    #expect(history.entries.contains { $0.frozenContent.content.contains(text) })
    let replayed = try #require(history.entries.first { $0.frozenContent.content.contains(text) })
    #expect(replayed.frozenContent == entry.frozenContent)
  }

  @Test(arguments: [
    "/tmp/report.pdf", "file:///tmp/report.pdf", "https://example.com/a.pdf", "../report.pdf",
  ])
  func rejectsUnscopedPaths(path: String) throws {
    let workspace = try workspace()
    let evaluation = ReadDocumentToolExecutor(
      converter: DocumentMarkdownConverterStub(text: "unused")
    )
    .evaluatePermission(.init(path: path), context: ToolContext(workspace: workspace))
    #expect(evaluation.decision == .denied)
  }

  @Test
  func rejectsAbsolutePathsEvenInsideWorkspaceAndRevalidatesSymlinks() async throws {
    let workspace = try workspace()
    let source = workspace.rootURL.appending(path: "report.pdf")
    try Data("source".utf8).write(to: source)
    let executor = ReadDocumentToolExecutor(
      converter: DocumentMarkdownConverterStub(text: "unused"))
    let context = ToolContext(workspace: workspace)
    #expect(
      executor.evaluatePermission(.init(path: source.path), context: context).decision == .denied)
    #expect(
      executor.evaluatePermission(.init(path: "report.pdf"), context: context).decision == .allowed)
    try FileManager.default.removeItem(at: source)
    let outside = try scopedTemporaryDirectory().appending(path: "outside.pdf")
    try Data("outside".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
    let result = await executor.run(.init(path: "report.pdf"), context: context)
    #expect(result == .readDocument(.failed(path: nil, reason: .file(.pathOutsideWorkspace))))
  }

  @Test(arguments: [
    ("", ReadDocumentFailure.emptyContent),
    (" \n\t", .emptyContent),
    (String(repeating: "a", count: 32_001), .contentTooLarge),
    (String(repeating: "\u{301}", count: 131_073), .markdownTooLarge),
  ])
  func rejectsInvalidExtractedContent(text: String, reason: ReadDocumentFailure) async throws {
    let workspace = try workspace()
    try Data("source".utf8).write(to: workspace.rootURL.appending(path: "report.pdf"))
    let result = await ReadDocumentToolExecutor(
      converter: DocumentMarkdownConverterStub(text: text)
    )
    .run(.init(path: "report.pdf"), context: ToolContext(workspace: workspace))
    #expect(result == .readDocument(.failed(path: .init(rawValue: "report.pdf"), reason: reason)))
    #expect(result.preview.text.contains("No document content was returned"))
  }

  @Test
  func unicodeCharacterBudgetIsSeparateFromByteBudget() throws {
    let text = String(repeating: "\u{1F600}", count: 32_000)
    let content = try ReadDocumentContent(path: .init(rawValue: "report.pdf"), markdown: text)
    #expect(content.markdown.utf8.count == 128_000)
    let data = try JSONEncoder().encode(content)
    #expect(try JSONDecoder().decode(ReadDocumentContent.self, from: data) == content)
    let exactBytes = String(
      repeating: "\u{301}", count: DocumentContentPolicy.maximumMarkdownBytes / 2)
    #expect(exactBytes.utf8.count == DocumentContentPolicy.maximumMarkdownBytes)
    #expect(
      try ReadDocumentContent(path: content.path, markdown: exactBytes).markdown == exactBytes)
    let oversized =
      "{\"path\":\"report.pdf\",\"markdown\":\"" + String(repeating: "a", count: 32_001) + "\"}"
    #expect(throws: ReadDocumentFailure.contentTooLarge) {
      try JSONDecoder().decode(ReadDocumentContent.self, from: Data(oversized.utf8))
    }
  }

  @Test
  func acceptsExactSourceLimitAndCanonicalizesPath() async throws {
    let workspace = try workspace()
    let url = workspace.rootURL.appending(path: "report.pdf")
    try Data().write(to: url)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(DocumentContentPolicy.maximumSourceBytes))
    try handle.close()
    try FileManager.default.createSymbolicLink(
      at: workspace.rootURL.appending(path: "alias.pdf"), withDestinationURL: url)
    let result = await ReadDocumentToolExecutor(converter: SourceBoundaryDocumentConverter())
      .run(.init(path: "./alias.pdf"), context: ToolContext(workspace: workspace))
    #expect(
      result
        == .readDocument(
          .success(
            try ReadDocumentContent(path: .init(rawValue: "report.pdf"), markdown: "complete"))))
  }

  @Test
  func fileFailuresDoNotConvertOrReturnPartialContent() async throws {
    let workspace = try workspace()
    let executor = ReadDocumentToolExecutor(
      converter: DocumentMarkdownConverterStub(text: "must not appear"))
    let context = ToolContext(workspace: workspace)
    let missing = await executor.run(.init(path: "missing.pdf"), context: context)
    #expect(
      missing
        == .readDocument(
          .failed(path: nil, reason: .file(.fileNotFound(path: nil, suggestions: [])))))
    let directory = await executor.run(.init(path: "."), context: context)
    #expect(directory == .readDocument(.failed(path: nil, reason: .notRegularFile)))
    try Data("ordinary text".utf8).write(to: workspace.rootURL.appending(path: "file.txt"))
    let unsupported = await executor.run(.init(path: "file.txt"), context: context)
    #expect(unsupported == .readDocument(.failed(path: nil, reason: .unsupportedFormat)))
    let source = workspace.rootURL.appending(path: "report.pdf")
    try Data("document".utf8).write(to: source)
    let unreadable = await ReadDocumentToolExecutor(
      converter: DocumentMarkdownConverterStub(text: "must not appear"),
      sourceSize: { _ in
        throw CocoaError(.fileReadUnknown)
      }
    ).run(.init(path: "report.pdf"), context: context)
    #expect(unreadable == .readDocument(.failed(path: nil, reason: .unreadableFile)))
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: source.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
    }
    let denied = await executor.run(.init(path: "report.pdf"), context: context)
    #expect(denied == .readDocument(.failed(path: nil, reason: .file(.permissionDenied))))
  }

  @Test
  func validatesSourceBeforeConversionAndBoundsGrowingFiles() async throws {
    let workspace = try workspace()
    let url = workspace.rootURL.appending(path: "report.pdf")
    try Data().write(to: url)
    let context = ToolContext(workspace: workspace)
    for (size, expected) in [
      (nil, ReadDocumentFailure.sourceSizeUnavailable),
      (DocumentContentPolicy.maximumSourceBytes + 1, .sourceTooLarge),
    ] {
      let result = await ReadDocumentToolExecutor(
        converter: DocumentMarkdownConverterStub(text: "unused"), sourceSize: { _ in size }
      )
      .run(.init(path: "report.pdf"), context: context)
      #expect(result.preview.status == .failed)
      #expect(result.preview.text == expected.message)
    }
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(DocumentContentPolicy.maximumSourceBytes + 1))
    try handle.close()
    let result = await ReadDocumentToolExecutor(
      converter: DocumentMarkdownConverterStub(text: "unused"), sourceSize: { _ in 0 }
    )
    .run(.init(path: "report.pdf"), context: context)
    #expect(result.preview.text == ReadDocumentFailure.sourceTooLarge.message)
  }

  @Test
  func cancellationAfterNonCooperativeConversionCannotPublishSuccess() async throws {
    let workspace = try workspace()
    try Data("source".utf8).write(to: workspace.rootURL.appending(path: "report.pdf"))
    let converter = DocumentGate()
    let task = Task {
      await ReadDocumentToolExecutor(converter: converter).run(
        .init(path: "report.pdf"), context: ToolContext(workspace: workspace))
    }
    await converter.waitUntilStarted()
    task.cancel()
    await converter.finish()
    let result = await task.value
    #expect(
      result
        == .readDocument(.failed(path: .init(rawValue: "report.pdf"), reason: .file(.cancelled))))
  }

  @Test
  func registryRequiresConverterAndSurvivesAgentRecomposition() throws {
    let converter = DocumentMarkdownConverterStub(text: "body")
    let configuration = AgentToolConfiguration(
      documentMarkdownConverter: converter, todoWriteEnabled: false, mcpExecutorGroups: [])
    let registry = configuration.executorRegistry(selectedMCPServerIDs: [])
    #expect(registry.toolRegistry.definition(for: .readDocument) != nil)
    #expect(ToolExecutorRegistry.chatWeb.toolRegistry.definition(for: .readDocument) == nil)
    #expect(ToolExecutorRegistry.codingAgent.toolRegistry.definition(for: .readDocument) == nil)
  }

  @Test
  func nativeRequestValidatesAndExecutesThroughRegisteredTool() async throws {
    let workspace = try workspace()
    try Data("source bytes".utf8).write(to: workspace.rootURL.appending(path: "report.pdf"))
    let registry = ToolExecutorRegistry.codingAgentRegistry(
      todoWriteEnabled: true,
      documentMarkdownConverter: DocumentMarkdownConverterStub(text: "complete document")
    )
    let raw = RawToolCallRequest(
      workspaceID: workspace.id, sessionID: UUID(), toolName: .readDocument,
      arguments: ["path": .string("report.pdf")])
    let request = ToolCallRequestValidator().validate(raw, registry: registry.toolRegistry)
    #expect(request.payload == .readDocument(.init(path: "report.pdf")))
    let record = await ToolOrchestrator(executorRegistry: registry).execute(
      request: raw, workspace: workspace)
    #expect(record.evaluation.decision == .allowed)
    #expect(
      record.resultPayload
        == .readDocument(
          .success(
            try ReadDocumentContent(
              path: .init(rawValue: "report.pdf"), markdown: "complete document"
            ))))
    let chat = ToolCallRequestValidator().validate(
      raw, registry: ToolExecutorRegistry.chatWeb.toolRegistry)
    guard case .invalid(let input) = chat.payload else {
      Issue.record("Expected read_document to be unavailable in Chat")
      return
    }
    #expect(input.reason == .unavailableToolName("read_document"))
  }

  private func workspace() throws -> Workspace {
    let root = try scopedTemporaryDirectory().appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return Workspace(name: "Documents", rootURL: root)
  }

  private func request(workspace: Workspace) -> ToolCallRequest {
    .validated(
      raw: RawToolCallRequest(
        workspaceID: workspace.id, sessionID: UUID(), toolName: .readDocument,
        arguments: ["path": .string("report.pdf")]),
      payload: .readDocument(.init(path: "report.pdf")))
  }
}

private struct SourceBoundaryDocumentConverter: DocumentMarkdownConverting {
  func markdown(from data: Data) async throws -> String {
    #expect(data.count == DocumentContentPolicy.maximumSourceBytes)
    return "complete"
  }
}

private actor DocumentGate: DocumentMarkdownConverting {
  private var result: CheckedContinuation<String, Never>?
  private var observer: CheckedContinuation<Void, Never>?

  func markdown(from _: Data) async throws -> String {
    await withCheckedContinuation { continuation in
      result = continuation
      observer?.resume()
      observer = nil
    }
  }

  func waitUntilStarted() async {
    if result != nil { return }
    await withCheckedContinuation { observer = $0 }
  }

  func finish() {
    result?.resume(returning: "complete but cancelled")
    result = nil
  }
}
