import Foundation
import Observation

@MainActor
@Observable
final class AppState {
  var workspaceLibrary: WorkspaceLibrary
  var workspaceErrorMessage: String?

  @ObservationIgnored let chatController: ChatSessionController
  @ObservationIgnored private let workspaceStore: any WorkspaceStoring
  @ObservationIgnored private let modelSettingsStore: any ModelSettingsStoring

  init(
    workspaceStore: any WorkspaceStoring = WorkspaceStore(),
    modelSettingsStore: any ModelSettingsStoring = ModelSettingsStore(),
    chatController: ChatSessionController? = nil
  ) {
    self.workspaceStore = workspaceStore
    self.modelSettingsStore = modelSettingsStore
    self.workspaceLibrary = workspaceStore.loadLibrary()

    if let chatController {
      self.chatController = chatController
    } else {
      self.chatController = ChatSessionController(
        modelSettingsStore: modelSettingsStore
      )
    }

    normalizeLoadedLibrary()
    loadActiveSession()
    self.chatController.setSessionChangeHandler { [weak self] in
      self?.persistActiveSession()
    }
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
    let availableModelIDs = Set(ManagedModelCatalog.models.map(\.id))
    let selectedModelID = modelSettingsStore.selectedModelID(availableModelIDs: availableModelIDs)
    let selectedModel =
      ManagedModelCatalog.model(id: selectedModelID)
      ?? ManagedModelCatalog.defaultModel
    let settings = modelSettingsStore.settings(for: selectedModel)

    return CodingSession(
      selectedModelID: selectedModel.id,
      systemPrompt: settings.systemPrompt,
      generationSettings: settings.generationSettings
    )
  }

  private func saveLibrary() {
    do {
      try workspaceStore.saveLibrary(workspaceLibrary)
      workspaceErrorMessage = nil
    } catch {
      workspaceErrorMessage = error.localizedDescription
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
