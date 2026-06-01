import AppKit
import SwiftUI

struct ContentView: View {
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var selection: AppNavigationSelection?
  @State private var appState: AppState

  @MainActor
  init() {
    _appState = State(initialValue: AppState())
  }

  @MainActor
  init(controller: ChatSessionController) {
    _appState = State(initialValue: AppState(chatController: controller))
  }

  @MainActor
  init(appState: AppState) {
    _appState = State(initialValue: appState)
  }

  var body: some View {
    let controller = appState.chatController

    NavigationSplitView(columnVisibility: $columnVisibility) {
      AppSidebar(
        appState: appState,
        selection: $selection,
        onAddWorkspace: chooseWorkspace
      )
      .navigationSplitViewColumnWidth(min: 260, ideal: 300)
    } detail: {
      if let selection {
        switch selection {
        case .models:
          ModelsView(controller: controller)
            .navigationTitle("Models")
        case .session:
          if let workspace = appState.activeWorkspace {
            WorkspaceChatView(
              controller: controller,
              workspace: workspace,
              sessionID: appState.activeSessionID,
              onAddAttachments: chooseAttachments
            )
            .navigationTitle(workspace.name)
          } else {
            EmptyWorkspaceView(onAddWorkspace: chooseWorkspace)
              .navigationTitle("Local Coder")
          }
        }
      } else {
        EmptyWorkspaceView(onAddWorkspace: chooseWorkspace)
          .navigationTitle("Local Coder")
      }
    }
    .navigationSplitViewStyle(.balanced)
    .frame(minWidth: 880, minHeight: 560)
    .onChange(of: controller.chatSession.systemPrompt) {
      controller.refreshContextUsage()
      controller.saveSelectedModelSettings()
      appState.persistActiveSession()
    }
    .onChange(of: controller.chatSession.generationSettings) {
      controller.saveSelectedModelSettings()
      appState.persistActiveSession()
    }
    .onChange(of: controller.modelContextTokenLimit) {
      controller.saveSelectedModelSettings()
    }
    .onChange(of: controller.draft) {
      controller.convertDroppedFilePathsInDraft()
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
      columnVisibility = .all
      controller.prepareDefaultModelDirectory()
      controller.startResourceMonitoring()
      if let sessionID = appState.activeSessionID {
        selection = .session(sessionID)
      }
    }
  }

  private func chooseWorkspace() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.message = "Choose a folder to use as a local-coder workspace."
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
