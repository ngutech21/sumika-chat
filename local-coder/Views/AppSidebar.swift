import LocalCoderCore
import SwiftUI

struct AppSidebar: View {
  let appState: AppState
  @Binding var selection: AppNavigationSelection?
  let onAddWorkspace: () -> Void
  @State private var sessionBeingRenamed: CodingSession?
  @State private var sessionPendingDeletion: CodingSession?
  @State private var renameTitle = ""

  var body: some View {
    List(selection: $selection) {
      Section {
        NavigationLink(value: AppNavigationSelection.models) {
          Label("Models", systemImage: "cpu")
        }
      }

      Section {
        Button(action: onAddWorkspace) {
          Label("Add Workspace", systemImage: "folder.badge.plus")
        }
      }

      ForEach(appState.workspaceLibrary.workspaces) { workspace in
        Section(workspace.name) {
          ForEach(workspace.sessions) { session in
            NavigationLink(value: AppNavigationSelection.session(session.id)) {
              Label(session.title, systemImage: "bubble.left.and.bubble.right")
            }
            .contextMenu {
              Button("Rename") {
                sessionBeingRenamed = session
                renameTitle = session.title
              }

              Button("Delete", role: .destructive) {
                sessionPendingDeletion = session
              }
            }
          }

          Button {
            if let sessionID = appState.createSession(in: workspace.id) {
              selection = .session(sessionID)
            }
          } label: {
            Label("New Session", systemImage: "plus")
          }
          .buttonStyle(.borderless)
        }
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("local-coder")
    .alert("Rename Session", isPresented: renameAlertBinding) {
      TextField("Session name", text: $renameTitle)

      Button("Cancel", role: .cancel) {
        sessionBeingRenamed = nil
        renameTitle = ""
      }

      Button("Rename") {
        if let sessionBeingRenamed {
          appState.renameSession(sessionBeingRenamed.id, title: renameTitle)
        }
        sessionBeingRenamed = nil
        renameTitle = ""
      }
    }
    .alert("Delete Session?", isPresented: deleteAlertBinding, presenting: sessionPendingDeletion) {
      session in
      Button("Cancel", role: .cancel) {
        sessionPendingDeletion = nil
      }

      Button("Delete", role: .destructive) {
        appState.deleteSession(session.id)
        sessionPendingDeletion = nil
      }
    } message: { session in
      Text("This permanently removes “\(session.title)” and its saved chat history.")
    }
  }

  private var renameAlertBinding: Binding<Bool> {
    Binding(
      get: { sessionBeingRenamed != nil },
      set: { isPresented in
        if !isPresented {
          sessionBeingRenamed = nil
          renameTitle = ""
        }
      }
    )
  }

  private var deleteAlertBinding: Binding<Bool> {
    Binding(
      get: { sessionPendingDeletion != nil },
      set: { isPresented in
        if !isPresented {
          sessionPendingDeletion = nil
        }
      }
    )
  }
}
