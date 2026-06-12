import Foundation

public struct DefaultChatSessionFactory: Equatable, Sendable {
  public var selectedModelID: ManagedModel.ID
  public var systemPrompt: String
  public var generationSettings: ChatGenerationSettings
  public var interactionMode: WorkspaceInteractionMode

  public init(
    selectedModelID: ManagedModel.ID,
    systemPrompt: String,
    generationSettings: ChatGenerationSettings,
    interactionMode: WorkspaceInteractionMode = .chat
  ) {
    self.selectedModelID = selectedModelID
    self.systemPrompt = systemPrompt
    self.generationSettings = generationSettings
    self.interactionMode = interactionMode
  }

  public func makeSession(
    title: String = ChatSession.defaultTitle,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) -> ChatSession {
    ChatSession(
      title: title,
      selectedModelID: selectedModelID,
      systemPrompt: systemPrompt,
      generationSettings: generationSettings,
      interactionMode: interactionMode,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}

public struct WorkspaceLibraryController {
  public private(set) var library: WorkspaceLibrary
  public var defaultSessionFactory: DefaultChatSessionFactory

  private let now: () -> Date

  public init(
    library: WorkspaceLibrary = WorkspaceLibrary(),
    defaultSessionFactory: DefaultChatSessionFactory,
    now: @escaping () -> Date = Date.init
  ) {
    self.library = library
    self.defaultSessionFactory = defaultSessionFactory
    self.now = now
  }

  public var activeWorkspace: Workspace? {
    guard let activeWorkspaceID = library.activeWorkspaceID else {
      return nil
    }

    return library.workspaces.first { $0.id == activeWorkspaceID }
  }

  public var activeSession: ChatSession? {
    guard
      let activeWorkspace,
      let activeSessionID = library.activeSessionID
    else {
      return nil
    }

    return activeWorkspace.sessions.first { $0.id == activeSessionID }
  }

  public var activeSessionID: ChatSession.ID? {
    library.activeSessionID
  }

  @discardableResult
  public mutating func addWorkspace(
    name: String,
    rootURL: URL,
    bookmarkData: Data? = nil
  ) -> ChatSession.ID? {
    let normalizedRootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    let normalizedPath = Workspace.normalizedPath(for: normalizedRootURL)

    if let existingWorkspace = library.workspaces.first(where: {
      $0.normalizedRootPath == normalizedPath
    }) {
      activateWorkspace(existingWorkspace.id)
      return library.activeSessionID
    }

    let currentDate = now()
    let session = makeDefaultSession(createdAt: currentDate, updatedAt: currentDate)
    let workspace = Workspace(
      name: name,
      rootURL: normalizedRootURL,
      bookmarkData: bookmarkData,
      sessions: [session],
      createdAt: currentDate,
      updatedAt: currentDate
    )

    library.workspaces.append(workspace)
    library.activeWorkspaceID = workspace.id
    library.activeSessionID = session.id
    return session.id
  }

  @discardableResult
  public mutating func createSession(in workspaceID: Workspace.ID? = nil) -> ChatSession.ID? {
    guard
      let workspaceIndex = workspaceIndex(for: workspaceID ?? library.activeWorkspaceID)
    else {
      return nil
    }

    let currentDate = now()
    let session = makeDefaultSession(createdAt: currentDate, updatedAt: currentDate)
    library.workspaces[workspaceIndex].sessions.append(session)
    library.workspaces[workspaceIndex].updatedAt = currentDate
    library.activeWorkspaceID = library.workspaces[workspaceIndex].id
    library.activeSessionID = session.id
    return session.id
  }

  @discardableResult
  public mutating func selectSession(_ sessionID: ChatSession.ID) -> Bool {
    guard
      let workspaceIndex = library.workspaces.firstIndex(where: { workspace in
        workspace.sessions.contains { $0.id == sessionID }
      })
    else {
      return false
    }

    library.activeWorkspaceID = library.workspaces[workspaceIndex].id
    library.activeSessionID = sessionID
    return true
  }

  @discardableResult
  public mutating func renameSession(_ sessionID: ChatSession.ID, title: String) -> Bool {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !trimmedTitle.isEmpty,
      let workspaceIndex = library.workspaces.firstIndex(where: { workspace in
        workspace.sessions.contains { $0.id == sessionID }
      }),
      let sessionIndex = library.workspaces[workspaceIndex].sessions.firstIndex(where: {
        $0.id == sessionID
      })
    else {
      return false
    }

    let currentDate = now()
    library.workspaces[workspaceIndex].sessions[sessionIndex].title = trimmedTitle
    library.workspaces[workspaceIndex].sessions[sessionIndex].updatedAt = currentDate
    library.workspaces[workspaceIndex].updatedAt = currentDate
    return true
  }

  @discardableResult
  public mutating func deleteSession(_ sessionID: ChatSession.ID) -> Bool {
    guard
      let workspaceIndex = library.workspaces.firstIndex(where: { workspace in
        workspace.sessions.contains { $0.id == sessionID }
      })
    else {
      return false
    }

    let wasActiveSession = library.activeSessionID == sessionID
    library.workspaces[workspaceIndex].sessions.removeAll { $0.id == sessionID }

    if library.workspaces[workspaceIndex].sessions.isEmpty {
      let currentDate = now()
      let replacementSession = makeDefaultSession(createdAt: currentDate, updatedAt: currentDate)
      library.workspaces[workspaceIndex].sessions = [replacementSession]
      library.activeWorkspaceID = library.workspaces[workspaceIndex].id
      library.activeSessionID = replacementSession.id
    } else if wasActiveSession {
      library.activeWorkspaceID = library.workspaces[workspaceIndex].id
      library.activeSessionID = library.workspaces[workspaceIndex].sessions.first?.id
    }

    library.workspaces[workspaceIndex].updatedAt = now()
    return true
  }

  public mutating func replaceLibrary(_ library: WorkspaceLibrary) {
    self.library = library
  }

  public mutating func normalizeLoadedLibrary() {
    library.workspaces = deduplicatedWorkspaces(library.workspaces)

    if let activeWorkspaceID = library.activeWorkspaceID,
      !library.workspaces.contains(where: { $0.id == activeWorkspaceID })
    {
      library.activeWorkspaceID = nil
      library.activeSessionID = nil
    }

    if library.activeWorkspaceID == nil {
      library.activeWorkspaceID = library.workspaces.first?.id
    }

    ensureActiveWorkspaceHasSession()

    if let activeWorkspaceIndex,
      let activeSessionID = library.activeSessionID,
      !library.workspaces[activeWorkspaceIndex].sessions.contains(where: {
        $0.id == activeSessionID
      })
    {
      library.activeSessionID = library.workspaces[activeWorkspaceIndex].sessions.first?.id
    }
  }

  public mutating func persistActiveSessionSnapshot(_ snapshot: ChatSession) {
    guard
      let workspaceIndex = activeWorkspaceIndex,
      let sessionIndex = activeSessionIndex(in: workspaceIndex)
    else {
      return
    }

    library.workspaces[workspaceIndex].sessions[sessionIndex] = snapshot
    library.workspaces[workspaceIndex].updatedAt = now()
  }

  private mutating func activateWorkspace(_ workspaceID: Workspace.ID) {
    library.activeWorkspaceID = workspaceID

    if let workspaceIndex = workspaceIndex(for: workspaceID) {
      if library.workspaces[workspaceIndex].sessions.isEmpty {
        let currentDate = now()
        let session = makeDefaultSession(createdAt: currentDate, updatedAt: currentDate)
        library.workspaces[workspaceIndex].sessions = [session]
        library.activeSessionID = session.id
      } else {
        library.activeSessionID = library.workspaces[workspaceIndex].sessions.first?.id
      }
    }
  }

  private mutating func ensureActiveWorkspaceHasSession() {
    guard let activeWorkspaceIndex else {
      return
    }

    if library.workspaces[activeWorkspaceIndex].sessions.isEmpty {
      let currentDate = now()
      let session = makeDefaultSession(createdAt: currentDate, updatedAt: currentDate)
      library.workspaces[activeWorkspaceIndex].sessions = [session]
      library.activeSessionID = session.id
    } else if library.activeSessionID == nil {
      library.activeSessionID = library.workspaces[activeWorkspaceIndex].sessions.first?.id
    }
  }

  private func makeDefaultSession(createdAt: Date, updatedAt: Date) -> ChatSession {
    defaultSessionFactory.makeSession(createdAt: createdAt, updatedAt: updatedAt)
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

    return library.workspaces.firstIndex { $0.id == workspaceID }
  }

  private var activeWorkspaceIndex: Int? {
    workspaceIndex(for: library.activeWorkspaceID)
  }

  private func activeSessionIndex(in workspaceIndex: Int) -> Int? {
    guard let activeSessionID = library.activeSessionID else {
      return nil
    }

    return library.workspaces[workspaceIndex].sessions.firstIndex {
      $0.id == activeSessionID
    }
  }
}
