//

import SwiftUI

@main
struct SumikaApp: App {
  @AppStorage("workspaceChat.isModelContextDebugVisible") private var isModelContextDebugVisible =
    false
  @AppStorage("workspaceChat.isTerminalVisible") private var isTerminalVisible =
    false
  @FocusedValue(\.addWorkspaceAction) private var addWorkspaceAction
  @FocusedValue(\.showSettingsAction) private var showSettingsAction
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
          addWorkspaceAction?()
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .disabled(addWorkspaceAction == nil)
      }
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") {
          showSettingsAction?()
        }
        .keyboardShortcut(",", modifiers: .command)
        .disabled(showSettingsAction == nil)
      }
      CommandGroup(after: .sidebar) {
        Toggle("Model Context Debug", isOn: $isModelContextDebugVisible)
          .keyboardShortcut("0", modifiers: [.command, .option])
        Toggle("Console", isOn: $isTerminalVisible)
          .keyboardShortcut("T", modifiers: [.command, .option])
      }
    }
  }
}

private struct AddWorkspaceActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

private struct ShowSettingsActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var addWorkspaceAction: (() -> Void)? {
    get { self[AddWorkspaceActionKey.self] }
    set { self[AddWorkspaceActionKey.self] = newValue }
  }

  var showSettingsAction: (() -> Void)? {
    get { self[ShowSettingsActionKey.self] }
    set { self[ShowSettingsActionKey.self] = newValue }
  }
}
