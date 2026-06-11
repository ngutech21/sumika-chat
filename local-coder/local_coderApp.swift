//

import SwiftUI

@main
struct LocalCoderApp: App {
  @AppStorage("workspaceChat.isModelContextDebugVisible") private var isModelContextDebugVisible =
    false

  var body: some Scene {
    WindowGroup {
      ContentView(appState: AppLaunchConfiguration.makeAppState())
    }
    .commands {
      CommandGroup(after: .sidebar) {
        Toggle("Model Context Debug", isOn: $isModelContextDebugVisible)
          .keyboardShortcut("0", modifiers: [.command, .option])
      }
    }
  }
}
