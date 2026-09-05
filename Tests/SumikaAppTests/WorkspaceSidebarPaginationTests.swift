import Foundation
import SumikaCore
import Testing

@testable import SumikaApp

@Suite
@MainActor
struct WorkspaceSidebarPaginationTests {
  @Test
  func prunesOnlyCollapsedIDsMissingFromCommittedMembership() {
    let retained = UUID()
    let removed = UUID()
    let raw = "\(removed),invalid,\(retained),\(retained)"
    #expect(
      WorkspaceSidebar.retainedCollapsedWorkspaceIDs(raw, retaining: [retained])
        == retained.uuidString)
    #expect(WorkspaceSidebar.retainedCollapsedWorkspaceIDs(raw, retaining: []).isEmpty)
  }

  @Test
  func initiallyShowsAtMostFiveSessions() {
    let shortWorkspace = makeWorkspace(sessionCount: 5)
    let longWorkspace = makeWorkspace(sessionCount: 6)
    let pagination = WorkspaceSidebarPagination()

    #expect(pagination.visibleSessionCount(in: shortWorkspace) == 5)
    #expect(!pagination.hasMoreSessions(in: shortWorkspace))
    #expect(pagination.visibleSessionCount(in: longWorkspace) == 5)
    #expect(pagination.remainingSessionCount(in: longWorkspace) == 1)
    #expect(pagination.hasMoreSessions(in: longWorkspace))
  }

  @Test
  func revealsFiveMoreSessionsAtATime() {
    let workspace = makeWorkspace(sessionCount: 12)
    var pagination = WorkspaceSidebarPagination()

    pagination.showMoreSessions(in: workspace)

    #expect(pagination.visibleSessionCount(in: workspace) == 10)
    #expect(pagination.remainingSessionCount(in: workspace) == 2)

    pagination.showMoreSessions(in: workspace)

    #expect(pagination.visibleSessionCount(in: workspace) == 12)
    #expect(!pagination.hasMoreSessions(in: workspace))
  }

  @Test
  func tracksVisibleSessionsIndependentlyForEachWorkspace() {
    let firstWorkspace = makeWorkspace(sessionCount: 12)
    let secondWorkspace = makeWorkspace(sessionCount: 12)
    var pagination = WorkspaceSidebarPagination()

    pagination.showMoreSessions(in: firstWorkspace)

    #expect(pagination.visibleSessionCount(in: firstWorkspace) == 10)
    #expect(pagination.visibleSessionCount(in: secondWorkspace) == 5)
  }

  @Test
  func revealsThePageContainingTheSelectedSession() throws {
    let workspace = makeWorkspace(sessionCount: 12)
    let selectedSessionID = try #require(workspace.sessions.last?.id)
    var pagination = WorkspaceSidebarPagination()

    pagination.revealSession(selectedSessionID, in: workspace)

    #expect(pagination.visibleSessionCount(in: workspace) == 12)
    #expect(!pagination.hasMoreSessions(in: workspace))
  }

  @Test
  func discardsPaginationForRemovedWorkspaces() {
    let removedWorkspace = makeWorkspace(sessionCount: 12)
    let retainedWorkspace = makeWorkspace(sessionCount: 12)
    var pagination = WorkspaceSidebarPagination()
    pagination.showMoreSessions(in: removedWorkspace)
    pagination.showMoreSessions(in: retainedWorkspace)

    pagination.retainWorkspaces([retainedWorkspace])

    #expect(pagination.visibleSessionCount(in: removedWorkspace) == 5)
    #expect(pagination.visibleSessionCount(in: retainedWorkspace) == 10)
  }

  private func makeWorkspace(sessionCount: Int) -> WorkspaceSidebarWorkspace {
    WorkspaceSidebarWorkspace(
      id: UUID(),
      name: "Project",
      sessions: (0..<sessionCount).map { index in
        WorkspaceSidebarSession(id: UUID(), title: "Session \(index)")
      }
    )
  }
}
