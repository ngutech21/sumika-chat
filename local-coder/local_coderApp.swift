//

import SwiftUI

@main
struct LocalCoderApp: App {
  @AppStorage("workspaceChat.isModelContextDebugVisible") private var isModelContextDebugVisible =
    false
  @AppStorage("workspaceChat.isTerminalVisible") private var isTerminalVisible =
    false
  @FocusedValue(\.addWorkspaceAction) private var addWorkspaceAction
  @FocusedValue(\.openSettingsAction) private var openSettingsAction

  init() {
    NSWindow.allowsAutomaticWindowTabbing = false
  }

  var body: some Scene {
    WindowGroup {
      ContentView(appState: AppLaunchConfiguration.makeAppState())
    }
    .commands {
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") {
          openSettingsAction?()
        }
        .keyboardShortcut(",", modifiers: .command)
        .disabled(openSettingsAction == nil)
      }
      CommandGroup(after: .newItem) {
        Button("Add Workspace…") {
          addWorkspaceAction?()
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .disabled(addWorkspaceAction == nil)
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

private struct OpenSettingsActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var addWorkspaceAction: (() -> Void)? {
    get { self[AddWorkspaceActionKey.self] }
    set { self[AddWorkspaceActionKey.self] = newValue }
  }

  var openSettingsAction: (() -> Void)? {
    get { self[OpenSettingsActionKey.self] }
    set { self[OpenSettingsActionKey.self] = newValue }
  }
}
