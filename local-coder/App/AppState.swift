import Foundation
import Observation

@MainActor
@Observable
final class AppState {
  var workspaceLibrary: WorkspaceLibrary
  var workspaceErrorMessage: String?
  var isWorkspaceLibraryLoading = true

  @ObservationIgnored let chatController: ChatSessionController
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
    self.workspaceLibrary = WorkspaceLibrary()

    if let chatController {
      self.chatController = chatController
    } else {
      self.chatController = ChatSessionController(
        modelSettingsStore: modelSettingsStore
      )
    }

    self.chatController.setSessionChangeHandler { [weak self] in
      self?.persistActiveSession()
    }
    loadStoredLibrary()
  }

  var activeWorkspace: Workspace? {
    guard let activeWorkspaceID = workspaceLibrary.activeWorkspaceID else {
      return nil
    }

    return workspaceLibrary.workspaces.first { $0.id == activeWorkspaceID }
  }

  var activeSession: CodingSession? {
    guard
      let activeWorkspace,
      let activeSessionID = workspaceLibrary.activeSessionID
    else {
      return nil
    }

    return activeWorkspace.sessions.first { $0.id == activeSessionID }
  }

  var activeSessionID: CodingSession.ID? {
    workspaceLibrary.activeSessionID
  }

  @discardableResult
  func addWorkspace(from url: URL) -> CodingSession.ID? {
    let rootURL = url.standardizedFileURL.resolvingSymlinksInPath()
    let normalizedPath = Workspace.normalizedPath(for: rootURL)

    if let existingWorkspace = workspaceLibrary.workspaces.first(where: {
      $0.normalizedRootPath == normalizedPath
    }) {
      activateWorkspace(existingWorkspace.id)
      return workspaceLibrary.activeSessionID
    }

    let session = makeDefaultSession()
    let now = Date()
    let workspace = Workspace(
      name: rootURL.lastPathComponent,
      rootURL: rootURL,
      bookmarkData: makeSecurityScopedBookmarkData(for: rootURL),
      sessions: [session],
      createdAt: now,
      updatedAt: now
    )

    workspaceLibrary.workspaces.append(workspace)
    workspaceLibrary.activeWorkspaceID = workspace.id
    workspaceLibrary.activeSessionID = session.id
    saveLibrary()
    loadActiveSession()
    return session.id
  }

  @discardableResult
  func createSession(in workspaceID: Workspace.ID? = nil) -> CodingSession.ID? {
    guard
      let workspaceIndex = workspaceIndex(for: workspaceID ?? workspaceLibrary.activeWorkspaceID)
    else {
      return nil
    }

    let session = makeDefaultSession()
    workspaceLibrary.workspaces[workspaceIndex].sessions.append(session)
    workspaceLibrary.workspaces[workspaceIndex].updatedAt = Date()
    workspaceLibrary.activeWorkspaceID = workspaceLibrary.workspaces[workspaceIndex].id
    workspaceLibrary.activeSessionID = session.id
    saveLibrary()
    loadActiveSession()
    return session.id
  }

  func selectSession(_ sessionID: CodingSession.ID) {
    persistActiveSession()

    guard
      let workspaceIndex = workspaceLibrary.workspaces.firstIndex(where: { workspace in
        workspace.sessions.contains { $0.id == sessionID }
      })
    else {
      return
    }

    workspaceLibrary.activeWorkspaceID = workspaceLibrary.workspaces[workspaceIndex].id
    workspaceLibrary.activeSessionID = sessionID
    saveLibrary()
    loadActiveSession()
  }

  func renameSession(_ sessionID: CodingSession.ID, title: String) {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !trimmedTitle.isEmpty,
      let workspaceIndex = workspaceLibrary.workspaces.firstIndex(where: { workspace in
        workspace.sessions.contains { $0.id == sessionID }
      }),
      let sessionIndex = workspaceLibrary.workspaces[workspaceIndex].sessions.firstIndex(where: {
        $0.id == sessionID
      })
    else {
      return
    }

    let now = Date()
    workspaceLibrary.workspaces[workspaceIndex].sessions[sessionIndex].title = trimmedTitle
    workspaceLibrary.workspaces[workspaceIndex].sessions[sessionIndex].updatedAt = now
    workspaceLibrary.workspaces[workspaceIndex].updatedAt = now
    saveLibrary()
  }

  func deleteSession(_ sessionID: CodingSession.ID) {
    guard
      let workspaceIndex = workspaceLibrary.workspaces.firstIndex(where: { workspace in
        workspace.sessions.contains { $0.id == sessionID }
      })
    else {
      return
    }

    let wasActiveSession = workspaceLibrary.activeSessionID == sessionID
    workspaceLibrary.workspaces[workspaceIndex].sessions.removeAll { $0.id == sessionID }

    if workspaceLibrary.workspaces[workspaceIndex].sessions.isEmpty {
      let replacementSession = makeDefaultSession()
      workspaceLibrary.workspaces[workspaceIndex].sessions = [replacementSession]
      workspaceLibrary.activeWorkspaceID = workspaceLibrary.workspaces[workspaceIndex].id
      workspaceLibrary.activeSessionID = replacementSession.id
    } else if wasActiveSession {
      workspaceLibrary.activeWorkspaceID = workspaceLibrary.workspaces[workspaceIndex].id
      workspaceLibrary.activeSessionID =
        workspaceLibrary.workspaces[workspaceIndex].sessions.first?.id
    }

    workspaceLibrary.workspaces[workspaceIndex].updatedAt = Date()
    saveLibrary()

    if wasActiveSession {
      loadActiveSession()
    }
  }

  func persistActiveSession() {
    guard
      let workspaceIndex = activeWorkspaceIndex,
      let sessionIndex = activeSessionIndex(in: workspaceIndex)
    else {
      return
    }

    let currentSession = workspaceLibrary.workspaces[workspaceIndex].sessions[sessionIndex]
    workspaceLibrary.workspaces[workspaceIndex].sessions[sessionIndex] =
      chatController.sessionSnapshot(updating: currentSession)
    workspaceLibrary.workspaces[workspaceIndex].updatedAt = Date()
    saveLibrary()
  }

  private func normalizeLoadedLibrary() {
    workspaceLibrary.workspaces = workspaceLibrary.workspaces.map(resolveBookmarkedWorkspace)
    workspaceLibrary.workspaces = deduplicatedWorkspaces(workspaceLibrary.workspaces)

    if let activeWorkspaceID = workspaceLibrary.activeWorkspaceID,
      !workspaceLibrary.workspaces.contains(where: { $0.id == activeWorkspaceID })
    {
      workspaceLibrary.activeWorkspaceID = nil
      workspaceLibrary.activeSessionID = nil
    }

    if workspaceLibrary.activeWorkspaceID == nil {
      workspaceLibrary.activeWorkspaceID = workspaceLibrary.workspaces.first?.id
    }

    ensureActiveWorkspaceHasSession()

    if let activeWorkspaceIndex,
      let activeSessionID = workspaceLibrary.activeSessionID,
      !workspaceLibrary.workspaces[activeWorkspaceIndex].sessions.contains(where: {
        $0.id == activeSessionID
      })
    {
      workspaceLibrary.activeSessionID =
        workspaceLibrary.workspaces[activeWorkspaceIndex].sessions.first?.id
    }

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

  private func ensureActiveWorkspaceHasSession() {
    guard let activeWorkspaceIndex else {
      return
    }

    if workspaceLibrary.workspaces[activeWorkspaceIndex].sessions.isEmpty {
      let session = makeDefaultSession()
      workspaceLibrary.workspaces[activeWorkspaceIndex].sessions = [session]
      workspaceLibrary.activeSessionID = session.id
    } else if workspaceLibrary.activeSessionID == nil {
      workspaceLibrary.activeSessionID =
        workspaceLibrary.workspaces[activeWorkspaceIndex].sessions.first?.id
    }
  }

  private func activateWorkspace(_ workspaceID: Workspace.ID) {
    persistActiveSession()
    workspaceLibrary.activeWorkspaceID = workspaceID

    if let workspaceIndex = workspaceIndex(for: workspaceID) {
      if workspaceLibrary.workspaces[workspaceIndex].sessions.isEmpty {
        let session = makeDefaultSession()
        workspaceLibrary.workspaces[workspaceIndex].sessions = [session]
        workspaceLibrary.activeSessionID = session.id
      } else {
        workspaceLibrary.activeSessionID =
          workspaceLibrary.workspaces[workspaceIndex].sessions.first?.id
      }
    }

    saveLibrary()
    loadActiveSession()
  }

  private func loadActiveSession() {
    guard let activeSession else {
      return
    }

    chatController.loadSession(activeSession)
  }

  private func makeDefaultSession() -> CodingSession {
    if chatController.modelRuntime.selectedModelID != ManagedModelCatalog.defaultModelID
      || defaultSessionModelID == ManagedModelCatalog.defaultModelID
    {
      return CodingSession(
        selectedModelID: chatController.modelRuntime.selectedModelID,
        systemPrompt: chatController.chatSession.systemPrompt,
        generationSettings: chatController.chatSession.generationSettings
      )
    }

    return CodingSession(
      selectedModelID: defaultSessionModelID,
      systemPrompt: defaultSessionSystemPrompt,
      generationSettings: defaultSessionGenerationSettings
    )
  }

  private func saveLibrary() {
    let library = workspaceLibrary
    let previousSaveTask = saveLibraryTask
    saveLibraryTask = Task { [workspaceStore] in
      await previousSaveTask?.value
      do {
        try await workspaceStore.saveLibrary(library)
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
      self.workspaceLibrary = library
      self.normalizeLoadedLibrary()
      self.loadActiveSession()
      self.isWorkspaceLibraryLoading = false
    }
  }

  private func deduplicatedWorkspaces(_ workspaces: [Workspace]) -> [Workspace] {
    var seenPaths = Set<String>()
    var uniqueWorkspaces: [Workspace] = []

    for workspace in workspaces {
      guard !seenPaths.contains(workspace.normalizedRootPath) else {
        continue
      }

      seenPaths.insert(workspace.normalizedRootPath)
      uniqueWorkspaces.append(workspace)
    }

    return uniqueWorkspaces
  }

  private func workspaceIndex(for workspaceID: Workspace.ID?) -> Int? {
    guard let workspaceID else {
      return nil
    }

    return workspaceLibrary.workspaces.firstIndex { $0.id == workspaceID }
  }

  private var activeWorkspaceIndex: Int? {
    workspaceIndex(for: workspaceLibrary.activeWorkspaceID)
  }

  private func activeSessionIndex(in workspaceIndex: Int) -> Int? {
    guard let activeSessionID = workspaceLibrary.activeSessionID else {
      return nil
    }

    return workspaceLibrary.workspaces[workspaceIndex].sessions.firstIndex {
      $0.id == activeSessionID
    }
  }

  private func makeSecurityScopedBookmarkData(for url: URL) -> Data? {
    try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil)
  }
}
