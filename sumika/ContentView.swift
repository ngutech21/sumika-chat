import AppKit
import SumikaCore
import SwiftUI

struct ContentView: View {
  @AppStorage("workspaceChat.isModelContextDebugVisible") private var isModelContextDebugVisible =
    false
  @AppStorage("workspaceChat.isTerminalVisible") private var isTerminalVisible = false
  @State private var selection: AppNavigationSelection?
  @State private var modelsTab = ModelsTab.text
  @State private var appState: AppState
  @State private var workspaceChatActions: WorkspaceChatActions

  @MainActor
  init() {
    let appState = AppState()
    _appState = State(initialValue: appState)
    _workspaceChatActions = State(
      initialValue: WorkspaceChatActions(workspaceState: appState.workspaceState)
    )
  }

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
        modelRuntime: appState.chatController.modelRuntime,
        selection: $selection,
        onAddWorkspace: chooseWorkspace,
        onCreateSession: createSession,
        onRenameSession: { sessionID, title in
          appState.workspaceState.renameSession(sessionID, title: title)
        },
        onDeleteSession: appState.deleteSession,
        onRemoveWorkspace: appState.removeWorkspace
      )
      .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 460)
    } detail: {
      detailContent(controller: controller)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 880, minHeight: 560)
    .onChange(of: selection) {
      if case .session(let sessionID) = selection {
        appState.selectSession(sessionID)
      }
    }
    .onChange(of: appState.workspaceState.activeSessionID) {
      if let sessionID = appState.workspaceState.activeSessionID {
        selection = .session(sessionID)
      } else if selection != .models {
        selection = nil
      }
    }
    .onAppear {
      appState.startModelRuntimeServices()
      let modelRuntime = controller.modelRuntime
      let hasDownloadedModel = modelRuntime.availableModels.contains {
        modelRuntime.isModelDownloaded($0)
      }
      if !hasDownloadedModel {
        selection = .models
      } else if let sessionID = appState.workspaceState.activeSessionID {
        selection = .session(sessionID)
      }
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
    if let selection {
      switch selection {
      case .models:
        ModelsRouteHost(
          controller: controller,
          audioModelController: appState.audioModelController,
          selectedTab: $modelsTab,
          onPersistActiveSession: appState.persistActiveSession
        )
      case .session:
        WorkspaceRouteHost(
          activeWorkspaceContext: appState.workspaceState.activeWorkspaceContext,
          activeSessionID: appState.workspaceState.activeSessionID,
          controller: appState.chatController,
          browserToolService: appState.browserToolService,
          appBehaviorSettings: appState.settingsState.appBehaviorSettings,
          assistantSpeechService: appState.assistantSpeechService,
          speechInputController: appState.composerSpeechInputController,
          workspaceChatActions: workspaceChatActions,
          isModelContextDebugVisible: $isModelContextDebugVisible,
          isWorkspaceTerminalVisible: $isTerminalVisible,
          onAddWorkspace: chooseWorkspace,
          onCreateSession: createSession,
          onOpenAudioModels: openAudioModels
        )
      }
    } else {
      EmptyWorkspaceView(onAddWorkspace: chooseWorkspace)
    }
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

  private func chooseWorkspace() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.message = "Choose a folder to use as a Sumika Chat workspace."
    panel.prompt = "Add Workspace"

    if panel.runModal() == .OK, let url = panel.url,
      let sessionID = appState.addWorkspace(from: url)
    {
      selection = .session(sessionID)
    }
  }

  private func createSession(in workspaceID: Workspace.ID) -> ChatSession.ID? {
    guard let sessionID = appState.createSession(in: workspaceID) else {
      return nil
    }
    selection = .session(sessionID)
    return sessionID
  }

  private func openAudioModels() {
    modelsTab = .audio
    selection = .models
  }

}

#Preview {
  ContentView()
}

private struct ModelsRouteHost: View {
  let controller: ChatSessionController
  let audioModelController: ComposerAudioModelController
  @Binding var selectedTab: ModelsTab
  let onPersistActiveSession: () -> Void

  var body: some View {
    ModelsView(
      modelRuntime: controller.modelRuntime,
      audioModelController: audioModelController,
      modeSettings: Binding(
        get: { controller.chatSession.modeSettings },
        set: { controller.chatSession.modeSettings = $0 }
      ),
      selectedTab: $selectedTab,
      errorMessage: controller.errorMessage,
      canChangeModel: !controller.isGenerating && controller.modelRuntime.canChangeModel,
      onPrepareModelRuntimeAction: { cancelGeneration, invalidateContext in
        controller.prepareForModelRuntimeAction(
          cancelGeneration: cancelGeneration,
          invalidateContext: invalidateContext
        )
      }
    )
    .onChange(of: controller.chatSession.modeSettings) {
      controller.refreshContextUsage()
      saveSelectedModelSettings()
      onPersistActiveSession()
    }
    .onChange(of: controller.modelRuntime.modelContextTokenLimit) {
      saveSelectedModelSettings()
    }
  }

  private func saveSelectedModelSettings() {
    controller.modelRuntime.saveSelectedModelSettings(
      modeSettings: controller.chatSession.modeSettings
    )
  }
}

private struct WorkspaceRouteHost: View {
  let activeWorkspaceContext: WorkspaceChatContext?
  let activeSessionID: ChatSession.ID?
  let controller: ChatSessionController
  let browserToolService: HTMLPreviewBrowserToolService
  let appBehaviorSettings: AppBehaviorSettings
  let assistantSpeechService: AssistantSpeechService
  let speechInputController: ComposerSpeechInputController
  let workspaceChatActions: WorkspaceChatActions
  @Binding var isModelContextDebugVisible: Bool
  @Binding var isWorkspaceTerminalVisible: Bool
  let onAddWorkspace: () -> Void
  let onCreateSession: (Workspace.ID) -> ChatSession.ID?
  let onOpenAudioModels: () -> Void

  var body: some View {
    if let context = activeWorkspaceContext {
      WorkspaceChatView(
        controller: controller,
        context: context,
        sessionID: activeSessionID,
        browserToolService: browserToolService,
        appBehaviorSettings: appBehaviorSettings,
        assistantSpeechService: assistantSpeechService,
        speechInputController: speechInputController,
        workspaceChatActions: workspaceChatActions,
        isModelContextDebugVisible: $isModelContextDebugVisible,
        isWorkspaceTerminalVisible: $isWorkspaceTerminalVisible,
        onCreateSession: onCreateSession,
        onOpenAudioModels: onOpenAudioModels
      )
      .equatable()
    } else {
      EmptyWorkspaceView(onAddWorkspace: onAddWorkspace)
    }
  }
}
