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
    let session = ChatSession(
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
    let webAccessSettingsStore = InMemoryWebAccessSettingsStore()
    let controller = ChatSessionController(
      modelSettingsStore: modelSettingsStore,
      runtime: AppStateTestRuntime()
    )
    let appState = AppState(
      workspaceStore: workspaceStore,
      modelSettingsStore: modelSettingsStore,
      webAccessSettingsStore: webAccessSettingsStore,
      chatController: controller
    )

    try await waitUntil {
      !appState.isWorkspaceLibraryLoading
    }

    #expect(appState.chatController.chatSession.interactionMode == .chat)

    appState.chatController.setInteractionMode(.agent)

    let savedLibrary = try await waitForSavedLibrary(in: workspaceStore) { library in
      library.workspaces.first?
        .sessions.first(where: { $0.id == sessionID })?
        .interactionMode == .agent
    }
    let savedSession = try #require(
      savedLibrary.workspaces.first?
        .sessions.first(where: { $0.id == sessionID })
    )

    #expect(savedSession.interactionMode == .agent)
  }

  @Test
  func webAccessSettingsAreGlobalAndPersistIndependentlyFromWorkspace() async throws {
    let workspaceID = UUID()
    let sessionID = UUID()
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: [ChatSession(id: sessionID)]
    )
    let workspaceStore = InMemoryWorkspaceStore(
      initialLibrary: WorkspaceLibrary(
        workspaces: [workspace],
        activeWorkspaceID: workspaceID,
        activeSessionID: sessionID
      )
    )
    let modelSettingsStore = InMemoryModelSettingsStore()
    let webAccessSettingsStore = InMemoryWebAccessSettingsStore(
      settings: WebAccessSettings(policy: .askEachTime, provider: .duckDuckGo)
    )
    let appState = AppState(
      workspaceStore: workspaceStore,
      modelSettingsStore: modelSettingsStore,
      webAccessSettingsStore: webAccessSettingsStore,
      chatController: ChatSessionController(
        modelSettingsStore: modelSettingsStore,
        runtime: AppStateTestRuntime()
      )
    )

    try await waitUntil {
      !appState.isWorkspaceLibraryLoading
        && appState.activeWebAccessSettings.policy == .askEachTime
    }

    let updated = WebAccessSettings(
      policy: .allow,
      provider: .searxng,
      searxngBaseURL: "https://search.example"
    )
    appState.updateActiveWebAccessSettings(updated)

    try await waitUntil {
      await webAccessSettingsStore.settings() == updated
    }
    #expect(appState.activeWebAccessSettings == updated)
  }

  @Test
  func webAccessSettingsSavesRemainOrderedWhenUpdatesHappenQuickly() async throws {
    let workspaceStore = InMemoryWorkspaceStore(initialLibrary: WorkspaceLibrary())
    let modelSettingsStore = InMemoryModelSettingsStore()
    let webAccessSettingsStore = SlowFirstWebAccessSettingsStore()
    let appState = AppState(
      workspaceStore: workspaceStore,
      modelSettingsStore: modelSettingsStore,
      webAccessSettingsStore: webAccessSettingsStore,
      chatController: ChatSessionController(
        modelSettingsStore: modelSettingsStore,
        runtime: AppStateTestRuntime()
      )
    )

    try await waitUntil {
      !appState.isWorkspaceLibraryLoading
    }

    let first = WebAccessSettings(policy: .allow, provider: .duckDuckGo)
    let second = WebAccessSettings(
      policy: .askEachTime,
      provider: .searxng,
      searxngBaseURL: "https://search.example"
    )
    appState.updateActiveWebAccessSettings(first)
    appState.updateActiveWebAccessSettings(second)

    try await waitUntil(timeout: 3) {
      await webAccessSettingsStore.saveCount() == 2
    }
    #expect(await webAccessSettingsStore.settings() == second)
    #expect(appState.activeWebAccessSettings == second)
  }

  @Test
  func autoloadLastModelDefaultsOffAndDoesNotLoadOnStartup() async throws {
    let modelSettingsStore = InMemoryModelSettingsStore()
    let appBehaviorSettingsStore = InMemoryAppBehaviorSettingsStore()
    let controller = ChatSessionController(
      modelSettingsStore: modelSettingsStore,
      runtime: AppStateTestRuntime()
    )
    let appState = AppState(
      workspaceStore: InMemoryWorkspaceStore(initialLibrary: WorkspaceLibrary()),
      modelSettingsStore: modelSettingsStore,
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      appBehaviorSettingsStore: appBehaviorSettingsStore,
      chatController: controller
    )

    try await waitUntil {
      !appState.isWorkspaceLibraryLoading
    }
    appState.startModelRuntimeServices()

    #expect(appState.activeAppBehaviorSettings == AppBehaviorSettings())
    #expect(controller.modelRuntime.modelState == .notLoaded)
  }

  @Test
  func autoloadLastModelSettingPersistsGlobally() async throws {
    let appBehaviorSettingsStore = InMemoryAppBehaviorSettingsStore()
    let modelSettingsStore = InMemoryModelSettingsStore()
    let runtime = AppStateTestRuntime()
    let appState = AppState(
      workspaceStore: InMemoryWorkspaceStore(initialLibrary: WorkspaceLibrary()),
      modelSettingsStore: modelSettingsStore,
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      appBehaviorSettingsStore: appBehaviorSettingsStore,
      chatController: ChatSessionController(
        modelSettingsStore: modelSettingsStore,
        runtime: runtime,
        modelAvailability: { _ in true }
      )
    )

    try await waitUntil {
      !appState.isWorkspaceLibraryLoading
    }
    appState.startModelRuntimeServices()

    let updated = AppBehaviorSettings(autoloadLastModel: true)
    appState.updateActiveAppBehaviorSettings(updated)

    try await waitUntil {
      await appBehaviorSettingsStore.settings() == updated
    }
    #expect(appState.activeAppBehaviorSettings == updated)
    #expect(await runtime.loadCount() == 0)
    #expect(appState.chatController.modelRuntime.modelState == .notLoaded)
  }

  @Test
  func autoloadLastModelStartsLoadingWhenEnabled() async throws {
    let modelSettingsStore = InMemoryModelSettingsStore()
    let runtime = AppStateTestRuntime()
    let controller = ChatSessionController(
      modelSettingsStore: modelSettingsStore,
      runtime: runtime,
      modelAvailability: { _ in true }
    )
    let appState = AppState(
      workspaceStore: InMemoryWorkspaceStore(initialLibrary: WorkspaceLibrary()),
      modelSettingsStore: modelSettingsStore,
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      appBehaviorSettingsStore: InMemoryAppBehaviorSettingsStore(
        settings: AppBehaviorSettings(autoloadLastModel: true)
      ),
      chatController: controller
    )

    try await waitUntil {
      !appState.isWorkspaceLibraryLoading
    }

    appState.startModelRuntimeServices()

    try await waitUntil {
      controller.modelRuntime.modelState == .ready
    }

    #expect(appState.activeAppBehaviorSettings.autoloadLastModel)
    #expect(await runtime.loadCount() == 1)
  }

  @Test
  func autoloadLastModelDoesNotLoadWhenSelectedModelIsNotDownloaded() async throws {
    let modelSettingsStore = InMemoryModelSettingsStore()
    let runtime = AppStateTestRuntime()
    let controller = ChatSessionController(
      modelSettingsStore: modelSettingsStore,
      runtime: runtime,
      modelAvailability: { _ in false }
    )
    let appState = AppState(
      workspaceStore: InMemoryWorkspaceStore(initialLibrary: WorkspaceLibrary()),
      modelSettingsStore: modelSettingsStore,
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      appBehaviorSettingsStore: InMemoryAppBehaviorSettingsStore(
        settings: AppBehaviorSettings(autoloadLastModel: true)
      ),
      chatController: controller
    )

    try await waitUntil {
      !appState.isWorkspaceLibraryLoading
    }

    appState.startModelRuntimeServices()

    #expect(appState.activeAppBehaviorSettings.autoloadLastModel)
    #expect(controller.modelRuntime.modelState == .notLoaded)
    #expect(await runtime.loadCount() == 0)
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

private actor InMemoryWebAccessSettingsStore: WebAccessSettingsStoring {
  private var storedSettings: WebAccessSettings

  init(settings: WebAccessSettings = .disabled) {
    self.storedSettings = settings
  }

  func settings() async -> WebAccessSettings {
    storedSettings
  }

  func save(settings: WebAccessSettings) async throws {
    storedSettings = settings
  }
}

private actor InMemoryAppBehaviorSettingsStore: AppBehaviorSettingsStoring {
  private var storedSettings: AppBehaviorSettings

  init(settings: AppBehaviorSettings = AppBehaviorSettings()) {
    self.storedSettings = settings
  }

  func settings() async -> AppBehaviorSettings {
    storedSettings
  }

  func save(settings: AppBehaviorSettings) async throws {
    storedSettings = settings
  }
}

private actor SlowFirstWebAccessSettingsStore: WebAccessSettingsStoring {
  private var storedSettings = WebAccessSettings.disabled
  private var saves = 0

  func settings() async -> WebAccessSettings {
    storedSettings
  }

  func save(settings: WebAccessSettings) async throws {
    saves += 1
    if saves == 1 {
      try await Task.sleep(for: .milliseconds(100))
    }
    storedSettings = settings
  }

  func saveCount() -> Int {
    saves
  }
}

private actor AppStateTestRuntime: ChatModelRuntime {
  private var loadedConfigurations: [ChatModelConfiguration] = []

  func load(configuration: ChatModelConfiguration) async throws {
    loadedConfigurations.append(configuration)
  }

  func loadCount() -> Int {
    loadedConfigurations.count
  }

  func unload() async {}
  func clearContext() async {}

  func contextUsage(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = transcript
    _ = attachments
    _ = systemPrompt
    return ChatContextUsage(usedTokens: 0, tokenLimit: nil)
  }

  func streamReply(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
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
