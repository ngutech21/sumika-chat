import SumikaCore

struct WorkspaceSidebarState: Equatable, Sendable {
  var workspaces: [WorkspaceSidebarWorkspace]

  init(workspaces: [WorkspaceSidebarWorkspace] = []) {
    self.workspaces = workspaces
  }

  init(library: WorkspaceLibrary) {
    self.init(
      workspaces: library.workspaces.map(WorkspaceSidebarWorkspace.init)
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
