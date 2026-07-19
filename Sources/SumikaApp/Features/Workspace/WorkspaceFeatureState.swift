import Foundation
import Observation
import SumikaCore

struct WorkspaceSelectionChange: Equatable {
  let selectionChanged: Bool
  let activeSessionID: ChatSession.ID?

  static let unchanged = WorkspaceSelectionChange(
    selectionChanged: false,
    activeSessionID: nil
  )

  static func changed(_ activeSessionID: ChatSession.ID?) -> WorkspaceSelectionChange {
    WorkspaceSelectionChange(
      selectionChanged: true,
      activeSessionID: activeSessionID
    )
  }
}

@MainActor
@Observable
final class WorkspaceFeatureState {
  var errorMessage: String?
  var isLoading = true
  private(set) var isPersistenceBlocked = false
  private(set) var activeWorkspaceContext: WorkspaceChatContext?
  private(set) var activeSessionID: ChatSession.ID?
  private(set) var sidebarState = WorkspaceSidebarState()

  var library: WorkspaceLibrary {
    workspaceLibraryController.library
  }

  var activeWorkspace: Workspace? {
    workspaceLibraryController.activeWorkspace
  }

  var activeSession: ChatSession? {
    workspaceLibraryController.activeSession
  }

  private var workspaceLibraryController: WorkspaceLibraryController
  @ObservationIgnored private let workspaceStore: any WorkspaceStoring
  @ObservationIgnored private let workspaceOpener: any WorkspaceOpening
  @ObservationIgnored private let turnTracer: any TurnTracing
  @ObservationIgnored private var saveLibraryTask: Task<Void, Never>?
  @ObservationIgnored private var errorMessageReflectsSaveFailure = false

  init(
    workspaceStore: any WorkspaceStoring,
    workspaceOpener: any WorkspaceOpening,
    defaultSessionFactory: DefaultChatSessionFactory,
    turnTracer: any TurnTracing
  ) {
    self.workspaceStore = workspaceStore
    self.workspaceOpener = workspaceOpener
    self.turnTracer = turnTracer
    self.workspaceLibraryController = WorkspaceLibraryController(
      defaultSessionFactory: defaultSessionFactory
    )
  }

  func updateDefaultSessionFactory(_ defaultSessionFactory: DefaultChatSessionFactory) {
    workspaceLibraryController.defaultSessionFactory = defaultSessionFactory
  }

  @discardableResult
  func loadLibrary(defaultSessionFactory: DefaultChatSessionFactory) async
    -> WorkspaceSelectionChange
  {
    updateDefaultSessionFactory(defaultSessionFactory)
    let loadResult = await workspaceStore.loadLibrary()
    isPersistenceBlocked = !loadResult.canPersist
    workspaceLibraryController.replaceLibrary(loadResult.library)
    normalizeLoadedLibrary(
      persistNormalization: loadResult.canPersist
    )
    syncWorkspaceProjections()
    if let loadIssueMessage = Self.loadIssueMessage(for: loadResult.issues) {
      errorMessage = loadIssueMessage
      errorMessageReflectsSaveFailure = false
    }
    isLoading = false
    return .changed(activeSessionID)
  }

  @discardableResult
  func addWorkspace(from url: URL) -> WorkspaceSelectionChange {
    guard !isPersistenceBlocked else {
      return .unchanged
    }
    let rootURL = url.standardizedFileURL.resolvingSymlinksInPath()
    let workspaceID = workspaceLibraryController.addWorkspace(
      name: rootURL.lastPathComponent,
      rootURL: rootURL,
      bookmarkData: makeSecurityScopedBookmarkData(for: rootURL)
    )
    syncWorkspaceProjections()
    saveLibrary()
    return workspaceID == nil ? .unchanged : .changed(activeSessionID)
  }

  @discardableResult
  func createSession(in workspaceID: Workspace.ID? = nil) -> WorkspaceSelectionChange {
    guard !isPersistenceBlocked else {
      return .unchanged
    }
    guard let sessionID = workspaceLibraryController.createSession(in: workspaceID) else {
      return .unchanged
    }
    syncWorkspaceProjections()
    saveLibrary()
    return .changed(sessionID)
  }

  @discardableResult
  func selectChat(
    workspaceID: Workspace.ID,
    sessionID: ChatSession.ID
  ) -> WorkspaceSelectionChange {
    guard !isPersistenceBlocked else {
      return .unchanged
    }
    guard workspaceLibraryController.selectChat(workspaceID: workspaceID, sessionID: sessionID)
    else {
      return .unchanged
    }
    syncWorkspaceProjections()
    saveLibrary()
    return .changed(activeSessionID)
  }

  @discardableResult
  func selectWorkspace(_ workspaceID: Workspace.ID) -> WorkspaceSelectionChange {
    guard !isPersistenceBlocked else {
      return .unchanged
    }
    guard workspaceLibraryController.selectWorkspace(workspaceID) else {
      return .unchanged
    }
    syncWorkspaceProjections()
    saveLibrary()
    return .changed(activeSessionID)
  }

  func renameSession(_ sessionID: ChatSession.ID, title: String) {
    guard !isPersistenceBlocked else {
      return
    }
    guard workspaceLibraryController.renameSession(sessionID, title: title) else {
      return
    }
    syncWorkspaceProjections()
    saveLibrary()
  }

