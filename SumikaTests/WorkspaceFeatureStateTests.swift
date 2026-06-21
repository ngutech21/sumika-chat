import Foundation
import SumikaCore
import Testing

@testable import Sumika

@Suite(.serialized)
@MainActor
struct WorkspaceFeatureStateTests {
  @Test
  func loadLibraryNormalizesAndPersistsActiveSession() async throws {
    let workspaceID = UUID()
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: []
    )
    let store = WorkspaceFeatureInMemoryStore(
      initialLibrary: WorkspaceLibrary(
        workspaces: [workspace],
        activeWorkspaceID: workspaceID,
        activeSessionID: nil
      )
    )
    let state = WorkspaceFeatureState(
      workspaceStore: store,
      workspaceOpener: WorkspaceFeatureRecordingOpener(),
      defaultSessionFactory: makeWorkspaceFeatureDefaultFactory(systemPrompt: "Initial")
    )

    let change = await state.loadLibrary(
      defaultSessionFactory: makeWorkspaceFeatureDefaultFactory(systemPrompt: "Loaded default")
    )

    #expect(!state.isLoading)
    #expect(change.activeSessionChanged)
    #expect(change.activeSessionID == state.activeSessionID)
    #expect(state.activeWorkspace?.id == workspaceID)
    #expect(state.activeSession?.systemPrompt == "Loaded default")

    let savedLibrary = try await waitForWorkspaceFeatureSavedLibrary(in: store) { library in
      library.workspaces.first?.sessions.count == 1
    }
    #expect(savedLibrary.activeWorkspaceID == workspaceID)
    #expect(savedLibrary.activeSessionID == state.activeSessionID)
  }

  @Test
  func workspaceMutationsReportWhenActiveSessionChanges() async throws {
    let firstSessionID = UUID()
    let secondSessionID = UUID()
    let workspaceID = UUID()
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: [
        ChatSession(id: firstSessionID, title: "First"),
        ChatSession(id: secondSessionID, title: "Second"),
      ]
    )
    let state = WorkspaceFeatureState(
      workspaceStore: WorkspaceFeatureInMemoryStore(
        initialLibrary: WorkspaceLibrary(
          workspaces: [workspace],
          activeWorkspaceID: workspaceID,
          activeSessionID: firstSessionID
        )
      ),
      workspaceOpener: WorkspaceFeatureRecordingOpener(),
      defaultSessionFactory: makeWorkspaceFeatureDefaultFactory()
    )

    await state.loadLibrary(defaultSessionFactory: makeWorkspaceFeatureDefaultFactory())

    let createdChange = state.createSession(in: workspaceID)
    #expect(createdChange.activeSessionChanged)
    #expect(createdChange.activeSessionID == state.activeSessionID)
    #expect(createdChange.activeSessionID != firstSessionID)

    let selectedChange = state.selectSession(secondSessionID)
    #expect(selectedChange.activeSessionChanged)
    #expect(selectedChange.activeSessionID == secondSessionID)

    state.renameSession(secondSessionID, title: "Renamed")
    #expect(state.activeSession?.title == "Renamed")

    let deletedChange = state.deleteSession(secondSessionID)
    #expect(deletedChange.activeSessionChanged)
    #expect(deletedChange.activeSessionID != secondSessionID)

    let removedChange = state.removeWorkspace(workspaceID)
    #expect(removedChange.activeSessionChanged)
    #expect(removedChange.activeSessionID == nil)
  }

  @Test
  func persistActiveSessionSnapshotUpdatesOnlyActiveSession() async throws {
    let activeSessionID = UUID()
    let otherSessionID = UUID()
    let workspaceID = UUID()
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: [
        ChatSession(id: activeSessionID, title: "Active"),
        ChatSession(id: otherSessionID, title: "Other"),
      ]
    )
    let store = WorkspaceFeatureInMemoryStore(
      initialLibrary: WorkspaceLibrary(
        workspaces: [workspace],
        activeWorkspaceID: workspaceID,
        activeSessionID: activeSessionID
      )
    )
    let state = WorkspaceFeatureState(
      workspaceStore: store,
      workspaceOpener: WorkspaceFeatureRecordingOpener(),
      defaultSessionFactory: makeWorkspaceFeatureDefaultFactory()
    )
    await state.loadLibrary(defaultSessionFactory: makeWorkspaceFeatureDefaultFactory())

    var snapshot = try #require(state.activeSession)
    snapshot.title = "Saved Active"
    state.persistActiveSessionSnapshot(snapshot)

    let savedLibrary = try await waitForWorkspaceFeatureSavedLibrary(in: store) { library in
      library.workspaces.first?
        .sessions.first(where: { $0.id == activeSessionID })?
        .title == "Saved Active"
    }
    let savedSessions = try #require(savedLibrary.workspaces.first?.sessions)
    #expect(savedSessions.first { $0.id == activeSessionID }?.title == "Saved Active")
    #expect(savedSessions.first { $0.id == otherSessionID }?.title == "Other")
  }

  @Test
  func openingActiveWorkspaceUsesWorkspaceURLAndReportsErrors() async throws {
    let workspaceID = UUID()
    let sessionID = UUID()
    let workspaceURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: workspaceURL,
      sessions: [ChatSession(id: sessionID)]
    )
    let opener = WorkspaceFeatureRecordingOpener()
    let state = WorkspaceFeatureState(
      workspaceStore: WorkspaceFeatureInMemoryStore(
        initialLibrary: WorkspaceLibrary(
          workspaces: [workspace],
          activeWorkspaceID: workspaceID,
          activeSessionID: sessionID
        )
      ),
      workspaceOpener: opener,
      defaultSessionFactory: makeWorkspaceFeatureDefaultFactory()
    )
    await state.loadLibrary(defaultSessionFactory: makeWorkspaceFeatureDefaultFactory())

    state.openActiveWorkspaceInFinder()

    try await waitForWorkspaceFeatureCondition {
      opener.requests.count == 1
    }
    #expect(opener.requests.first?.url == workspaceURL)
    #expect(opener.requests.first?.destination == .finder)
    #expect(state.errorMessage == nil)

    let emptyState = WorkspaceFeatureState(
      workspaceStore: WorkspaceFeatureInMemoryStore(initialLibrary: WorkspaceLibrary()),
      workspaceOpener: opener,
      defaultSessionFactory: makeWorkspaceFeatureDefaultFactory()
    )
    await emptyState.loadLibrary(defaultSessionFactory: makeWorkspaceFeatureDefaultFactory())
    emptyState.openActiveWorkspaceInVisualStudioCode()
    #expect(emptyState.errorMessage == "No active workspace is selected.")
  }
}

