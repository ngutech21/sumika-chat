//

import SwiftUI

@main
struct SumikaApp: App {
  @AppStorage("workspaceChat.isModelContextDebugVisible") private var isModelContextDebugVisible =
    false
  @AppStorage("workspaceChat.isTerminalVisible") private var isTerminalVisible =
    false
  @FocusedValue(\.addWorkspaceAction) private var addWorkspaceAction
  @FocusedValue(\.removeWorkspaceAction) private var removeWorkspaceAction
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

        Button("Remove Workspace…") {
          removeWorkspaceAction?()
        }
        .keyboardShortcut(.delete, modifiers: [.command, .shift])
        .disabled(removeWorkspaceAction == nil)
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

private struct RemoveWorkspaceActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var addWorkspaceAction: (() -> Void)? {
    get { self[AddWorkspaceActionKey.self] }
    set { self[AddWorkspaceActionKey.self] = newValue }
  }

  var removeWorkspaceAction: (() -> Void)? {
    get { self[RemoveWorkspaceActionKey.self] }
    set { self[RemoveWorkspaceActionKey.self] = newValue }
  }
}
