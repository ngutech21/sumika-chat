import Foundation
import Testing

@testable import SumikaApp
@testable import SumikaCore

@Suite(.serialized)
@MainActor
struct AppStateTests {
  @Test
  func chatFacadeProjectsEngineStateAndRoutesUserOperations() async throws {
    let sessionID = UUID()
    let workspace = Workspace(
      name: "Project",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: [ChatSession(id: sessionID)]
    )
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
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: AppStateTestRuntime()
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }

    #expect(appState.chatFeatureState.transcript.sessionID == sessionID)
    #expect(appState.chatFeatureState.transcript.turns.isEmpty)
    #expect(appState.chatFeatureState.composer.session.interactionMode == .chat)

    appState.chatFeatureState.setInteractionMode(.agent)

    #expect(appState.chatFeatureState.composer.session.interactionMode == .agent)
  }

  @Test
  func modelManagementFacadeRoutesStateChangesThroughExplicitActions() async throws {
    let appState = AppState(
      workspaceStore: InMemoryWorkspaceStore(initialLibrary: WorkspaceLibrary()),
      modelSettingsStore: InMemoryModelSettingsStore(),
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: AppStateTestRuntime(),
      modelAvailability: { _ in false }
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }

    let targetModel = try #require(ManagedModelCatalog.model(id: "gemma4-26b-qat-4bit"))
    appState.modelManagementState.selectModel(targetModel)
    appState.modelManagementState.updateContextTokenLimit(12_288)

    #expect(appState.modelManagementState.state.selectedModel == targetModel)
    #expect(appState.modelManagementState.state.modelContextTokenLimit == 12_288)
    #expect(appState.modelManagementState.primaryAction == .download)
  }

  @Test
  func modelManagementErrorsStayOnModelManagementState() async throws {
    let appState = AppState(
      workspaceStore: InMemoryWorkspaceStore(initialLibrary: WorkspaceLibrary()),
      modelSettingsStore: InMemoryModelSettingsStore(),
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: AppStateTestRuntime(),
      modelAvailability: { _ in false }
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }

    appState.modelManagementState.loadAvailableModelForConversation()

    #expect(
      appState.modelManagementState.errorMessage
        == "Download a model from Models first."
    )
    #expect(appState.chatFeatureState.composer.errorMessage == nil)

    appState.modelManagementState.performPrimaryAction()

    try await waitUntil {
      appState.modelManagementState.errorMessage == "No model downloader is configured."
    }
    #expect(appState.chatFeatureState.composer.errorMessage == nil)
  }

  @Test
  func updatingModeSettingsRefreshesAndPersistsActiveSession() async throws {
    let workspaceID = UUID()
    let sessionID = UUID()
    let otherSessionID = UUID()
    let session = ChatSession(
      id: sessionID,
      selectedModelID: ManagedModelCatalog.defaultModelID,
      modeSettings: testModeSettings(
        systemPrompt: "Initial prompt",
        generationSettings: .chatDefault
      )
    )
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: [
        session,
        ChatSession(
          id: otherSessionID,
          selectedModelID: ManagedModelCatalog.defaultModelID
        ),
      ]
    )
    let workspaceStore = InMemoryWorkspaceStore(
      initialLibrary: WorkspaceLibrary(
        workspaces: [workspace],
        activeWorkspaceID: workspaceID,
        activeSessionID: sessionID
      )
    )
    let modelSettingsStore = InMemoryModelSettingsStore()
    let appState = AppState(
      workspaceStore: workspaceStore,
      modelSettingsStore: modelSettingsStore,
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: AppStateTestRuntime()
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }
    appState.modelManagementState.setModelLoadStateForTesting(.ready)
    appState.chatFeatureState.refreshContextUsageForTesting()
    let initialUsage = try #require(appState.chatFeatureState.composer.contextUsage)

    var updatedModeSettings = appState.modelManagementState.modeSettings
    updatedModeSettings.chat.systemPrompt += String(
      repeating: " Additional context.",
      count: 100
    )

    appState.modelManagementState.updateModeSettings(updatedModeSettings)

    let refreshedUsage = try #require(appState.chatFeatureState.composer.contextUsage)
    #expect(refreshedUsage.usedTokens > initialUsage.usedTokens)

    let selectedModel = appState.modelManagementState.state.selectedModel
    try await waitUntil {
      await modelSettingsStore.settings(for: selectedModel).modeSettings
        == updatedModeSettings
    }
    let savedLibrary = try await waitForSavedLibrary(in: workspaceStore) { library in
      library.workspaces.first?
        .sessions.first(where: { $0.id == sessionID })?
        .modeSettings == updatedModeSettings
    }
    let savedSession = try #require(
      savedLibrary.workspaces.first?
        .sessions.first(where: { $0.id == sessionID })
    )
    #expect(savedSession.modeSettings == updatedModeSettings)

    #expect(
      appState.selectChat(
        workspaceID: workspaceID,
        sessionID: otherSessionID
      )
    )
    #expect(
      appState.selectChat(
        workspaceID: workspaceID,
        sessionID: sessionID
      )
    )
    #expect(appState.modelManagementState.modeSettings == updatedModeSettings)
  }

  @Test
  func updatingContextLimitPersistsCurrentModeSettings() async throws {
    let modelSettingsStore = InMemoryModelSettingsStore()
    let appState = AppState(
      workspaceStore: InMemoryWorkspaceStore(initialLibrary: WorkspaceLibrary()),
      modelSettingsStore: modelSettingsStore,
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: AppStateTestRuntime()
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }

    let selectedModel = appState.modelManagementState.state.selectedModel
    let currentModeSettings = appState.modelManagementState.modeSettings
    let contextTokenLimit = 12_288

    appState.modelManagementState.updateContextTokenLimit(contextTokenLimit)

    try await waitUntil {
      let settings = await modelSettingsStore.settings(for: selectedModel)
      return settings.contextTokenLimit == contextTokenLimit
        && settings.modeSettings == currentModeSettings
    }
    let storedSettings = await modelSettingsStore.settings(for: selectedModel)

    #expect(appState.modelManagementState.state.modelContextTokenLimit == contextTokenLimit)
    #expect(storedSettings.contextTokenLimit == contextTokenLimit)
    #expect(storedSettings.modeSettings == currentModeSettings)
    #expect(appState.modelManagementState.modeSettings == currentModeSettings)
  }

  @Test
  func selectingSessionAppliesItsModelThroughModelManagement() async throws {
    let workspaceID = UUID()
    let initialSession = ChatSession(selectedModelID: ManagedModelCatalog.defaultModelID)
    let selectedModel = try #require(
      ManagedModelCatalog.model(id: "gemma4-12b-qat-4bit")
    )
    let targetSession = ChatSession(selectedModelID: selectedModel.id)
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: [initialSession, targetSession]
    )
    let appState = AppState(
      workspaceStore: InMemoryWorkspaceStore(
        initialLibrary: WorkspaceLibrary(
          workspaces: [workspace],
          activeWorkspaceID: workspaceID,
          activeSessionID: initialSession.id
        )
      ),
      modelSettingsStore: InMemoryModelSettingsStore(),
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: AppStateTestRuntime()
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
        && appState.modelManagementState.state.selectedModel.id
          == ManagedModelCatalog.defaultModelID
    }

    #expect(
      appState.selectChat(
        workspaceID: workspaceID,
        sessionID: targetSession.id
      )
    )
    #expect(appState.chatFeatureState.transcript.sessionID == targetSession.id)
    #expect(appState.modelManagementState.state.selectedModel == selectedModel)
    #expect(
      appState.chatFeatureState.sessionSnapshotForTesting.selectedModelID == selectedModel.id
    )
  }

  @Test
  func interactionModeChangePersistsActiveSession() async throws {
    let workspaceID = UUID()
    let sessionID = UUID()
    let session = ChatSession(
      id: sessionID,
      selectedModelID: ManagedModelCatalog.defaultModelID,
      modeSettings: testModeSettings(
        systemPrompt: "System",
        generationSettings: .agentDefault
      ),
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
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: AppStateTestRuntime()
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }

    #expect(appState.chatFeatureState.composer.session.interactionMode == .chat)

    appState.chatFeatureState.setInteractionMode(.agent)

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
  func prepareForTerminationPersistsUnsavedSessionStateBeforeReturning() async throws {
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
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: AppStateTestRuntime()
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }

    appState.renameSession(sessionID, title: "Unsaved title")

    await appState.prepareForTermination()

    let savedLibrary = await workspaceStore.latestSavedLibrary()
    let savedSession = try #require(
      savedLibrary?.workspaces.first?.sessions.first(where: { $0.id == sessionID })
    )
    #expect(savedSession.title == "Unsaved title")
  }

  @Test
  func prepareForTerminationWaitsForInFlightSavesBeforeReturning() async throws {
    let workspaceID = UUID()
    let sessionID = UUID()
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: [ChatSession(id: sessionID)]
    )
    let workspaceStore = SlowSaveWorkspaceStore(
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
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: AppStateTestRuntime()
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }

    _ = appState.persistActiveSession()
    appState.renameSession(sessionID, title: "Final title")

    await appState.prepareForTermination()

    let savedLibrary = await workspaceStore.latestSavedLibrary()
    let savedSession = try #require(
      savedLibrary?.workspaces.first?.sessions.first(where: { $0.id == sessionID })
    )
    #expect(savedSession.title == "Final title")
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
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: AppStateTestRuntime(eventTurns: [[.chunk("Persisted reply.")]])
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }
    guard let activeWorkspace = appState.workspaceState.activeWorkspace else {
      throw AppStateTestFailure.missingWorkspace
    }
    let activeSessionID = try #require(appState.workspaceState.activeSessionID)
    appState.modelManagementState.setModelLoadStateForTesting(.ready)
    appState.sendMessage(
      prompt: "Persist this",
      in: WorkspaceChatContext(workspace: activeWorkspace),
      sessionID: activeSessionID
    )

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
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: AppStateTestRuntime()
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
        && appState.settingsState.webAccessSettings.policy == .askEachTime
    }

    let updated = WebAccessSettings(
      policy: .allow,
      provider: .searxng,
      searxngBaseURL: "https://search.example"
    )
    appState.settingsState.updateWebAccessSettings(updated)

    try await waitUntil {
      await webAccessSettingsStore.settings() == updated
    }
    #expect(appState.settingsState.webAccessSettings == updated)
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
      mcpServersStore: InMemoryMCPServersStore(),
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
    appState.settingsState.updateWebAccessSettings(first)
    appState.settingsState.updateWebAccessSettings(second)

    try await waitUntil(timeout: 3) {
      await webAccessSettingsStore.saveCount() == 2
    }
    #expect(await webAccessSettingsStore.settings() == second)
    #expect(appState.settingsState.webAccessSettings == second)
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
      mcpServersStore: InMemoryMCPServersStore(),
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
      mcpServersStore: InMemoryMCPServersStore(),
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
      mcpServersStore: InMemoryMCPServersStore(),
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
          modeSettings: testModeSettings(
            systemPrompt: "Workspace private system prompt",
            generationSettings: workspaceGenerationSettings
          )
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
      mcpServersStore: InMemoryMCPServersStore(),
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
    #expect(appState.chatFeatureState.transcript.sessionID != sessionID)
    #expect(
      appState.modelManagementState.modeSettings.chat.systemPrompt
        != "Workspace private system prompt"
    )
    #expect(
      appState.modelManagementState.modeSettings.chat.generationSettings
        != workspaceGenerationSettings)
  }

  @Test
  func loadStoredLibrarySetsInitialRouteFromPersistedChat() async throws {
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
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: AppStateTestRuntime()
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }

    #expect(appState.route == .chat(workspaceID: workspaceID, sessionID: sessionID))
    #expect(appState.chatFeatureState.transcript.sessionID == sessionID)
  }

  @Test
  func loadStoredLibrarySetsWorkspaceRouteWhenNoSessionIsActive() async throws {
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
          activeSessionID: nil
        )
      ),
      modelSettingsStore: InMemoryModelSettingsStore(),
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: AppStateTestRuntime()
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }

    #expect(appState.route == .workspace(workspaceID))
    #expect(appState.workspaceState.activeSessionID == nil)
    #expect(appState.chatFeatureState.transcript.sessionID != sessionID)
  }

  @Test
  func modelsRoutePlaceholderDoesNotPersistOverActiveChat() async throws {
    let workspaceID = UUID()
    let sessionID = UUID()
    let session = ChatSession(id: sessionID, title: "Persisted Chat")
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: [session]
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
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: AppStateTestRuntime()
    )

    appState.selectModels()

    try await waitUntil {
      !appState.workspaceState.isLoading
    }

    #expect(appState.route == .models)
    #expect(appState.workspaceState.activeSessionID == sessionID)
    #expect(appState.chatFeatureState.transcript.sessionID != sessionID)

    let didPersist = appState.persistActiveSession()

    #expect(!didPersist)
    #expect(appState.workspaceState.activeSession?.title == "Persisted Chat")
  }

  @Test
  func automaticMissingModelRouteDoesNotOverrideLoadedActiveChat() async throws {
    let workspaceID = UUID()
    let sessionID = UUID()
    let session = ChatSession(id: sessionID, title: "UI Test Chat")
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: [session]
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
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: AppStateTestRuntime(),
      modelAvailability: { _ in false }
    )

    appState.startModelRuntimeServices()

    try await waitUntil {
      !appState.workspaceState.isLoading
    }

    #expect(appState.route == .chat(workspaceID: workspaceID, sessionID: sessionID))
    #expect(appState.chatFeatureState.transcript.sessionID == sessionID)
  }

  @Test
  func workspaceAndChatNavigationPersistThroughRouteSSOT() async throws {
    let firstWorkspaceID = UUID()
    let firstSessionID = UUID()
    let secondWorkspaceID = UUID()
    let secondSessionID = UUID()
    let firstWorkspace = Workspace(
      id: firstWorkspaceID,
      name: "First",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: [ChatSession(id: firstSessionID, title: "First")]
    )
    let secondWorkspace = Workspace(
      id: secondWorkspaceID,
      name: "Second",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: [ChatSession(id: secondSessionID, title: "Second")]
    )
    let workspaceStore = InMemoryWorkspaceStore(
      initialLibrary: WorkspaceLibrary(
        workspaces: [firstWorkspace, secondWorkspace],
        activeWorkspaceID: firstWorkspaceID,
        activeSessionID: firstSessionID
      )
    )
    let appState = AppState(
      workspaceStore: workspaceStore,
      modelSettingsStore: InMemoryModelSettingsStore(),
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: AppStateTestRuntime()
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }

    appState.selectWorkspace(secondWorkspaceID)
    let workspaceRouteLibrary = try await waitForSavedLibrary(in: workspaceStore) { library in
      library.activeWorkspaceID == secondWorkspaceID && library.activeSessionID == nil
    }
    #expect(workspaceRouteLibrary.activeWorkspaceID == secondWorkspaceID)
    #expect(appState.route == .workspace(secondWorkspaceID))
    #expect(appState.workspaceState.activeSessionID == nil)
    #expect(appState.chatFeatureState.transcript.sessionID != secondSessionID)

    appState.selectChat(workspaceID: secondWorkspaceID, sessionID: secondSessionID)
    let chatRouteLibrary = try await waitForSavedLibrary(in: workspaceStore) { library in
      library.activeWorkspaceID == secondWorkspaceID
        && library.activeSessionID == secondSessionID
    }
    #expect(chatRouteLibrary.activeSessionID == secondSessionID)
    #expect(appState.route == .chat(workspaceID: secondWorkspaceID, sessionID: secondSessionID))
    #expect(appState.chatFeatureState.transcript.sessionID == secondSessionID)

    let didSelectInvalidChat = appState.selectChat(
      workspaceID: firstWorkspaceID,
      sessionID: secondSessionID
    )
    #expect(!didSelectInvalidChat)
    #expect(appState.route == .chat(workspaceID: secondWorkspaceID, sessionID: secondSessionID))
  }

  @Test
  func renamedActiveSessionIsNotRevertedWhenSelectingWorkspace() async throws {
    let workspaceID = UUID()
    let sessionID = UUID()
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: [ChatSession(id: sessionID, title: "New Session")]
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
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: AppStateTestRuntime()
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }

    appState.renameSession(sessionID, title: "huhu")
    #expect(appState.workspaceState.activeSession?.title == "huhu")

    appState.selectWorkspace(workspaceID)

    let savedLibrary = try await waitForSavedLibrary(in: workspaceStore) { library in
      library.activeSessionID == nil
        && library.workspaces.first?.sessions.first(where: { $0.id == sessionID })?.title
          == "huhu"
    }
    #expect(savedLibrary.activeSessionID == nil)
    #expect(
      savedLibrary.workspaces.first?.sessions.first(where: { $0.id == sessionID })?.title
        == "huhu")
    #expect(appState.workspaceState.sidebarState.workspaces.first?.sessions.first?.title == "huhu")
  }

  @Test
  func createSessionRoutesToNewChat() async throws {
    let workspaceID = UUID()
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: []
    )
    let workspaceStore = InMemoryWorkspaceStore(
      initialLibrary: WorkspaceLibrary(
        workspaces: [workspace],
        activeWorkspaceID: workspaceID,
        activeSessionID: nil
      )
    )
    let appState = AppState(
      workspaceStore: workspaceStore,
      modelSettingsStore: InMemoryModelSettingsStore(),
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: AppStateTestRuntime()
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }

    let sessionID = try #require(appState.createSession(in: workspaceID))

    let savedLibrary = try await waitForSavedLibrary(in: workspaceStore) { library in
      library.activeWorkspaceID == workspaceID && library.activeSessionID == sessionID
    }
    #expect(savedLibrary.activeSessionID == sessionID)
    #expect(appState.route == .chat(workspaceID: workspaceID, sessionID: sessionID))
    #expect(appState.chatFeatureState.transcript.sessionID == sessionID)
  }

  @Test
  func addWorkspaceRoutesToCreatedChat() async throws {
    let workspaceURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: workspaceURL)
    }
    let workspaceStore = InMemoryWorkspaceStore(initialLibrary: WorkspaceLibrary())
    let appState = AppState(
      workspaceStore: workspaceStore,
      modelSettingsStore: InMemoryModelSettingsStore(),
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: AppStateTestRuntime()
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }

    let workspaceID = try #require(appState.addWorkspace(from: workspaceURL))

    let savedLibrary = try await waitForSavedLibrary(in: workspaceStore) { library in
      library.activeWorkspaceID == workspaceID
        && library.activeSessionID != nil
        && library.workspaces.first?.sessions.count == 1
    }
    let sessionID = try #require(savedLibrary.activeSessionID)
    #expect(savedLibrary.activeWorkspaceID == workspaceID)
    #expect(appState.route == .chat(workspaceID: workspaceID, sessionID: sessionID))
    #expect(appState.workspaceState.activeSessionID == sessionID)
    #expect(appState.chatFeatureState.transcript.sessionID == sessionID)
  }

  @Test
  func sendingFromWorkspaceRouteCreatesSessionBeforePersistingTurn() async throws {
    let workspaceID = UUID()
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: []
    )
    let workspaceStore = InMemoryWorkspaceStore(
      initialLibrary: WorkspaceLibrary(
        workspaces: [workspace],
        activeWorkspaceID: workspaceID,
        activeSessionID: nil
      )
    )
    let appState = AppState(
      workspaceStore: workspaceStore,
      modelSettingsStore: InMemoryModelSettingsStore(),
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: AppStateTestRuntime(eventTurns: [[.chunk("Persisted reply.")]])
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }
    let context = try #require(appState.workspaceState.activeWorkspaceContext)
    appState.modelManagementState.setModelLoadStateForTesting(.ready)

    let didSend = appState.sendMessage(prompt: "Create a chat", in: context, sessionID: nil)

    #expect(didSend)
    let savedLibrary = try await waitForSavedLibrary(in: workspaceStore) { library in
      guard
        let sessionID = library.activeSessionID,
        let savedSession = library.workspaces.first?.sessions.first(where: { $0.id == sessionID })
      else {
        return false
      }
      return savedSession.transcriptTextForAppStateTesting == [
        "Create a chat",
        "Persisted reply.",
      ]
    }
    let sessionID = try #require(savedLibrary.activeSessionID)
    #expect(appState.route == .chat(workspaceID: workspaceID, sessionID: sessionID))
    #expect(appState.chatFeatureState.transcript.sessionID == sessionID)
  }

  @Test
  func deleteActiveSessionRoutesToWorkspace() async throws {
    let activeSessionID = UUID()
    let replacementSessionID = UUID()
    let workspaceID = UUID()
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: [
        ChatSession(id: activeSessionID, title: "Active"),
        ChatSession(id: replacementSessionID, title: "Replacement"),
      ]
    )
    let workspaceStore = InMemoryWorkspaceStore(
      initialLibrary: WorkspaceLibrary(
        workspaces: [workspace],
        activeWorkspaceID: workspaceID,
        activeSessionID: activeSessionID
      )
    )
    let appState = AppState(
      workspaceStore: workspaceStore,
      modelSettingsStore: InMemoryModelSettingsStore(),
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: AppStateTestRuntime()
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }

    appState.deleteSession(activeSessionID)

    let savedLibrary = try await waitForSavedLibrary(in: workspaceStore) { library in
      library.activeWorkspaceID == workspaceID
        && library.activeSessionID == nil
        && library.workspaces.first?.sessions.contains { $0.id == activeSessionID } == false
    }
    #expect(savedLibrary.activeSessionID == nil)
    #expect(appState.route == .workspace(workspaceID))
    #expect(appState.workspaceState.activeSessionID == nil)
    #expect(appState.workspaceState.activeSession == nil)
    #expect(appState.chatFeatureState.transcript.sessionID != replacementSessionID)
    #expect(
      appState.workspaceState.sidebarState.workspaces.first?.sessions.map(\.id)
        == [replacementSessionID])
  }

  @Test
  func deleteInactiveSessionPersistsCurrentActiveSnapshot() async throws {
    let activeSessionID = UUID()
    let deletedSessionID = UUID()
    let workspaceID = UUID()
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: [
        ChatSession(id: activeSessionID, title: "Active"),
        ChatSession(id: deletedSessionID, title: "Delete Me"),
      ]
    )
    let workspaceStore = InMemoryWorkspaceStore(
      initialLibrary: WorkspaceLibrary(
        workspaces: [workspace],
        activeWorkspaceID: workspaceID,
        activeSessionID: activeSessionID
      )
    )
    let appState = AppState(
      workspaceStore: workspaceStore,
      modelSettingsStore: InMemoryModelSettingsStore(),
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: AppStateTestRuntime()
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }

    appState.renameSession(activeSessionID, title: "Unsaved Active")
    appState.deleteSession(deletedSessionID)

    let savedLibrary = try await waitForSavedLibrary(in: workspaceStore) { library in
      let sessions = library.workspaces.first?.sessions ?? []
      return sessions.contains { $0.id == deletedSessionID } == false
        && sessions.first { $0.id == activeSessionID }?.title == "Unsaved Active"
    }
    let savedSessions = try #require(savedLibrary.workspaces.first?.sessions)
    #expect(savedSessions.contains { $0.id == deletedSessionID } == false)
    #expect(savedSessions.first { $0.id == activeSessionID }?.title == "Unsaved Active")
    #expect(appState.workspaceState.activeSessionID == activeSessionID)
    #expect(appState.chatFeatureState.transcript.sessionID == activeSessionID)
  }

  @Test
  func autoloadLastModelDefaultsOffAndDoesNotLoadOnStartup() async throws {
    let modelSettingsStore = InMemoryModelSettingsStore()
    let appBehaviorSettingsStore = InMemoryAppBehaviorSettingsStore()
    let webAccessSettingsStore = InMemoryWebAccessSettingsStore()
    let browserToolService = HTMLPreviewBrowserToolService()
    let conversation = AppLaunchConfiguration.makeConversationComposition(
      modelSettingsStore: modelSettingsStore,
      runtime: AppStateTestRuntime(),
      toolOrchestrator: ToolOrchestrator(
        executorRegistry: .codingAgentRegistry(todoWriteEnabled: false),
        browserToolService: browserToolService,
        webAccessSettingsProvider: {
          await webAccessSettingsStore.settings()
        }
      ),
      turnTracer: NoopTurnTracer()
    )
    let appState = AppState(
      workspaceStore: InMemoryWorkspaceStore(initialLibrary: WorkspaceLibrary()),
      modelSettingsStore: modelSettingsStore,
      webAccessSettingsStore: webAccessSettingsStore,
      appBehaviorSettingsStore: appBehaviorSettingsStore,
      mcpServersStore: InMemoryMCPServersStore(),
      browserToolService: browserToolService,
      conversation: conversation,
      turnTracer: NoopTurnTracer()
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }
    appState.startModelRuntimeServices()

    #expect(appState.settingsState.appBehaviorSettings == AppBehaviorSettings())
    #expect(!appState.settingsState.appBehaviorSettings.todoWriteToolEnabled)
    #expect(appState.modelManagementState.state.modelState == .notLoaded)
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
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: runtime,
      modelAvailability: { _ in true }
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }
    appState.startModelRuntimeServices()

    let updated = AppBehaviorSettings(autoloadLastModel: true)
    appState.updateAppBehaviorSettings(updated)

    try await waitUntil {
      await appBehaviorSettingsStore.settings() == updated
    }
    #expect(appState.settingsState.appBehaviorSettings == updated)
    #expect(await runtime.loadCount() == 0)
    #expect(appState.modelManagementState.state.modelState == .notLoaded)
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
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: runtime,
      modelAvailability: { _ in true }
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }

    appState.startModelRuntimeServices()

    try await waitUntil {
      appState.modelManagementState.state.modelState == .ready
    }

    #expect(appState.settingsState.appBehaviorSettings.autoloadLastModel)
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
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: runtime,
      modelAvailability: { _ in false }
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }

    appState.startModelRuntimeServices()

    #expect(appState.settingsState.appBehaviorSettings.autoloadLastModel)
    #expect(appState.modelManagementState.state.modelState == .notLoaded)
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
        "XCTestConfigurationFilePath": "/tmp/sumika-unit-tests.xctestconfiguration",
        "SUMIKA_UNIT_TEST_STORAGE_ROOT": fixture.storageRoot.path(percentEncoded: false),
        "SUMIKA_UNIT_TEST_DEFAULTS_SUITE": "sumika-unit-tests-\(UUID().uuidString)",
      ],
      runtime: runtime
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }
    appState.startModelRuntimeServices()

    #expect(appState.settingsState.appBehaviorSettings.autoloadLastModel)
    #expect(appState.modelManagementState.state.modelState == .notLoaded)
    #expect(await runtime.loadCount() == 0)
  }

  @Test
  func injectedControllerUsesSuppliedBrowserToolService() async throws {
    let modelSettingsStore = InMemoryModelSettingsStore()
    let webAccessSettingsStore = InMemoryWebAccessSettingsStore()
    let browserToolService = HTMLPreviewBrowserToolService()
    let conversation = AppLaunchConfiguration.makeConversationComposition(
      modelSettingsStore: modelSettingsStore,
      runtime: AppStateTestRuntime(),
      toolOrchestrator: ToolOrchestrator(
        executorRegistry: .codingAgentRegistry(todoWriteEnabled: false),
        browserToolService: browserToolService,
        webAccessSettingsProvider: {
          await webAccessSettingsStore.settings()
        }
      ),
      turnTracer: NoopTurnTracer()
    )
    let chatFeatureState = conversation.chatFeatureState

    let appState = AppState(
      workspaceStore: InMemoryWorkspaceStore(initialLibrary: WorkspaceLibrary()),
      modelSettingsStore: modelSettingsStore,
      webAccessSettingsStore: webAccessSettingsStore,
      mcpServersStore: InMemoryMCPServersStore(),
      browserToolService: browserToolService,
      conversation: conversation,
      turnTracer: NoopTurnTracer()
    )

    #expect(appState.browserToolService === browserToolService)
    #expect(appState.chatFeatureState === chatFeatureState)
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
    appState.chatFeatureState.setInteractionMode(.agent)
    appState.modelManagementState.setModelLoadStateForTesting(.ready)
    appState.sendMessage(
      prompt: "refresh the preview",
      in: WorkspaceChatContext(workspace: workspace),
      sessionID: activeSessionID
    )

    try await waitUntil {
      !appState.chatFeatureState.transcript.isGenerating
    }

    #expect(await probe.refreshCount() == 1)
    let toolCall = try #require(appState.chatFeatureState.toolCallsForAppStateTesting.first)
    #expect(toolCall.request.toolName == .browserRefresh)
    #expect(toolCall.status == .completed)
  }

  @Test
  func defaultAppAgentRegistryHidesTodoWriteAndKeepsFinishTaskAfterMCPComposition() async throws {
    let sessionID = UUID()
    let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let workspace = Workspace(
      name: "Project",
      rootURL: rootURL,
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
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: runtime
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }
    guard let activeWorkspace = appState.workspaceState.activeWorkspace else {
      throw AppStateTestFailure.missingWorkspace
    }
    let activeSessionID = try #require(appState.workspaceState.activeSessionID)
    appState.modelManagementState.setModelLoadStateForTesting(.ready)
    appState.chatFeatureState.setInteractionMode(.agent)
    appState.sendMessage(
      prompt: "inspect the project",
      in: WorkspaceChatContext(workspace: activeWorkspace),
      sessionID: activeSessionID
    )

    try await waitUntil {
      !appState.chatFeatureState.transcript.isGenerating
    }

    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.first?.contains("todo_write") == false)
    #expect(capturedSystemPrompts.first?.contains("finish_task") == true)
    let capturedToolContexts = await runtime.capturedToolContexts
    let toolContext = try #require(capturedToolContexts.first ?? nil)
    #expect(toolContext.registry.definition(for: .todoWrite) == nil)
    #expect(toolContext.registry.definition(for: .finishTask) != nil)
  }

  @Test
  func enablingTodoWriteToolExposesItInAppAgentPromptAndSchema() async throws {
    let sessionID = UUID()
    let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let workspace = Workspace(
      name: "Project",
      rootURL: rootURL,
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
      mcpServersStore: InMemoryMCPServersStore(),
      runtime: runtime
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
    }
    let updatedSettings = AppBehaviorSettings(todoWriteToolEnabled: true)
    appState.updateAppBehaviorSettings(updatedSettings)
    try await waitUntil {
      await appBehaviorSettingsStore.settings() == updatedSettings
    }

    guard let activeWorkspace = appState.workspaceState.activeWorkspace else {
      throw AppStateTestFailure.missingWorkspace
    }
    let activeSessionID = try #require(appState.workspaceState.activeSessionID)
    appState.modelManagementState.setModelLoadStateForTesting(.ready)
    appState.chatFeatureState.setInteractionMode(.agent)
    appState.sendMessage(
      prompt: "inspect the project",
      in: WorkspaceChatContext(workspace: activeWorkspace),
      sessionID: activeSessionID
    )

    try await waitUntil {
      !appState.chatFeatureState.transcript.isGenerating
    }

    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.first?.contains("todo_write") == true)
    let capturedToolContexts = await runtime.capturedToolContexts
    let toolContext = try #require(capturedToolContexts.first ?? nil)
    #expect(toolContext.registry.definition(for: .todoWrite) != nil)
  }

  @Test
  func storedChatSessionDoesNotStartSelectedMCPServer() async throws {
    let server = MCPServerConfig(name: "Unused", command: "/usr/bin/false")
    let sessionID = UUID()
    let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let session = ChatSession(
      id: sessionID,
      interactionMode: .chat,
      selectedMCPServerIDs: [server.id]
    )
    let workspace = Workspace(name: "Project", rootURL: rootURL, sessions: [session])
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
      mcpServersStore: InMemoryMCPServersStore(servers: [server]),
      runtime: AppStateTestRuntime(eventTurns: [])
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
        && appState.settingsState.mcpServerStatuses.first?.state == .disconnected
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(appState.settingsState.mcpServerStatuses.count == 1)
    #expect(appState.settingsState.mcpServerStatuses.first?.state == .disconnected)
    await appState.prepareForTermination()
  }

  @Test
  func prepareForTerminationWaitsForMCPServerTest() async throws {
    let script = try makeMCPServerScript(initializationDelay: 0.2)
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let server = MCPServerConfig(
      name: "Probe",
      command: script.path(percentEncoded: false)
    )
    let sessionID = UUID()
    let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let session = ChatSession(id: sessionID, interactionMode: .chat)
    let workspace = Workspace(name: "Project", rootURL: rootURL, sessions: [session])
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
      mcpServersStore: InMemoryMCPServersStore(servers: [server]),
      runtime: AppStateTestRuntime(eventTurns: [])
    )

    try await waitUntil {
      !appState.workspaceState.isLoading
        && appState.settingsState.mcpServerStatuses.first?.state == .disconnected
    }

    appState.testMCPServer(server.id)
    await appState.prepareForTermination()

    #expect(appState.settingsState.mcpServerTestFeedback?.message.contains("1 tool") == true)
  }

  @Test
  func selectedMCPServersFilterAgentToolSchemaPerSession() async throws {
    let script = try makeMCPServerScript()
    defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
    let firstServer = MCPServerConfig(
      name: "First",
      command: script.path(percentEncoded: false)
    )
    let secondServer = MCPServerConfig(
      name: "Second",
      command: script.path(percentEncoded: false)
    )
    let sessionID = UUID()
    let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let session = ChatSession(
      id: sessionID,
      interactionMode: .agent,
      selectedMCPServerIDs: [firstServer.id]
    )
    let workspace = Workspace(name: "Project", rootURL: rootURL, sessions: [session])
    let runtime = AppStateTestRuntime(eventTurns: [
      [.chunk("First response.")],
      [.chunk("Second response.")],
    ])
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
      mcpServersStore: InMemoryMCPServersStore(servers: [firstServer, secondServer]),
      runtime: runtime
    )

    try await waitUntil {
      let statuses = appState.settingsState.mcpServerStatuses
      return !appState.workspaceState.isLoading
        && statuses.first(where: { $0.serverID == firstServer.id })?.state
          == .connected(toolCount: 1)
        && statuses.first(where: { $0.serverID == secondServer.id })?.state
          == .disconnected
    }

    appState.testMCPServer(secondServer.id)
    try await waitUntil {
      appState.settingsState.mcpServerTestFeedback?.message.contains("1 tool") == true
    }
    #expect(
      appState.settingsState.mcpServerStatuses.first {
        $0.serverID == secondServer.id
      }?.state == .disconnected)

    appState.settingsState.mcpServerTestFeedback = nil
    appState.testMCPServer(firstServer.id)
    try await waitUntil {
      appState.settingsState.mcpServerTestFeedback?.message.contains("1 tool") == true
    }
    #expect(
      appState.settingsState.mcpServerStatuses.first {
        $0.serverID == firstServer.id
      }?.state == .connected(toolCount: 1))

    let activeWorkspace = try #require(appState.workspaceState.activeWorkspace)
    appState.modelManagementState.setModelLoadStateForTesting(.ready)
    appState.sendMessage(
      prompt: "Use the first server",
      in: WorkspaceChatContext(workspace: activeWorkspace),
      sessionID: sessionID
    )
    try await waitUntil { !appState.chatFeatureState.transcript.isGenerating }

    appState.setSelectedMCPServerIDs([secondServer.id])
    try await waitUntil {
      let statuses = appState.settingsState.mcpServerStatuses
      return statuses.first(where: { $0.serverID == firstServer.id })?.state
        == .disconnected
        && statuses.first(where: { $0.serverID == secondServer.id })?.state
          == .connected(toolCount: 1)
    }
    appState.sendMessage(
      prompt: "Use the second server",
      in: WorkspaceChatContext(workspace: activeWorkspace),
      sessionID: sessionID
    )
    try await waitUntil { !appState.chatFeatureState.transcript.isGenerating }

    let capturedToolContexts = await runtime.capturedToolContexts
    let contexts = capturedToolContexts.compactMap { $0 }
    let firstContext = try #require(contexts.first)
    let secondContext = try #require(contexts.dropFirst().first)
    #expect(mcpToolNames(in: firstContext) == ["mcp__first__echo"])
    #expect(mcpToolNames(in: secondContext) == ["mcp__second__echo"])
    #expect(
      appState.chatFeatureState.composer.session.selectedMCPServerIDs == [secondServer.id])
    await appState.prepareForTermination()
  }

  @Test
  func disabledMCPSelectionPersistsAndDeletedConfigurationIsPruned() async throws {
    let configuredServer = MCPServerConfig(
      name: "Offline",
      command: "/usr/bin/false",
      isEnabled: false
    )
    let deletedServerID = UUID()
    let sessionID = UUID()
    let workspace = Workspace(
      name: "Project",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: [
        ChatSession(
          id: sessionID,
          interactionMode: .agent,
          selectedMCPServerIDs: [configuredServer.id, deletedServerID]
        )
      ]
    )
    let workspaceStore = InMemoryWorkspaceStore(
      initialLibrary: WorkspaceLibrary(
        workspaces: [workspace],
        activeWorkspaceID: workspace.id,
        activeSessionID: sessionID
      )
    )
    let appState = AppState(
      workspaceStore: workspaceStore,
      modelSettingsStore: InMemoryModelSettingsStore(),
      webAccessSettingsStore: InMemoryWebAccessSettingsStore(),
      mcpServersStore: InMemoryMCPServersStore(servers: [configuredServer]),
      runtime: AppStateTestRuntime()
    )

    try await waitUntil { !appState.workspaceState.isLoading }
    #expect(
      appState.chatFeatureState.composer.session.selectedMCPServerIDs == [configuredServer.id])

    appState.updateMCPServers([])
    try await waitUntil {
      appState.settingsState.mcpServers.isEmpty
        && appState.chatFeatureState.composer.session.selectedMCPServerIDs.isEmpty
    }
    let savedLibrary = try await waitForSavedLibrary(in: workspaceStore) { library in
      library.workspaces.first?.sessions.first?.selectedMCPServerIDs.isEmpty == true
    }
    #expect(savedLibrary.workspaces.first?.sessions.first?.selectedMCPServerIDs == [])
  }
}

