import Foundation
import Observation
import SumikaCore

@MainActor
@Observable
final class AppState {
  let workspaceState: WorkspaceFeatureState
  let modelManagementState: ModelManagementFeatureState
  let settingsState: SettingsFeatureState
  let assistantSpeechService: AssistantSpeechService
  let audioModelController: ComposerAudioModelController
  let composerSpeechInputController: ComposerSpeechInputController
  let chatFeatureState: ChatFeatureState
  private(set) var route: AppRoute?
  @ObservationIgnored private let sumika: Sumika
  @ObservationIgnored let browserToolService: HTMLPreviewBrowserToolService
  @ObservationIgnored private let modelSettingsStore: any ModelSettingsStoring
  @ObservationIgnored private var defaultSessionModelID = ManagedModelCatalog.defaultModel.id
  @ObservationIgnored private var defaultSessionModeSettings =
    ManagedModelCatalog.defaultModel.defaultModeSettings
  @ObservationIgnored private var didAttemptAutoloadLastModel = false
  @ObservationIgnored private var routeWasAutomaticMissingModelRedirect = false

  convenience init(
    workspaceStore: any WorkspaceStoring = WorkspaceStore(),
    modelSettingsStore: any ModelSettingsStoring = ModelSettingsStore(),
    webAccessSettingsStore: any WebAccessSettingsStoring = WebAccessSettingsStore(),
    appBehaviorSettingsStore: any AppBehaviorSettingsStoring = AppBehaviorSettingsStore(),
    mcpServersStore: any MCPServersStoring = MCPServersStore(),
    runtime: any ChatModelRuntime,
    modelAvailability: (@Sendable (ManagedModel) -> Bool)? = nil,
    turnTracer: any TurnTracing = NoopTurnTracer(),
    workspaceOpener: any WorkspaceOpening = MacWorkspaceOpenService(),
    assistantSpeechService: AssistantSpeechService = AssistantSpeechService(),
    audioModelController: ComposerAudioModelController = ComposerAudioModelController()
  ) {
    let browserToolService = HTMLPreviewBrowserToolService()
    let sumika = AppLaunchConfiguration.makeSumika(
      modelSettingsStore: modelSettingsStore,
      runtime: runtime,
      modelAvailability: modelAvailability,
      browserToolService: browserToolService,
      webAccessSettingsProvider: {
        await webAccessSettingsStore.settings()
      },
      turnTracer: turnTracer
    )
    self.init(
      workspaceStore: workspaceStore,
      modelSettingsStore: modelSettingsStore,
      webAccessSettingsStore: webAccessSettingsStore,
      appBehaviorSettingsStore: appBehaviorSettingsStore,
      mcpServersStore: mcpServersStore,
      workspaceOpener: workspaceOpener,
      assistantSpeechService: assistantSpeechService,
      audioModelController: audioModelController,
      composerSpeechInputController: ComposerSpeechInputController(
        audioModelController: audioModelController
      ),
      browserToolService: browserToolService,
      sumika: sumika,
      turnTracer: turnTracer
    )
  }

