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
  private(set) var route: AppRoute?
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
  func addWorkspace(from url: URL) -> Workspace.ID? {
    persistActiveSession()
    refreshDefaultSessionFactory()
    let change = workspaceState.addWorkspace(from: url)
    guard change.selectionChanged, let workspaceID = workspaceState.activeWorkspace?.id else {
      return nil
    }
    route = .workspace(workspaceID)
    loadRouteSession()
    return workspaceID
  }

  @discardableResult
  func createSession(in workspaceID: Workspace.ID? = nil) -> ChatSession.ID? {
    persistActiveSession()
    refreshDefaultSessionFactory()
    let change = workspaceState.createSession(in: workspaceID)
    guard
      let sessionID = change.activeSessionID,
      let activeWorkspaceID = workspaceState.activeWorkspace?.id
    else {
      return nil
    }
    route = .chat(workspaceID: activeWorkspaceID, sessionID: sessionID)
    loadRouteSession()
    return sessionID
  }

  func navigate(to requestedRoute: AppRoute?) {
    guard let requestedRoute else {
      return
    }

    switch requestedRoute {
    case .models:
      selectModels()
    case .workspace(let workspaceID):
      selectWorkspace(workspaceID)
    case .chat(let workspaceID, let sessionID):
      selectChat(workspaceID: workspaceID, sessionID: sessionID)
    }
  }

  func selectModels() {
    persistActiveSession()
    route = .models
  }

  func renameSession(_ sessionID: ChatSession.ID, title: String) {
    workspaceState.renameSession(sessionID, title: title)

    guard
      chatController.chatSession.id == sessionID,
      let renamedSession = workspaceState.library.workspaces
        .flatMap(\.sessions)
        .first(where: { $0.id == sessionID })
    else {
      return
    }

    chatController.chatSession.title = renamedSession.title
  }

  @discardableResult
  func selectWorkspace(_ workspaceID: Workspace.ID) -> Bool {
    persistActiveSession()
    let change = workspaceState.selectWorkspace(workspaceID)
    guard change.selectionChanged else {
      return false
    }
    route = .workspace(workspaceID)
    loadRouteSession()
    return true
  }

  @discardableResult
  func selectChat(workspaceID: Workspace.ID, sessionID: ChatSession.ID) -> Bool {
    persistActiveSession()
    let change = workspaceState.selectChat(workspaceID: workspaceID, sessionID: sessionID)
    guard change.selectionChanged else {
      return false
    }
    route = .chat(workspaceID: workspaceID, sessionID: sessionID)
    loadRouteSession()
    return true
  }

  func deleteSession(_ sessionID: ChatSession.ID) {
    let currentRoute = route
    persistActiveSession()
    refreshDefaultSessionFactory()
    _ = workspaceState.deleteSession(sessionID)

    if case .chat(let workspaceID, let routedSessionID) = currentRoute,
      routedSessionID == sessionID
    {
      route = routeAfterRemovingActiveChat(in: workspaceID)
      loadRouteSession()
    }
  }

  func removeWorkspace(_ workspaceID: Workspace.ID) {
    let currentRoute = route
    persistActiveSession()
    _ = workspaceState.removeWorkspace(workspaceID)

    if currentRoute?.workspaceID == workspaceID {
      route = routeFromWorkspaceSelection()
      loadRouteSession()
    }
  }

  func updateAppBehaviorSettings(_ settings: AppBehaviorSettings) {
    settingsState.updateAppBehaviorSettings(settings)
    applyAppBehaviorSettings(settings)
  }

  func startModelRuntimeServices() {
    chatController.modelRuntime.prepareDefaultModelDirectory()
    chatController.modelRuntime.startResourceMonitoring()
    audioModelController.refreshAvailability()
    routeToModelsIfNoTextModelIsDownloaded()
    attemptAutoloadLastModelIfReady()
  }

  @discardableResult
  func persistActiveSession() -> Bool {
    guard
      let currentSession = workspaceState.activeSession,
      chatController.chatSession.id == currentSession.id
    else {
      return false
    }

    workspaceState.persistActiveSessionSnapshot(
      chatController.sessionSnapshot(updating: currentSession)
    )
    return true
  }

  private func loadRouteSession() {
    guard
      case .chat = route,
      let activeSession = workspaceState.activeSession
    else {
      chatController.loadSession(emptySessionForNoActiveWorkspace())
      return
    }

    chatController.loadSession(activeSession)
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
      if self.route != .models {
        self.route = self.routeFromWorkspaceSelection()
      }
      self.loadRouteSession()
      self.attemptAutoloadLastModelIfReady()
    }
  }

  private func routeFromWorkspaceSelection() -> AppRoute? {
    guard let workspaceID = workspaceState.activeWorkspace?.id else {
      return nil
    }

    if let sessionID = workspaceState.activeSessionID {
      return .chat(workspaceID: workspaceID, sessionID: sessionID)
    }

    return .workspace(workspaceID)
  }

  private func routeAfterRemovingActiveChat(in workspaceID: Workspace.ID) -> AppRoute? {
    if workspaceState.library.workspaces.contains(where: { $0.id == workspaceID }) {
      return .workspace(workspaceID)
    }

    return routeFromWorkspaceSelection()
  }

  private func routeToModelsIfNoTextModelIsDownloaded() {
    let modelRuntime = chatController.modelRuntime
    let hasDownloadedModel = modelRuntime.availableModels.contains {
      modelRuntime.isModelDownloaded($0)
    }
    if !hasDownloadedModel {
      selectModels()
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

extension AppRoute {
  fileprivate var workspaceID: Workspace.ID? {
    switch self {
    case .models:
      nil
    case .workspace(let workspaceID):
      workspaceID
    case .chat(let workspaceID, _):
      workspaceID
    }
  }
}
