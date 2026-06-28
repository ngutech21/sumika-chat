import SumikaCore
import SwiftUI

struct WorkspaceSidebar: View {
  let sidebarState: WorkspaceSidebarState
  let modelRuntime: ModelRuntimeController
  @Binding var selection: AppNavigationSelection?
  let onAddWorkspace: () -> Void
  let onCreateSession: (Workspace.ID) -> ChatSession.ID?
  let onRenameSession: (ChatSession.ID, String) -> Void
  let onDeleteSession: (ChatSession.ID) -> Void
  let onRemoveWorkspace: (Workspace.ID) -> Void
  @State private var sessionBeingRenamed: WorkspaceSidebarSession?
  @State private var sessionPendingDeletion: WorkspaceSidebarSession?
  @State private var workspacePendingRemoval: WorkspaceSidebarWorkspace?
  @State private var renameTitle = ""
  @AppStorage("sidebar.collapsedWorkspaceIDs") private var collapsedWorkspaceIDsRaw = ""

  private var collapsedWorkspaces: Set<Workspace.ID> {
    Set(collapsedWorkspaceIDsRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
  }

  var body: some View {
    VStack(spacing: 0) {
      List(selection: $selection) {
        Section {
          modelRow
        }

        Section("Workspaces") {
          ForEach(sidebarState.workspaces) { workspace in
            workspaceSection(workspace)
          }
        }
      }
      .listStyle(.sidebar)
      .accessibilityIdentifier("sidebar.workspaceList")

      SidebarRuntimeFooter(
        modelRuntime: modelRuntime,
        onAddWorkspace: onAddWorkspace
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .alert("Rename Chat", isPresented: renameAlertBinding) {
      TextField("Chat name", text: $renameTitle)

      Button("Cancel", role: .cancel) {
        sessionBeingRenamed = nil
        renameTitle = ""
      }

      Button("Rename") {
        if let sessionBeingRenamed {
          onRenameSession(sessionBeingRenamed.id, renameTitle)
        }
        sessionBeingRenamed = nil
        renameTitle = ""
      }
    }
    .alert("Remove Chat?", isPresented: deleteAlertBinding, presenting: sessionPendingDeletion) {
      session in
      Button("Cancel", role: .cancel) {
        sessionPendingDeletion = nil
      }

      Button("Remove", role: .destructive) {
        onDeleteSession(session.id)
        sessionPendingDeletion = nil
      }
    } message: { session in
      Text("This permanently removes “\(session.title)” and its saved chat history.")
    }
    .alert(
      "Remove Workspace from Sumika?",
      isPresented: removeWorkspaceAlertBinding,
      presenting: workspacePendingRemoval
    ) { workspace in
      Button("Cancel", role: .cancel) {
        workspacePendingRemoval = nil
      }

      Button("Remove", role: .destructive) {
        onRemoveWorkspace(workspace.id)
        workspacePendingRemoval = nil
      }
    } message: { workspace in
      Text(
        "This removes “\(workspace.name)” and its saved Sumika chats from the app. The folder on disk will not be deleted."
      )
    }
  }

  private var modelRow: some View {
    Label {
      Text("Models")
        .lineLimit(1)
    } icon: {
      Image(systemName: "cpu")
        .foregroundStyle(.secondary)
    }
    .tag(AppNavigationSelection.models)
    .accessibilityIdentifier("sidebar.modelsLink")
    .accessibilityValue(selection == .models ? "Selected" : "")
  }

  @ViewBuilder
  private func workspaceSection(_ workspace: WorkspaceSidebarWorkspace) -> some View {
    DisclosureGroup(isExpanded: expansionBinding(for: workspace.id)) {
      ForEach(workspace.sessions) { session in
        sessionRow(session)
      }
    } label: {
      Label {
        Text(workspace.name)
          .fontWeight(.semibold)
          .lineLimit(1)
          .truncationMode(.tail)
      } icon: {
        Image(systemName: isExpanded(workspace.id) ? "folder" : "folder.fill")
          .foregroundStyle(.tint)
      }
      .contextMenu {
        Button("New Chat") {
          createSession(in: workspace.id)
        }

        Divider()

        Button("Remove Workspace", role: .destructive) {
          workspacePendingRemoval = workspace
        }
      }
    }
    .accessibilityIdentifier("sidebar.workspaceDisclosure")
    .accessibilityValue(isExpanded(workspace.id) ? "Expanded" : "Collapsed")
  }

  private func sessionRow(_ session: WorkspaceSidebarSession) -> some View {
    let item = AppNavigationSelection.session(session.id)

    return Text(session.displayTitle)
      .lineLimit(1)
      .truncationMode(.tail)
      .tag(item)
      .accessibilityIdentifier("sidebar.sessionLink")
      .accessibilityValue(selection == item ? "Selected" : "")
      .contextMenu {
        Button("Rename Chat") {
          sessionBeingRenamed = session
          renameTitle = session.title
        }

        Divider()

        Button("Remove Chat", role: .destructive) {
          sessionPendingDeletion = session
        }
      }
  }

  private func isExpanded(_ workspaceID: Workspace.ID) -> Bool {
    !collapsedWorkspaces.contains(workspaceID)
  }

  private func createSession(in workspaceID: Workspace.ID) {
    setWorkspace(workspaceID, isExpanded: true)
    if let sessionID = onCreateSession(workspaceID) {
      selection = .session(sessionID)
    }
  }

  private func expansionBinding(for workspaceID: Workspace.ID) -> Binding<Bool> {
    Binding(
      get: { isExpanded(workspaceID) },
      set: { isExpanded in
        setWorkspace(workspaceID, isExpanded: isExpanded)
      }
    )
  }

  private func setWorkspace(_ workspaceID: Workspace.ID, isExpanded: Bool) {
    withAnimation(.snappy(duration: 0.18)) {
      var ids = collapsedWorkspaces
      if isExpanded {
        ids.remove(workspaceID)
      } else {
        ids.insert(workspaceID)
      }
      collapsedWorkspaceIDsRaw = ids.map(\.uuidString).sorted().joined(separator: ",")
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

  private var removeWorkspaceAlertBinding: Binding<Bool> {
    Binding(
      get: { workspacePendingRemoval != nil },
      set: { isPresented in
        if !isPresented {
          workspacePendingRemoval = nil
        }
      }
    )
  }
}

private struct SidebarRuntimeFooter: View {
  let modelRuntime: ModelRuntimeController
  let onAddWorkspace: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      Button(action: onAddWorkspace) {
        Image(systemName: "plus")
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .frame(width: 36, height: 34)
      .accessibilityLabel("Add Workspace")
      .accessibilityIdentifier("sidebar.addWorkspaceButton")

      SettingsLink {
        Image(systemName: "gearshape")
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .frame(width: 36, height: 34)
      .accessibilityLabel("Settings")
      .accessibilityIdentifier("sidebar.settingsButton")

      ModelRuntimeFooter(processUsage: modelRuntime.processUsage)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial)
    .overlay(alignment: .top) {
      Divider()
    }
  }
}
