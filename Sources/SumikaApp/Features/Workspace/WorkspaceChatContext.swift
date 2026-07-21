import Foundation
import SumikaCore

struct WorkspaceChatContext: Equatable, Identifiable, Sendable {
  let id: Workspace.ID
  let name: String
  let rootURL: URL

  init(workspace: Workspace) {
    self.id = workspace.id
    self.name = workspace.name
    self.rootURL = workspace.rootURL
  }
}
