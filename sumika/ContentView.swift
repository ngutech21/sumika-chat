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

    WorkspaceCommandHost(
      workspaceState: appState.workspaceState,
      onRemoveWorkspace: appState.removeWorkspace
    ) {
      HStack(spacing: 0) {
        if !isSidebarCollapsed {
          WorkspaceSidebar(
            workspaceState: appState.workspaceState,
            modelRuntime: appState.chatController.modelRuntime,
            selection: $selection,
            onAddWorkspace: chooseWorkspace,
            onCreateSession: { workspaceID in appState.createSession(in: workspaceID) },
            onRenameSession: { sessionID, title in
              appState.workspaceState.renameSession(sessionID, title: title)
            },
            onDeleteSession: appState.deleteSession,
            onRemoveWorkspace: appState.removeWorkspace
          )
          .frame(width: sidebarWidth)
          .background(.bar)
          .transition(.move(edge: .leading).combined(with: .opacity))

          sidebarResizeHandle
        }

        detailContent(controller: controller)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(minWidth: 880, minHeight: 560)
      .focusedSceneValue(\.addWorkspaceAction, chooseWorkspace)
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
  private func detailContent(controller: ChatSessionController) -> some View {
    if let selection {
      switch selection {
      case .models:
        ModelsRouteHost(
          controller: controller,
          onPersistActiveSession: appState.persistActiveSession
        )
      case .session:
        WorkspaceRouteHost(
          activeWorkspaceContext: appState.workspaceState.activeWorkspaceContext,
          activeSessionID: appState.workspaceState.activeSessionID,
          controller: appState.chatController,
          browserToolService: appState.browserToolService,
          isModelContextDebugVisible: $isModelContextDebugVisible,
          isWorkspaceTerminalVisible: $isTerminalVisible,
          isSidebarCollapsed: isSidebarCollapsed,
          onToggleSidebar: toggleSidebarVisibility,
          onAddWorkspace: chooseWorkspace,
          onOpenWorkspaceInFinder: appState.workspaceState.openActiveWorkspaceInFinder,
          onOpenWorkspaceInVisualStudioCode: appState.workspaceState
            .openActiveWorkspaceInVisualStudioCode
        )
      }
    } else {
      EmptyWorkspaceView(onAddWorkspace: chooseWorkspace)
    }
  }

  private func toggleSidebarVisibility() {
    withAnimation(.snappy(duration: 0.2)) {
      isSidebarCollapsed.toggle()
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

}

#Preview {
  ContentView()
}

private struct ModelsRouteHost: View {
  let controller: ChatSessionController
  let onPersistActiveSession: () -> Void

  var body: some View {
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
    .onChange(of: controller.chatSession.systemPrompt) {
      controller.refreshContextUsage()
      saveSelectedModelSettings()
      onPersistActiveSession()
    }
    .onChange(of: controller.chatSession.generationSettings) {
      saveSelectedModelSettings()
      onPersistActiveSession()
    }
    .onChange(of: controller.modelRuntime.modelContextTokenLimit) {
      saveSelectedModelSettings()
    }
  }

  private func saveSelectedModelSettings() {
    controller.modelRuntime.saveSelectedModelSettings(
      systemPrompt: controller.chatSession.systemPrompt,
      generationSettings: controller.chatSession.generationSettings
    )
  }
}

private struct WorkspaceRouteHost: View {
  let activeWorkspaceContext: WorkspaceChatContext?
  let activeSessionID: ChatSession.ID?
  let controller: ChatSessionController
  let browserToolService: HTMLPreviewBrowserToolService
  @Binding var isModelContextDebugVisible: Bool
  @Binding var isWorkspaceTerminalVisible: Bool
  let isSidebarCollapsed: Bool
  let onToggleSidebar: () -> Void
  let onAddWorkspace: () -> Void
  let onOpenWorkspaceInFinder: () -> Void
  let onOpenWorkspaceInVisualStudioCode: () -> Void

  var body: some View {
    if let context = activeWorkspaceContext {
      WorkspaceChatView(
        controller: controller,
        context: context,
        sessionID: activeSessionID,
        browserToolService: browserToolService,
        isModelContextDebugVisible: $isModelContextDebugVisible,
        isWorkspaceTerminalVisible: $isWorkspaceTerminalVisible,
        isSidebarCollapsed: isSidebarCollapsed,
        onToggleSidebar: onToggleSidebar,
        onOpenWorkspaceInFinder: onOpenWorkspaceInFinder,
        onOpenWorkspaceInVisualStudioCode: onOpenWorkspaceInVisualStudioCode
      )
    } else {
      EmptyWorkspaceView(onAddWorkspace: onAddWorkspace)
    }
  }
}
