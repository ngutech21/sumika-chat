import Foundation
import Testing

@testable import SumikaCore

struct WorkspaceStoreTests {
  @Test
  func workspaceStoreReturnsCleanEmptyLibraryForMissingFile() async throws {
    let missingStore = WorkspaceStore(libraryURL: temporaryLibraryURL())

    let result = await missingStore.loadLibrary()
    #expect(result.library == WorkspaceLibrary())
    #expect(result.issues.isEmpty)
  }

  @Test
  func workspaceStoreMovesCorruptFileAsideAndReportsDecodeFailure() async throws {
    let corruptURL = temporaryLibraryURL()
    try FileManager.default.createDirectory(
      at: corruptURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "not json".write(to: corruptURL, atomically: true, encoding: .utf8)
    let store = WorkspaceStore(libraryURL: corruptURL)

    let result = await store.loadLibrary()

    #expect(result.library == WorkspaceLibrary())
    guard case .decodeFailed(_, let backupPath) = result.issues.first else {
      Issue.record("Expected a decodeFailed issue, got \(result.issues)")
      return
    }
    let backup = try #require(backupPath)
    #expect(backup.contains("workspaces.json.corrupt-"))
    #expect(FileManager.default.fileExists(atPath: backup))
    #expect(!FileManager.default.fileExists(atPath: corruptURL.path(percentEncoded: false)))
    #expect(try String(contentsOfFile: backup, encoding: .utf8) == "not json")
  }

  @Test
  func workspaceStoreKeepsBackupCopyWhenElementsAreDropped() async throws {
    let libraryURL = temporaryLibraryURL()
    let store = WorkspaceStore(libraryURL: libraryURL)
    let intactWorkspace = Workspace(
      name: "Intact",
      rootURL: URL(filePath: "/tmp/intact", directoryHint: .isDirectory)
    )
    try await store.saveLibrary(WorkspaceLibrary(workspaces: [intactWorkspace]))

    // Corrupt one workspace element in place: rootURL is the only required
    // field, so removing it makes exactly that element undecodable.
    var object = try #require(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: libraryURL)
      ) as? [String: Any]
    )
    var workspaces = try #require(object["workspaces"] as? [[String: Any]])
    var broken = workspaces[0]
    broken.removeValue(forKey: "rootURL")
    broken["name"] = "Broken"
    workspaces.append(broken)
    object["workspaces"] = workspaces
    try JSONSerialization.data(withJSONObject: object).write(to: libraryURL)

    let result = await store.loadLibrary()

