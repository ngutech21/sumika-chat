import Foundation
import SumikaCore
import Testing

@testable import Sumika

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
    let appState = AppState(
      workspaceStore: workspaceStore,
      modelSettingsStore: modelSettingsStore,
      webAccessSettingsStore: webAccessSettingsStore,
      runtime: AppStateTestRuntime()
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
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
  func sendMessagePersistsActiveSession() async throws {
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
    let appState = AppState(
      workspaceStore: workspaceStore,
      modelSettingsStore: InMemoryModelSettingsStore(),
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      runtime: AppStateTestRuntime(eventTurns: [[.chunk("Persisted reply.")]])
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }
    guard let activeWorkspace = appState.workspaceState.activeWorkspace else {
      throw AppStateTestFailure.missingWorkspace
    }
    let activeSessionID = try #require(appState.workspaceState.activeSessionID)
    appState.chatController.modelRuntime.modelState = .ready
    appState.chatController.draft = "Persist this"

    appState.chatController.sendMessage(in: activeWorkspace, sessionID: activeSessionID)

    let savedLibrary = try await waitForSavedLibrary(in: workspaceStore) { library in
      let savedSession = library.workspaces.first?
        .sessions.first(where: { $0.id == sessionID })
      return savedSession?.transcriptTextForAppStateTesting == [
        "Persist this",
        "Persisted reply.",
      ]
    }
    let savedSession = try #require(
      savedLibrary.workspaces.first?
        .sessions.first(where: { $0.id == sessionID })
    )

    #expect(savedSession.turns.first?.status == .completed)
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
      runtime: AppStateTestRuntime()
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
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
      runtime: AppStateTestRuntime()
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
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
  func workspaceStateOpenInFinderUsesActiveRootURL() async throws {
    let workspaceID = UUID()
    let sessionID = UUID()
    let workspaceURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: workspaceURL,
      sessions: [ChatSession(id: sessionID)]
    )
    let opener = RecordingWorkspaceOpener()
    let appState = AppState(
      workspaceStore: InMemoryWorkspaceStore(
        initialLibrary: WorkspaceLibrary(
          workspaces: [workspace],
          activeWorkspaceID: workspaceID,
          activeSessionID: sessionID
        )
      ),
      modelSettingsStore: InMemoryModelSettingsStore(),
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      runtime: AppStateTestRuntime(),
      workspaceOpener: opener
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }

    appState.workspaceState.openActiveWorkspaceInFinder()

    try await waitUntil {
      opener.requests.count == 1
    }
    #expect(opener.requests.first?.url == workspaceURL)
    #expect(opener.requests.first?.destination == .finder)
    #expect(appState.workspaceState.errorMessage == nil)
  }

  @Test
  func workspaceStateOpenInVisualStudioCodeUsesActiveRootURL() async throws {
    let workspaceID = UUID()
    let sessionID = UUID()
    let workspaceURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: workspaceURL,
      sessions: [ChatSession(id: sessionID)]
    )
    let opener = RecordingWorkspaceOpener()
    let appState = AppState(
      workspaceStore: InMemoryWorkspaceStore(
        initialLibrary: WorkspaceLibrary(
          workspaces: [workspace],
          activeWorkspaceID: workspaceID,
          activeSessionID: sessionID
        )
      ),
      modelSettingsStore: InMemoryModelSettingsStore(),
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      runtime: AppStateTestRuntime(),
      workspaceOpener: opener
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }

    appState.workspaceState.openActiveWorkspaceInVisualStudioCode()

    try await waitUntil {
      opener.requests.count == 1
    }
    #expect(opener.requests.first?.url == workspaceURL)
    #expect(opener.requests.first?.destination == .visualStudioCode)
    #expect(appState.workspaceState.errorMessage == nil)
  }

  @Test
  func openActiveWorkspaceReportsOpenFailure() async throws {
    let workspaceID = UUID()
    let sessionID = UUID()
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: [ChatSession(id: sessionID)]
    )
    let appState = AppState(
      workspaceStore: InMemoryWorkspaceStore(
        initialLibrary: WorkspaceLibrary(
          workspaces: [workspace],
          activeWorkspaceID: workspaceID,
          activeSessionID: sessionID
        )
      ),
      modelSettingsStore: InMemoryModelSettingsStore(),
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      runtime: AppStateTestRuntime(),
      workspaceOpener: FailingWorkspaceOpener(
        error: WorkspaceOpenError.applicationNotFound("Visual Studio Code")
      )
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }

    appState.workspaceState.openActiveWorkspaceInVisualStudioCode()

    try await waitUntil {
      appState.workspaceState.errorMessage
        == "Visual Studio Code was not found in /Applications or ~/Applications."
    }
  }

  @Test
  func removeWorkspaceDeletesOnlySumikaLibraryEntryAndKeepsFolder() async throws {
    let workspaceID = UUID()
    let sessionID = UUID()
    let workspaceURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    let markerURL = workspaceURL.appending(path: "keep.txt", directoryHint: .notDirectory)
    let workspaceGenerationSettings = ChatGenerationSettings(
      temperature: 0.42,
      topP: 0.75,
      topK: 12,
      maxTokens: 128
    )
    try Data("keep".utf8).write(to: markerURL)
    defer {
      try? FileManager.default.removeItem(at: workspaceURL)
    }
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: workspaceURL,
      sessions: [
        ChatSession(
          id: sessionID,
          systemPrompt: "Workspace private system prompt",
          generationSettings: workspaceGenerationSettings
        )
      ]
    )
    let workspaceStore = InMemoryWorkspaceStore(
      initialLibrary: WorkspaceLibrary(
        workspaces: [workspace],
        activeWorkspaceID: workspaceID,
        activeSessionID: sessionID
      )
    )
    let appState = AppState(
      workspaceStore: workspaceStore,
      modelSettingsStore: InMemoryModelSettingsStore(),
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      runtime: AppStateTestRuntime()
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }

    appState.removeWorkspace(workspaceID)

    let savedLibrary = try await waitForSavedLibrary(in: workspaceStore) { library in
      library.workspaces.isEmpty
    }
    #expect(savedLibrary.workspaces.isEmpty)
    #expect(savedLibrary.activeWorkspaceID == nil)
    #expect(savedLibrary.activeSessionID == nil)
    #expect(FileManager.default.fileExists(atPath: markerURL.path(percentEncoded: false)))
    #expect(appState.chatController.chatSession.id != sessionID)
    #expect(appState.chatController.chatSession.systemPrompt != "Workspace private system prompt")
    #expect(
      appState.chatController.chatSession.generationSettings
        != workspaceGenerationSettings)
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
      browserToolService: HTMLPreviewBrowserToolService(),
      chatController: controller
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }
    appState.startModelRuntimeServices()

    #expect(appState.activeAppBehaviorSettings == AppBehaviorSettings())
    #expect(!appState.activeAppBehaviorSettings.todoWriteToolEnabled)
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
      runtime: runtime,
      modelAvailability: { _ in true }
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
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
    let defaultModelDirectory = ManagedModelCatalog.defaultModel.localDirectoryURL
    let defaultModelDirectoryPath = defaultModelDirectory.path(percentEncoded: false)
    let didCreateDefaultModelDirectory = !FileManager.default.fileExists(
      atPath: defaultModelDirectoryPath)
    if didCreateDefaultModelDirectory {
      try FileManager.default.createDirectory(
        at: defaultModelDirectory,
        withIntermediateDirectories: true
      )
    }
    defer {
      if didCreateDefaultModelDirectory {
        try? FileManager.default.removeItem(at: defaultModelDirectory)
      }
    }
    let appState = AppState(
      workspaceStore: InMemoryWorkspaceStore(initialLibrary: WorkspaceLibrary()),
      modelSettingsStore: modelSettingsStore,
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      appBehaviorSettingsStore: InMemoryAppBehaviorSettingsStore(
        settings: AppBehaviorSettings(autoloadLastModel: true)
      ),
      runtime: runtime,
      modelAvailability: { _ in true }
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }

    appState.startModelRuntimeServices()

    try await waitUntil {
      appState.chatController.modelRuntime.modelState == .ready
    }

    #expect(appState.activeAppBehaviorSettings.autoloadLastModel)
    #expect(await runtime.loadCount() == 1)
  }

  @Test
  func autoloadLastModelDoesNotLoadWhenSelectedModelIsNotDownloaded() async throws {
    let modelSettingsStore = InMemoryModelSettingsStore()
    let runtime = AppStateTestRuntime()
    let appState = AppState(
      workspaceStore: InMemoryWorkspaceStore(initialLibrary: WorkspaceLibrary()),
      modelSettingsStore: modelSettingsStore,
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      appBehaviorSettingsStore: InMemoryAppBehaviorSettingsStore(
        settings: AppBehaviorSettings(autoloadLastModel: true)
      ),
      runtime: runtime,
      modelAvailability: { _ in false }
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }

    appState.startModelRuntimeServices()

    #expect(appState.activeAppBehaviorSettings.autoloadLastModel)
    #expect(appState.chatController.modelRuntime.modelState == .notLoaded)
    #expect(await runtime.loadCount() == 0)
  }

  @Test
  func unitTestHostLaunchDoesNotAutoloadRealModel() async throws {
    let runtime = AppStateTestRuntime()
    let fixture = try makeLaunchFixture()
    let settingsURL = fixture.storageRoot.appending(
      path: "app-behavior-settings.json",
      directoryHint: .notDirectory
    )
    try JSONEncoder().encode(AppBehaviorSettings(autoloadLastModel: true)).write(
      to: settingsURL,
      options: .atomic
    )
    let appState = AppLaunchConfiguration.makeAppState(
      environment: [
        "XCTestConfigurationFilePath": "/tmp/sumika-chat-unit-tests.xctestconfiguration",
        "SUMIKA_UNIT_TEST_STORAGE_ROOT": fixture.storageRoot.path(percentEncoded: false),
        "SUMIKA_UNIT_TEST_DEFAULTS_SUITE": "sumika-chat-unit-tests-\(UUID().uuidString)",
      ],
      runtime: runtime
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }
    appState.startModelRuntimeServices()

    #expect(appState.activeAppBehaviorSettings.autoloadLastModel)
    #expect(appState.chatController.modelRuntime.modelState == .notLoaded)
    #expect(await runtime.loadCount() == 0)
  }

  @Test
  func injectedControllerUsesSuppliedBrowserToolService() async throws {
    let modelSettingsStore = InMemoryModelSettingsStore()
    let browserToolService = HTMLPreviewBrowserToolService()
    let controller = ChatSessionController(
      modelSettingsStore: modelSettingsStore,
      runtime: AppStateTestRuntime()
    )

    let appState = AppState(
      workspaceStore: InMemoryWorkspaceStore(initialLibrary: WorkspaceLibrary()),
      modelSettingsStore: modelSettingsStore,
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      browserToolService: browserToolService,
      chatController: controller
    )

    #expect(appState.browserToolService === browserToolService)
    #expect(appState.chatController === controller)
  }

  @Test
  func uiTestLaunchAppStateSharesBrowserToolServiceWithControllerTools() async throws {
    let runtime = AppStateTestRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "browser_refresh",
            arguments: ["hard": .bool(true)]
          ))
      ],
      [.chunk("Preview refreshed.")],
    ])
    let fixture = try makeLaunchFixture()
    let appState = AppLaunchConfiguration.makeAppState(
      environment: [
        "SUMIKA_UI_TEST_MODE": "1",
        "SUMIKA_UI_TEST_STORAGE_ROOT": fixture.storageRoot.path(percentEncoded: false),
        "SUMIKA_UI_TEST_WORKSPACE_PATH": fixture.workspaceURL.path(percentEncoded: false),
        "SUMIKA_UI_TEST_MODEL_ID": ManagedModelCatalog.defaultModelID,
      ],
      runtime: runtime
    )
    let probe = BrowserToolProbe()

    try await waitUntil {
      !appState.workspaceState.isLoading
    }
    await appState.browserToolService.register(
      refreshHandler: { input in
        await probe.recordRefresh(input)
        return .success(
          path: WorkspaceRelativePath(rawValue: "index.html"),
          url: "file:///index.html",
          hard: input.hard ?? false
        )
      },
      inspectHandler: { input in
        await probe.recordInspect(input)
        return .success(
          path: WorkspaceRelativePath(rawValue: "index.html"),
          title: "Preview Fixture",
          url: "file:///index.html",
          selector: input.selector,
          text: ToolTextOutput(text: "Preview Fixture"),
          html: nil
        )
      }
    )
    guard let workspace = appState.workspaceState.activeWorkspace else {
      throw AppStateTestFailure.missingWorkspace
    }
    let activeSessionID = try #require(appState.workspaceState.activeSessionID)
    appState.chatController.setInteractionMode(.agent)
    appState.chatController.modelRuntime.modelState = .ready
    appState.chatController.draft = "refresh the preview"

    appState.chatController.sendMessage(in: workspace, sessionID: activeSessionID)

    try await waitUntil {
      !appState.chatController.isGenerating
    }

    #expect(await probe.refreshCount() == 1)
    let toolCall = try #require(appState.chatController.chatSession.toolCalls.first)
    #expect(toolCall.request.toolName == .browserRefresh)
    #expect(toolCall.status == .completed)
  }

  @Test
  func todoWriteToolIsHiddenByDefaultInAppAgentPromptAndSchema() async throws {
    let sessionID = UUID()
    let workspace = Workspace(
      name: "Project",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: [ChatSession(id: sessionID)]
    )
    let runtime = AppStateTestRuntime(eventTurns: [[.chunk("Done.")]])
    let appState = AppState(
      workspaceStore: InMemoryWorkspaceStore(
        initialLibrary: WorkspaceLibrary(
          workspaces: [workspace],
          activeWorkspaceID: workspace.id,
          activeSessionID: sessionID
        )
      ),
      modelSettingsStore: InMemoryModelSettingsStore(),
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      appBehaviorSettingsStore: InMemoryAppBehaviorSettingsStore(),
      runtime: runtime
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }
    guard let activeWorkspace = appState.workspaceState.activeWorkspace else {
      throw AppStateTestFailure.missingWorkspace
    }
    let activeSessionID = try #require(appState.workspaceState.activeSessionID)
    appState.chatController.modelRuntime.modelState = .ready
    appState.chatController.setInteractionMode(.agent)
    appState.chatController.draft = "inspect the project"

    appState.chatController.sendMessage(in: activeWorkspace, sessionID: activeSessionID)

    try await waitUntil {
      !appState.chatController.isGenerating
    }

    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.first?.contains("todo_write") == false)
    let capturedToolContexts = await runtime.capturedToolContexts
    let toolContext = try #require(capturedToolContexts.first ?? nil)
    #expect(toolContext.registry.definition(for: .todoWrite) == nil)
  }

  @Test
  func enablingTodoWriteToolExposesItInAppAgentPromptAndSchema() async throws {
    let sessionID = UUID()
    let workspace = Workspace(
      name: "Project",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: [ChatSession(id: sessionID)]
    )
    let appBehaviorSettingsStore = InMemoryAppBehaviorSettingsStore()
    let runtime = AppStateTestRuntime(eventTurns: [[.chunk("Done.")]])
    let appState = AppState(
      workspaceStore: InMemoryWorkspaceStore(
        initialLibrary: WorkspaceLibrary(
          workspaces: [workspace],
          activeWorkspaceID: workspace.id,
          activeSessionID: sessionID
        )
      ),
      modelSettingsStore: InMemoryModelSettingsStore(),
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      appBehaviorSettingsStore: appBehaviorSettingsStore,
      runtime: runtime
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }
    let updatedSettings = AppBehaviorSettings(todoWriteToolEnabled: true)
    appState.updateActiveAppBehaviorSettings(updatedSettings)
    try await waitUntil {
      await appBehaviorSettingsStore.settings() == updatedSettings
    }

    guard let activeWorkspace = appState.workspaceState.activeWorkspace else {
      throw AppStateTestFailure.missingWorkspace
    }
    let activeSessionID = try #require(appState.workspaceState.activeSessionID)
    appState.chatController.modelRuntime.modelState = .ready
    appState.chatController.setInteractionMode(.agent)
    appState.chatController.draft = "inspect the project"

    appState.chatController.sendMessage(in: activeWorkspace, sessionID: activeSessionID)

    try await waitUntil {
      !appState.chatController.isGenerating
    }

    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.first?.contains("todo_write") == true)
    let capturedToolContexts = await runtime.capturedToolContexts
    let toolContext = try #require(capturedToolContexts.first ?? nil)
    #expect(toolContext.registry.definition(for: .todoWrite) != nil)
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

