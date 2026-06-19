import AppKit
import SumikaCore
import SwiftUI

struct ContentView: View {
  @AppStorage("workspaceChat.isModelContextDebugVisible") private var isModelContextDebugVisible =
    false
  @AppStorage("workspaceChat.isTerminalVisible") private var isTerminalVisible = false
  @State private var selection: AppNavigationSelection?
  @State private var appState: AppState
  // Sidebar collapse is @State (resets to expanded on launch) so you can never
  // start in a collapsed-with-no-toggle dead end. Width persists.
  @State private var isSidebarCollapsed = false
  @AppStorage("contentView.sidebarWidth") private var sidebarWidth = 300.0
  @State private var dragStartWidth: Double?

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
      if !isSidebarCollapsed {
        AppSidebar(
          appState: appState,
          selection: $selection,
          onAddWorkspace: chooseWorkspace
        )
        .frame(width: sidebarWidth)
        .background(.bar)
        .transition(.move(edge: .leading).combined(with: .opacity))

        sidebarResizeHandle
      }

      detailContent(controller: controller, isSidebarCollapsed: $isSidebarCollapsed)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 880, minHeight: 560)
    .focusedSceneValue(\.addWorkspaceAction, chooseWorkspace)
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

  private var sidebarResizeHandle: some View {
    Divider()
      .overlay {
        Rectangle()
          .fill(.clear)
          .frame(width: 8)
          .contentShape(Rectangle())
          .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
          }
          .gesture(
            DragGesture()
              .onChanged { value in
                if dragStartWidth == nil { dragStartWidth = sidebarWidth }
                let base = dragStartWidth ?? sidebarWidth
                sidebarWidth = min(max(base + value.translation.width, 220), 460)
              }
              .onEnded { _ in dragStartWidth = nil }
          )
      }
  }

  @ViewBuilder
  private func detailContent(controller: ChatSessionController, isSidebarCollapsed: Binding<Bool>)
    -> some View
  {
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
            isSidebarCollapsed: isSidebarCollapsed,
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
