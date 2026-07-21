import Foundation
import SumikaCore
import Testing

@testable import SumikaApp

struct WorkspaceChatContextTests {
  @Test
  func contextKeepsWorkspaceRouteMetadataWithoutCopyingSessions() {
    let workspaceID = UUID()
    let bookmarkData = Data([1, 2, 3])
    let rootURL = URL(filePath: "/tmp/project")
    let context = WorkspaceChatContext(
      workspace: Workspace(
        id: workspaceID,
        name: "Project",
        rootURL: rootURL,
        bookmarkData: bookmarkData,
        sessions: [
          ChatSession(id: UUID(), title: "Persisted")
        ]
      )
    )

    #expect(context.id == workspaceID)
    #expect(context.name == "Project")
    #expect(context.rootURL == rootURL)
    #expect(context.bookmarkData == bookmarkData)
  }
}
