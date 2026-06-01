import SwiftUI

struct EmptyWorkspaceView: View {
  let onAddWorkspace: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("No Workspace", systemImage: "folder")
    } description: {
      Text("Choose a folder to start a local coding session.")
    } actions: {
      Button(action: onAddWorkspace) {
        Label("Add Workspace", systemImage: "folder.badge.plus")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
