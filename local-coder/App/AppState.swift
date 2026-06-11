import Foundation
import LocalCoderCore
import Observation

@MainActor
@Observable
final class AppState {
  var workspaceLibrary: WorkspaceLibrary {
    get { workspaceLibraryController.library }
    set { workspaceLibraryController.replaceLibrary(newValue) }
  }
  var workspaceErrorMessage: String?
  var isWorkspaceLibraryLoading = true

  @ObservationIgnored let chatController: ChatSessionController
  @ObservationIgnored let browserToolService: HTMLPreviewBrowserToolService
  private var workspaceLibraryController: WorkspaceLibraryController
  @ObservationIgnored private let workspaceStore: any WorkspaceStoring
  @ObservationIgnored private let modelSettingsStore: any ModelSettingsStoring
  @ObservationIgnored private let webAccessSettingsStore: any WebAccessSettingsStoring
  @ObservationIgnored private let appBehaviorSettingsStore: any AppBehaviorSettingsStoring
  @ObservationIgnored private var defaultSessionModelID = ManagedModelCatalog.defaultModel.id
  @ObservationIgnored private var defaultSessionSystemPrompt =
    ManagedModelCatalog.defaultModel.defaultSystemPrompt
  @ObservationIgnored private var defaultSessionGenerationSettings =
    ManagedModelCatalog.defaultModel.defaultGenerationSettings
  @ObservationIgnored private var saveLibraryTask: Task<Void, Never>?
  @ObservationIgnored private var saveWebAccessSettingsTask: Task<Void, Never>?
  @ObservationIgnored private var saveAppBehaviorSettingsTask: Task<Void, Never>?
  @ObservationIgnored private var didAttemptAutoloadLastModel = false
  var activeWebAccessSettings = WebAccessSettings.disabled
  var activeAppBehaviorSettings = AppBehaviorSettings()

  convenience init(
    workspaceStore: any WorkspaceStoring = WorkspaceStore(),
    modelSettingsStore: any ModelSettingsStoring = ModelSettingsStore(),
    webAccessSettingsStore: any WebAccessSettingsStoring = WebAccessSettingsStore(),
    appBehaviorSettingsStore: any AppBehaviorSettingsStoring = AppBehaviorSettingsStore(),
    modelDownloader: any ModelDownloading = HuggingFaceModelDownloader(),
    runtime: any ChatModelRuntime = GemmaMLXRuntime(),
    modelAvailability: @escaping @Sendable (ManagedModel) -> Bool =
      ModelLifecycleCoordinator.defaultModelAvailability,
    turnTracer: any TurnTracing = GemmaDebugTraceStore.shared
  ) {
    let browserToolService = HTMLPreviewBrowserToolService()
    self.init(
      workspaceStore: workspaceStore,
      modelSettingsStore: modelSettingsStore,
      webAccessSettingsStore: webAccessSettingsStore,
      appBehaviorSettingsStore: appBehaviorSettingsStore,
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
    browserToolService: HTMLPreviewBrowserToolService,
    chatController: ChatSessionController
  ) {
    self.workspaceStore = workspaceStore
    self.modelSettingsStore = modelSettingsStore
    self.webAccessSettingsStore = webAccessSettingsStore
    self.appBehaviorSettingsStore = appBehaviorSettingsStore
    self.browserToolService = browserToolService
    self.chatController = chatController
    self.workspaceLibraryController = WorkspaceLibraryController(
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
        executorRegistry: .codingAgent,
        browserToolService: browserToolService,
        webAccessSettingsProvider: {
          await webAccessSettingsStore.settings()
        }
      ),
      turnTracer: turnTracer
    )
  }

  var activeWorkspace: Workspace? {
    workspaceLibraryController.activeWorkspace
  }

  var activeSession: ChatSession? {
    workspaceLibraryController.activeSession
  }

  var activeSessionID: ChatSession.ID? {
    workspaceLibraryController.activeSessionID
  }

  @discardableResult
  func addWorkspace(from url: URL) -> ChatSession.ID? {
    let rootURL = url.standardizedFileURL.resolvingSymlinksInPath()
    persistActiveSession()
    refreshDefaultSessionFactory()
    let sessionID = workspaceLibraryController.addWorkspace(
      name: rootURL.lastPathComponent,
      rootURL: rootURL,
      bookmarkData: makeSecurityScopedBookmarkData(for: rootURL)
    )
    saveLibrary()
    loadActiveSession()
    return sessionID
  }

  @discardableResult
  func createSession(in workspaceID: Workspace.ID? = nil) -> ChatSession.ID? {
    refreshDefaultSessionFactory()
    guard let sessionID = workspaceLibraryController.createSession(in: workspaceID) else {
      return nil
    }
    saveLibrary()
    loadActiveSession()
    return sessionID
  }

  func selectSession(_ sessionID: ChatSession.ID) {
    persistActiveSession()
    guard workspaceLibraryController.selectSession(sessionID) else {
      return
    }
    saveLibrary()
    loadActiveSession()
  }

  func renameSession(_ sessionID: ChatSession.ID, title: String) {
    guard workspaceLibraryController.renameSession(sessionID, title: title) else {
      return
    }
    saveLibrary()
  }

  func deleteSession(_ sessionID: ChatSession.ID) {
    let wasActiveSession = workspaceLibrary.activeSessionID == sessionID
    refreshDefaultSessionFactory()
    guard workspaceLibraryController.deleteSession(sessionID) else {
      return
    }
    saveLibrary()

    if wasActiveSession {
      loadActiveSession()
    }
  }