private actor WorkspaceFeatureInMemoryStore: WorkspaceStoring {
  private var library: WorkspaceLibrary
  private var savedLibraries: [WorkspaceLibrary] = []

  init(initialLibrary: WorkspaceLibrary) {
    self.library = initialLibrary
  }

  func loadLibrary() async -> WorkspaceLibrary {
    library
  }

  func saveLibrary(_ library: WorkspaceLibrary) async throws {
    self.library = library
    savedLibraries.append(library)
  }

  func latestSavedLibrary() -> WorkspaceLibrary? {
    savedLibraries.last
  }
}

@MainActor
private final class WorkspaceFeatureRecordingOpener: WorkspaceOpening {
  private(set) var requests: [(url: URL, destination: WorkspaceOpenDestination)] = []

  func open(_ url: URL, destination: WorkspaceOpenDestination) async throws {
    requests.append((url, destination))
  }
}

private func makeWorkspaceFeatureDefaultFactory(
  systemPrompt: String = "Default system"
) -> DefaultChatSessionFactory {
  DefaultChatSessionFactory(
    selectedModelID: ManagedModelCatalog.defaultModelID,
    systemPrompt: systemPrompt,
    generationSettings: .codingDefault
  )
}

private func waitForWorkspaceFeatureSavedLibrary(
  in store: WorkspaceFeatureInMemoryStore,
  matching predicate: (WorkspaceLibrary) -> Bool
) async throws -> WorkspaceLibrary {
  var matchedLibrary: WorkspaceLibrary?
  try await waitForWorkspaceFeatureCondition {
    guard let library = await store.latestSavedLibrary(), predicate(library) else {
      return false
    }
    matchedLibrary = library
    return true
  }
  return try #require(matchedLibrary)
}

private func waitForWorkspaceFeatureCondition(
  timeout: TimeInterval = 2,
  _ predicate: () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if await predicate() {
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw WorkspaceFeatureTestTimeoutError()
}

private struct WorkspaceFeatureTestTimeoutError: Error {}
