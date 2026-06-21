import Foundation
import Observation
import SumikaCore

@MainActor
@Observable
final class AppState {
  let workspaceState: WorkspaceFeatureState
  let settingsState: SettingsFeatureState
  @ObservationIgnored let chatController: ChatSessionController
  @ObservationIgnored let browserToolService: HTMLPreviewBrowserToolService
  @ObservationIgnored private let modelSettingsStore: any ModelSettingsStoring
  @ObservationIgnored private var defaultSessionModelID = ManagedModelCatalog.defaultModel.id
  @ObservationIgnored private var defaultSessionSystemPrompt =
    ManagedModelCatalog.defaultModel.defaultSystemPrompt
  @ObservationIgnored private var defaultSessionGenerationSettings =
    ManagedModelCatalog.defaultModel.defaultGenerationSettings
  @ObservationIgnored private var didAttemptAutoloadLastModel = false

  convenience init(
    workspaceStore: any WorkspaceStoring = WorkspaceStore(),
    modelSettingsStore: any ModelSettingsStoring = ModelSettingsStore(),
    webAccessSettingsStore: any WebAccessSettingsStoring = WebAccessSettingsStore(),
    appBehaviorSettingsStore: any AppBehaviorSettingsStoring = AppBehaviorSettingsStore(),
    modelDownloader: any ModelDownloading = HuggingFaceModelDownloader(),
    runtime: any ChatModelRuntime = GemmaMLXRuntime(),
    modelAvailability: @escaping @Sendable (ManagedModel) -> Bool =
      ModelLifecycleCoordinator.defaultModelAvailability,
    turnTracer: any TurnTracing = GemmaDebugTraceStore.shared,
    workspaceOpener: any WorkspaceOpening = MacWorkspaceOpenService()
  ) {
    let browserToolService = HTMLPreviewBrowserToolService()
    self.init(
      workspaceStore: workspaceStore,
      modelSettingsStore: modelSettingsStore,
      webAccessSettingsStore: webAccessSettingsStore,
      appBehaviorSettingsStore: appBehaviorSettingsStore,
      workspaceOpener: workspaceOpener,
      browserToolService: browserToolService,
      chatController: Self.makeChatController(
        modelSettingsStore: modelSettingsStore,
        webAccessSettingsStore: webAccessSettingsStore,
        modelDownloader: modelDownloader,
        runtime: runtime,
        modelAvailability: modelAvailability,
        browserToolService: browserToolService,
        turnTracer: turnTracer
      )
    )
  }

  init(
    workspaceStore: any WorkspaceStoring = WorkspaceStore(),
    modelSettingsStore: any ModelSettingsStoring = ModelSettingsStore(),
    webAccessSettingsStore: any WebAccessSettingsStoring = WebAccessSettingsStore(),
    appBehaviorSettingsStore: any AppBehaviorSettingsStoring = AppBehaviorSettingsStore(),
    workspaceOpener: any WorkspaceOpening = MacWorkspaceOpenService(),
    browserToolService: HTMLPreviewBrowserToolService,
    chatController: ChatSessionController
  ) {
    self.modelSettingsStore = modelSettingsStore
    self.browserToolService = browserToolService
    self.chatController = chatController
    self.settingsState = SettingsFeatureState(
      webAccessSettingsStore: webAccessSettingsStore,
      appBehaviorSettingsStore: appBehaviorSettingsStore
    )
    self.workspaceState = WorkspaceFeatureState(
      workspaceStore: workspaceStore,
      workspaceOpener: workspaceOpener,
      defaultSessionFactory: Self.defaultSessionFactory(
        selectedModelID: defaultSessionModelID,
        systemPrompt: defaultSessionSystemPrompt,
        generationSettings: defaultSessionGenerationSettings
      )
    )

    self.chatController.setSessionChangeHandler { [weak self] in
      self?.persistActiveSession()
    }
    loadStoredLibrary()
  }

  private static func makeChatController(
    modelSettingsStore: any ModelSettingsStoring,
    webAccessSettingsStore: any WebAccessSettingsStoring,
    modelDownloader: any ModelDownloading,
    runtime: any ChatModelRuntime,
    modelAvailability: @escaping @Sendable (ManagedModel) -> Bool,
    browserToolService: HTMLPreviewBrowserToolService,
    turnTracer: any TurnTracing
  ) -> ChatSessionController {
    ChatSessionController(
      modelSettingsStore: modelSettingsStore,
      modelDownloader: modelDownloader,
      runtime: runtime,
      modelAvailability: modelAvailability,
      toolOrchestrator: ToolOrchestrator(
        executorRegistry: .codingAgentRegistry(todoWriteEnabled: false),
        browserToolService: browserToolService,
        webAccessSettingsProvider: {
          await webAccessSettingsStore.settings()
        }
      ),
      turnTracer: turnTracer
    )
  }

  @discardableResult
  func addWorkspace(from url: URL) -> ChatSession.ID? {
    persistActiveSession()
    refreshDefaultSessionFactory()
    let change = workspaceState.addWorkspace(from: url)
    loadActiveSession(ifNeededFor: change)
    return change.activeSessionID
  }

