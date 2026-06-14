//

import SwiftUI

@main
struct LocalCoderApp: App {
  @AppStorage("workspaceChat.isModelContextDebugVisible") private var isModelContextDebugVisible =
    false
  @AppStorage("workspaceChat.isTerminalVisible") private var isTerminalVisible =
    false
  @FocusedValue(\.addWorkspaceAction) private var addWorkspaceAction
  @State private var appState: AppState

  @MainActor
  init() {
    NSWindow.allowsAutomaticWindowTabbing = false
    _appState = State(initialValue: AppLaunchConfiguration.makeAppState())
  }

  var body: some Scene {
    WindowGroup {
      ContentView(appState: appState)
    }
    .commands {
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

    Settings {
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
    }
  }
}

private struct AddWorkspaceActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var addWorkspaceAction: (() -> Void)? {
    get { self[AddWorkspaceActionKey.self] }
    set { self[AddWorkspaceActionKey.self] = newValue }
  }
}
