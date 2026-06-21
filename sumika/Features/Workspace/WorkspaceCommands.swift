import SumikaCore
import SwiftUI

struct WorkspaceCommandHost<Content: View>: View {
  let workspaceState: WorkspaceFeatureState
  let onRemoveWorkspace: (Workspace.ID) -> Void
  let content: Content
  @State private var workspacePendingRemoval: Workspace?

  init(
    workspaceState: WorkspaceFeatureState,
    onRemoveWorkspace: @escaping (Workspace.ID) -> Void,
    @ViewBuilder content: () -> Content
  ) {
    self.workspaceState = workspaceState
    self.onRemoveWorkspace = onRemoveWorkspace
    self.content = content()
  }

  var body: some View {
    content
      .focusedSceneValue(\.removeWorkspaceAction, removeWorkspaceMenuAction)
      .modifier(
        RemoveWorkspaceAlert(
          workspace: $workspacePendingRemoval,
          onRemove: { workspace in onRemoveWorkspace(workspace.id) }
        )
      )
  }

  private var removeWorkspaceMenuAction: (() -> Void)? {
    guard workspaceState.activeWorkspace != nil else {
      return nil
    }

    return removeActiveWorkspace
  }

  private func removeActiveWorkspace() {
    workspacePendingRemoval = workspaceState.activeWorkspace
  }
}

struct WorkspaceErrorAlert: ViewModifier {
  @Binding var isPresented: Bool
  let message: String
  let onDismiss: () -> Void

  func body(content: Content) -> some View {
    content.alert("Workspace Error", isPresented: $isPresented) {
      Button("OK", role: .cancel) {
        onDismiss()
      }
    } message: {
      Text(message)
    }
  }
}

struct RemoveWorkspaceAlert: ViewModifier {
  @Binding var workspace: Workspace?
  let onRemove: (Workspace) -> Void

  func body(content: Content) -> some View {
    content.alert(
      "Remove Workspace from Sumika?",
      isPresented: isPresented,
      presenting: workspace
    ) { workspace in
      Button("Cancel", role: .cancel) {
        self.workspace = nil
      }

      Button("Remove", role: .destructive) {
        onRemove(workspace)
        self.workspace = nil
      }
    } message: { workspace in
      Text(
        "This removes “\(workspace.name)” and its saved Sumika chats from the app. The folder on disk will not be deleted."
      )
    }
  }

  private var isPresented: Binding<Bool> {
    Binding(
      get: { workspace != nil },
      set: { isPresented in
        if !isPresented {
          workspace = nil
        }
      }
    )
  }
}
