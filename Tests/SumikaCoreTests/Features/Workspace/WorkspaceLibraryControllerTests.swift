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
          selectedModelID: "gemma4-12b-qat-4bit",
          modeSettings: testModeSettings(
            systemPrompt: "Existing",
            generationSettings: .agentDefault
          )
        )
      ]
    )
    var controller = makeController(
      library: WorkspaceLibrary(workspaces: [workspace])
    )

    let activatedWorkspaceID = controller.addWorkspace(
      name: "Project Copy",
      rootURL: URL(filePath: "/tmp/project/", directoryHint: .isDirectory),
      bookmarkData: Data([1, 2, 3])
    )

    #expect(activatedWorkspaceID == workspaceID)
    #expect(controller.library.workspaces.count == 1)
    #expect(controller.library.activeWorkspaceID == workspaceID)
    #expect(controller.library.activeSessionID == nil)
    #expect(controller.library.workspaces.first?.bookmarkData == nil)
  }

  @Test
  func addNewWorkspaceSelectsCreatedDefaultSession() throws {
    var controller = makeController(library: WorkspaceLibrary())

    let addedWorkspaceID = controller.addWorkspace(
      name: "Project",
      rootURL: URL(filePath: "/tmp/project", directoryHint: .isDirectory)
    )
    let workspaceID = try #require(addedWorkspaceID)
    let workspace = try #require(controller.library.workspaces.first)
    let session = try #require(workspace.sessions.first)

    #expect(workspace.id == workspaceID)
    #expect(controller.library.activeWorkspaceID == workspaceID)
    #expect(controller.library.activeSessionID == session.id)
    #expect(controller.activeSession?.id == session.id)
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
    #expect(controller.library.activeSessionID == nil)
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

    controller.selectChat(workspaceID: workspaceID, sessionID: firstSessionID)
    #expect(controller.library.activeSessionID == firstSessionID)

    let membershipUpdatedAt = controller.activeWorkspace?.updatedAt
    controller.renameSession(firstSessionID, title: "  Renamed  ")
    #expect(controller.activeSession?.title == "Renamed")
    #expect(controller.activeWorkspace?.updatedAt == membershipUpdatedAt)

    controller.renameSession(firstSessionID, title: "   ")
    #expect(controller.activeSession?.title == "Renamed")

    controller.deleteSession(firstSessionID)
    #expect(controller.library.activeWorkspaceID == workspaceID)
    #expect(controller.library.activeSessionID == nil)
    #expect(controller.activeSession == nil)

    controller.deleteSession(secondSessionID)
    let remainingSessions = try #require(controller.activeWorkspace?.sessions)
    #expect(remainingSessions.isEmpty)
    #expect(controller.library.activeSessionID == nil)
  }

  @Test
  func selectWorkspaceClearsActiveSessionAndAllowsEmptyWorkspace() throws {
    let firstWorkspaceID = fixedUUID("00000000-0000-0000-0000-000000000701")
    let firstSessionID = fixedUUID("00000000-0000-0000-0000-000000000702")
    let secondWorkspaceID = fixedUUID("00000000-0000-0000-0000-000000000703")
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
      sessions: []
    )
    var controller = makeController(
      library: WorkspaceLibrary(
        workspaces: [firstWorkspace, secondWorkspace],
        activeWorkspaceID: firstWorkspaceID,
        activeSessionID: firstSessionID
      )
    )

    let didSelectWorkspace = controller.selectWorkspace(secondWorkspaceID)

    let activeWorkspace = try #require(controller.activeWorkspace)
    #expect(didSelectWorkspace)
    #expect(activeWorkspace.id == secondWorkspaceID)
    #expect(activeWorkspace.sessions.isEmpty)
    #expect(controller.library.activeSessionID == nil)
    #expect(controller.activeSession == nil)
  }

  @Test
  func selectChatValidatesWorkspaceAndSessionPair() {
    let firstWorkspaceID = fixedUUID("00000000-0000-0000-0000-000000000801")
    let firstSessionID = fixedUUID("00000000-0000-0000-0000-000000000802")
    let secondWorkspaceID = fixedUUID("00000000-0000-0000-0000-000000000803")
    let secondSessionID = fixedUUID("00000000-0000-0000-0000-000000000804")
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
      library: WorkspaceLibrary(workspaces: [firstWorkspace, secondWorkspace])
    )

    let didRejectMismatchedPair = controller.selectChat(
      workspaceID: secondWorkspaceID,
      sessionID: firstSessionID
    )
    #expect(!didRejectMismatchedPair)
    #expect(controller.library.activeWorkspaceID == nil)
    #expect(controller.library.activeSessionID == nil)

    let didSelectChat = controller.selectChat(
      workspaceID: secondWorkspaceID,
      sessionID: secondSessionID
    )
    #expect(didSelectChat)
    #expect(controller.library.activeWorkspaceID == secondWorkspaceID)
    #expect(controller.library.activeSessionID == secondSessionID)
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
    #expect(controller.library.activeSessionID == nil)

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
    #expect(activeWorkspace.id == validWorkspaceID)
    #expect(activeWorkspace.sessions.isEmpty)
    #expect(controller.library.activeSessionID == nil)
    #expect(controller.activeSession == nil)
  }

  @Test
  func persistActiveSessionSnapshotDoesNotChangeWorkspaceTimestamp() throws {
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
    #expect(savedWorkspace.updatedAt == workspaceUpdatedAt)
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
        selectedModelID: "gemma4-12b-qat-4bit",
        systemPrompt: "Default system",
        generationSettings: .agentDefault
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
      selectedModelID: "gemma4-12b-qat-4bit",
      modeSettings: testModeSettings(
        systemPrompt: "System",
        generationSettings: .agentDefault
      )
    )
  }

  private func fixedUUID(_ value: String) -> UUID {
    guard let uuid = UUID(uuidString: value) else {
      preconditionFailure("Invalid fixed UUID: \(value)")
    }
    return uuid
  }
}
