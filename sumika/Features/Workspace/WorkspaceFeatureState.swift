import Foundation
import Observation
import SumikaCore

struct WorkspaceSelectionChange: Equatable {
  let activeSessionChanged: Bool
  let activeSessionID: ChatSession.ID?

  static let unchanged = WorkspaceSelectionChange(
    activeSessionChanged: false,
    activeSessionID: nil
  )

  static func changed(_ activeSessionID: ChatSession.ID?) -> WorkspaceSelectionChange {
    WorkspaceSelectionChange(
      activeSessionChanged: true,
      activeSessionID: activeSessionID
    )
  }
}

@MainActor
@Observable
final class WorkspaceFeatureState {
  var errorMessage: String?
  var isLoading = true

  var library: WorkspaceLibrary {
    get { workspaceLibraryController.library }
    set { workspaceLibraryController.replaceLibrary(newValue) }
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

  private var workspaceLibraryController: WorkspaceLibraryController
  @ObservationIgnored private let workspaceStore: any WorkspaceStoring
  @ObservationIgnored private let workspaceOpener: any WorkspaceOpening
  @ObservationIgnored private var saveLibraryTask: Task<Void, Never>?

  init(
    workspaceStore: any WorkspaceStoring,
    workspaceOpener: any WorkspaceOpening,
    defaultSessionFactory: DefaultChatSessionFactory
  ) {
    self.workspaceStore = workspaceStore
    self.workspaceOpener = workspaceOpener
    self.workspaceLibraryController = WorkspaceLibraryController(
      defaultSessionFactory: defaultSessionFactory
    )
  }

  func updateDefaultSessionFactory(_ defaultSessionFactory: DefaultChatSessionFactory) {
    workspaceLibraryController.defaultSessionFactory = defaultSessionFactory
  }

  @discardableResult
  func loadLibrary(defaultSessionFactory: DefaultChatSessionFactory) async -> WorkspaceSelectionChange {
    updateDefaultSessionFactory(defaultSessionFactory)
    let library = await workspaceStore.loadLibrary()
    workspaceLibraryController.replaceLibrary(library)
    normalizeLoadedLibrary()
    isLoading = false
    return .changed(activeSessionID)
  }

  @discardableResult
  func addWorkspace(from url: URL) -> WorkspaceSelectionChange {
    let rootURL = url.standardizedFileURL.resolvingSymlinksInPath()
    let sessionID = workspaceLibraryController.addWorkspace(
      name: rootURL.lastPathComponent,
      rootURL: rootURL,
      bookmarkData: makeSecurityScopedBookmarkData(for: rootURL)
    )
    saveLibrary()
    return .changed(sessionID)
  }

  @discardableResult
  func createSession(in workspaceID: Workspace.ID? = nil) -> WorkspaceSelectionChange {
    guard let sessionID = workspaceLibraryController.createSession(in: workspaceID) else {
      return .unchanged
    }
    saveLibrary()
    return .changed(sessionID)
  }

  @discardableResult
  func selectSession(_ sessionID: ChatSession.ID) -> WorkspaceSelectionChange {
    guard workspaceLibraryController.selectSession(sessionID) else {
      return .unchanged
    }
    saveLibrary()
    return .changed(activeSessionID)
  }

  func renameSession(_ sessionID: ChatSession.ID, title: String) {
    guard workspaceLibraryController.renameSession(sessionID, title: title) else {
      return
    }
    saveLibrary()
  }

  @discardableResult
  func deleteSession(_ sessionID: ChatSession.ID) -> WorkspaceSelectionChange {
    let wasActiveSession = library.activeSessionID == sessionID
    guard workspaceLibraryController.deleteSession(sessionID) else {
      return .unchanged
    }
    saveLibrary()
    return wasActiveSession ? .changed(activeSessionID) : .unchanged
  }

  @discardableResult
  func removeWorkspace(_ workspaceID: Workspace.ID) -> WorkspaceSelectionChange {
    let wasActiveWorkspace = library.activeWorkspaceID == workspaceID
    guard workspaceLibraryController.removeWorkspace(workspaceID) else {
      return .unchanged
    }
    saveLibrary()
    return wasActiveWorkspace ? .changed(activeSessionID) : .unchanged
  }

  func persistActiveSessionSnapshot(_ snapshot: ChatSession) {
    workspaceLibraryController.persistActiveSessionSnapshot(snapshot)
    saveLibrary()
  }

  func openActiveWorkspaceInFinder() {
    openActiveWorkspace(destination: .finder)
  }

  func openActiveWorkspaceInVisualStudioCode() {
    openActiveWorkspace(destination: .visualStudioCode)
  }

  private func normalizeLoadedLibrary() {
    let resolvedLibrary = WorkspaceLibrary(
      workspaces: library.workspaces.map(resolveBookmarkedWorkspace),
      activeWorkspaceID: library.activeWorkspaceID,
      activeSessionID: library.activeSessionID
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

  private func saveLibrary() {
    let library = library
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
          errorMessage = nil
        }
      } catch {
        await MainActor.run {
          errorMessage = error.localizedDescription
        }
      }
    }
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
