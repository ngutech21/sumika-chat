import AppKit
import SumikaCore
import SwiftUI

@main
struct SumikaApp: App {
  @AppStorage("workspaceChat.isModelContextDebugVisible") private var isModelContextDebugVisible =
    false
  @AppStorage("workspaceChat.isTerminalVisible") private var isTerminalVisible =
    false
  @State private var appState: AppState

  @MainActor
  init() {
    NSWindow.allowsAutomaticWindowTabbing = false
    _appState = State(initialValue: AppLaunchConfiguration.makeAppState())
  }

  var body: some Scene {
    Window("Sumika Chat", id: "main") {
      ContentView(appState: appState)
    }
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("Add Workspace…") {
          chooseWorkspace()
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])

        Button("Remove Workspace…") {
          confirmRemoveActiveWorkspace()
        }
        .keyboardShortcut(.delete, modifiers: [.command, .shift])
        .disabled(appState.workspaceState.activeWorkspaceContext == nil)
      }
      CommandGroup(after: .sidebar) {
        Toggle("Model Context Debug", isOn: $isModelContextDebugVisible)
          .keyboardShortcut("0", modifiers: [.command, .option])
        Toggle("Console", isOn: $isTerminalVisible)
          .keyboardShortcut("T", modifiers: [.command, .option])
      }
    }

    Settings {
      AppSettingsView(
        settingsState: appState.settingsState,
        onUpdateAppBehaviorSettings: appState.updateAppBehaviorSettings
      )
    }
  }

  private func chooseWorkspace() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.message = "Choose a folder to use as a Sumika Chat workspace."
    panel.prompt = "Add Workspace"

    if panel.runModal() == .OK, let url = panel.url {
      _ = appState.addWorkspace(from: url)
    }
  }

  private func confirmRemoveActiveWorkspace() {
    guard let workspace = appState.workspaceState.activeWorkspace else {
      return
    }

    let alert = NSAlert()
    alert.messageText = "Remove Workspace from Sumika?"
    alert.informativeText =
      "This removes “\(workspace.name)” and its saved Sumika chats from the app. The folder on disk will not be deleted."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")

    if alert.runModal() == .alertFirstButtonReturn {
      appState.removeWorkspace(workspace.id)
    }
  }
}
