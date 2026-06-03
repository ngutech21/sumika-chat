import Foundation
import Testing

@testable import LocalCoderCore

struct WorkspaceStoreTests {
  @Test
  func workspaceStoreReturnsEmptyLibraryForMissingOrCorruptFile() async throws {
    let missingStore = WorkspaceStore(libraryURL: temporaryLibraryURL())

    #expect(await missingStore.loadLibrary() == WorkspaceLibrary())

    let corruptURL = temporaryLibraryURL()
    try FileManager.default.createDirectory(
      at: corruptURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "not json".write(to: corruptURL, atomically: true, encoding: .utf8)
    let corruptStore = WorkspaceStore(libraryURL: corruptURL)

    #expect(await corruptStore.loadLibrary() == WorkspaceLibrary())
  }

  @Test
  func workspaceStorePersistsLibraryAndBookmarkData() async throws {
    let libraryURL = temporaryLibraryURL()
    let store = WorkspaceStore(libraryURL: libraryURL)
    let session = CodingSession(
      selectedModelID: "gemma3-1b",
      systemPrompt: "Use short answers.",
      generationSettings: ChatGenerationSettings(
        temperature: 0.2,
        topP: 0.8,
        topK: 20,
        maxTokens: 512
      )
    )
    let workspace = Workspace(
      name: "Project",
      rootURL: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      bookmarkData: Data([1, 2, 3]),
      sessions: [session]
    )
    let library = WorkspaceLibrary(
      workspaces: [workspace],
      activeWorkspaceID: workspace.id,
      activeSessionID: session.id
    )

    try await store.saveLibrary(library)

    let reloaded = await WorkspaceStore(libraryURL: libraryURL).loadLibrary()
    #expect(reloaded == library)
    #expect(reloaded.workspaces.first?.bookmarkData == Data([1, 2, 3]))
  }

  @Test
  func workspaceStorePersistsToolCallRecords() async throws {
    let libraryURL = temporaryLibraryURL()
    let store = WorkspaceStore(libraryURL: libraryURL)
    let workspaceID = UUID()
    let sessionID = UUID()
    let toolCall = makeToolCallRecord(workspaceID: workspaceID, sessionID: sessionID)
    let turn = ChatTurnRecord(
      status: .cancelled,
      modelContextPolicy: .excluded,
      toolCallIDs: [toolCall.id]
    )
    let session = CodingSession(
      id: sessionID,
      selectedModelID: "gemma3-1b",
      toolCalls: [toolCall],
      turns: [turn],
      systemPrompt: "Use short answers.",
      generationSettings: .codingDefault
    )
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      sessions: [session]
    )
    let library = WorkspaceLibrary(
      workspaces: [workspace],
      activeWorkspaceID: workspaceID,
      activeSessionID: sessionID
    )

    try await store.saveLibrary(library)

    let reloaded = await WorkspaceStore(libraryURL: libraryURL).loadLibrary()
    let reloadedToolCall = try #require(reloaded.workspaces.first?.sessions.first?.toolCalls.first)
    #expect(reloadedToolCall == toolCall)
    #expect(reloadedToolCall.events.first?.actor == .assistant)
    #expect(
      reloadedToolCall.resultPayload
        == .readFile(
          .success(
            path: WorkspaceRelativePath(rawValue: "README.md"),
            content: ToolTextOutput(text: "Preview", truncated: true, redacted: true)
          )))
    #expect(reloadedToolCall.resultPreview?.redacted == true)
    #expect(reloaded.workspaces.first?.sessions.first?.turns == [turn])
  }

  @Test
  func codingSessionDecodesLegacyJSONWithoutToolCallsOrTurns() throws {
    let legacySession = LegacyCodingSession(
      id: UUID(),
      title: "Legacy",
      selectedModelID: "gemma3-1b",
      messages: [ChatMessage(userContent: "hello")],
      systemPrompt: "Legacy prompt",
      generationSettings: .codingDefault,
      createdAt: Date(),
      updatedAt: Date()
    )
    let data = try JSONEncoder().encode(legacySession)

    let decoded = try JSONDecoder().decode(CodingSession.self, from: data)

    #expect(decoded.id == legacySession.id)
    #expect(decoded.messages == legacySession.messages)
    #expect(decoded.toolCalls.isEmpty)
    #expect(decoded.turns.isEmpty)
  }

  private func temporaryLibraryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "local-coder-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
      .appending(path: "workspaces.json", directoryHint: .notDirectory)
  }

  private func makeToolCallRecord(
    workspaceID: Workspace.ID,
    sessionID: CodingSession.ID
  ) -> ToolCallRecord {
    let rawRequest = RawToolCallRequest(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      workspaceID: workspaceID,
      sessionID: sessionID,
      toolName: .readFile,
      arguments: ["path": .string("README.md")],
      createdAt: Date(timeIntervalSinceReferenceDate: 1)
    )
    let request = ToolCallRequest.validated(
      raw: rawRequest,
      payload: .readFile(ReadFileInput(path: "README.md"))
    )
    return ToolCallRecord(
      request: request,
      status: .awaitingApproval,
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Reading files inside the workspace is allowed.",
        riskLevel: .low,
        normalizedPaths: ["/tmp/project/README.md"]
      ),
      events: [
        ToolCallEvent(
          id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
          timestamp: Date(timeIntervalSinceReferenceDate: 2),
          actor: .assistant,
          kind: .requested,
          message: "Read README.md"
        ),
        ToolCallEvent(
          id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
          timestamp: Date(timeIntervalSinceReferenceDate: 3),
          actor: .user,
          kind: .cancelled,
          message: "Cancelled by user"
        ),
      ],
      resultPayload: .readFile(
        .success(
          path: WorkspaceRelativePath(rawValue: "README.md"),
          content: ToolTextOutput(text: "Preview", truncated: true, redacted: true)
        )),
      resultPreview: ToolResultPreview(
        text: "Preview",
        truncated: true,
        redacted: true,
        affectedPaths: ["/tmp/project/README.md"]
      )
    )
  }
}

private struct LegacyCodingSession: Codable {
  let id: UUID
  let title: String
  let selectedModelID: ManagedModel.ID
  let messages: [ChatMessage]
  let systemPrompt: String
  let generationSettings: ChatGenerationSettings
  let createdAt: Date
  let updatedAt: Date
}
