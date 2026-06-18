import SumikaCore
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
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          modelRow

          VStack(alignment: .leading, spacing: 4) {
            Text("Workspaces")
              .font(.caption)
              .fontWeight(.semibold)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 14)
              .padding(.top, 2)

            ForEach(appState.workspaceLibrary.workspaces) { workspace in
              workspaceSection(workspace)
            }
          }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityIdentifier("sidebar.workspaceList")

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

        ModelRuntimeFooter(processUsage: appState.chatController.modelRuntime.processUsage)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.regularMaterial)
      .overlay(alignment: .top) {
        Divider()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

  private var modelRow: some View {
    Button {
      selection = .models
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "cpu")
          .foregroundStyle(.secondary)
          .frame(width: 16)

        Text("Models")
          .lineLimit(1)

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .frame(height: 28)
      .background(rowBackground(isSelected: selection == .models))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("sidebar.modelsLink")
    .accessibilityValue(selection == .models ? "Selected" : "")
  }

  @ViewBuilder
  private func workspaceSection(_ workspace: Workspace) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Button {
        toggleExpansion(for: workspace.id)
      } label: {
        HStack(spacing: 6) {
          Image(systemName: isExpanded(workspace.id) ? "chevron.down" : "chevron.right")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(width: 10)

          Image(systemName: isExpanded(workspace.id) ? "folder" : "folder.fill")
            .foregroundStyle(.tint)
            .frame(width: 16)

          Text(workspace.name)
            .fontWeight(.semibold)
            .lineLimit(1)
            .truncationMode(.tail)

          Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("sidebar.workspaceDisclosure")
      .accessibilityValue(isExpanded(workspace.id) ? "Expanded" : "Collapsed")

      if isExpanded(workspace.id) {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(workspace.sessions) { session in
            sessionRow(session)
          }

          newSessionButton(for: workspace.id)
        }
        .padding(.leading, 18)
      }
    }
  }

  private func sessionRow(_ session: ChatSession) -> some View {
    let item = AppNavigationSelection.session(session.id)
    let isSelected = selection == item

    return Button {
      selection = item
    } label: {
      HStack(spacing: 8) {
        Text(sidebarTitle(for: session))
          .lineLimit(1)
          .truncationMode(.tail)

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .frame(height: 28)
      .background(rowBackground(isSelected: isSelected))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("sidebar.sessionLink")
    .accessibilityValue(isSelected ? "Selected" : "")
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

  private func newSessionButton(for workspaceID: Workspace.ID) -> some View {
    Button {
      if let sessionID = appState.createSession(in: workspaceID) {
        selection = .session(sessionID)
      }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "plus")
          .foregroundStyle(.secondary)
          .frame(width: 16)

        Text("New Chat")

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .frame(height: 28)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("sidebar.newSessionButton")
  }

  private func rowBackground(isSelected: Bool) -> some View {
    RoundedRectangle(cornerRadius: 6, style: .continuous)
      .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
  }

  private func sidebarTitle(for session: ChatSession) -> String {
    session.title == ChatSession.defaultTitle ? "Untitled" : session.title
  }

  private func isExpanded(_ workspaceID: Workspace.ID) -> Bool {
    !collapsedWorkspaces.contains(workspaceID)
  }

  private func toggleExpansion(for workspaceID: Workspace.ID) {
    withAnimation(.snappy(duration: 0.18)) {
      var ids = collapsedWorkspaces
      if ids.contains(workspaceID) {
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
}
