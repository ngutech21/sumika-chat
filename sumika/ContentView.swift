import AppKit
import SumikaCore
import SwiftUI

struct ContentView: View {
  @AppStorage("workspaceChat.isModelContextDebugVisible") private var isModelContextDebugVisible =
    false
  @AppStorage("workspaceChat.isTerminalVisible") private var isTerminalVisible = false
  @State private var selection: AppNavigationSelection?
  @State private var appState: AppState
  @State private var isSettingsPresented = false

  @MainActor
  init() {
    _appState = State(initialValue: AppState())
  }

  @MainActor
  init(appState: AppState) {
    _appState = State(initialValue: appState)
  }

  var body: some View {
    let controller = appState.chatController

    HStack(spacing: 0) {
      AppSidebar(
        appState: appState,
        selection: $selection,
        onAddWorkspace: chooseWorkspace
      )
      .frame(width: 300)
      .frame(minWidth: 260, maxWidth: 340)
      .background(.bar)

      Divider()

      detailContent(controller: controller)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 880, minHeight: 560)
    .focusedSceneValue(\.addWorkspaceAction, chooseWorkspace)
    .focusedSceneValue(\.showSettingsAction) {
      isSettingsPresented = true
    }
    .sheet(isPresented: $isSettingsPresented) {
      settingsSheet
    }
    .onChange(of: controller.chatSession.systemPrompt) {
      controller.refreshContextUsage()
      controller.modelRuntime.saveSelectedModelSettings(
        systemPrompt: controller.chatSession.systemPrompt,
        generationSettings: controller.chatSession.generationSettings
      )
      appState.persistActiveSession()
    }
    .onChange(of: controller.chatSession.generationSettings) {
      controller.modelRuntime.saveSelectedModelSettings(
        systemPrompt: controller.chatSession.systemPrompt,
        generationSettings: controller.chatSession.generationSettings
      )
      appState.persistActiveSession()
    }
    .onChange(of: controller.modelRuntime.modelContextTokenLimit) {
      controller.modelRuntime.saveSelectedModelSettings(
        systemPrompt: controller.chatSession.systemPrompt,
        generationSettings: controller.chatSession.generationSettings
      )
    }
    .onChange(of: selection) {
      if case .session(let sessionID) = selection {
        appState.selectSession(sessionID)
      }
    }
    .onChange(of: appState.activeSessionID) {
      if let sessionID = appState.activeSessionID {
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
      } else if let sessionID = appState.activeSessionID {
        selection = .session(sessionID)
      }
    }
    .alert("Workspace Error", isPresented: workspaceErrorAlertBinding) {
      Button("OK", role: .cancel) {
        appState.workspaceErrorMessage = nil
      }
    } message: {
      Text(appState.workspaceErrorMessage ?? "")
    }
  }

  @ViewBuilder
  private func detailContent(controller: ChatSessionController) -> some View {
    if let selection {
      switch selection {
      case .models:
        ModelsView(
          modelRuntime: controller.modelRuntime,
          systemPrompt: Binding(
            get: { controller.chatSession.systemPrompt },
            set: { controller.chatSession.systemPrompt = $0 }
          ),
          generationSettings: Binding(
            get: { controller.chatSession.generationSettings },
            set: { controller.chatSession.generationSettings = $0 }
          ),
          contextUsage: controller.contextUsage,
          errorMessage: controller.errorMessage,
          canChangeModel: !controller.isGenerating && controller.modelRuntime.canChangeModel,
          onPrepareModelRuntimeAction: { cancelGeneration, invalidateContext in
            controller.prepareForModelRuntimeAction(
              cancelGeneration: cancelGeneration,
              invalidateContext: invalidateContext
            )
          }
        )
      case .session:
        if let workspace = appState.activeWorkspace {
          WorkspaceChatView(
            controller: controller,
            workspace: workspace,
            sessionID: appState.activeSessionID,
            browserToolService: appState.browserToolService,
            isModelContextDebugVisible: $isModelContextDebugVisible,
            isWorkspaceTerminalVisible: $isTerminalVisible,
            onAddAttachments: chooseAttachments,
            onOpenWorkspaceInFinder: appState.openActiveWorkspaceInFinder,
            onOpenWorkspaceInVisualStudioCode: appState.openActiveWorkspaceInVisualStudioCode
          )
        } else {
          EmptyWorkspaceView(onAddWorkspace: chooseWorkspace)
        }
      }
    } else {
      EmptyWorkspaceView(onAddWorkspace: chooseWorkspace)
    }
  }

  private var settingsSheet: some View {
    VStack(spacing: 0) {
      AppSettingsView(
        appBehaviorSettings: Binding(
          get: { appState.activeAppBehaviorSettings },
          set: { appState.updateActiveAppBehaviorSettings($0) }
        ),
        webAccessSettings: Binding(
          get: { appState.activeWebAccessSettings },
          set: { appState.updateActiveWebAccessSettings($0) }
        )
      )

      Divider()

      HStack {
        Spacer()
        Button("Done") {
          isSettingsPresented = false
        }
        .keyboardShortcut(.defaultAction)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
    }
  }

  private var workspaceErrorAlertBinding: Binding<Bool> {
    Binding(
      get: { appState.workspaceErrorMessage != nil },
      set: { isPresented in
        if !isPresented {
          appState.workspaceErrorMessage = nil
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

  private func chooseAttachments() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.canCreateDirectories = false
    panel.message = "Choose text files to add as model context."
    panel.prompt = "Add"

    if panel.runModal() == .OK {
      appState.chatController.addAttachments(from: panel.urls)
    }
  }
}

#Preview {
  ContentView()
}
