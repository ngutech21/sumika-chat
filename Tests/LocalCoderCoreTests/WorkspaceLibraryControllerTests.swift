import Foundation
import Testing

@testable import LocalCoderCore

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
          selectedModelID: "gemma3-1b",
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
    #expect(activeSession.selectedModelID == "gemma3-1b")
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
    snapshot.interactionMode = .inspect

    controller.persistActiveSessionSnapshot(snapshot)

    let savedWorkspace = try #require(controller.activeWorkspace)
    let savedActiveSession = try #require(controller.activeSession)
    let savedOtherSession = try #require(
      savedWorkspace.sessions.first(where: { $0.id == otherSessionID })
    )
    #expect(savedWorkspace.updatedAt == persistedAt)
    #expect(savedActiveSession.title == "Persisted")
    #expect(savedActiveSession.interactionMode == .inspect)
    #expect(savedOtherSession == otherSession)
  }

  private func makeController(
    library: WorkspaceLibrary = WorkspaceLibrary(),
    now: @escaping () -> Date = { Date(timeIntervalSinceReferenceDate: 20) }
  ) -> WorkspaceLibraryController {
    WorkspaceLibraryController(
      library: library,
      defaultSessionFactory: DefaultChatSessionFactory(
        selectedModelID: "gemma3-1b",
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
      selectedModelID: "gemma3-1b",
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
