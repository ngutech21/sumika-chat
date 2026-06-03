import Foundation
import LocalCoderCore
import Testing

@testable import local_coder

@Suite(.serialized)
@MainActor
struct AppStateTests {
  @Test
  func interactionModeChangePersistsActiveSession() async throws {
    let workspaceID = UUID()
    let sessionID = UUID()
    let session = CodingSession(
      id: sessionID,
      selectedModelID: ManagedModelCatalog.defaultModelID,
      systemPrompt: "System",
      generationSettings: .codingDefault,
      interactionMode: .chat
    )
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: [session]
    )
    let initialLibrary = WorkspaceLibrary(
      workspaces: [workspace],
      activeWorkspaceID: workspaceID,
      activeSessionID: sessionID
    )
    let workspaceStore = InMemoryWorkspaceStore(initialLibrary: initialLibrary)
    let modelSettingsStore = InMemoryModelSettingsStore()
    let controller = ChatSessionController(
      modelSettingsStore: modelSettingsStore,
      runtime: AppStateTestRuntime()
    )
    let appState = AppState(
      workspaceStore: workspaceStore,
      modelSettingsStore: modelSettingsStore,
      chatController: controller
    )

    try await waitUntil {
      !appState.isWorkspaceLibraryLoading
    }

    #expect(appState.chatController.chatSession.interactionMode == .chat)

    appState.chatController.setInteractionMode(.inspect)

    let savedLibrary = try await waitForSavedLibrary(in: workspaceStore) { library in
      library.workspaces.first?
        .sessions.first(where: { $0.id == sessionID })?
        .interactionMode == .inspect
    }
    let savedSession = try #require(
      savedLibrary.workspaces.first?
        .sessions.first(where: { $0.id == sessionID })
    )

    #expect(savedSession.interactionMode == .inspect)
  }
}

private actor InMemoryWorkspaceStore: WorkspaceStoring {
  private var library: WorkspaceLibrary
  private var savedLibraries: [WorkspaceLibrary] = []

  init(initialLibrary: WorkspaceLibrary) {
    self.library = initialLibrary
  }

  func loadLibrary() async -> WorkspaceLibrary {
    library
  }

  func saveLibrary(_ library: WorkspaceLibrary) async throws {
    self.library = library
    savedLibraries.append(library)
  }

  func latestSavedLibrary() -> WorkspaceLibrary? {
    savedLibraries.last
  }
}

private actor InMemoryModelSettingsStore: ModelSettingsStoring {
  private var selectedModelID = ManagedModelCatalog.defaultModelID
  private var settingsByModelID: [ManagedModel.ID: StoredModelSettings] = [:]

  func selectedModelID(availableModelIDs: Set<String>) async -> String {
    availableModelIDs.contains(selectedModelID)
      ? selectedModelID : ManagedModelCatalog.defaultModelID
  }

  func setSelectedModelID(_ modelID: String) async {
    selectedModelID = modelID
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

private actor AppStateTestRuntime: ChatModelRuntime {
  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}
  func clearContext() async {}

  func contextUsage(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = messages
    _ = attachments
    _ = systemPrompt
    return ChatContextUsage(usedTokens: 0, tokenLimit: nil)
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
      continuation.finish()
    }
  }
}

private func waitForSavedLibrary(
  in store: InMemoryWorkspaceStore,
  matching predicate: (WorkspaceLibrary) -> Bool
) async throws -> WorkspaceLibrary {
  var matchedLibrary: WorkspaceLibrary?
  try await waitUntil {
    guard let library = await store.latestSavedLibrary(), predicate(library) else {
      return false
    }
    matchedLibrary = library
    return true
  }
  return try #require(matchedLibrary)
}

private func waitUntil(
  timeout: TimeInterval = 2,
  _ predicate: () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if await predicate() {
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw AppStateTestTimeoutError()
}

private struct AppStateTestTimeoutError: Error {}
