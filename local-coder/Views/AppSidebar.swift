import LocalCoderCore
import SwiftUI

struct AppSidebar: View {
  let appState: AppState
  @Binding var selection: AppNavigationSelection?
  let onAddWorkspace: () -> Void
  @State private var sessionBeingRenamed: ChatSession?
  @State private var sessionPendingDeletion: ChatSession?
  @State private var renameTitle = ""
  @State private var collapsedWorkspaces: Set<Workspace.ID> = []

  var body: some View {
    List(selection: $selection) {
      Section {
        NavigationLink(value: AppNavigationSelection.settings) {
          Label("Settings", systemImage: "gearshape")
            .font(.body.weight(.regular))
        }
        .accessibilityIdentifier("sidebar.settingsLink")

        NavigationLink(value: AppNavigationSelection.models) {
          Label("Models", systemImage: "cpu")
            .font(.body.weight(.regular))
        }
        .accessibilityIdentifier("sidebar.modelsLink")
      }

      Section {
        Button(action: onAddWorkspace) {
          Label("Add Workspace", systemImage: "folder.badge.plus")
            .font(.body.weight(.regular))
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
        .accessibilityIdentifier("sidebar.addWorkspaceButton")
      }

      ForEach(appState.workspaceLibrary.workspaces) { workspace in
        DisclosureGroup(isExpanded: expansionBinding(for: workspace.id)) {
          ForEach(workspace.sessions) { session in
            NavigationLink(value: AppNavigationSelection.session(session.id)) {
              Text(sidebarTitle(for: session))
                .font(.callout.weight(.regular))
                .lineLimit(1)
                .truncationMode(.tail)
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
            .font(.callout.weight(.regular))
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("sidebar.newSessionButton")
        } label: {
          Label {
            Text(workspace.name)
              .font(.body.weight(.medium))
              .foregroundStyle(.primary)
          } icon: {
            Image(systemName: "folder")
          }
        }
        .accessibilityIdentifier("sidebar.workspaceDisclosure")
      }
    }
    .accessibilityIdentifier("sidebar.workspaceList")
    .listStyle(.sidebar)
    .navigationTitle("local-coder")
    .safeAreaInset(edge: .bottom, spacing: 0) {
      ModelRuntimeFooter(processUsage: appState.chatController.modelRuntime.processUsage)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
          Divider()
        }
    }
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

  private func expansionBinding(for workspaceID: Workspace.ID) -> Binding<Bool> {
    Binding(
      get: { !collapsedWorkspaces.contains(workspaceID) },
      set: { isExpanded in
        if isExpanded {
          collapsedWorkspaces.remove(workspaceID)
        } else {
          collapsedWorkspaces.insert(workspaceID)
        }
      }
    )
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
