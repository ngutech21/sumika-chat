import AppKit
import SumikaCore
import SwiftUI

struct ContentView: View {
  @AppStorage("workspaceChat.isModelContextDebugVisible") private var isModelContextDebugVisible =
    false
  @AppStorage("workspaceChat.isTerminalVisible") private var isTerminalVisible = false
  @State private var modelsTab = ModelsTab.text
  @State private var appState: AppState
  @State private var workspaceChatActions: WorkspaceChatActions

  @MainActor
  init(appState: AppState) {
    _appState = State(initialValue: appState)
    _workspaceChatActions = State(
      initialValue: WorkspaceChatActions(workspaceState: appState.workspaceState)
    )
  }

  var body: some View {
    let controller = appState.chatController

    NavigationSplitView {
      WorkspaceSidebar(
        sidebarState: appState.workspaceState.sidebarState,
        processUsage: appState.modelManagementState.state.processUsage,
        selection: routeSelection,
        onAddWorkspace: chooseWorkspace,
        onCreateSession: createSession,
        onRenameSession: appState.renameSession,
        onDeleteSession: deleteSession,
        onRemoveWorkspace: appState.removeWorkspace
      )
      .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 460)
    } detail: {
      detailContent(controller: controller)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 880, minHeight: 560)
    .onAppear {
      appState.startModelRuntimeServices()
    }
    .modifier(
      WorkspaceErrorAlert(
        isPresented: workspaceErrorAlertBinding,
        message: appState.workspaceState.errorMessage ?? "",
        onDismiss: { appState.workspaceState.errorMessage = nil }
      )
    )
  }

  @ViewBuilder
  private func detailContent(controller: ChatSessionController) -> some View {
    if let route = appState.route {
      switch route {
      case .models:
        ModelsView(
          modelManagementState: appState.modelManagementState,
          audioModelController: appState.audioModelController,
          selectedTab: $modelsTab,
          errorMessage: appState.modelManagementState.errorMessage
        )
      case .workspace:
        WorkspaceRouteHost(
          activeWorkspaceContext: appState.workspaceState.activeWorkspaceContext,
          activeSessionID: nil,
          controller: appState.chatController,
          modelManagementState: appState.modelManagementState,
          browserToolService: appState.browserToolService,
          appBehaviorSettings: appState.settingsState.appBehaviorSettings,
          mcpServers: appState.settingsState.mcpServers,
          mcpServerStatuses: appState.settingsState.mcpServerStatuses,
          assistantSpeechService: appState.assistantSpeechService,
          speechInputController: appState.composerSpeechInputController,
          workspaceChatActions: workspaceChatActions,
          isModelContextDebugVisible: modelContextDebugVisibilityBinding,
          isWorkspaceTerminalVisible: $isTerminalVisible,
          onAddWorkspace: chooseWorkspace,
          onCreateSession: createSession,
          onSendMessage: appState.sendMessage,
          onSelectMCPServerIDs: appState.setSelectedMCPServerIDs,
          onOpenAudioModels: openAudioModels
        )
      case .chat(_, let sessionID):
        WorkspaceRouteHost(
          activeWorkspaceContext: appState.workspaceState.activeWorkspaceContext,
          activeSessionID: sessionID,
          controller: appState.chatController,
          modelManagementState: appState.modelManagementState,
          browserToolService: appState.browserToolService,
          appBehaviorSettings: appState.settingsState.appBehaviorSettings,
          mcpServers: appState.settingsState.mcpServers,
          mcpServerStatuses: appState.settingsState.mcpServerStatuses,
          assistantSpeechService: appState.assistantSpeechService,
          speechInputController: appState.composerSpeechInputController,
          workspaceChatActions: workspaceChatActions,
          isModelContextDebugVisible: modelContextDebugVisibilityBinding,
          isWorkspaceTerminalVisible: $isTerminalVisible,
          onAddWorkspace: chooseWorkspace,
          onCreateSession: createSession,
          onSendMessage: appState.sendMessage,
          onSelectMCPServerIDs: appState.setSelectedMCPServerIDs,
          onOpenAudioModels: openAudioModels
        )
      }
    } else {
      EmptyWorkspaceView(onAddWorkspace: chooseWorkspace)
    }
  }

  private var routeSelection: Binding<AppRoute?> {
    Binding(
      get: { appState.route },
      set: { newRoute in
        appState.navigate(to: newRoute)
      }
    )
  }

  private var workspaceErrorAlertBinding: Binding<Bool> {
    Binding(
      get: { appState.workspaceState.errorMessage != nil },
      set: { isPresented in
        if !isPresented {
          appState.workspaceState.errorMessage = nil
        }
      }
    )
  }

  private var modelContextDebugVisibilityBinding: Binding<Bool> {
    #if DEBUG
      return $isModelContextDebugVisible
    #else
      return .constant(false)
    #endif
  }

  private func chooseWorkspace() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.message = "Choose a folder to use as a Sumika workspace."
    panel.prompt = "Add Workspace"

    if panel.runModal() == .OK, let url = panel.url {
      _ = appState.addWorkspace(from: url)
    }
  }

  private func createSession(in workspaceID: Workspace.ID) -> ChatSession.ID? {
    appState.createSession(in: workspaceID)
  }

  private func deleteSession(_ sessionID: ChatSession.ID) {
    appState.deleteSession(sessionID)
  }

  private func openAudioModels() {
    modelsTab = .audio
    appState.selectModels()
  }

}

#Preview {
  ContentView(appState: AppLaunchConfiguration.makeAppState())
}

private struct WorkspaceRouteHost: View {
  let activeWorkspaceContext: WorkspaceChatContext?
  let activeSessionID: ChatSession.ID?
  let controller: ChatSessionController
  let modelManagementState: ModelManagementFeatureState
  let browserToolService: HTMLPreviewBrowserToolService
  let appBehaviorSettings: AppBehaviorSettings
  let mcpServers: [MCPServerConfig]
  let mcpServerStatuses: [MCPServerStatus]
  let assistantSpeechService: AssistantSpeechService
  let speechInputController: ComposerSpeechInputController
  let workspaceChatActions: WorkspaceChatActions
  @Binding var isModelContextDebugVisible: Bool
  @Binding var isWorkspaceTerminalVisible: Bool
  let onAddWorkspace: () -> Void
  let onCreateSession: (Workspace.ID) -> ChatSession.ID?
  let onSendMessage: (String, WorkspaceChatContext, ChatSession.ID?) -> Bool
  let onSelectMCPServerIDs: ([UUID]) -> Void
  let onOpenAudioModels: () -> Void

  var body: some View {
    if let context = activeWorkspaceContext {
      WorkspaceChatView(
        controller: controller,
        context: context,
        sessionID: activeSessionID,
        modelManagementState: modelManagementState,
        browserToolService: browserToolService,
        appBehaviorSettings: appBehaviorSettings,
        mcpServers: mcpServers,
        mcpServerStatuses: mcpServerStatuses,
        assistantSpeechService: assistantSpeechService,
        speechInputController: speechInputController,
        workspaceChatActions: workspaceChatActions,
        isModelContextDebugVisible: $isModelContextDebugVisible,
        isWorkspaceTerminalVisible: $isWorkspaceTerminalVisible,
        onCreateSession: onCreateSession,
        onSendMessage: onSendMessage,
        onSelectMCPServerIDs: onSelectMCPServerIDs,
        onOpenAudioModels: onOpenAudioModels
      )
      .equatable()
    } else {
      EmptyWorkspaceView(onAddWorkspace: onAddWorkspace)
    }
  }
}
