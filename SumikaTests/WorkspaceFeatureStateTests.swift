import Foundation
import SumikaCore
import Testing

@testable import Sumika

@Suite(.serialized)
@MainActor
struct WorkspaceFeatureStateTests {
  @Test
  func loadLibraryNormalizesAndPersistsActiveWorkspaceWithoutSession() async throws {
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
    #expect(change.selectionChanged)
    #expect(change.activeSessionID == state.activeSessionID)
    #expect(state.activeWorkspace?.id == workspaceID)
    #expect(state.activeWorkspaceContext?.id == workspaceID)
    #expect(state.activeWorkspaceContext?.name == "Project")
    #expect(state.activeWorkspaceContext?.rootURL == workspace.rootURL)
    #expect(state.activeSessionID == nil)
    #expect(state.activeSession == nil)

    let savedLibrary = try await waitForWorkspaceFeatureSavedLibrary(in: store) { library in
      library.activeWorkspaceID == workspaceID && library.activeSessionID == nil
    }
    #expect(savedLibrary.activeWorkspaceID == workspaceID)
    #expect(savedLibrary.activeSessionID == nil)
    #expect(savedLibrary.workspaces.first?.sessions.isEmpty == true)
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
    #expect(state.activeWorkspaceContext == WorkspaceChatContext(workspace: workspace))
    #expect(state.activeSessionID == firstSessionID)

    let createdChange = state.createSession(in: workspaceID)
    #expect(createdChange.selectionChanged)
    #expect(createdChange.activeSessionID == state.activeSessionID)
    #expect(createdChange.activeSessionID != firstSessionID)
    #expect(state.activeWorkspaceContext == WorkspaceChatContext(workspace: workspace))

    let selectedChange = state.selectChat(workspaceID: workspaceID, sessionID: secondSessionID)
    #expect(selectedChange.selectionChanged)
    #expect(selectedChange.activeSessionID == secondSessionID)
    #expect(state.activeSessionID == secondSessionID)
    #expect(state.activeWorkspaceContext == WorkspaceChatContext(workspace: workspace))

    state.renameSession(secondSessionID, title: "Renamed")
    #expect(state.activeSession?.title == "Renamed")
    #expect(state.activeWorkspaceContext == WorkspaceChatContext(workspace: workspace))

    let deletedChange = state.deleteSession(secondSessionID)
    #expect(deletedChange.selectionChanged)
    #expect(deletedChange.activeSessionID == nil)
    #expect(state.activeSessionID == nil)
    #expect(state.activeSession == nil)
    #expect(state.activeWorkspaceContext == WorkspaceChatContext(workspace: workspace))

    let removedChange = state.removeWorkspace(workspaceID)
    #expect(removedChange.selectionChanged)
    #expect(removedChange.activeSessionID == nil)
    #expect(state.activeWorkspaceContext == nil)
    #expect(state.activeSessionID == nil)
  }

  @Test
  func selectWorkspaceClearsActiveSession() async throws {
    let firstWorkspaceID = UUID()
    let firstSessionID = UUID()
    let secondWorkspaceID = UUID()
    let secondSessionID = UUID()
    let firstWorkspace = Workspace(
      id: firstWorkspaceID,
      name: "First",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: [ChatSession(id: firstSessionID, title: "First Session")]
    )
    let secondWorkspace = Workspace(
      id: secondWorkspaceID,
      name: "Second",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: [ChatSession(id: secondSessionID, title: "Second Session")]
    )
    let state = WorkspaceFeatureState(
      workspaceStore: WorkspaceFeatureInMemoryStore(
        initialLibrary: WorkspaceLibrary(
          workspaces: [firstWorkspace, secondWorkspace],
          activeWorkspaceID: firstWorkspaceID,
          activeSessionID: firstSessionID
        )
      ),
      workspaceOpener: WorkspaceFeatureRecordingOpener(),
      defaultSessionFactory: makeWorkspaceFeatureDefaultFactory()
    )

    await state.loadLibrary(defaultSessionFactory: makeWorkspaceFeatureDefaultFactory())

    let change = state.selectWorkspace(secondWorkspaceID)

    #expect(change.selectionChanged)
    #expect(change.activeSessionID == nil)
    #expect(state.activeWorkspace?.id == secondWorkspaceID)
    #expect(state.activeSessionID == nil)
    #expect(state.activeSession == nil)
    #expect(state.activeWorkspaceContext == WorkspaceChatContext(workspace: secondWorkspace))
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
    let contextBeforePersist = state.activeWorkspaceContext
    let activeSessionIDBeforePersist = state.activeSessionID

    let snapshot = ChatSession(
      id: activeSessionID,
      title: "Saved Active",
      turns: [
        ChatTurn(
          status: .completed,
          items: [.userMessage(UserTurnMessage(content: "New persisted turn"))]
        )
      ]
    )
    state.persistActiveSessionSnapshot(snapshot)

    #expect(state.activeWorkspaceContext == contextBeforePersist)
    #expect(state.activeSessionID == activeSessionIDBeforePersist)

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
  func persistActiveSessionSnapshotDoesNotChangeSidebarStateForTurnOnlyUpdates() async throws {
    let activeSessionID = UUID()
    let workspaceID = UUID()
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: [
        ChatSession(id: activeSessionID, title: "Active")
      ]
    )
    let state = WorkspaceFeatureState(
      workspaceStore: WorkspaceFeatureInMemoryStore(
        initialLibrary: WorkspaceLibrary(
          workspaces: [workspace],
          activeWorkspaceID: workspaceID,
          activeSessionID: activeSessionID
        )
      ),
      workspaceOpener: WorkspaceFeatureRecordingOpener(),
      defaultSessionFactory: makeWorkspaceFeatureDefaultFactory()
    )
    await state.loadLibrary(defaultSessionFactory: makeWorkspaceFeatureDefaultFactory())
    let sidebarStateBeforePersist = state.sidebarState

    let snapshot = ChatSession(
      id: activeSessionID,
      title: "Active",
      turns: [
        ChatTurn(
          status: .completed,
          items: [.userMessage(UserTurnMessage(content: "New persisted turn"))]
        )
      ]
    )
    state.persistActiveSessionSnapshot(snapshot)

    #expect(state.sidebarState == sidebarStateBeforePersist)
  }

  @Test
  func persistActiveSessionSnapshotUpdatesSidebarStateWhenTitleChanges() async throws {
    let activeSessionID = UUID()
    let workspaceID = UUID()
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
      sessions: [
        ChatSession(id: activeSessionID, title: ChatSession.defaultTitle)
      ]
    )
    let state = WorkspaceFeatureState(
      workspaceStore: WorkspaceFeatureInMemoryStore(
        initialLibrary: WorkspaceLibrary(
          workspaces: [workspace],
          activeWorkspaceID: workspaceID,
          activeSessionID: activeSessionID
        )
      ),
      workspaceOpener: WorkspaceFeatureRecordingOpener(),
      defaultSessionFactory: makeWorkspaceFeatureDefaultFactory()
    )
    await state.loadLibrary(defaultSessionFactory: makeWorkspaceFeatureDefaultFactory())

    let snapshot = ChatSession(
      id: activeSessionID,
      title: "Saved Active",
      turns: [
        ChatTurn(
          status: .completed,
          items: [.userMessage(UserTurnMessage(content: "First prompt"))]
        )
      ]
    )
    state.persistActiveSessionSnapshot(snapshot)

    #expect(state.sidebarState.workspaces.first?.sessions.first?.title == "Saved Active")
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
    generationSettings: .agentDefault
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
