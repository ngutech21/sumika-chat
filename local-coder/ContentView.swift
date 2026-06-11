import AppKit
import LocalCoderCore
import SwiftUI

struct ContentView: View {
  @AppStorage("contentView.columnVisibility") private var storedColumnVisibility =
    Self.defaultColumnVisibility.storageValue
  @AppStorage("workspaceChat.isModelContextDebugVisible") private var isModelContextDebugVisible =
    false
  @State private var selection: AppNavigationSelection?
  @State private var appState: AppState

  private static let defaultColumnVisibility = NavigationSplitViewVisibility.all

  private var columnVisibility: Binding<NavigationSplitViewVisibility> {
    Binding(
      get: { NavigationSplitViewVisibility(storageValue: storedColumnVisibility) },
      set: { storedColumnVisibility = $0.storageValue }
    )
  }

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

    NavigationSplitView(columnVisibility: columnVisibility) {
      AppSidebar(
        appState: appState,
        selection: $selection,
        onAddWorkspace: chooseWorkspace
      )
      .navigationSplitViewColumnWidth(min: 260, ideal: 300)
    } detail: {
      if let selection {
        switch selection {
        case .settings:
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
          .navigationTitle("Settings")
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
          .navigationTitle("Models")
        case .session:
          if let workspace = appState.activeWorkspace {
            WorkspaceChatView(
              controller: controller,
              workspace: workspace,
              sessionID: appState.activeSessionID,
              browserToolService: appState.browserToolService,
              isModelContextDebugVisible: $isModelContextDebugVisible,
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
      } else if selection != .models && selection != .settings {
        selection = nil
      }
    }
    .onAppear {
      appState.startModelRuntimeServices()
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

extension NavigationSplitViewVisibility {
  fileprivate init(storageValue: String) {
    switch storageValue {
    case Self.all.storageValue:
      self = .all
    case Self.doubleColumn.storageValue:
      self = .doubleColumn
    case Self.detailOnly.storageValue:
      self = .detailOnly
    default:
      self = .automatic
    }
  }

  fileprivate var storageValue: String {
    switch self {
    case .automatic:
      "automatic"
    case .all:
      "all"
    case .doubleColumn:
      "doubleColumn"
    case .detailOnly:
      "detailOnly"
    default:
      "automatic"
    }
  }
}