  @discardableResult
  func deleteSession(_ sessionID: ChatSession.ID) -> WorkspaceSelectionChange {
    guard !isPersistenceBlocked else {
      return .unchanged
    }
    let wasActiveSession = library.activeSessionID == sessionID
    guard workspaceLibraryController.deleteSession(sessionID) else {
      return .unchanged
    }
    syncWorkspaceProjections()
    saveLibrary()
    return wasActiveSession ? .changed(activeSessionID) : .unchanged
  }

  @discardableResult
  func removeWorkspace(_ workspaceID: Workspace.ID) -> WorkspaceSelectionChange {
    guard !isPersistenceBlocked else {
      return .unchanged
    }
    let wasActiveWorkspace = library.activeWorkspaceID == workspaceID
    guard workspaceLibraryController.removeWorkspace(workspaceID) else {
      return .unchanged
    }
    syncWorkspaceProjections()
    saveLibrary()
    return wasActiveWorkspace ? .changed(activeSessionID) : .unchanged
  }

  func persistActiveSessionSnapshot(_ snapshot: ChatSession) {
    guard !isPersistenceBlocked else {
      return
    }
    workspaceLibraryController.persistActiveSessionSnapshot(snapshot)
    syncWorkspaceProjections()
    saveLibrary()
  }

  func openActiveWorkspaceInFinder() {
    openActiveWorkspace(destination: .finder)
  }

  func openActiveWorkspaceInVisualStudioCode() {
    openActiveWorkspace(destination: .visualStudioCode)
  }

  private func normalizeLoadedLibrary(persistNormalization: Bool) {
    let resolvedLibrary = WorkspaceLibrary(
      workspaces: library.workspaces.map(resolveBookmarkedWorkspace),
      activeWorkspaceID: library.activeWorkspaceID,
      activeSessionID: library.activeSessionID
    )
    workspaceLibraryController.replaceLibrary(resolvedLibrary)
    workspaceLibraryController.normalizeLoadedLibrary()
    syncWorkspaceProjections()
    // After a read failure the on-disk file may still hold the only copy of
    // the user's sessions, so never overwrite it with the fallback library.
    if persistNormalization {
      saveLibrary()
    }
  }

  private static func loadIssueMessage(for issues: [WorkspaceLibraryLoadIssue]) -> String? {
    guard let issue = issues.first else {
      return nil
    }

    switch issue {
    case .readFailed:
      return "Stored workspaces could not be read. The existing data was left untouched."
    case .decodeFailed:
      return "Stored workspaces are invalid. The existing data was left untouched."
    case .migrationFailed:
      return
        "Stored workspaces could not be migrated losslessly. "
        + "The legacy data was left untouched."
    case .unsupportedVersion(_, let found, let supported):
      return
        "Stored workspaces use format version \(found), "
        + "but this version of Sumika supports \(supported)."
    case .legacyCleanupFailed:
      return "Stored workspaces were migrated, but the obsolete legacy file could not be removed."
    }
  }

  private func syncWorkspaceProjections() {
    syncActiveWorkspaceProjection()
    syncSidebarProjection()
  }

  private func syncActiveWorkspaceProjection() {
    let nextContext = activeWorkspace.map(WorkspaceChatContext.init)
    if activeWorkspaceContext != nextContext {
      activeWorkspaceContext = nextContext
    }

    let nextSessionID = workspaceLibraryController.activeSessionID
    if activeSessionID != nextSessionID {
      activeSessionID = nextSessionID
    }
  }

  private func syncSidebarProjection() {
    let nextState = WorkspaceSidebarState(library: library)
    if sidebarState != nextState {
      sidebarState = nextState
    }
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

  private func saveLibrary() {
    let library = library
    let previousSaveTask = saveLibraryTask
    saveLibraryTask = Task { [turnTracer, workspaceStore] in
      await previousSaveTask?.value
      do {
        let startedAt = Date()
        try await workspaceStore.saveLibrary(library)
        await turnTracer.recordTurnTraceEvent(
          TurnTraceEvent(
            phase: .persist,
            durationMs: Date().timeIntervalSince(startedAt) * 1000
          )
        )
        await MainActor.run {
          // Only clear messages this save path produced; a pending load-issue
          // notice must survive until the user dismisses it.
          if errorMessageReflectsSaveFailure {
            errorMessage = nil
            errorMessageReflectsSaveFailure = false
          }
        }
      } catch {
        await MainActor.run {
          errorMessage = error.localizedDescription
          errorMessageReflectsSaveFailure = true
        }
      }
    }
  }

  /// Waits until every queued library write has reached the store. Saves are
  /// chained behind each other, so awaiting the newest task drains the whole
  /// queue.
  func flushPendingSaves() async {
    await saveLibraryTask?.value
  }

  private func openActiveWorkspace(destination: WorkspaceOpenDestination) {
    guard let workspace = activeWorkspace else {
      errorMessage = WorkspaceOpenError.noActiveWorkspace.localizedDescription
      return
    }

    Task {
      do {
        try await workspaceOpener.open(workspace.rootURL, destination: destination)
        errorMessage = nil
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func makeSecurityScopedBookmarkData(for url: URL) -> Data? {
    try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil)
  }
}
