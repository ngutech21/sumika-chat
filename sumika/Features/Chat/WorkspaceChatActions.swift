@MainActor
final class WorkspaceChatActions {
  private let workspaceState: WorkspaceFeatureState

  init(workspaceState: WorkspaceFeatureState) {
    self.workspaceState = workspaceState
  }

  func openWorkspaceInFinder() {
    workspaceState.openActiveWorkspaceInFinder()
  }

  func openWorkspaceInVisualStudioCode() {
    workspaceState.openActiveWorkspaceInVisualStudioCode()
  }
}
