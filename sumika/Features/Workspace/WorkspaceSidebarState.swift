import Foundation
import SumikaCore

struct WorkspaceSidebarState: Equatable, Sendable {
  var workspaces: [WorkspaceSidebarWorkspace]
  var activeSessionID: ChatSession.ID?

  init(workspaces: [WorkspaceSidebarWorkspace] = [], activeSessionID: ChatSession.ID? = nil) {
    self.workspaces = workspaces
    self.activeSessionID = activeSessionID
  }

  init(library: WorkspaceLibrary) {
    self.init(
      workspaces: library.workspaces.map(WorkspaceSidebarWorkspace.init),
      activeSessionID: library.activeSessionID
    )
  }
}

struct WorkspaceSidebarWorkspace: Equatable, Identifiable, Sendable {
  let id: Workspace.ID
  let name: String
  let sessions: [WorkspaceSidebarSession]

  init(id: Workspace.ID, name: String, sessions: [WorkspaceSidebarSession]) {
    self.id = id
    self.name = name
    self.sessions = sessions
  }

  init(workspace: Workspace) {
    self.init(
      id: workspace.id,
      name: workspace.name,
      sessions: workspace.sessions.map(WorkspaceSidebarSession.init)
    )
  }
}

struct WorkspaceSidebarSession: Equatable, Identifiable, Sendable {
  let id: ChatSession.ID
  let title: String

  init(id: ChatSession.ID, title: String) {
    self.id = id
    self.title = title
  }

  init(session: ChatSession) {
    self.init(id: session.id, title: session.title)
  }

  var displayTitle: String {
    title == ChatSession.defaultTitle ? "Untitled" : title
  }
}