  init(
    workspaceStore: any WorkspaceStoring = WorkspaceStore(),
    modelSettingsStore: any ModelSettingsStoring = ModelSettingsStore(),
    webAccessSettingsStore: any WebAccessSettingsStoring = WebAccessSettingsStore(),
    appBehaviorSettingsStore: any AppBehaviorSettingsStoring = AppBehaviorSettingsStore(),
    mcpServersStore: any MCPServersStoring = MCPServersStore(),
    workspaceOpener: any WorkspaceOpening = MacWorkspaceOpenService(),
    assistantSpeechService: AssistantSpeechService = AssistantSpeechService(),
    audioModelController: ComposerAudioModelController = ComposerAudioModelController(),
    composerSpeechInputController: ComposerSpeechInputController? = nil,
    browserToolService: HTMLPreviewBrowserToolService,
    sumika: Sumika,
    turnTracer: any TurnTracing
  ) {
    self.modelSettingsStore = modelSettingsStore
    self.browserToolService = browserToolService
    self.sumika = sumika
    self.chatFeatureState = ChatFeatureState(conversation: sumika.conversation)
    self.modelManagementState = ModelManagementFeatureState(models: sumika.models)
    self.assistantSpeechService = assistantSpeechService
    self.audioModelController = audioModelController
    self.composerSpeechInputController =
      composerSpeechInputController
      ?? ComposerSpeechInputController(audioModelController: audioModelController)
    self.settingsState = SettingsFeatureState(
      webAccessSettingsStore: webAccessSettingsStore,
      appBehaviorSettingsStore: appBehaviorSettingsStore,
      mcpServersStore: mcpServersStore
    )
    self.workspaceState = WorkspaceFeatureState(
      workspaceStore: workspaceStore,
      workspaceOpener: workspaceOpener,
      defaultSessionFactory: Self.defaultSessionFactory(
        selectedModelID: defaultSessionModelID,
        modeSettings: defaultSessionModeSettings
      ),
      turnTracer: turnTracer
    )

    self.sumika.conversation.setSessionChangeHandler { [weak self] session in
      self?.persistActiveSession(session)
      self?.reconcileMCPConnectionsIfNeeded()
    }
    self.sumika.agent.setStatusChangeHandler { [weak self] statuses in
      self?.settingsState.mcpServerStatuses = statuses
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

  @discardableResult
  func addWorkspace(from url: URL) -> Workspace.ID? {
    persistActiveSession()
    refreshDefaultSessionFactory()
    let change = workspaceState.addWorkspace(from: url)
    guard change.selectionChanged, let workspaceID = workspaceState.activeWorkspace?.id else {
      return nil
    }
    route = routeFromWorkspaceSelection()
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

  @discardableResult
  func sendMessage(
    prompt: String,
    in context: WorkspaceChatContext,
    sessionID: ChatSession.ID?
  ) -> Bool {
    if let sessionID {
      return sumika.conversation.sendMessage(
        prompt: prompt,
        in: context.workspace(containing: sessionID),
        sessionID: sessionID
      )
    }

    guard let createdSessionID = createSession(in: context.id) else {
      return false
    }
    return sumika.conversation.sendMessage(
      prompt: prompt,
      in: context.workspace(containing: createdSessionID),
      sessionID: createdSessionID
    )
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
    routeWasAutomaticMissingModelRedirect = false
    reconcileMCPConnectionsIfNeeded()
  }

  func renameSession(_ sessionID: ChatSession.ID, title: String) {
    guard
      !workspaceState.isPersistenceBlocked,
      workspaceState.activeSessionID == sessionID,
      sumika.conversation.state.sessionID == sessionID
    else {
      workspaceState.renameSession(sessionID, title: title)
      return
    }

    sumika.conversation.renameSession(to: title)
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

  func updateMCPServers(_ servers: [MCPServerConfig]) {
    settingsState.updateMCPServers(servers)
    reconcileMCPConnectionsIfNeeded(force: true)
  }

  func testMCPServer(_ serverID: UUID) {
    guard let config = settingsState.mcpServers.first(where: { $0.id == serverID }),
      config.isEnabled,
      let workspaceRootURL = workspaceState.activeWorkspace?.rootURL
    else {
      return
    }
    let isActiveServer = activeMCPServerIDs.contains(serverID)
    sumika.agent.testServer(
      server: config,
      workspaceRootURL: workspaceRootURL,
      reconnectActiveServer: isActiveServer
    ) { [weak self] result in
      guard let self else {
        return
      }
      switch result {
      case .success(.activeConnection(let state)):
        self.settingsState.mcpServerTestFeedback = MCPServerTestFeedback(
          message: Self.mcpTestMessage(serverName: config.name, state: state)
        )
      case .success(.isolatedConnection(let toolCount)):
        self.settingsState.mcpServerTestFeedback = MCPServerTestFeedback(
          message: Self.mcpTestSuccessMessage(serverName: config.name, toolCount: toolCount)
        )
      case .failure(let error):
        self.settingsState.mcpServerTestFeedback = MCPServerTestFeedback(
          message: "\(config.name) failed: \(error.localizedDescription)"
        )
      }
    }
  }

  func setSelectedMCPServerIDs(_ serverIDs: [UUID]) {
    let selection = normalizedMCPServerSelection(serverIDs)
    sumika.agent.setSelectedMCPServerIDs(selection)
    reconcileMCPConnectionsIfNeeded()
  }

  private func normalizedMCPServerSelection(_ serverIDs: [UUID]) -> [UUID] {
    let requestedIDs = Set(serverIDs)
    return settingsState.mcpServers.map(\.id).filter { requestedIDs.contains($0) }
  }

  private var activeMCPServerIDs: Set<UUID> {
    let conversation = sumika.conversation.state
    guard case .chat = route,
      conversation.composer.interactionMode == .agent
    else {
      return []
    }
    return Set(conversation.composer.selectedMCPServerIDs)
  }

  private func reconcileMCPConnectionsIfNeeded(force: Bool = false) {
    sumika.agent.reconcile(desiredAgentConnectionConfiguration(), force: force)
  }

  private func desiredAgentConnectionConfiguration() -> AgentConnectionConfiguration {
    let conversation = sumika.conversation.state
    guard case .chat(_, let sessionID) = route,
      conversation.sessionID == sessionID,
      conversation.composer.interactionMode == .agent,
      let workspaceRootURL = workspaceState.activeWorkspace?.rootURL
    else {
      return AgentConnectionConfiguration(servers: settingsState.mcpServers)
    }
    return AgentConnectionConfiguration(
      servers: settingsState.mcpServers,
      activeSessionID: sessionID,
      selectedServerIDs: normalizedMCPServerSelection(
        conversation.composer.selectedMCPServerIDs
      ),
      workspaceRootURL: workspaceRootURL
    )
  }

  private static func mcpTestMessage(
    serverName: String,
    state: MCPServerStatus.State?
  ) -> String {
    switch state {
    case .connected(let toolCount):
      return mcpTestSuccessMessage(serverName: serverName, toolCount: toolCount)
    case .failed(let message):
      return "\(serverName) failed: \(message)"
    case .connecting:
      return "\(serverName) is still connecting."
    case .disconnected, .none:
      return "\(serverName) is disconnected."
    }
  }

  private static func mcpTestSuccessMessage(serverName: String, toolCount: Int) -> String {
    let tools = toolCount == 1 ? "1 tool" : "\(toolCount) tools"
    return "\(serverName) connected successfully and advertised \(tools)."
  }

  func startModelRuntimeServices() {
    modelManagementState.startRuntimeServices()
    audioModelController.refreshAvailability()
    routeToModelsIfNoTextModelIsDownloaded()
    attemptAutoloadLastModelIfReady()
  }

  @discardableResult
  func persistActiveSession() -> Bool {
    persistActiveSession(sumika.conversation.snapshot())
  }

  @discardableResult
  private func persistActiveSession(_ session: ChatSession) -> Bool {
    guard
      let activeSessionID = workspaceState.activeSessionID,
      session.id == activeSessionID
    else {
      return false
    }

    workspaceState.persistActiveSessionSnapshot(session)
    return true
  }

  /// Runs on the termination path: snapshots the live session, waits until
  /// every queued library write has reached the store — the unstructured save
  /// tasks would otherwise die with the process — and terminates spawned MCP
  /// server processes so they do not outlive the app.
  func prepareForTermination() async {
    persistActiveSession()
    await workspaceState.flushPendingSaves()
    await sumika.agent.prepareForTermination()
  }

  private func loadRouteSession() {
    let session: ChatSession
    if case .chat = route, let activeSession = workspaceState.activeSession {
      session = activeSession
    } else {
      session = emptySessionForNoActiveWorkspace()
    }
    sumika.conversation.activate(session)
    let selection = normalizedMCPServerSelection(session.selectedMCPServerIDs)
    sumika.agent.reconcileSelectedMCPServerIDs(selection)
    reconcileMCPConnectionsIfNeeded()
  }

  private func applyAppBehaviorSettings(_ settings: AppBehaviorSettings) {
    sumika.agent.updateConfiguration(todoWriteEnabled: settings.todoWriteToolEnabled)
    audioModelController.applyPersistedSelection(settings.speechInputAudioModelID)
    if !settings.assistantSpeechEnabled {
      assistantSpeechService.stop()
    }
  }

  private func refreshDefaultSessionFactory() {
    workspaceState.updateDefaultSessionFactory(makeDefaultSessionFactory())
  }

  private func makeDefaultSessionFactory() -> DefaultChatSessionFactory {
    let selectedModelID = modelManagementState.state.selectedModel.id
    if selectedModelID != ManagedModelCatalog.defaultModelID
      || defaultSessionModelID == ManagedModelCatalog.defaultModelID
    {
      return Self.defaultSessionFactory(
        selectedModelID: selectedModelID,
        modeSettings: sumika.conversation.state.modeSettings
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
      await sumika.agent.loadServerConfiguration(settingsState.mcpServers)
      defaultSessionModelID = selectedModel.id
      defaultSessionModeSettings = settings.modeSettings
      let defaultSessionFactory = self.makeDefaultSessionFactory()
      await self.workspaceState.loadLibrary(defaultSessionFactory: defaultSessionFactory)
      if self.route != .models || self.routeWasAutomaticMissingModelRedirect {
        self.route = self.routeFromWorkspaceSelection()
        self.routeWasAutomaticMissingModelRedirect = false
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
    if modelManagementState.downloadedModels.isEmpty {
      persistActiveSession()
      route = .models
      routeWasAutomaticMissingModelRedirect = true
      reconcileMCPConnectionsIfNeeded()
    }
  }

  private func attemptAutoloadLastModelIfReady() {
    guard settingsState.appBehaviorSettings.autoloadLastModel,
      !didAttemptAutoloadLastModel,
      modelManagementState.state.modelState == .notLoaded,
      modelManagementState.isSelectedModelDownloaded()
    else {
      return
    }

    didAttemptAutoloadLastModel = true
    modelManagementState.loadSelectedModelForStartup()
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