private func makeMCPServerScript(initializationDelay: Double = 0) throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "sumika-app-mcp-tests-\(UUID().uuidString)",
    directoryHint: .isDirectory
  )
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let script = directory.appending(path: "server.sh", directoryHint: .notDirectory)
  try """
  #!/bin/sh
  request_id() {
    printf '%s\\n' "$1" | sed -E 's/.*"id":("[^"]*"|[0-9]+).*/\\1/'
  }
  sleep \(initializationDelay)
  read -r line
  id=$(request_id "$line")
  printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"1.0"}}}\\n' "$id"
  read -r line
  read -r line
  id=$(request_id "$line")
  printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","description":"Echo text.","inputSchema":{"type":"object"}}]}}\\n' "$id"
  while read -r line; do :; done
  """.write(to: script, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o755],
    ofItemAtPath: script.path(percentEncoded: false)
  )
  return script
}

private func mcpToolNames(in context: ChatRuntimeToolContext) -> [String] {
  context.registry.tools
    .filter { $0.capabilities.contains(.externalService) }
    .map(\.name.rawValue)
}

private actor InMemoryWorkspaceStore: WorkspaceStoring {
  private var library: WorkspaceLibrary
  private var savedLibraries: [WorkspaceLibrary] = []

  init(initialLibrary: WorkspaceLibrary) {
    self.library = initialLibrary
  }

  func loadLibrary() async -> WorkspaceLibraryLoadResult {
    WorkspaceLibraryLoadResult(library: library)
  }

  func saveLibrary(_ library: WorkspaceLibrary) async throws {
    self.library = library
    savedLibraries.append(library)
  }

  func latestSavedLibrary() -> WorkspaceLibrary? {
    savedLibraries.last
  }
}

