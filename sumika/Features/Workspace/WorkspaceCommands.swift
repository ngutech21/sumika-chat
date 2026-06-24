import SumikaCore
import SwiftUI

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
