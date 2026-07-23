import AppKit
import SumikaCore
import SwiftUI

public struct SumikaApplication: App {
  #if DEBUG
    @AppStorage("workspaceChat.isModelContextDebugVisible") private var isModelContextDebugVisible =
      false
  #endif
  @AppStorage("workspaceChat.isTerminalVisible") private var isTerminalVisible =
    false
  @NSApplicationDelegateAdaptor(SumikaAppDelegate.self) private var appDelegate
  @StateObject private var appUpdater: AppUpdater
  @State private var launchState = AppLaunchState.loading

  @MainActor
  public init() {
    NSWindow.allowsAutomaticWindowTabbing = false
    _appUpdater = StateObject(
      wrappedValue: AppUpdater(
        startingUpdater: AppLaunchConfiguration.shouldStartUpdater()
      )
    )
  }

  public var body: some Scene {
    Window("Sumika", id: "main") {
      Group {
        if let appState {
          ContentView(appState: appState)
            .onAppear {
              appDelegate.prepareForTermination = {
                await appState.prepareForTermination()
              }
            }
            .alert(
              "Model Settings Could Not Be Restored",
              isPresented: recoveryAlertBinding
            ) {
              Button("OK") {}
            } message: {
              Text(launchState.recoveryMessage ?? "")
            }
        } else {
          AppLaunchLoadingView()
        }
      }
      .task {
        guard case .loading = launchState else {
          return
        }
        launchState = await AppLaunchConfiguration.bootstrap()
      }
    }
    .commands {
      CommandGroup(replacing: .appInfo) {
        Button("About Sumika") {
          showAboutPanel()
        }

        Divider()

        Button("Check for Updates…") {
          appUpdater.checkForUpdates()
        }
        .disabled(!appUpdater.canCheckForUpdates)
      }

      CommandGroup(replacing: .newItem) {
        Button("New Chat") {
          createSessionInActiveWorkspace()
        }
        .keyboardShortcut("n")
        .disabled(appState?.workspaceState.activeWorkspaceContext == nil)

        Button("Add Workspace…") {
          chooseWorkspace()
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .disabled(appState == nil)

        Button("Remove Workspace…") {
          confirmRemoveActiveWorkspace()
        }
        .keyboardShortcut(.delete, modifiers: [.command, .shift])
        .disabled(appState?.workspaceState.activeWorkspaceContext == nil)
      }
      CommandGroup(after: .sidebar) {
        #if DEBUG
          Toggle("Model Context Debug", isOn: $isModelContextDebugVisible)
            .keyboardShortcut("0", modifiers: [.command, .option])
        #endif
        Toggle("Console", isOn: $isTerminalVisible)
          .keyboardShortcut("T", modifiers: [.command, .option])
      }
    }

    Settings {
      if let appState {
        AppSettingsView(
          settingsState: appState.settingsState,
          onUpdateAppBehaviorSettings: appState.updateAppBehaviorSettings,
          onUpdateMCPServers: appState.updateMCPServers,
          canTestMCPServers: appState.workspaceState.activeWorkspace != nil,
          onTestMCPServer: appState.testMCPServer
        )
      } else {
        AppLaunchLoadingView()
          .frame(width: 420, height: 240)
      }
    }
  }

  private var appState: AppState? {
    launchState.appState
  }

  private var recoveryAlertBinding: Binding<Bool> {
    Binding(
      get: { launchState.recoveryMessage != nil },
      set: { isPresented in
        guard !isPresented, case .recovered(let appState, _) = launchState else {
          return
        }
        launchState = .ready(appState)
      }
    )
  }

  private func createSessionInActiveWorkspace() {
    guard
      let appState,
      let workspaceID = appState.workspaceState.activeWorkspaceContext?.id
    else {
      return
    }
    _ = appState.createSession(in: workspaceID)
  }

  private func showAboutPanel() {
    let buildInfo = AppBuildInfo.current
    var options: [NSApplication.AboutPanelOptionKey: Any] = [
      .applicationVersion: buildInfo.aboutApplicationVersion
    ]

    if let buildVersion = buildInfo.aboutBuildVersion {
      options[.version] = buildVersion
    }

    NSApplication.shared.orderFrontStandardAboutPanel(options: options)
  }

  private func chooseWorkspace() {
    guard let appState else {
      return
    }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.message = "Choose a folder to use as a Sumika workspace."
    panel.prompt = "Add Workspace"

    if panel.runModal() == .OK, let url = panel.url {
      _ = appState.addWorkspace(from: url)
    }
  }

  private func confirmRemoveActiveWorkspace() {
    guard let appState, let workspace = appState.workspaceState.activeWorkspace else {
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

private struct AppLaunchLoadingView: View {
  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
        .controlSize(.large)
      Text("Restoring Sumika…")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .frame(minWidth: 420, minHeight: 240)
  }
}