@MainActor
private final class RecordingWorkspaceOpener: WorkspaceOpening {
  private(set) var requests: [(url: URL, destination: WorkspaceOpenDestination)] = []

  func open(_ url: URL, destination: WorkspaceOpenDestination) async throws {
    requests.append((url, destination))
  }
}

@MainActor
private final class FailingWorkspaceOpener: WorkspaceOpening {
  private let error: Error

  init(error: Error) {
    self.error = error
  }

  func open(_ url: URL, destination: WorkspaceOpenDestination) async throws {
    _ = url
    _ = destination
    throw error
  }
}

private actor AppStateTestRuntime: ChatModelRuntime {
  private let turns: [[ChatModelStreamEvent]]
  private var loadedConfigurations: [ChatModelConfiguration] = []
  private var streamReplyCount = 0
  private(set) var capturedSystemPrompts: [String] = []
  private(set) var capturedToolContexts: [ChatRuntimeToolContext?] = []

  init(eventTurns: [[ChatModelStreamEvent]] = []) {
    self.turns = eventTurns
  }

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
    _ = settings
    capturedSystemPrompts.append(systemPrompt)
    capturedToolContexts.append(nil)
    return stream(from: nextEvents())
  }

  func streamReply(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings,
    toolContext: ChatRuntimeToolContext?
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = settings
    capturedSystemPrompts.append(systemPrompt)
    capturedToolContexts.append(toolContext)
    return stream(from: nextEvents())
  }

  private func nextEvents() -> [ChatModelStreamEvent] {
    let events: [ChatModelStreamEvent]
    if turns.isEmpty {
      events = []
    } else {
      events = turns[min(streamReplyCount, turns.count - 1)]
    }
    streamReplyCount += 1
    return events
  }

  private func stream(from events: [ChatModelStreamEvent])
    -> AsyncThrowingStream<ChatModelStreamEvent, Error>
  {
    AsyncThrowingStream { continuation in
      for event in events {
        continuation.yield(event)
      }
      continuation.yield(.completed(nil))
      continuation.finish()
    }
  }
}