private actor SlowSaveWorkspaceStore: WorkspaceStoring {
  private var library: WorkspaceLibrary
  private var savedLibraries: [WorkspaceLibrary] = []

  init(initialLibrary: WorkspaceLibrary) {
    self.library = initialLibrary
  }

  func loadLibrary() async -> WorkspaceLibraryLoadResult {
    WorkspaceLibraryLoadResult(library: library)
  }

  func saveLibrary(_ library: WorkspaceLibrary) async throws {
    try await Task.sleep(for: .milliseconds(50))
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

private actor InMemoryMCPServersStore: MCPServersStoring {
  private var storedServers: [MCPServerConfig]

  init(servers: [MCPServerConfig] = []) {
    self.storedServers = servers
  }

  func servers() async -> [MCPServerConfig] {
    storedServers
  }

  func save(servers: [MCPServerConfig]) async throws {
    storedServers = servers
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
  private(set) var capturedPromptPlans: [ChatRuntimePromptPlan] = []

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

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = settings
    capturedPromptPlans.append(promptPlan)
    capturedSystemPrompts.append(promptPlan.stableInstructions)
    capturedToolContexts.append(promptPlan.toolContext)
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
    path: "sumika-app-state-tests-\(UUID().uuidString)",
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

extension ChatFeatureState {
  fileprivate var toolCallsForAppStateTesting: [ToolCallRecord] {
    transcript.turns.flatMap(\.items).compactMap { item in
      guard case .tool(let record) = item else {
        return nil
      }
      return record
    }
  }
}

extension ChatSession {
  fileprivate var transcriptTextForAppStateTesting: [String] {
    turns.flatMap(\.items).compactMap { item in
      switch item {
      case .userMessage(let message):
        message.content
      case .assistantThinking(let message):
        message.content
      case .assistantMessage(let message):
        message.content
      case .tool:
        nil
      }
    }
  }
}