  func updateActiveWebAccessSettings(_ settings: WebAccessSettings) {
    activeWebAccessSettings = settings
    let previousSaveTask = saveWebAccessSettingsTask
    saveWebAccessSettingsTask = Task { [webAccessSettingsStore] in
      await previousSaveTask?.value
      do {
        try await webAccessSettingsStore.save(settings: settings)
        await MainActor.run {
          workspaceErrorMessage = nil
        }
      } catch {
        await MainActor.run {
          workspaceErrorMessage = error.localizedDescription
        }
      }
    }
  }

  func updateActiveAppBehaviorSettings(_ settings: AppBehaviorSettings) {
    activeAppBehaviorSettings = settings
    let previousSaveTask = saveAppBehaviorSettingsTask
    saveAppBehaviorSettingsTask = Task { [appBehaviorSettingsStore] in
      await previousSaveTask?.value
      do {
        try await appBehaviorSettingsStore.save(settings: settings)
        await MainActor.run {
          workspaceErrorMessage = nil
        }
      } catch {
        await MainActor.run {
          workspaceErrorMessage = error.localizedDescription
        }
      }
    }
  }

  func startModelRuntimeServices() {
    chatController.modelRuntime.prepareDefaultModelDirectory()
    chatController.modelRuntime.startResourceMonitoring()
    attemptAutoloadLastModelIfReady()
  }

  func persistActiveSession() {
    guard
      let currentSession = activeSession
    else {
      return
    }

    workspaceLibraryController.persistActiveSessionSnapshot(
      chatController.sessionSnapshot(updating: currentSession)
    )
    saveLibrary()
  }

  private func normalizeLoadedLibrary() {
    let resolvedLibrary = WorkspaceLibrary(
      workspaces: workspaceLibrary.workspaces.map(resolveBookmarkedWorkspace),
      activeWorkspaceID: workspaceLibrary.activeWorkspaceID,
      activeSessionID: workspaceLibrary.activeSessionID
    )
    workspaceLibraryController.replaceLibrary(resolvedLibrary)
    workspaceLibraryController.normalizeLoadedLibrary()
    saveLibrary()
  }

  private func resolveBookmarkedWorkspace(_ workspace: Workspace) -> Workspace {
    guard let bookmarkData = workspace.bookmarkData else {
      return workspace
    }

    do {
      var isStale = false
      let resolvedURL = try URL(
        resolvingBookmarkData: bookmarkData,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      var resolvedWorkspace = workspace
      resolvedWorkspace.rootURL = resolvedURL.standardizedFileURL.resolvingSymlinksInPath()
      if isStale {
        resolvedWorkspace.bookmarkData = makeSecurityScopedBookmarkData(for: resolvedURL)
      }
      return resolvedWorkspace
    } catch {
      return workspace
    }
  }

  private func loadActiveSession() {
    guard let activeSession else {
      return
    }

    chatController.loadSession(activeSession)
  }

  private func loadWebAccessSettings() {
    Task { [webAccessSettingsStore] in
      activeWebAccessSettings = await webAccessSettingsStore.settings()
    }
  }

  private func refreshDefaultSessionFactory() {
    workspaceLibraryController.defaultSessionFactory = makeDefaultSessionFactory()
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

  private func saveLibrary() {
    let library = workspaceLibrary
    let previousSaveTask = saveLibraryTask
    saveLibraryTask = Task { [workspaceStore] in
      await previousSaveTask?.value
      do {
        let startedAt = Date()
        try await workspaceStore.saveLibrary(library)
        await GemmaDebugTraceStore.shared.traceTurnEvent(
          TurnTraceEvent(
            phase: .persist,
            durationMs: Date().timeIntervalSince(startedAt) * 1000
          )
        )
        await MainActor.run {
          workspaceErrorMessage = nil
        }
      } catch {
        await MainActor.run {
          workspaceErrorMessage = error.localizedDescription
        }
      }
    }
  }

  private func loadStoredLibrary() {
    Task { [modelSettingsStore, workspaceStore, appBehaviorSettingsStore] in
      let availableModelIDs = Set(ManagedModelCatalog.models.map(\.id))
      let selectedModelID = await modelSettingsStore.selectedModelID(
        availableModelIDs: availableModelIDs)
      let selectedModel =
        ManagedModelCatalog.model(id: selectedModelID) ?? ManagedModelCatalog.defaultModel
      let settings = await modelSettingsStore.settings(for: selectedModel)
      let appBehaviorSettings = await appBehaviorSettingsStore.settings()
      let library = await workspaceStore.loadLibrary()

      activeAppBehaviorSettings = appBehaviorSettings
      defaultSessionModelID = selectedModel.id
      defaultSessionSystemPrompt = settings.systemPrompt
      defaultSessionGenerationSettings = settings.generationSettings
      self.refreshDefaultSessionFactory()
      self.workspaceLibraryController.replaceLibrary(library)
      self.normalizeLoadedLibrary()
      self.loadActiveSession()
      self.loadWebAccessSettings()
      self.isWorkspaceLibraryLoading = false
      self.attemptAutoloadLastModelIfReady()
    }
  }

  private func attemptAutoloadLastModelIfReady() {
    guard activeAppBehaviorSettings.autoloadLastModel,
      !didAttemptAutoloadLastModel,
      chatController.modelRuntime.modelState == .notLoaded,
      chatController.modelRuntime.isSelectedModelDownloaded()
    else {
      return
    }

    didAttemptAutoloadLastModel = true
    chatController.modelRuntime.loadSelectedModel()
  }

  private func makeSecurityScopedBookmarkData(for url: URL) -> Data? {
    try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil)
  }
}
