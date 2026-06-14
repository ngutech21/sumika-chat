import LocalCoderCore
import SwiftUI

struct AppSidebar: View {
  let appState: AppState
  @Binding var selection: AppNavigationSelection?
  let onAddWorkspace: () -> Void
  @State private var sessionBeingRenamed: ChatSession?
  @State private var sessionPendingDeletion: ChatSession?
  @State private var renameTitle = ""
  @AppStorage("sidebar.collapsedWorkspaceIDs") private var collapsedWorkspaceIDsRaw = ""

  private var collapsedWorkspaces: Set<Workspace.ID> {
    Set(collapsedWorkspaceIDsRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
  }

  var body: some View {
    List(selection: $selection) {
      Section {
        NavigationLink(value: AppNavigationSelection.models) {
          Label("Models", systemImage: "cpu")
        }
        .accessibilityIdentifier("sidebar.modelsLink")
      }

      Section("Workspaces") {
        ForEach(appState.workspaceLibrary.workspaces) { workspace in
          DisclosureGroup(isExpanded: expansionBinding(for: workspace.id)) {
            ForEach(workspace.sessions) { session in
              NavigationLink(value: AppNavigationSelection.session(session.id)) {
                Text(sidebarTitle(for: session))
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
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar.newSessionButton")
          } label: {
            Label {
              Text(workspace.name)
            } icon: {
              Image(systemName: isExpanded(workspace.id) ? "folder.fill" : "folder")
                .foregroundStyle(.tint)
            }
          }
          .accessibilityIdentifier("sidebar.workspaceDisclosure")
        }
      }
    }
    .accessibilityIdentifier("sidebar.workspaceList")
    .listStyle(.sidebar)
    .navigationTitle("local-coder")
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HStack(spacing: 0) {
        Button(action: onAddWorkspace) {
          Image(systemName: "plus")
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .padding(.leading, 8)
        .help("Add Workspace")
        .accessibilityIdentifier("sidebar.addWorkspaceButton")

        ModelRuntimeFooter(processUsage: appState.chatController.modelRuntime.processUsage)
      }
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

  private func isExpanded(_ workspaceID: Workspace.ID) -> Bool {
    !collapsedWorkspaces.contains(workspaceID)
  }

  private func expansionBinding(for workspaceID: Workspace.ID) -> Binding<Bool> {
    Binding(
      get: { !collapsedWorkspaces.contains(workspaceID) },
      set: { isExpanded in
        withAnimation(.snappy(duration: 0.22)) {
          var ids = collapsedWorkspaces
          if isExpanded {
            ids.remove(workspaceID)
          } else {
            ids.insert(workspaceID)
          }
          collapsedWorkspaceIDsRaw = ids.map(\.uuidString).sorted().joined(separator: ",")
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
