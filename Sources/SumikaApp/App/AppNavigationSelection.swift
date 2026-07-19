import SumikaCore

enum AppRoute: Hashable {
  case models
  case workspace(Workspace.ID)
  case chat(workspaceID: Workspace.ID, sessionID: ChatSession.ID)
}
