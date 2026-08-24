import SumikaCore
import SwiftUI

struct WorkspaceSidebar: View {
  let sidebarState: WorkspaceSidebarState
  let busySessionID: ChatSession.ID?
  let processResourceMonitor: ProcessResourceMonitor
  @Binding var selection: AppRoute?
  let onAddWorkspace: () -> Void
  let onCreateSession: (Workspace.ID) -> ChatSession.ID?
  let onRenameSession: (ChatSession.ID, String) -> Void
  let onDeleteSession: (ChatSession.ID) -> Void
  let onRemoveWorkspace: (Workspace.ID) -> Void
  @State private var sessionBeingRenamed: WorkspaceSidebarSession?
  @State private var sessionPendingDeletion: WorkspaceSidebarSession?
  @State private var workspacePendingRemoval: WorkspaceSidebarWorkspace?
  @State private var sessionPagination = WorkspaceSidebarPagination()
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
        processResourceMonitor: processResourceMonitor,
        onAddWorkspace: onAddWorkspace
      )
    }
    .onAppear {
      syncSessionPagination()
    }
    .onChange(of: selection) {
      revealSelectedSessionIfNeeded()
    }
    .onChange(of: sidebarState) {
      sessionPagination.retainWorkspaces(sidebarState.workspaces)
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
    .tag(AppRoute.models)
    .accessibilityIdentifier("sidebar.modelsLink")
    .accessibilityValue(selection == .models ? "Selected" : "")
  }

  @ViewBuilder
  private func workspaceSection(_ workspace: WorkspaceSidebarWorkspace) -> some View {
    DisclosureGroup(isExpanded: expansionBinding(for: workspace.id)) {
      ForEach(workspace.sessions.prefix(sessionPagination.visibleSessionCount(in: workspace))) {
        session in
        sessionRow(session, in: workspace.id)
      }

      if sessionPagination.hasMoreSessions(in: workspace) {
        showMoreSessionsButton(for: workspace)
      }
    } label: {
      Label {
        Text(workspace.name)
          .fontWeight(.semibold)
          .lineLimit(1)
          .truncationMode(.tail)
      } icon: {
        Image(systemName: isExpanded(workspace.id) ? "folder" : "folder.fill")
          .foregroundStyle(Color.accentColor)
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
      .accessibilityIdentifier("sidebar.workspaceDisclosure")
      .accessibilityValue(
        workspaceAccessibilityValue(
          workspace.id,
          isSelected: selection == .workspace(workspace.id)
        )
      )
    }
    .tag(AppRoute.workspace(workspace.id))
  }

  private func showMoreSessionsButton(for workspace: WorkspaceSidebarWorkspace) -> some View {
    let remainingSessionCount = sessionPagination.remainingSessionCount(in: workspace)

    return Button {
      withAnimation(.snappy(duration: 0.18)) {
        sessionPagination.showMoreSessions(in: workspace)
      }
    } label: {
      Text("Show more")
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(Color.accentColor)
    .accessibilityIdentifier("sidebar.showMoreSessions")
    .accessibilityLabel("Show more chats")
    .accessibilityValue(
      remainingSessionCount == 1
        ? "1 chat remaining" : "\(remainingSessionCount) chats remaining"
    )
  }

  private func sessionRow(
    _ session: WorkspaceSidebarSession,
    in workspaceID: Workspace.ID
  ) -> some View {
    let route = AppRoute.chat(workspaceID: workspaceID, sessionID: session.id)

    return HStack(spacing: 6) {
      Text(session.displayTitle)
        .lineLimit(1)
        .truncationMode(.tail)
      if busySessionID == session.id {
        ProgressView()
          .controlSize(.mini)
          .accessibilityLabel("Chat operation in progress")
      }
    }
    .tag(route)
    .accessibilityIdentifier("sidebar.sessionLink")
    .accessibilityValue(selection == route ? "Selected" : "")
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
    _ = onCreateSession(workspaceID)
  }

  private func workspaceAccessibilityValue(
    _ workspaceID: Workspace.ID,
    isSelected: Bool
  ) -> String {
    let expansionValue = isExpanded(workspaceID) ? "Expanded" : "Collapsed"
    return isSelected ? "\(expansionValue), Selected" : expansionValue
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

  private func syncSessionPagination() {
    sessionPagination.retainWorkspaces(sidebarState.workspaces)
    revealSelectedSessionIfNeeded()
  }

  private func revealSelectedSessionIfNeeded() {
    guard case .chat(let workspaceID, let sessionID) = selection,
      let workspace = sidebarState.workspaces.first(where: { $0.id == workspaceID })
    else {
      return
    }

    sessionPagination.revealSession(sessionID, in: workspace)
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

struct WorkspaceSidebarPagination: Equatable {
  static let pageSize = 5

  private var requestedVisibleSessionCounts: [Workspace.ID: Int] = [:]

  func visibleSessionCount(in workspace: WorkspaceSidebarWorkspace) -> Int {
    min(
      requestedVisibleSessionCounts[workspace.id, default: Self.pageSize],
      workspace.sessions.count
    )
  }

  func remainingSessionCount(in workspace: WorkspaceSidebarWorkspace) -> Int {
    workspace.sessions.count - visibleSessionCount(in: workspace)
  }

  func hasMoreSessions(in workspace: WorkspaceSidebarWorkspace) -> Bool {
    remainingSessionCount(in: workspace) > 0
  }

  mutating func showMoreSessions(in workspace: WorkspaceSidebarWorkspace) {
    requestedVisibleSessionCounts[workspace.id] = min(
      visibleSessionCount(in: workspace) + Self.pageSize,
      workspace.sessions.count
    )
  }

  mutating func revealSession(
    _ sessionID: ChatSession.ID,
    in workspace: WorkspaceSidebarWorkspace
  ) {
    guard let sessionIndex = workspace.sessions.firstIndex(where: { $0.id == sessionID }) else {
      return
    }

    let requiredVisibleSessionCount = ((sessionIndex / Self.pageSize) + 1) * Self.pageSize
    let requestedVisibleSessionCount = requestedVisibleSessionCounts[
      workspace.id,
      default: Self.pageSize
    ]
    guard requiredVisibleSessionCount > requestedVisibleSessionCount else {
      return
    }

    requestedVisibleSessionCounts[workspace.id] = requiredVisibleSessionCount
  }

  mutating func retainWorkspaces(_ workspaces: [WorkspaceSidebarWorkspace]) {
    let workspaceIDs = Set(workspaces.map(\.id))
    requestedVisibleSessionCounts = requestedVisibleSessionCounts.filter {
      workspaceIDs.contains($0.key)
    }
  }
}

private struct SidebarRuntimeFooter: View {
  let processResourceMonitor: ProcessResourceMonitor
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

      ProcessResourceFooter(monitor: processResourceMonitor)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial)
    .overlay(alignment: .top) {
      Divider()
    }
  }
}
