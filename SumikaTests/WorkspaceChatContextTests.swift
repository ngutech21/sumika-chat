import Foundation
import SumikaCore
import Testing

@testable import Sumika

struct WorkspaceChatContextTests {
  @Test
  func workspaceContainingSessionKeepsRouteMetadataWithoutPersistedSessions() {
    let workspaceID = UUID()
    let sessionID = UUID()
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

    let bridgedWorkspace = context.workspace(containing: sessionID)

    #expect(bridgedWorkspace.id == workspaceID)
    #expect(bridgedWorkspace.name == "Project")
    #expect(bridgedWorkspace.rootURL == rootURL)
    #expect(bridgedWorkspace.bookmarkData == bookmarkData)
    #expect(bridgedWorkspace.sessions.map(\.id) == [sessionID])
  }
}
