import AppKit
import SumikaCore
import SwiftUI

struct WorkspaceChatView: View, Equatable {
  let controller: ChatSessionController
  let context: WorkspaceChatContext
  let sessionID: ChatSession.ID?
  let browserToolService: HTMLPreviewBrowserToolService
  let appBehaviorSettings: AppBehaviorSettings
  let assistantSpeechService: AssistantSpeechService
  let speechInputController: ComposerSpeechInputController
  let workspaceChatActions: WorkspaceChatActions
  @Binding var isModelContextDebugVisible: Bool
  @Binding var isWorkspaceTerminalVisible: Bool
  let onCreateSession: (Workspace.ID) -> ChatSession.ID?
  let onOpenAudioModels: () -> Void
  @State private var previewState = WorkspacePreviewFeatureState()

  static func == (lhs: WorkspaceChatView, rhs: WorkspaceChatView) -> Bool {
    ObjectIdentifier(lhs.controller) == ObjectIdentifier(rhs.controller)
      && lhs.context == rhs.context
      && lhs.sessionID == rhs.sessionID
      && ObjectIdentifier(lhs.browserToolService) == ObjectIdentifier(rhs.browserToolService)
      && lhs.appBehaviorSettings == rhs.appBehaviorSettings
      && ObjectIdentifier(lhs.assistantSpeechService)
        == ObjectIdentifier(rhs.assistantSpeechService)
      && ObjectIdentifier(lhs.speechInputController)
        == ObjectIdentifier(rhs.speechInputController)
      && ObjectIdentifier(lhs.workspaceChatActions) == ObjectIdentifier(rhs.workspaceChatActions)
      && lhs.isModelContextDebugVisible == rhs.isModelContextDebugVisible
      && lhs.isWorkspaceTerminalVisible == rhs.isWorkspaceTerminalVisible
  }

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = Self._printChanges()
    #endif

    HStack(spacing: 0) {
      WorkspaceChatMainColumn(
        controller: controller,
        context: context,
        sessionID: sessionID,
        appBehaviorSettings: appBehaviorSettings,
        assistantSpeechService: assistantSpeechService,
        speechInputController: speechInputController,
        previewState: previewState,
        isWorkspaceTerminalVisible: $isWorkspaceTerminalVisible,
        onOpenAudioModels: onOpenAudioModels
      )
      .equatable()

      WorkspacePreviewSlot(
        previewState: previewState,
        browserToolService: browserToolService
      )
      .equatable()

      #if DEBUG
        WorkspaceDebugSlot(
          controller: controller,
          context: context,
          sessionID: sessionID,
          isModelContextDebugVisible: $isModelContextDebugVisible
        )
        .equatable()
      #endif
    }
    .navigationTitle(context.name)
    .toolbar {
      WorkspaceChatToolbar(
        workspaceID: context.id,
        isWorkspaceTerminalVisible: $isWorkspaceTerminalVisible,
        workspaceChatActions: workspaceChatActions,
        onCreateSession: onCreateSession
      )
    }
    .onDisappear {
      Task {
        await browserToolService.clear()
      }
    }
  }

}

private struct WorkspaceChatMainColumn: View, Equatable {
  let controller: ChatSessionController
  let context: WorkspaceChatContext
  let sessionID: ChatSession.ID?
  let appBehaviorSettings: AppBehaviorSettings
  let assistantSpeechService: AssistantSpeechService
  let speechInputController: ComposerSpeechInputController
  let previewState: WorkspacePreviewFeatureState
  @Binding var isWorkspaceTerminalVisible: Bool
  let onOpenAudioModels: () -> Void

  static func == (lhs: WorkspaceChatMainColumn, rhs: WorkspaceChatMainColumn) -> Bool {
    ObjectIdentifier(lhs.controller) == ObjectIdentifier(rhs.controller)
      && lhs.context == rhs.context
      && lhs.sessionID == rhs.sessionID
      && lhs.appBehaviorSettings == rhs.appBehaviorSettings
      && ObjectIdentifier(lhs.assistantSpeechService)
        == ObjectIdentifier(rhs.assistantSpeechService)
      && ObjectIdentifier(lhs.speechInputController)
        == ObjectIdentifier(rhs.speechInputController)
      && ObjectIdentifier(lhs.previewState) == ObjectIdentifier(rhs.previewState)
      && lhs.isWorkspaceTerminalVisible == rhs.isWorkspaceTerminalVisible
  }

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = Self._printChanges()
    #endif

