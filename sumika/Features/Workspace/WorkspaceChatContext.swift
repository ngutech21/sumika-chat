import Foundation
import SumikaCore

struct WorkspaceChatContext: Equatable, Identifiable, Sendable {
  let id: Workspace.ID
  let name: String
  let rootURL: URL
  let bookmarkData: Data?

  private static let placeholderDate = Date(timeIntervalSince1970: 0)

  init(workspace: Workspace) {
    self.id = workspace.id
    self.name = workspace.name
    self.rootURL = workspace.rootURL
    self.bookmarkData = workspace.bookmarkData
  }

  var workspaceWithoutSessions: Workspace {
    Workspace(
      id: id,
      name: name,
      rootURL: rootURL,
      bookmarkData: bookmarkData,
      sessions: [],
      createdAt: Self.placeholderDate,
      updatedAt: Self.placeholderDate
    )
  }

  func workspace(containing sessionID: ChatSession.ID) -> Workspace {
    Workspace(
      id: id,
      name: name,
      rootURL: rootURL,
      bookmarkData: bookmarkData,
      sessions: [ChatSession(id: sessionID)],
      createdAt: Self.placeholderDate,
      updatedAt: Self.placeholderDate
    )
  }
}
