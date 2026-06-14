import LocalCoderCore
import SwiftUI

struct AppSidebar: View {
  let appState: AppState
  @Binding var selection: AppNavigationSelection?
  let onAddWorkspace: () -> Void
  @State private var sessionBeingRenamed: ChatSession?
  @State private var sessionPendingDeletion: ChatSession?
  @State private var renameTitle = ""
  private let workspaceChildIndent: CGFloat = 24

  var body: some View {
    List(selection: $selection) {
      Section {
        NavigationLink(value: AppNavigationSelection.settings) {
          Label("Settings", systemImage: "gearshape")
        }
        .accessibilityIdentifier("sidebar.settingsLink")

        NavigationLink(value: AppNavigationSelection.models) {
          Label("Models", systemImage: "cpu")
        }
        .accessibilityIdentifier("sidebar.modelsLink")
      }

      Section {
        Button(action: onAddWorkspace) {
          Label("Add Workspace", systemImage: "folder.badge.plus")
            .font(.body)
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
        .accessibilityIdentifier("sidebar.addWorkspaceButton")
      }

      ForEach(appState.workspaceLibrary.workspaces) { workspace in
        Section {
          ForEach(workspace.sessions) { session in
            NavigationLink(value: AppNavigationSelection.session(session.id)) {
              Text(sidebarTitle(for: session))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, workspaceChildIndent)
            }
            .accessibilityIdentifier("sidebar.sessionLink")
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
            HStack(spacing: 8) {
              Image(systemName: "plus")
                .foregroundStyle(.secondary)

              Text("New Chat")
            }
            .font(.callout)
            .padding(.leading, workspaceChildIndent)
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("sidebar.newSessionButton")
        } header: {
          Label {
            Text(workspace.name)
              .font(.body.weight(.semibold))
              .foregroundStyle(.primary)
          } icon: {
            Image(systemName: "folder.fill")
          }
        }
      }
    }
    .accessibilityIdentifier("sidebar.workspaceList")
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

  private func sidebarTitle(for session: ChatSession) -> String {
    session.title == ChatSession.defaultTitle ? "Untitled" : session.title
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
