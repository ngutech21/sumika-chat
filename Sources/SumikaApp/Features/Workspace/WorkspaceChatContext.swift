import Foundation
import SumikaCore

struct WorkspaceChatContext: Equatable, Identifiable, Sendable {
  let id: Workspace.ID
  let name: String
  let rootURL: URL
  let bookmarkData: Data?

  init(workspace: Workspace) {
    self.id = workspace.id
    self.name = workspace.name
    self.rootURL = workspace.rootURL
    self.bookmarkData = workspace.bookmarkData
  }

}