private actor BrowserToolProbe {
  private var refreshInputs: [BrowserRefreshInput] = []
  private var inspectInputs: [BrowserInspectInput] = []

  func recordRefresh(_ input: BrowserRefreshInput) {
    refreshInputs.append(input)
  }

  func recordInspect(_ input: BrowserInspectInput) {
    inspectInputs.append(input)
  }

  func refreshCount() -> Int {
    refreshInputs.count
  }
}

private func makeLaunchFixture() throws -> (storageRoot: URL, workspaceURL: URL) {
  let storageRoot = FileManager.default.temporaryDirectory.appending(
    path: "sumika-chat-app-state-tests-\(UUID().uuidString)",
    directoryHint: .isDirectory
  )
  let workspaceURL = storageRoot.appending(path: "workspace", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
  try """
  <!doctype html>
  <html>
  <body>Preview Fixture</body>
  </html>
  """.write(
    to: workspaceURL.appending(path: "index.html", directoryHint: .notDirectory),
    atomically: true,
    encoding: .utf8
  )
  return (storageRoot, workspaceURL)
}

private enum AppStateTestFailure: Error {
  case missingWorkspace
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

extension ChatSession {
  fileprivate var transcriptTextForAppStateTesting: [String] {
    turns.flatMap(\.items).compactMap { item in
      switch item {
      case .userMessage(let message):
        message.content
      case .assistantMessage(let message):
        message.content
      case .tool:
        nil
      }
    }
  }
}
