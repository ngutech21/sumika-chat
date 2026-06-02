import Foundation
import Testing

@testable import local_coder

@MainActor
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
    let session = CodingSession(
      id: sessionID,
      selectedModelID: "gemma3-1b",
      toolCalls: [toolCall],
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
    #expect(reloadedToolCall.resultPreview?.redacted == true)
  }

  @Test
  func codingSessionDecodesLegacyJSONWithoutToolCalls() throws {
    let legacySession = LegacyCodingSession(
      id: UUID(),
      title: "Legacy",
      selectedModelID: "gemma3-1b",
      messages: [ChatMessage(kind: .user, content: "hello")],
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
  }

  @Test
  func appStateAddsWorkspaceWithDefaultSessionAndDeduplicatesByPath() async throws {
    let workspaceURL = try makeTemporaryDirectory()
    let workspaceStore = FakeWorkspaceStore()
    let modelStore = FakeModelSettingsStore()
    modelStore.selectedModelIDValue = "gemma3-1b"
    modelStore.settingsByModelID["gemma3-1b"] = StoredModelSettings(
      systemPrompt: "Tiny model prompt",
      generationSettings: ChatGenerationSettings(
        temperature: 0.1,
        topP: 0.7,
        topK: 10,
        maxTokens: 256
      )
    )
    let appState = AppState(
      workspaceStore: workspaceStore,
      modelSettingsStore: modelStore,
      chatController: ChatSessionController(
        runtime: FakeChatModelRuntime(),
        modelPath: "/tmp/model",
        modelSettingsStore: modelStore
      )
    )
    try await waitUntil { !appState.isWorkspaceLibraryLoading }

    let firstSessionID = appState.addWorkspace(from: workspaceURL)
    let duplicateSessionID = appState.addWorkspace(from: workspaceURL)

    #expect(firstSessionID == duplicateSessionID)
    #expect(appState.workspaceLibrary.workspaces.count == 1)
    #expect(appState.activeWorkspace?.name == workspaceURL.lastPathComponent)
    #expect(appState.activeSession?.title == "New Session")
    #expect(appState.activeSession?.selectedModelID == "gemma3-1b")
    #expect(appState.activeSession?.systemPrompt == "Tiny model prompt")
    #expect(appState.activeSession?.generationSettings.maxTokens == 256)
  }

  @Test
  func appStateCreateSessionInExplicitWorkspaceActivatesAndLoadsNewSession() async throws {
    let firstSession = CodingSession(
      title: "Existing",
      selectedModelID: "gemma3-1b",
      messages: [ChatMessage(kind: .user, content: "existing")],
      systemPrompt: "Existing prompt",
      generationSettings: .codingDefault
    )
    let workspace = Workspace(
      name: "Project",
      rootURL: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      sessions: [firstSession]
    )
    let controller = ChatSessionController(
      runtime: FakeChatModelRuntime(),
      modelPath: "/tmp/model",
      modelSettingsStore: FakeModelSettingsStore()
    )
    let workspaceStore = FakeWorkspaceStore(
      library: WorkspaceLibrary(workspaces: [workspace])
    )
    let appState = AppState(workspaceStore: workspaceStore, chatController: controller)
    try await waitUntil { !appState.isWorkspaceLibraryLoading }

    let newSessionID = try #require(appState.createSession(in: workspace.id))
    try await waitUntil { workspaceStore.savedLibrary?.activeSessionID == newSessionID }

    #expect(appState.workspaceLibrary.activeWorkspaceID == workspace.id)
    #expect(appState.workspaceLibrary.activeSessionID == newSessionID)
    #expect(appState.activeWorkspace?.sessions.map(\.id).contains(newSessionID) == true)
    #expect(controller.chatSession.messages.isEmpty)
    #expect(controller.chatSession.systemPrompt == appState.activeSession?.systemPrompt)
    #expect(workspaceStore.savedLibrary?.activeSessionID == newSessionID)
  }

  @Test
  func appStateCreateSessionReturnsNilWithoutActiveOrRequestedWorkspace() async throws {
    let workspaceStore = FakeWorkspaceStore()
    let appState = AppState(
      workspaceStore: workspaceStore,
      chatController: ChatSessionController(
        runtime: FakeChatModelRuntime(),
        modelPath: "/tmp/model",
        modelSettingsStore: FakeModelSettingsStore()
      )
    )
    try await waitUntil { !appState.isWorkspaceLibraryLoading }

    let sessionID = appState.createSession()

    #expect(sessionID == nil)
    #expect(appState.workspaceLibrary.workspaces.isEmpty)
  }

  @Test
  func appStateInitializationCreatesSessionForActiveWorkspaceWithoutSessions() async throws {
    let workspace = Workspace(
      name: "Empty",
      rootURL: URL(filePath: "/tmp/empty", directoryHint: .isDirectory),
      sessions: []
    )
    let workspaceStore = FakeWorkspaceStore(
      library: WorkspaceLibrary(
        workspaces: [workspace],
        activeWorkspaceID: workspace.id,
        activeSessionID: nil
      )
    )
    let controller = ChatSessionController(
      runtime: FakeChatModelRuntime(),
      modelPath: "/tmp/model",
      modelSettingsStore: FakeModelSettingsStore()
    )

    let appState = AppState(workspaceStore: workspaceStore, chatController: controller)
    try await waitUntil { !appState.isWorkspaceLibraryLoading }
    try await waitUntil {
      workspaceStore.savedLibrary?.activeSessionID == appState.activeSession?.id
    }

    let activeSession = appState.activeSession
    #expect(activeSession != nil)
    #expect(appState.activeWorkspace?.sessions.count == 1)
    #expect(appState.workspaceLibrary.activeSessionID == activeSession?.id)
    #expect(controller.chatSession.systemPrompt == activeSession?.systemPrompt)
    #expect(workspaceStore.savedLibrary?.activeSessionID == activeSession?.id)
  }

  @Test
  func appStateInitializationClearsMissingActiveWorkspaceAndSelectsFirstWorkspace() async throws {
    let firstSession = CodingSession(
      selectedModelID: "gemma3-1b",
      systemPrompt: "Prompt",
      generationSettings: .codingDefault
    )
    let workspace = Workspace(
      name: "Project",
      rootURL: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      sessions: [firstSession]
    )
    let workspaceStore = FakeWorkspaceStore(
      library: WorkspaceLibrary(
        workspaces: [workspace],
        activeWorkspaceID: UUID(),
        activeSessionID: UUID()
      )
    )
    let controller = ChatSessionController(
      runtime: FakeChatModelRuntime(),
      modelPath: "/tmp/model",
      modelSettingsStore: FakeModelSettingsStore()
    )

    let appState = AppState(workspaceStore: workspaceStore, chatController: controller)
    try await waitUntil { !appState.isWorkspaceLibraryLoading }

    #expect(appState.workspaceLibrary.activeWorkspaceID == workspace.id)
    #expect(appState.workspaceLibrary.activeSessionID == firstSession.id)
    #expect(controller.chatSession.systemPrompt == firstSession.systemPrompt)
  }

  @Test
  func appStateSwitchesSessionsAndLoadsChatState() async throws {
    let firstSession = CodingSession(
      title: "First",
      selectedModelID: "gemma3-1b",
      messages: [ChatMessage(kind: .user, content: "first")],
      systemPrompt: "First prompt",
      generationSettings: .codingDefault
    )
    let secondSession = CodingSession(
      title: "Second",
      selectedModelID: "gemma3-4b",
      messages: [ChatMessage(kind: .user, content: "second")],
      systemPrompt: "Second prompt",
      generationSettings: ChatGenerationSettings(
        temperature: 0.4,
        topP: 0.9,
        topK: 30,
        maxTokens: 1024
      )
    )
    let workspace = Workspace(
      name: "Project",
      rootURL: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      sessions: [firstSession, secondSession]
    )
    let library = WorkspaceLibrary(
      workspaces: [workspace],
      activeWorkspaceID: workspace.id,
      activeSessionID: firstSession.id
    )
    let workspaceStore = FakeWorkspaceStore(library: library)
    let controller = ChatSessionController(
      runtime: FakeChatModelRuntime(),
      modelPath: "/tmp/model",
      modelSettingsStore: FakeModelSettingsStore()
    )
    let appState = AppState(workspaceStore: workspaceStore, chatController: controller)
    try await waitUntil { !appState.isWorkspaceLibraryLoading }

    appState.selectSession(secondSession.id)

    #expect(controller.modelRuntime.selectedModelID == "gemma3-4b")
    #expect(controller.chatSession.messages == secondSession.messages)
    #expect(controller.chatSession.systemPrompt == "Second prompt")
    #expect(controller.chatSession.generationSettings.maxTokens == 1024)
  }

  @Test
  func appStateSwitchesSessionsAndLoadsToolCalls() async throws {
    let firstSession = CodingSession(
      title: "First",
      selectedModelID: "gemma3-1b",
      systemPrompt: "First prompt",
      generationSettings: .codingDefault
    )
    let secondSession = CodingSession(
      title: "Second",
      selectedModelID: "gemma3-1b",
      toolCalls: [makeToolCallRecord(workspaceID: UUID(), sessionID: UUID())],
      systemPrompt: "Second prompt",
      generationSettings: .codingDefault
    )
    let workspace = Workspace(
      name: "Project",
      rootURL: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      sessions: [firstSession, secondSession]
    )
    let workspaceStore = FakeWorkspaceStore(
      library: WorkspaceLibrary(
        workspaces: [workspace],
        activeWorkspaceID: workspace.id,
        activeSessionID: firstSession.id
      )
    )
    let controller = ChatSessionController(
      runtime: FakeChatModelRuntime(),
      modelPath: "/tmp/model",
      modelSettingsStore: FakeModelSettingsStore()
    )
    let appState = AppState(workspaceStore: workspaceStore, chatController: controller)
    try await waitUntil { !appState.isWorkspaceLibraryLoading }

    appState.selectSession(secondSession.id)

    #expect(controller.chatSession.toolCalls == secondSession.toolCalls)
  }

  @Test
  func appStateRenamesSessionAndPersistsTitle() async throws {
    let workspaceURL = try makeTemporaryDirectory()
    let workspaceStore = FakeWorkspaceStore()
    let appState = AppState(
      workspaceStore: workspaceStore,
      chatController: ChatSessionController(
        runtime: FakeChatModelRuntime(),
        modelPath: "/tmp/model",
        modelSettingsStore: FakeModelSettingsStore()
      )
    )
    try await waitUntil { !appState.isWorkspaceLibraryLoading }
    let sessionID = try #require(appState.addWorkspace(from: workspaceURL))

    appState.renameSession(sessionID, title: "  Refactor parser  ")
    try await waitUntil {
      workspaceStore.savedLibrary?.workspaces.first?.sessions.first?.title == "Refactor parser"
    }

    #expect(appState.activeSession?.title == "Refactor parser")
    #expect(
      workspaceStore.savedLibrary?.workspaces.first?.sessions.first?.title == "Refactor parser")
  }

  @Test
  func appStateIgnoresEmptySessionRename() async throws {
    let workspaceURL = try makeTemporaryDirectory()
    let workspaceStore = FakeWorkspaceStore()
    let appState = AppState(
      workspaceStore: workspaceStore,
      chatController: ChatSessionController(
        runtime: FakeChatModelRuntime(),
        modelPath: "/tmp/model",
        modelSettingsStore: FakeModelSettingsStore()
      )
    )
    try await waitUntil { !appState.isWorkspaceLibraryLoading }
    let sessionID = try #require(appState.addWorkspace(from: workspaceURL))

    appState.renameSession(sessionID, title: "   ")

    #expect(appState.activeSession?.title == "New Session")
  }

  @Test
  func appStateDeletesInactiveSessionAndItsMessages() async throws {
    let deletedSession = CodingSession(
      title: "Delete me",
      selectedModelID: "gemma3-1b",
      messages: [ChatMessage(kind: .user, content: "remove this chat")],
      systemPrompt: "Delete prompt",
      generationSettings: .codingDefault
    )
    let activeSession = CodingSession(
      title: "Keep me",
      selectedModelID: "gemma3-4b",
      messages: [ChatMessage(kind: .user, content: "keep this chat")],
      systemPrompt: "Keep prompt",
      generationSettings: .codingDefault
    )
    let workspace = Workspace(
      name: "Project",
      rootURL: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      sessions: [deletedSession, activeSession]
    )
    let workspaceStore = FakeWorkspaceStore(
      library: WorkspaceLibrary(
        workspaces: [workspace],
        activeWorkspaceID: workspace.id,
        activeSessionID: activeSession.id
      )
    )
    let appState = AppState(workspaceStore: workspaceStore)
    try await waitUntil { !appState.isWorkspaceLibraryLoading }

    appState.deleteSession(deletedSession.id)
    try await waitUntil { workspaceStore.savedLibrary?.workspaces.first?.sessions.count == 1 }

    #expect(appState.activeSession?.id == activeSession.id)
    #expect(appState.workspaceLibrary.workspaces.first?.sessions.map(\.id) == [activeSession.id])
    #expect(
      workspaceStore.savedLibrary?.workspaces.first?.sessions.contains {
        $0.messages.contains { $0.content == "remove this chat" }
      } == false)
  }

  @Test
  func appStateDeletesActiveSessionAndSelectsRemainingSession() async throws {
    let activeSession = CodingSession(
      title: "Active",
      selectedModelID: "gemma3-1b",
      messages: [ChatMessage(kind: .user, content: "active chat")],
      systemPrompt: "Active prompt",
      generationSettings: .codingDefault
    )
    let remainingSession = CodingSession(
      title: "Remaining",
      selectedModelID: "gemma3-4b",
      messages: [ChatMessage(kind: .user, content: "remaining chat")],
      systemPrompt: "Remaining prompt",
      generationSettings: .codingDefault
    )
    let workspace = Workspace(
      name: "Project",
      rootURL: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      sessions: [activeSession, remainingSession]
    )
    let controller = ChatSessionController(
      runtime: FakeChatModelRuntime(),
      modelPath: "/tmp/model",
      modelSettingsStore: FakeModelSettingsStore()
    )
    let appState = AppState(
      workspaceStore: FakeWorkspaceStore(
        library: WorkspaceLibrary(
          workspaces: [workspace],
          activeWorkspaceID: workspace.id,
          activeSessionID: activeSession.id
        )
      ),
      chatController: controller
    )
    try await waitUntil { !appState.isWorkspaceLibraryLoading }

    appState.deleteSession(activeSession.id)

    #expect(appState.activeSession?.id == remainingSession.id)
    #expect(controller.chatSession.messages == remainingSession.messages)
    #expect(controller.chatSession.systemPrompt == "Remaining prompt")
  }

  @Test
  func appStateDeletingLastSessionCreatesEmptyReplacementSession() async throws {
    let onlySession = CodingSession(
      title: "Only",
      selectedModelID: "gemma3-1b",
      messages: [ChatMessage(kind: .user, content: "deleted chat")],
      systemPrompt: "Only prompt",
      generationSettings: .codingDefault
    )
    let workspace = Workspace(
      name: "Project",
      rootURL: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      sessions: [onlySession]
    )
    let controller = ChatSessionController(
      runtime: FakeChatModelRuntime(),
      modelPath: "/tmp/model",
      modelSettingsStore: FakeModelSettingsStore()
    )
    let appState = AppState(
      workspaceStore: FakeWorkspaceStore(
        library: WorkspaceLibrary(
          workspaces: [workspace],
          activeWorkspaceID: workspace.id,
          activeSessionID: onlySession.id
        )
      ),
      chatController: controller
    )
    try await waitUntil { !appState.isWorkspaceLibraryLoading }

    appState.deleteSession(onlySession.id)

    #expect(appState.workspaceLibrary.workspaces.first?.sessions.count == 1)
    #expect(appState.activeSession?.id != onlySession.id)
    #expect(appState.activeSession?.title == "New Session")
    #expect(appState.activeSession?.messages.isEmpty == true)
    #expect(controller.chatSession.messages.isEmpty)
  }

  @Test
  func appStatePersistsChatMutationIntoActiveSession() async throws {
    let workspaceURL = try makeTemporaryDirectory()
    let workspaceStore = FakeWorkspaceStore()
    let controller = ChatSessionController(
      runtime: FakeChatModelRuntime(chunks: ["hello", " world"]),
      modelPath: "/tmp/model",
      modelSettingsStore: FakeModelSettingsStore()
    )
    let appState = AppState(workspaceStore: workspaceStore, chatController: controller)
    try await waitUntil { !appState.isWorkspaceLibraryLoading }
    _ = appState.addWorkspace(from: workspaceURL)
    controller.modelRuntime.modelState = .ready
    controller.draft = "Say hello"

    controller.sendMessage()

    try await waitUntil { !controller.isGenerating }

    #expect(appState.activeSession?.messages.count == 2)
    #expect(appState.activeSession?.messages.first?.content == "Say hello")
    #expect(appState.activeSession?.messages.last?.content == "hello world")
    #expect(workspaceStore.savedLibrary?.activeSessionID == appState.activeSession?.id)
  }

  @Test
  func appStatePersistsToolCallsFromSessionSnapshot() async throws {
    let workspaceURL = try makeTemporaryDirectory()
    let workspaceStore = FakeWorkspaceStore()
    let controller = ChatSessionController(
      runtime: FakeChatModelRuntime(),
      modelPath: "/tmp/model",
      modelSettingsStore: FakeModelSettingsStore()
    )
    let appState = AppState(workspaceStore: workspaceStore, chatController: controller)
    try await waitUntil { !appState.isWorkspaceLibraryLoading }
    _ = appState.addWorkspace(from: workspaceURL)
    let workspaceID = try #require(appState.activeWorkspace?.id)
    let sessionID = try #require(appState.activeSession?.id)
    let toolCall = makeToolCallRecord(workspaceID: workspaceID, sessionID: sessionID)

    controller.chatSession.toolCalls = [toolCall]
    appState.persistActiveSession()
    try await waitUntil {
      workspaceStore.savedLibrary?.workspaces.first?.sessions.first?.toolCalls == [toolCall]
    }

    #expect(appState.activeSession?.toolCalls == [toolCall])
    #expect(workspaceStore.savedLibrary?.workspaces.first?.sessions.first?.toolCalls == [toolCall])
  }

  private func temporaryLibraryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "local-coder-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
      .appending(path: "workspaces.json", directoryHint: .notDirectory)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "local-coder-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let start = ContinuousClock.now
    while !condition() {
      if start.duration(to: .now) > timeout {
        Issue.record("Timed out waiting for condition")
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func makeToolCallRecord(
    workspaceID: Workspace.ID,
    sessionID: CodingSession.ID
  ) -> ToolCallRecord {
    let request = ToolCallRequest(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      workspaceID: workspaceID,
      sessionID: sessionID,
      toolName: .readFile,
      arguments: ["path": .string("README.md")],
      createdAt: Date(timeIntervalSinceReferenceDate: 1)
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
      resultPreview: ToolResultPreview(
        text: "Preview",
        truncated: true,
        redacted: true,
        affectedPaths: ["/tmp/project/README.md"]
      )
    )
  }
}

@MainActor
private struct ChatSessionBootstrapTests {
  @Test
  func persistedModelBootstrapDoesNotClearLoadedSessionTranscript() async throws {
    let modelStore = FakeModelSettingsStore()
    let selectedModel = ManagedModelCatalog.model(id: "gemma3-1b")!
    modelStore.selectedModelIDValue = selectedModel.id
    modelStore.settingsByModelID[selectedModel.id] = StoredModelSettings(
      systemPrompt: "Persisted model prompt",
      generationSettings: ChatGenerationSettings(
        temperature: 0.2,
        topP: 0.8,
        topK: 20,
        maxTokens: 512
      )
    )
    let session = CodingSession(
      selectedModelID: selectedModel.id,
      messages: [ChatMessage(kind: .user, content: "keep this transcript")],
      systemPrompt: "Session prompt",
      generationSettings: .codingDefault
    )
    let controller = ChatSessionController(
      runtime: FakeChatModelRuntime(),
      modelPath: "/tmp/model",
      modelSettingsStore: modelStore
    )

    controller.loadSession(session)
    controller.modelRuntime.loadPersistedModelSelection()
    try await Task.sleep(for: .milliseconds(60))

    #expect(controller.chatSession.messages == session.messages)
    #expect(controller.chatSession.systemPrompt == "Session prompt")
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

private final class FakeWorkspaceStore: WorkspaceStoring, @unchecked Sendable {
  var library: WorkspaceLibrary
  var savedLibrary: WorkspaceLibrary?

  init(library: WorkspaceLibrary = WorkspaceLibrary()) {
    self.library = library
  }

  func loadLibrary() async -> WorkspaceLibrary {
    library
  }

  func saveLibrary(_ library: WorkspaceLibrary) async throws {
    self.library = library
    savedLibrary = library
  }
}

private final class FakeModelSettingsStore: ModelSettingsStoring, @unchecked Sendable {
  var selectedModelIDValue = ManagedModelCatalog.defaultModelID
  var settingsByModelID: [String: StoredModelSettings] = [:]

  func selectedModelID(availableModelIDs: Set<String>) async -> String {
    availableModelIDs.contains(selectedModelIDValue)
      ? selectedModelIDValue : ManagedModelCatalog.defaultModelID
  }

  func setSelectedModelID(_ modelID: String) async {
    selectedModelIDValue = modelID
  }

  func settings(for model: ManagedModel) async -> StoredModelSettings {
    settingsByModelID[model.id]
      ?? StoredModelSettings(
        systemPrompt: model.defaultSystemPrompt,
        generationSettings: model.defaultGenerationSettings,
        contextTokenLimit: model.defaultContextTokenLimit
      )
  }

  func save(settings: StoredModelSettings, for model: ManagedModel) async throws {
    settingsByModelID[model.id] = settings
  }
}

private actor FakeChatModelRuntime: ChatModelRuntime {
  private let chunks: [String]

  init(chunks: [String] = []) {
    self.chunks = chunks
  }

  func load(configuration: ChatModelConfiguration) async throws {}
  func unload() async {}
  func clearContext() async {}

  func contextUsage(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    ChatContextUsage(usedTokens: 0, tokenLimit: nil)
  }

  func streamReply(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = messages
    _ = attachments
    _ = systemPrompt
    _ = settings

    return AsyncThrowingStream { continuation in
      for chunk in chunks {
        continuation.yield(.chunk(chunk))
      }
      continuation.yield(
        .completed(ChatGenerationMetrics(generatedTokenCount: chunks.count, tokensPerSecond: 100))
      )
      continuation.finish()
    }
  }
}
