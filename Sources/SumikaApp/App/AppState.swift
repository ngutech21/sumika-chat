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
  @ObservationIgnored private var defaultSessionModelID = ManagedModelCatalog.defaultModel.id
  @ObservationIgnored private var defaultSessionModeSettings =
    ManagedModelCatalog.defaultModel.defaultModeSettings
  @ObservationIgnored private var didAttemptAutoloadLastModel = false
  @ObservationIgnored private var startupTask: Task<Void, Never>?

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
    let initialModelID = sumika.models.state.selectedModel.id
    let initialModeSettings = sumika.models.modeSettings
    self.browserToolService = browserToolService
    self.sumika = sumika
    self.modelManagementState = ModelManagementFeatureState(models: sumika.models)
    self.defaultSessionModelID = initialModelID
    self.defaultSessionModeSettings = initialModeSettings
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
    let workspaceState = WorkspaceFeatureState(
      workspaceStore: workspaceStore,
      workspaceOpener: workspaceOpener,
      defaultSessionFactory: Self.defaultSessionFactory(
        selectedModelID: defaultSessionModelID,
        modeSettings: defaultSessionModeSettings
      ),
      turnTracer: turnTracer
    )
    self.workspaceState = workspaceState
    self.chatFeatureState = ChatFeatureState(
      conversation: sumika.conversation,
      workspaceState: workspaceState
    )

    self.chatFeatureState.setConversationActivator { [weak self] workspaceID, sessionID in
      guard let self else {
        throw ConversationIntentError.inactive
      }
      _ = try self.activateConversation(workspaceID: workspaceID, sessionID: sessionID)
    }
    self.sumika.conversation.setSessionChangeHandler { [weak self] workspaceID, session in
      self?.persistSession(session, in: workspaceID)
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
    startupTask = Task { @MainActor [weak self] in
      await self?.loadStoredLibrary()
    }
  }

  @discardableResult
  func addWorkspace(from url: URL) -> Workspace.ID? {
    refreshDefaultSessionFactory()
    let change = workspaceState.addWorkspace(from: url)
    guard change.selectionChanged, let workspaceID = workspaceState.activeWorkspace?.id else {
      return nil
    }
    route = routeFromWorkspaceSelection()
    return workspaceID
  }

  @discardableResult
  func createSession(in workspaceID: Workspace.ID? = nil) -> ChatSession.ID? {
    refreshDefaultSessionFactory()
    let change = workspaceState.createSession(in: workspaceID)
    guard
      let sessionID = change.activeSessionID,
      let activeWorkspaceID = workspaceState.activeWorkspace?.id
    else {
      return nil
    }
    route = .chat(workspaceID: activeWorkspaceID, sessionID: sessionID)
    return sessionID
  }

  @discardableResult
  func sendMessage(prompt: String) -> Bool {
    do {
      guard let workspaceID = workspaceState.activeWorkspace?.id else {
        throw ConversationIntentError.inactive
      }
      _ = try activateConversation(
        workspaceID: workspaceID,
        sessionID: workspaceState.activeSessionID
      )
      try sumika.conversation.sendMessage(prompt: prompt)
      return true
    } catch {
      workspaceState.errorMessage = error.localizedDescription
      return false
    }
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
    route = .models
    reconcileMCPConnectionsIfNeeded()
  }

  func renameSession(_ sessionID: ChatSession.ID, title: String) {
    guard !workspaceState.isPersistenceBlocked else {
      return
    }
    guard sumika.conversation.state.active?.sessionID == sessionID else {
      workspaceState.renameSession(sessionID, title: title)
      return
    }

    _ = try? sumika.conversation.renameSession(to: title)
  }

  @discardableResult
  func selectWorkspace(_ workspaceID: Workspace.ID) -> Bool {
    let change = workspaceState.selectWorkspace(workspaceID)
    guard change.selectionChanged else {
      return false
    }
    route = .workspace(workspaceID)
    return true
  }

  @discardableResult
  func selectChat(workspaceID: Workspace.ID, sessionID: ChatSession.ID) -> Bool {
    let change = workspaceState.selectChat(workspaceID: workspaceID, sessionID: sessionID)
    guard change.selectionChanged else {
      return false
    }
    route = .chat(workspaceID: workspaceID, sessionID: sessionID)
    return true
  }

  func deleteSession(_ sessionID: ChatSession.ID) {
    let currentRoute = route
    if let active = sumika.conversation.state.active, active.sessionID == sessionID {
      guard !active.activity.isBusy else {
        workspaceState.errorMessage = "Wait for the active chat operation to finish."
        return
      }
      sumika.conversation.deactivate()
    }
    refreshDefaultSessionFactory()
    _ = workspaceState.deleteSession(sessionID)

    if case .chat(let workspaceID, let routedSessionID) = currentRoute,
      routedSessionID == sessionID
    {
      route = routeAfterRemovingActiveChat(in: workspaceID)
    }
  }

  func removeWorkspace(_ workspaceID: Workspace.ID) {
    let currentRoute = route
    if let active = sumika.conversation.state.active, active.workspaceID == workspaceID {
      guard !active.activity.isBusy else {
        workspaceState.errorMessage = "Wait for the active chat operation to finish."
        return
      }
      sumika.conversation.deactivate()
    }
    _ = workspaceState.removeWorkspace(workspaceID)

    if currentRoute?.workspaceID == workspaceID {
      route = routeFromWorkspaceSelection()
    }
  }

  func updateAppBehaviorSettings(_ settings: AppBehaviorSettings) {
    settingsState.updateAppBehaviorSettings(settings)
    applyAppBehaviorSettings(settings)
  }

  func updateMCPServers(_ servers: [MCPServerConfig]) {
    settingsState.updateMCPServers(servers)
    let availableServerIDs = Set(servers.map(\.id))
    workspaceState.retainSelectedMCPServerIDs(availableServerIDs)
    if let active = sumika.conversation.state.active {
      sumika.agent.reconcileSelectedMCPServerIDs(
        active.composer.selectedMCPServerIDs.filter(availableServerIDs.contains)
      )
    }
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
    guard let workspaceID = workspaceState.activeWorkspace?.id else {
      return
    }
    do {
      _ = try activateConversation(
        workspaceID: workspaceID,
        sessionID: workspaceState.activeSessionID
      )
    } catch {
      workspaceState.errorMessage = error.localizedDescription
      return
    }
    sumika.agent.setSelectedMCPServerIDs(selection)
    reconcileMCPConnectionsIfNeeded()
  }

  private func normalizedMCPServerSelection(_ serverIDs: [UUID]) -> [UUID] {
    let requestedIDs = Set(serverIDs)
    return settingsState.mcpServers.map(\.id).filter { requestedIDs.contains($0) }
  }

  private var activeMCPServerIDs: Set<UUID> {
    Set(desiredAgentConnectionConfiguration().selectedServerIDs)
  }

  private func reconcileMCPConnectionsIfNeeded(force: Bool = false) {
    sumika.agent.reconcile(desiredAgentConnectionConfiguration(), force: force)
  }

  private func desiredAgentConnectionConfiguration() -> AgentConnectionConfiguration {
    if let active = sumika.conversation.state.active, active.activity.isBusy {
      guard active.composer.interactionMode == .agent,
        let workspace = workspaceState.library.workspaces.first(where: {
          $0.id == active.workspaceID
        })
      else {
        return AgentConnectionConfiguration(servers: settingsState.mcpServers)
      }
      return AgentConnectionConfiguration(
        servers: settingsState.mcpServers,
        activeSessionID: active.sessionID,
        selectedServerIDs: normalizedMCPServerSelection(
          active.composer.selectedMCPServerIDs
        ),
        workspaceRootURL: workspace.rootURL
      )
    }

    guard case .chat(_, let sessionID) = route,
      let workspace = workspaceState.activeWorkspace,
      let session = workspace.sessions.first(where: { $0.id == sessionID }),
      session.interactionMode == .agent
    else {
      return AgentConnectionConfiguration(servers: settingsState.mcpServers)
    }
    return AgentConnectionConfiguration(
      servers: settingsState.mcpServers,
      activeSessionID: sessionID,
      selectedServerIDs: normalizedMCPServerSelection(
        session.selectedMCPServerIDs
      ),
      workspaceRootURL: workspace.rootURL
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

  func waitForStartup() async {
    await startupTask?.value
  }

  @discardableResult
  private func persistSession(
    _ session: ChatSession,
    in workspaceID: Workspace.ID
  ) -> Bool {
    guard workspaceState.workspace(id: workspaceID, containing: session.id) != nil else {
      return false
    }

    workspaceState.persistSessionSnapshot(session, in: workspaceID)
    return true
  }

  /// Runs on the termination path: snapshots the live session, waits until
  /// every queued library write has reached the store — the unstructured save
  /// tasks would otherwise die with the process — and terminates spawned MCP
  /// server processes so they do not outlive the app.
  func prepareForTermination() async {
    sumika.conversation.deactivate()
    await workspaceState.flushPendingSaves()
    await sumika.agent.prepareForTermination()
  }

  @discardableResult
  private func activateConversation(
    workspaceID: Workspace.ID,
    sessionID requestedSessionID: ChatSession.ID?
  ) throws -> ChatSession.ID {
    let sessionID: ChatSession.ID
    if let requestedSessionID {
      sessionID = requestedSessionID
    } else if let selectedSessionID = workspaceState.activeSessionID,
      workspaceState.workspace(id: workspaceID, containing: selectedSessionID) != nil
    {
      sessionID = selectedSessionID
    } else if let createdSessionID = createSession(in: workspaceID) {
      sessionID = createdSessionID
    } else {
      throw ConversationIntentError.sessionCreationFailed(workspaceID: workspaceID)
    }

    guard let workspace = workspaceState.workspace(id: workspaceID, containing: sessionID) else {
      throw ConversationIntentError.sessionNotFound(
        workspaceID: workspaceID,
        sessionID: sessionID
      )
    }

    try sumika.conversation.activate(sessionID: sessionID, in: workspace)
    let selection = normalizedMCPServerSelection(
      workspace.sessions.first(where: { $0.id == sessionID })?.selectedMCPServerIDs ?? []
    )
    sumika.agent.reconcileSelectedMCPServerIDs(selection)
    reconcileMCPConnectionsIfNeeded()
    return sessionID
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
        modeSettings: modelManagementState.modeSettings
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

  private func loadStoredLibrary() async {
    await modelManagementState.initialize()
    audioModelController.refreshAvailability()
    await settingsState.load()

    applyAppBehaviorSettings(settingsState.appBehaviorSettings)
    await sumika.agent.loadServerConfiguration(settingsState.mcpServers)
    let defaultSessionFactory = makeDefaultSessionFactory()
    await workspaceState.loadLibrary(defaultSessionFactory: defaultSessionFactory)
    workspaceState.retainSelectedMCPServerIDs(
      Set(settingsState.mcpServers.map(\.id))
    )
    if route != .models {
      route = routeFromWorkspaceSelection()
    }
    routeToModelsIfNoTextModelIsDownloaded()
    reconcileMCPConnectionsIfNeeded()
    attemptAutoloadLastModelIfReady()
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
    guard modelManagementState.downloadedModels.isEmpty, route == nil else {
      return
    }
    route = .models
    reconcileMCPConnectionsIfNeeded()
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