    VStack(spacing: 0) {
      Divider()

      ChatTranscriptHost(
        controller: controller,
        context: context,
        sessionID: sessionID,
        appBehaviorSettings: appBehaviorSettings,
        assistantSpeechService: assistantSpeechService
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      WorkspaceChatComposerHost(
        controller: controller,
        context: context,
        sessionID: sessionID,
        previewState: previewState,
        speechInputController: speechInputController,
        onOpenAudioModels: onOpenAudioModels
      )

      WorkspaceTerminalSlot(
        context: context,
        isWorkspaceTerminalVisible: $isWorkspaceTerminalVisible
      )
      .equatable()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct WorkspaceTerminalSlot: View, Equatable {
  let context: WorkspaceChatContext
  @Binding var isWorkspaceTerminalVisible: Bool

  static func == (lhs: WorkspaceTerminalSlot, rhs: WorkspaceTerminalSlot) -> Bool {
    lhs.context == rhs.context
      && lhs.isWorkspaceTerminalVisible == rhs.isWorkspaceTerminalVisible
  }

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = Self._printChanges()
    #endif

    if isWorkspaceTerminalVisible {
      WorkspaceTerminalPane(
        configuration: WorkspaceTerminalConfiguration(
          workspaceName: context.name,
          rootURL: context.rootURL
        ),
        onClose: {
          isWorkspaceTerminalVisible = false
        }
      )
      .id(context.id)
      .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
  }
}

private struct WorkspacePreviewSlot: View, Equatable {
  let previewState: WorkspacePreviewFeatureState
  let browserToolService: HTMLPreviewBrowserToolService

  static func == (lhs: WorkspacePreviewSlot, rhs: WorkspacePreviewSlot) -> Bool {
    ObjectIdentifier(lhs.previewState) == ObjectIdentifier(rhs.previewState)
      && ObjectIdentifier(lhs.browserToolService) == ObjectIdentifier(rhs.browserToolService)
  }

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = Self._printChanges()
    #endif

    if previewState.isVisible {
      WorkspacePreviewHost(
        previewState: previewState,
        browserToolService: browserToolService
      )
    }
  }
}

private struct WorkspaceDebugSlot: View, Equatable {
  let controller: ChatSessionController
  let context: WorkspaceChatContext
  let sessionID: ChatSession.ID?
  @Binding var isModelContextDebugVisible: Bool

  static func == (lhs: WorkspaceDebugSlot, rhs: WorkspaceDebugSlot) -> Bool {
    ObjectIdentifier(lhs.controller) == ObjectIdentifier(rhs.controller)
      && lhs.context == rhs.context
      && lhs.sessionID == rhs.sessionID
      && lhs.isModelContextDebugVisible == rhs.isModelContextDebugVisible
  }

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = Self._printChanges()
    #endif

    if isModelContextDebugVisible {
      ModelContextDebugHost(
        controller: controller,
        context: context,
        sessionID: sessionID,
        onClose: {
          isModelContextDebugVisible = false
        }
      )
      .transition(.move(edge: .trailing).combined(with: .opacity))
    }
  }
}

private struct WorkspaceChatToolbar: ToolbarContent {
  let workspaceID: Workspace.ID
  @Binding var isWorkspaceTerminalVisible: Bool
  let workspaceChatActions: WorkspaceChatActions
  let onCreateSession: (Workspace.ID) -> ChatSession.ID?

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      Button(action: onNewChat) {
        Label("New Chat", systemImage: "square.and.pencil")
      }
      .help("New chat")
      .accessibilityLabel("New Chat")
      .accessibilityIdentifier("workspace.newChatButton")
    }

    toolbarGroupSpacer

    ToolbarItemGroup(placement: .primaryAction) {
      Menu {
        Button(action: workspaceChatActions.openWorkspaceInVisualStudioCode) {
          Label {
            Text("Open in VS Code")
          } icon: {
            WorkspaceOpenAppIcon(.visualStudioCode)
          }
        }

        Button(action: workspaceChatActions.openWorkspaceInFinder) {
          Label {
            Text("Reveal in Finder")
          } icon: {
            WorkspaceOpenAppIcon(.finder)
          }
        }
      } label: {
        Label {
          Text("Open Workspace")
        } icon: {
          WorkspaceOpenAppIcon(.visualStudioCode)
        }
      }
      .help("Open workspace in another app")
      .accessibilityLabel("Open Workspace")
      .accessibilityIdentifier("workspace.openWorkspaceMenu")
    }

    toolbarGroupSpacer

    ToolbarItemGroup(placement: .primaryAction) {
      Toggle(isOn: $isWorkspaceTerminalVisible) {
        Image(systemName: isWorkspaceTerminalVisible ? "terminal.fill" : "terminal")
      }
      .toggleStyle(.button)
      .help(isWorkspaceTerminalVisible ? "Hide workspace terminal" : "Show workspace terminal")
      .accessibilityLabel(
        isWorkspaceTerminalVisible ? "Hide workspace terminal" : "Show workspace terminal"
      )
      .accessibilityIdentifier("workspace.terminalToggleButton")
    }
  }

  private func onNewChat() {
    _ = onCreateSession(workspaceID)
  }

  @ToolbarContentBuilder
  private var toolbarGroupSpacer: some ToolbarContent {
    if #available(macOS 26.0, *) {
      ToolbarSpacer(.fixed, placement: .primaryAction)
    } else {
      ToolbarItem(placement: .primaryAction) {
        Spacer()
          .frame(width: 8)
      }
    }
  }
}

private struct WorkspaceOpenAppIcon: View {
  enum App {
    case finder
    case visualStudioCode
  }

  let app: App

  init(_ app: App) {
    self.app = app
  }

  var body: some View {
    if let image = app.icon {
      Image(nsImage: image)
        .resizable()
        .scaledToFit()
        .frame(width: 16, height: 16)
    } else {
      Image(systemName: app.fallbackSystemImage)
        .frame(width: 16, height: 16)
    }
  }
}

extension WorkspaceOpenAppIcon.App {
  fileprivate var icon: NSImage? {
    switch self {
    case .finder:
      NSWorkspace.shared.icon(
        forFile: "/System/Library/CoreServices/Finder.app"
      )
    case .visualStudioCode:
      visualStudioCodeIcon
    }
  }

  fileprivate var fallbackSystemImage: String {
    switch self {
    case .finder:
      "folder"
    case .visualStudioCode:
      "curlybraces"
    }
  }

  private var visualStudioCodeIcon: NSImage? {
    if let appURL = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: "com.microsoft.VSCode"
    ) {
      return NSWorkspace.shared.icon(forFile: appURL.path(percentEncoded: false))
    }

    let candidatePaths = [
      "/Applications/Visual Studio Code.app",
      "~/Applications/Visual Studio Code.app",
    ]

    for path in candidatePaths {
      let expandedPath = (path as NSString).expandingTildeInPath
      if FileManager.default.fileExists(atPath: expandedPath) {
        return NSWorkspace.shared.icon(forFile: expandedPath)
      }
    }

    return nil
  }
}
