import Foundation
import Observation
import SumikaCore

@MainActor
@Observable
final class AppState {
  let workspaceState: WorkspaceFeatureState
  let settingsState: SettingsFeatureState
  let assistantSpeechService: AssistantSpeechService
  let audioModelController: ComposerAudioModelController
  let composerSpeechInputController: ComposerSpeechInputController
  @ObservationIgnored let chatController: ChatSessionController
  @ObservationIgnored let browserToolService: HTMLPreviewBrowserToolService
  @ObservationIgnored private let modelSettingsStore: any ModelSettingsStoring
  @ObservationIgnored private var defaultSessionModelID = ManagedModelCatalog.defaultModel.id
  @ObservationIgnored private var defaultSessionModeSettings =
    ManagedModelCatalog.defaultModel.defaultModeSettings
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
    workspaceOpener: any WorkspaceOpening = MacWorkspaceOpenService(),
    assistantSpeechService: AssistantSpeechService = AssistantSpeechService(),
    audioModelController: ComposerAudioModelController = ComposerAudioModelController()
  ) {
    let browserToolService = HTMLPreviewBrowserToolService()
    self.init(
      workspaceStore: workspaceStore,
      modelSettingsStore: modelSettingsStore,
      webAccessSettingsStore: webAccessSettingsStore,
      appBehaviorSettingsStore: appBehaviorSettingsStore,
      workspaceOpener: workspaceOpener,
      assistantSpeechService: assistantSpeechService,
      audioModelController: audioModelController,
      composerSpeechInputController: ComposerSpeechInputController(
        audioModelController: audioModelController
      ),
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
    assistantSpeechService: AssistantSpeechService = AssistantSpeechService(),
    audioModelController: ComposerAudioModelController = ComposerAudioModelController(),
    composerSpeechInputController: ComposerSpeechInputController? = nil,
    browserToolService: HTMLPreviewBrowserToolService,
    chatController: ChatSessionController
  ) {
    self.modelSettingsStore = modelSettingsStore
    self.browserToolService = browserToolService
    self.chatController = chatController
    self.assistantSpeechService = assistantSpeechService
    self.audioModelController = audioModelController
    self.composerSpeechInputController =
      composerSpeechInputController
      ?? ComposerSpeechInputController(audioModelController: audioModelController)
    self.settingsState = SettingsFeatureState(
      webAccessSettingsStore: webAccessSettingsStore,
      appBehaviorSettingsStore: appBehaviorSettingsStore
    )
    self.workspaceState = WorkspaceFeatureState(
      workspaceStore: workspaceStore,
      workspaceOpener: workspaceOpener,
      defaultSessionFactory: Self.defaultSessionFactory(
        selectedModelID: defaultSessionModelID,
        modeSettings: defaultSessionModeSettings
      )
    )

    self.chatController.setSessionChangeHandler { [weak self] in
      self?.persistActiveSession()
    }
    self.audioModelController.onSelectionChanged = { [weak self] modelID in
      guard let self else {
        return
      }
      var settings = self.settingsState.appBehaviorSettings
      settings.speechInputAudioModelID = modelID.rawValue
      self.updateAppBehaviorSettings(settings)
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

  @discardableResult
  func selectWorkspace(_ workspaceID: Workspace.ID) -> ChatSession.ID? {
    persistActiveSession()
    let change = workspaceState.selectWorkspace(workspaceID)
    loadActiveSession(ifNeededFor: change)
    return change.activeSessionID
  }

  func deleteSession(_ sessionID: ChatSession.ID) {
    persistActiveSession()
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
    audioModelController.refreshAvailability()
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
    audioModelController.applyPersistedSelection(settings.speechInputAudioModelID)
    if !settings.assistantSpeechEnabled {
      assistantSpeechService.stop()
    }
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
        modeSettings: chatController.chatSession.modeSettings
      )
    }

    return Self.defaultSessionFactory(
      selectedModelID: defaultSessionModelID,
      modeSettings: defaultSessionModeSettings
    )
  }

  private static func defaultSessionFactory(
    selectedModelID: ManagedModel.ID,
    modeSettings: ChatModeSettingsSet
  ) -> DefaultChatSessionFactory {
    DefaultChatSessionFactory(
      selectedModelID: selectedModelID,
      modeSettings: modeSettings,
      interactionMode: .chat
    )
  }

  private func emptySessionForNoActiveWorkspace() -> ChatSession {
    Self.defaultSessionFactory(
      selectedModelID: defaultSessionModelID,
      modeSettings: defaultSessionModeSettings
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
      defaultSessionModeSettings = settings.modeSettings
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