    #expect(result.library.workspaces.map(\.name) == ["Intact"])
    guard case .droppedElements(let details, let backupPath) = result.issues.first else {
      Issue.record("Expected a droppedElements issue, got \(result.issues)")
      return
    }
    #expect(details.count == 1)
    let backup = try #require(backupPath)
    #expect(backup.contains("workspaces.json.partial-"))
    #expect(FileManager.default.fileExists(atPath: backup))
    // The original file stays in place for the app to keep using.
    #expect(FileManager.default.fileExists(atPath: libraryURL.path(percentEncoded: false)))
  }

  @Test
  func workspaceStoreDropsUndecodableSessionButKeepsSiblings() async throws {
    let libraryURL = temporaryLibraryURL()
    let store = WorkspaceStore(libraryURL: libraryURL)
    let intactSession = ChatSession(title: "Intact", selectedModelID: "gemma4-12b-qat-4bit")
    let workspace = Workspace(
      name: "Project",
      rootURL: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      sessions: [intactSession]
    )
    try await store.saveLibrary(WorkspaceLibrary(workspaces: [workspace]))

    var object = try #require(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: libraryURL)
      ) as? [String: Any]
    )
    var workspaces = try #require(object["workspaces"] as? [[String: Any]])
    var sessions = try #require(workspaces[0]["sessions"] as? [[String: Any]])
    var broken = sessions[0]
    // A present-but-mistyped field must fail only this session.
    broken["interactionMode"] = 42
    broken["title"] = "Broken"
    sessions.append(broken)
    workspaces[0]["sessions"] = sessions
    object["workspaces"] = workspaces
    try JSONSerialization.data(withJSONObject: object).write(to: libraryURL)

    let result = await store.loadLibrary()

    #expect(result.library.workspaces.first?.sessions.map(\.title) == ["Intact"])
    guard case .droppedElements(let details, _) = result.issues.first else {
      Issue.record("Expected a droppedElements issue, got \(result.issues)")
      return
    }
    #expect(details.count == 1)
  }

  @Test
  func workspaceStorePersistsLibraryAndBookmarkData() async throws {
    let libraryURL = temporaryLibraryURL()
    let store = WorkspaceStore(libraryURL: libraryURL)
    let session = ChatSession(
      selectedModelID: "gemma4-12b-qat-4bit",
      turns: [
        ChatTurn(
          status: .completed,
          items: [
            .userMessage(UserTurnMessage(content: "hello")),
            .assistantMessage(AssistantTurnMessage(content: "hi")),
          ])
      ],
      modeSettings: testModeSettings(
        systemPrompt: "Use short answers.",
        generationSettings: ChatGenerationSettings(
          temperature: 0.2,
          topP: 0.8,
          topK: 20,
          maxTokens: 512
        )
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

    let reloaded = await WorkspaceStore(libraryURL: libraryURL).loadLibrary().library
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
    let turn = ChatTurn(
      status: .cancelled,
      modelContextPolicy: .excluded,
      items: [.tool(toolCall)]
    )
    let session = ChatSession(
      id: sessionID,
      selectedModelID: "gemma4-12b-qat-4bit",
      turns: [turn],
      modeSettings: testModeSettings(
        systemPrompt: "Use short answers.",
        generationSettings: .agentDefault
      )
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

    let reloaded = await WorkspaceStore(libraryURL: libraryURL).loadLibrary().library
    let reloadedToolCall = try #require(reloaded.workspaces.first?.sessions.first?.toolCalls.first)
    #expect(reloadedToolCall == toolCall)
    #expect(
      reloadedToolCall.resultPayload
        == .readFile(
          .success(
            path: WorkspaceRelativePath(rawValue: "README.md"),
            content: ToolTextOutput(text: "Preview", truncated: true, redacted: true)
          )))
    #expect(reloadedToolCall.resultPreview?.redacted == true)
    #expect(reloaded.workspaces.first?.sessions.first?.turns == session.turns)
  }

  @Test
  func workspaceStorePersistsFocusedFileState() async throws {
    let libraryURL = temporaryLibraryURL()
    let store = WorkspaceStore(libraryURL: libraryURL)
    let path = WorkspaceRelativePath(rawValue: "Sources/App.swift")
    let focusedFileState = FocusedFileState(
      activePath: path,
      recentPaths: [
        FocusedPath(
          path: path,
          source: .editFile,
          confidence: .active,
          updatedAt: Date(timeIntervalSinceReferenceDate: 2)
        )
      ],
      snapshots: [
        path: FocusedFileSnapshot(
          contentHash: "abc",
          excerpt: "struct App {}",
          fullContentAvailable: true,
          updatedAt: Date(timeIntervalSinceReferenceDate: 3)
        )
      ]
    )
    let session = ChatSession(
      selectedModelID: "gemma4-12b-qat-4bit",
      focusedFileState: focusedFileState,
      modeSettings: testModeSettings(
        systemPrompt: "Use short answers.",
        generationSettings: .agentDefault
      )
    )
    let workspace = Workspace(
      name: "Project",
      rootURL: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      sessions: [session]
    )
    let library = WorkspaceLibrary(workspaces: [workspace])

    try await store.saveLibrary(library)

    let reloaded = await WorkspaceStore(libraryURL: libraryURL).loadLibrary().library
    #expect(reloaded.workspaces.first?.sessions.first?.focusedFileState == focusedFileState)
  }

  @Test
  func workspaceStorePersistsTodoState() async throws {
    let libraryURL = temporaryLibraryURL()
    let store = WorkspaceStore(libraryURL: libraryURL)
    let todoState = TodoState(items: [
      TodoItem(id: "inspect", content: "Inspect files", status: .completed),
      TodoItem(id: "verify", content: "Run tests", status: .inProgress),
    ])
    let session = ChatSession(
      selectedModelID: "gemma4-12b-qat-4bit",
      modeSettings: testModeSettings(
        systemPrompt: "Use short answers.",
        generationSettings: .agentDefault
      ),
      todoState: todoState
    )
    let workspace = Workspace(
      name: "Project",
      rootURL: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      sessions: [session]
    )

    try await store.saveLibrary(WorkspaceLibrary(workspaces: [workspace]))

    let reloaded = await WorkspaceStore(libraryURL: libraryURL).loadLibrary().library
    #expect(reloaded.workspaces.first?.sessions.first?.todoState == todoState)
  }

  @Test
  func chatSessionDecodeDefaultsMissingActiveAttachmentContext() throws {
    let session = ChatSession(selectedModelID: "gemma4-12b-qat-4bit")
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any]
    )
    object.removeValue(forKey: "activeAttachmentContext")
    let data = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(ChatSession.self, from: data)
    #expect(decoded.activeAttachmentContext == .empty)
  }

  @Test
  func chatSessionDecodeDefaultsMissingTodoState() throws {
    let session = ChatSession(selectedModelID: "gemma4-12b-qat-4bit")
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any]
    )
    object.removeValue(forKey: "todoState")
    let data = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(ChatSession.self, from: data)
    #expect(decoded.todoState == nil)
  }

  @Test
  func chatSessionDecodeIgnoresAbsentLegacyModelContextSnapshot() throws {
    let session = ChatSession(
      title: "Current",
      selectedModelID: "gemma4-12b-qat-4bit",
      modeSettings: ChatModeSettingsSet(
        chat: ChatModeSettings(
          systemPrompt: "Chat prompt",
          generationSettings: .chatDefault
        ),
        agent: ChatModeSettings(
          systemPrompt: "Agent prompt",
          generationSettings: .agentDefault
        )
      )
    )
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any]
    )
    object.removeValue(forKey: "modelContextSnapshot")
    let data = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(ChatSession.self, from: data)
    #expect(decoded.title == "Current")
    #expect(decoded.modeSettings == session.modeSettings)
  }

  @Test
  func chatSessionEncodingOmitsPendingAttachmentsTranscriptWrapperAndLegacyModelContextSnapshot()
    throws
  {
    let session = ChatSession(
      selectedModelID: "gemma4-12b-qat-4bit",
      turns: [
        ChatTurn(
          status: .completed,
          items: [.userMessage(UserTurnMessage(content: "hello"))])
      ],
      pendingAttachments: [
        ChatAttachment(
          url: URL(filePath: "/tmp/project/README.md"),
          displayName: "README.md",
          kind: .text,
          content: "draft"
        )
      ],
      modeSettings: testModeSettings(
        systemPrompt: "Use short answers.",
        generationSettings: .agentDefault
      )
    )
    let data = try JSONEncoder().encode(session)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let decoded = try JSONDecoder().decode(ChatSession.self, from: data)

    #expect(object["transcript"] == nil)
    #expect(object["pendingAttachments"] == nil)
    #expect(object["modeSettings"] != nil)
    #expect(object["systemPrompt"] == nil)
    #expect(object["generationSettings"] == nil)
    #expect(object["modelContextSnapshot"] == nil)
    #expect(decoded.pendingAttachments.isEmpty)
    #expect(decoded == session)
  }

  private func temporaryLibraryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "sumika-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
      .appending(path: "workspaces.json", directoryHint: .notDirectory)
  }

  private func makeToolCallRecord(
    workspaceID: Workspace.ID,
    sessionID: ChatSession.ID
  ) -> ToolCallRecord {
    let rawRequest = RawToolCallRequest(
      id: fixedUUID("00000000-0000-0000-0000-000000000001"),
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
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Reading files inside the workspace is allowed.",
        riskLevel: .low,
        normalizedPaths: ["/tmp/project/README.md"]
      ),
      state: .completed(
        .readFile(
          .success(
            path: WorkspaceRelativePath(rawValue: "README.md"),
            content: ToolTextOutput(text: "Preview", truncated: true, redacted: true)
          )))
    )
  }

  private func fixedUUID(_ value: String) -> UUID {
    guard let uuid = UUID(uuidString: value) else {
      preconditionFailure("Invalid test UUID: \(value)")
    }
    return uuid
  }
}
