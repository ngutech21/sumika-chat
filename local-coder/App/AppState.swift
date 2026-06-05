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
  private var workspaceLibraryController: WorkspaceLibraryController
  @ObservationIgnored private let workspaceStore: any WorkspaceStoring
  @ObservationIgnored private let modelSettingsStore: any ModelSettingsStoring
  @ObservationIgnored private var defaultSessionModelID = ManagedModelCatalog.defaultModel.id
  @ObservationIgnored private var defaultSessionSystemPrompt =
    ManagedModelCatalog.defaultModel.defaultSystemPrompt
  @ObservationIgnored private var defaultSessionGenerationSettings =
    ManagedModelCatalog.defaultModel.defaultGenerationSettings
  @ObservationIgnored private var saveLibraryTask: Task<Void, Never>?

  init(
    workspaceStore: any WorkspaceStoring = WorkspaceStore(),
    modelSettingsStore: any ModelSettingsStoring = ModelSettingsStore(),
    chatController: ChatSessionController? = nil
  ) {
    self.workspaceStore = workspaceStore
    self.modelSettingsStore = modelSettingsStore

    if let chatController {
      self.chatController = chatController
    } else {
      self.chatController = ChatSessionController(
        modelSettingsStore: modelSettingsStore,
        modelDownloader: HuggingFaceModelDownloader(),
        runtime: GemmaMLXRuntime(),
        turnTracer: GemmaDebugTraceStore.shared
      )
    }
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

  var activeWorkspace: Workspace? {
    workspaceLibraryController.activeWorkspace
  }

  var activeSession: CodingSession? {
    workspaceLibraryController.activeSession
  }

  var activeSessionID: CodingSession.ID? {
    workspaceLibraryController.activeSessionID
  }

  @discardableResult
  func addWorkspace(from url: URL) -> CodingSession.ID? {
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
  func createSession(in workspaceID: Workspace.ID? = nil) -> CodingSession.ID? {
    refreshDefaultSessionFactory()
    guard let sessionID = workspaceLibraryController.createSession(in: workspaceID) else {
      return nil
    }
    saveLibrary()
    loadActiveSession()
    return sessionID
  }

  func selectSession(_ sessionID: CodingSession.ID) {
    persistActiveSession()
    guard workspaceLibraryController.selectSession(sessionID) else {
      return
    }
    saveLibrary()
    loadActiveSession()
  }

  func renameSession(_ sessionID: CodingSession.ID, title: String) {
    guard workspaceLibraryController.renameSession(sessionID, title: title) else {
      return
    }
    saveLibrary()
  }

  func deleteSession(_ sessionID: CodingSession.ID) {
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

  private func refreshDefaultSessionFactory() {
    workspaceLibraryController.defaultSessionFactory = makeDefaultSessionFactory()
  }

  private func makeDefaultSessionFactory() -> DefaultCodingSessionFactory {
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
  ) -> DefaultCodingSessionFactory {
    DefaultCodingSessionFactory(
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
    Task { [modelSettingsStore, workspaceStore] in
      let availableModelIDs = Set(ManagedModelCatalog.models.map(\.id))
      let selectedModelID = await modelSettingsStore.selectedModelID(
        availableModelIDs: availableModelIDs)
      let selectedModel =
        ManagedModelCatalog.model(id: selectedModelID) ?? ManagedModelCatalog.defaultModel
      let settings = await modelSettingsStore.settings(for: selectedModel)
      let library = await workspaceStore.loadLibrary()

      defaultSessionModelID = selectedModel.id
      defaultSessionSystemPrompt = settings.systemPrompt
      defaultSessionGenerationSettings = settings.generationSettings
      self.refreshDefaultSessionFactory()
      self.workspaceLibraryController.replaceLibrary(library)
      self.normalizeLoadedLibrary()
      self.loadActiveSession()
      self.isWorkspaceLibraryLoading = false
    }
  }

  private func makeSecurityScopedBookmarkData(for url: URL) -> Data? {
    try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil)
  }
}
