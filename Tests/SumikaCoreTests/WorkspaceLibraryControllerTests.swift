import Foundation
import Testing

@testable import SumikaCore

struct WorkspaceLibraryControllerTests {
  @Test
  func addExistingWorkspaceActivatesOriginalWithoutDuplicatingPath() throws {
    let workspaceID = fixedUUID("00000000-0000-0000-0000-000000000101")
    let sessionID = fixedUUID("00000000-0000-0000-0000-000000000102")
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      sessions: [
        ChatSession(
          id: sessionID,
          selectedModelID: "gemma4-e4b",
          systemPrompt: "Existing",
          generationSettings: .codingDefault
        )
      ]
    )
    var controller = makeController(
      library: WorkspaceLibrary(workspaces: [workspace])
    )

    let activatedSessionID = controller.addWorkspace(
      name: "Project Copy",
      rootURL: URL(filePath: "/tmp/project/", directoryHint: .isDirectory),
      bookmarkData: Data([1, 2, 3])
    )

    #expect(activatedSessionID == sessionID)
    #expect(controller.library.workspaces.count == 1)
    #expect(controller.library.activeWorkspaceID == workspaceID)
    #expect(controller.library.activeSessionID == sessionID)
    #expect(controller.library.workspaces.first?.bookmarkData == nil)
  }

  @Test
  func normalizeLoadedLibraryDeduplicatesWorkspacesByNormalizedRootPath() {
    let firstWorkspace = Workspace(
      name: "Project",
      rootURL: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      sessions: [makeSession(title: "First")]
    )
    let duplicateWorkspace = Workspace(
      name: "Project Duplicate",
      rootURL: URL(filePath: "/tmp/project/", directoryHint: .isDirectory),
      sessions: [makeSession(title: "Duplicate")]
    )
    var controller = makeController(
      library: WorkspaceLibrary(workspaces: [firstWorkspace, duplicateWorkspace])
    )

    controller.normalizeLoadedLibrary()

    #expect(controller.library.workspaces.map(\.id) == [firstWorkspace.id])
    #expect(controller.library.activeWorkspaceID == firstWorkspace.id)
    #expect(controller.library.activeSessionID == firstWorkspace.sessions.first?.id)
  }

  @Test
  func createSelectRenameAndDeleteSessionsMaintainActiveInvariants() throws {
    let workspaceID = fixedUUID("00000000-0000-0000-0000-000000000201")
    let firstSessionID = fixedUUID("00000000-0000-0000-0000-000000000202")
    let firstSession = makeSession(id: firstSessionID, title: "First")
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      sessions: [firstSession]
    )
    var controller = makeController(
      library: WorkspaceLibrary(
        workspaces: [workspace],
        activeWorkspaceID: workspaceID,
        activeSessionID: firstSessionID
      )
    )

    let createdSessionID = controller.createSession(in: workspaceID)
    let secondSessionID = try #require(createdSessionID)
    #expect(controller.library.activeWorkspaceID == workspaceID)
    #expect(controller.library.activeSessionID == secondSessionID)
    #expect(controller.activeSession?.title == "New Session")

    controller.selectSession(firstSessionID)
    #expect(controller.library.activeSessionID == firstSessionID)

    controller.renameSession(firstSessionID, title: "  Renamed  ")
    #expect(controller.activeSession?.title == "Renamed")

    controller.renameSession(firstSessionID, title: "   ")
    #expect(controller.activeSession?.title == "Renamed")

    controller.deleteSession(firstSessionID)
    #expect(controller.library.activeSessionID == secondSessionID)
    #expect(controller.activeSession?.id == secondSessionID)

    controller.deleteSession(secondSessionID)
    let remainingSessions = try #require(controller.activeWorkspace?.sessions)
    #expect(remainingSessions.count == 1)
    #expect(controller.library.activeSessionID == remainingSessions.first?.id)
    #expect(remainingSessions.first?.title == "New Session")
  }

  @Test
  func removeInactiveWorkspaceLeavesActiveSelectionUnchanged() {
    let activeWorkspaceID = fixedUUID("00000000-0000-0000-0000-000000000501")
    let activeSessionID = fixedUUID("00000000-0000-0000-0000-000000000502")
    let removedWorkspaceID = fixedUUID("00000000-0000-0000-0000-000000000503")
    let removedSessionID = fixedUUID("00000000-0000-0000-0000-000000000504")
    let activeWorkspace = Workspace(
      id: activeWorkspaceID,
      name: "Active",
      rootURL: URL(filePath: "/tmp/active", directoryHint: .isDirectory),
      sessions: [makeSession(id: activeSessionID)]
    )
    let removedWorkspace = Workspace(
      id: removedWorkspaceID,
      name: "Removed",
      rootURL: URL(filePath: "/tmp/removed", directoryHint: .isDirectory),
      sessions: [makeSession(id: removedSessionID)]
    )
    var controller = makeController(
      library: WorkspaceLibrary(
        workspaces: [activeWorkspace, removedWorkspace],
        activeWorkspaceID: activeWorkspaceID,
        activeSessionID: activeSessionID
      )
    )

    let didRemove = controller.removeWorkspace(removedWorkspaceID)

    #expect(didRemove)
    #expect(controller.library.workspaces.map(\.id) == [activeWorkspaceID])
    #expect(controller.library.activeWorkspaceID == activeWorkspaceID)
    #expect(controller.library.activeSessionID == activeSessionID)
  }

  @Test
  func removeActiveWorkspaceSelectsNextAvailableWorkspaceOrClearsSelection() {
    let firstWorkspaceID = fixedUUID("00000000-0000-0000-0000-000000000601")
    let firstSessionID = fixedUUID("00000000-0000-0000-0000-000000000602")
    let secondWorkspaceID = fixedUUID("00000000-0000-0000-0000-000000000603")
    let secondSessionID = fixedUUID("00000000-0000-0000-0000-000000000604")
    let firstWorkspace = Workspace(
      id: firstWorkspaceID,
      name: "First",
      rootURL: URL(filePath: "/tmp/first", directoryHint: .isDirectory),
      sessions: [makeSession(id: firstSessionID)]
    )
    let secondWorkspace = Workspace(
      id: secondWorkspaceID,
      name: "Second",
      rootURL: URL(filePath: "/tmp/second", directoryHint: .isDirectory),
      sessions: [makeSession(id: secondSessionID)]
    )
    var controller = makeController(
      library: WorkspaceLibrary(
        workspaces: [firstWorkspace, secondWorkspace],
        activeWorkspaceID: firstWorkspaceID,
        activeSessionID: firstSessionID
      )
    )

    let didRemoveFirstWorkspace = controller.removeWorkspace(firstWorkspaceID)
    #expect(didRemoveFirstWorkspace)
    #expect(controller.library.workspaces.map(\.id) == [secondWorkspaceID])
    #expect(controller.library.activeWorkspaceID == secondWorkspaceID)
    #expect(controller.library.activeSessionID == secondSessionID)

    let didRemoveSecondWorkspace = controller.removeWorkspace(secondWorkspaceID)
    #expect(didRemoveSecondWorkspace)
    #expect(controller.library.workspaces.isEmpty)
    #expect(controller.library.activeWorkspaceID == nil)
    #expect(controller.library.activeSessionID == nil)
  }

  @Test
  func normalizeLoadedLibraryRepairsInvalidActiveIDsAndEmptySessions() throws {
    let validWorkspaceID = fixedUUID("00000000-0000-0000-0000-000000000301")
    let invalidWorkspaceID = fixedUUID("00000000-0000-0000-0000-000000000302")
    let invalidSessionID = fixedUUID("00000000-0000-0000-0000-000000000303")
    let workspace = Workspace(
      id: validWorkspaceID,
      name: "Project",
      rootURL: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      sessions: []
    )
    var controller = makeController(
      library: WorkspaceLibrary(
        workspaces: [workspace],
        activeWorkspaceID: invalidWorkspaceID,
        activeSessionID: invalidSessionID
      )
    )

    controller.normalizeLoadedLibrary()

    let activeWorkspace = try #require(controller.activeWorkspace)
    let activeSession = try #require(controller.activeSession)
    #expect(activeWorkspace.id == validWorkspaceID)
    #expect(activeWorkspace.sessions.count == 1)
    #expect(activeSession.selectedModelID == "gemma4-e4b")
    #expect(activeSession.systemPrompt == "Default system")
  }

  @Test
  func persistActiveSessionSnapshotUpdatesOnlyActiveSessionAndWorkspaceTimestamp() throws {
    let workspaceUpdatedAt = Date(timeIntervalSinceReferenceDate: 10)
    let persistedAt = Date(timeIntervalSinceReferenceDate: 40)
    let workspaceID = fixedUUID("00000000-0000-0000-0000-000000000401")
    let activeSessionID = fixedUUID("00000000-0000-0000-0000-000000000402")
    let otherSessionID = fixedUUID("00000000-0000-0000-0000-000000000403")
    let activeSession = makeSession(id: activeSessionID, title: "Active")
    let otherSession = makeSession(id: otherSessionID, title: "Other")
    let workspace = Workspace(
      id: workspaceID,
      name: "Project",
      rootURL: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      sessions: [activeSession, otherSession],
      updatedAt: workspaceUpdatedAt
    )
    var controller = makeController(
      library: WorkspaceLibrary(
        workspaces: [workspace],
        activeWorkspaceID: workspaceID,
        activeSessionID: activeSessionID
      ),
      now: { persistedAt }
    )
    var snapshot = activeSession
    snapshot.title = "Persisted"
    snapshot.interactionMode = .agent

    controller.persistActiveSessionSnapshot(snapshot)

    let savedWorkspace = try #require(controller.activeWorkspace)
    let savedActiveSession = try #require(controller.activeSession)
    let savedOtherSession = try #require(
      savedWorkspace.sessions.first(where: { $0.id == otherSessionID })
    )
    #expect(savedWorkspace.updatedAt == persistedAt)
    #expect(savedActiveSession.title == "Persisted")
    #expect(savedActiveSession.interactionMode == .agent)
    #expect(savedOtherSession == otherSession)
  }

  private func makeController(
    library: WorkspaceLibrary = WorkspaceLibrary(),
    now: @escaping () -> Date = { Date(timeIntervalSinceReferenceDate: 20) }
  ) -> WorkspaceLibraryController {
    WorkspaceLibraryController(
      library: library,
      defaultSessionFactory: DefaultChatSessionFactory(
        selectedModelID: "gemma4-e4b",
        systemPrompt: "Default system",
        generationSettings: .codingDefault
      ),
      now: now
    )
  }

  private func makeSession(
    id: ChatSession.ID = UUID(),
    title: String = "Session"
  ) -> ChatSession {
    ChatSession(
      id: id,
      title: title,
      selectedModelID: "gemma4-e4b",
      systemPrompt: "System",
      generationSettings: .codingDefault
    )
  }

  private func fixedUUID(_ value: String) -> UUID {
    guard let uuid = UUID(uuidString: value) else {
      preconditionFailure("Invalid fixed UUID: \(value)")
    }
    return uuid
  }
}