  @discardableResult
  func createSession(in workspaceID: Workspace.ID? = nil) -> ChatSession.ID? {
    refreshDefaultSessionFactory()
    let change = workspaceState.createSession(in: workspaceID)
    loadActiveSession(ifNeededFor: change)
    return change.activeSessionID
  }

  func selectSession(_ sessionID: ChatSession.ID) {
    persistActiveSession()
    let change = workspaceState.selectSession(sessionID)
    loadActiveSession(ifNeededFor: change)
  }

  func deleteSession(_ sessionID: ChatSession.ID) {
    refreshDefaultSessionFactory()
    let change = workspaceState.deleteSession(sessionID)
    loadActiveSession(ifNeededFor: change)
  }

  func removeWorkspace(_ workspaceID: Workspace.ID) {
    persistActiveSession()
    let change = workspaceState.removeWorkspace(workspaceID)
    loadActiveSession(ifNeededFor: change)
  }

  func updateAppBehaviorSettings(_ settings: AppBehaviorSettings) {
    settingsState.updateAppBehaviorSettings(settings)
    applyAppBehaviorSettings(settings)
  }

  func startModelRuntimeServices() {
    chatController.modelRuntime.prepareDefaultModelDirectory()
    chatController.modelRuntime.startResourceMonitoring()
    attemptAutoloadLastModelIfReady()
  }

  func persistActiveSession() {
    guard
      let currentSession = workspaceState.activeSession
    else {
      return
    }

    workspaceState.persistActiveSessionSnapshot(
      chatController.sessionSnapshot(updating: currentSession)
    )
  }

  private func loadActiveSession() {
    guard let activeSession = workspaceState.activeSession else {
      chatController.loadSession(emptySessionForNoActiveWorkspace())
      return
    }

    chatController.loadSession(activeSession)
  }

  private func loadActiveSession(ifNeededFor change: WorkspaceSelectionChange) {
    guard change.activeSessionChanged else {
      return
    }

    loadActiveSession()
  }

  private func applyAppBehaviorSettings(_ settings: AppBehaviorSettings) {
    chatController.configureAgentTools(todoWriteEnabled: settings.todoWriteToolEnabled)
  }

  private func refreshDefaultSessionFactory() {
    workspaceState.updateDefaultSessionFactory(makeDefaultSessionFactory())
  }

  private func makeDefaultSessionFactory() -> DefaultChatSessionFactory {
    if chatController.modelRuntime.selectedModelID != ManagedModelCatalog.defaultModelID
      || defaultSessionModelID == ManagedModelCatalog.defaultModelID
    {
      return Self.defaultSessionFactory(
        selectedModelID: chatController.modelRuntime.selectedModelID,
        systemPrompt: chatController.chatSession.systemPrompt,
        generationSettings: chatController.chatSession.generationSettings
      )
    }

    return Self.defaultSessionFactory(
      selectedModelID: defaultSessionModelID,
      systemPrompt: defaultSessionSystemPrompt,
      generationSettings: defaultSessionGenerationSettings
    )
  }

  private static func defaultSessionFactory(
    selectedModelID: ManagedModel.ID,
    systemPrompt: String,
    generationSettings: ChatGenerationSettings
  ) -> DefaultChatSessionFactory {
    DefaultChatSessionFactory(
      selectedModelID: selectedModelID,
      systemPrompt: systemPrompt,
      generationSettings: generationSettings,
      interactionMode: .chat
    )
  }

  private func emptySessionForNoActiveWorkspace() -> ChatSession {
    Self.defaultSessionFactory(
      selectedModelID: defaultSessionModelID,
      systemPrompt: defaultSessionSystemPrompt,
      generationSettings: defaultSessionGenerationSettings
    )
    .makeSession()
  }

  private func loadStoredLibrary() {
    Task { [modelSettingsStore] in
      let availableModelIDs = Set(ManagedModelCatalog.models.map(\.id))
      let selectedModelID = await modelSettingsStore.selectedModelID(
        availableModelIDs: availableModelIDs)
      let selectedModel =
        ManagedModelCatalog.model(id: selectedModelID) ?? ManagedModelCatalog.defaultModel
      let settings = await modelSettingsStore.settings(for: selectedModel)
      await settingsState.load()

      applyAppBehaviorSettings(settingsState.appBehaviorSettings)
      defaultSessionModelID = selectedModel.id
      defaultSessionSystemPrompt = settings.systemPrompt
      defaultSessionGenerationSettings = settings.generationSettings
      let defaultSessionFactory = self.makeDefaultSessionFactory()
      await self.workspaceState.loadLibrary(defaultSessionFactory: defaultSessionFactory)
      self.loadActiveSession()
      self.attemptAutoloadLastModelIfReady()
    }
  }

  private func attemptAutoloadLastModelIfReady() {
    guard settingsState.appBehaviorSettings.autoloadLastModel,
      !didAttemptAutoloadLastModel,
      chatController.modelRuntime.modelState == .notLoaded,
      chatController.modelRuntime.isSelectedModelDownloaded()
    else {
      return
    }

    didAttemptAutoloadLastModel = true
    chatController.modelRuntime.loadSelectedModel()
  }

}
