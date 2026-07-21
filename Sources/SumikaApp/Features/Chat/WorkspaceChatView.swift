import AppKit
import SumikaCore
import SwiftUI

struct WorkspaceChatView: View, Equatable {
  let chatState: ChatFeatureState
  let workspace: Workspace
  let context: WorkspaceChatContext
  let sessionID: ChatSession.ID?
  let modelManagementState: ModelManagementFeatureState
  let browserToolService: HTMLPreviewBrowserToolService
  let appBehaviorSettings: AppBehaviorSettings
  let mcpServers: [MCPServerConfig]
  let mcpServerStatuses: [MCPServerStatus]
  let assistantSpeechService: AssistantSpeechService
  let speechInputController: ComposerSpeechInputController
  @Binding var isModelContextDebugVisible: Bool
  @Binding var isWorkspaceTerminalVisible: Bool
  let onCreateSession: (Workspace.ID) -> ChatSession.ID?
  let onOpenWorkspaceInFinder: () -> Void
  let onOpenWorkspaceInVisualStudioCode: () -> Void
  let onSendMessage: (String) -> Bool
  let onSelectMCPServerIDs: ([UUID]) -> Void
  let onOpenAudioModels: () -> Void
  @State private var previewState = WorkspacePreviewFeatureState()

  static func == (lhs: WorkspaceChatView, rhs: WorkspaceChatView) -> Bool {
    ObjectIdentifier(lhs.chatState) == ObjectIdentifier(rhs.chatState)
      && lhs.workspace == rhs.workspace
      && lhs.context == rhs.context
      && lhs.sessionID == rhs.sessionID
      && ObjectIdentifier(lhs.modelManagementState)
        == ObjectIdentifier(rhs.modelManagementState)
      && ObjectIdentifier(lhs.browserToolService) == ObjectIdentifier(rhs.browserToolService)
      && lhs.appBehaviorSettings == rhs.appBehaviorSettings
      && lhs.mcpServers == rhs.mcpServers
      && lhs.mcpServerStatuses == rhs.mcpServerStatuses
      && ObjectIdentifier(lhs.assistantSpeechService)
        == ObjectIdentifier(rhs.assistantSpeechService)
      && ObjectIdentifier(lhs.speechInputController)
        == ObjectIdentifier(rhs.speechInputController)
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
        chatState: chatState,
        workspace: workspace,
        context: context,
        sessionID: sessionID,
        modelManagementState: modelManagementState,
        appBehaviorSettings: appBehaviorSettings,
        mcpServers: mcpServers,
        mcpServerStatuses: mcpServerStatuses,
        assistantSpeechService: assistantSpeechService,
        speechInputController: speechInputController,
        previewState: previewState,
        isWorkspaceTerminalVisible: $isWorkspaceTerminalVisible,
        onSendMessage: onSendMessage,
        onSelectMCPServerIDs: onSelectMCPServerIDs,
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
          chatState: chatState,
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
        onCreateSession: onCreateSession,
        onOpenWorkspaceInFinder: onOpenWorkspaceInFinder,
        onOpenWorkspaceInVisualStudioCode: onOpenWorkspaceInVisualStudioCode
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
  let chatState: ChatFeatureState
  let workspace: Workspace
  let context: WorkspaceChatContext
  let sessionID: ChatSession.ID?
  let modelManagementState: ModelManagementFeatureState
  let appBehaviorSettings: AppBehaviorSettings
  let mcpServers: [MCPServerConfig]
  let mcpServerStatuses: [MCPServerStatus]
  let assistantSpeechService: AssistantSpeechService
  let speechInputController: ComposerSpeechInputController
  let previewState: WorkspacePreviewFeatureState
  @Binding var isWorkspaceTerminalVisible: Bool
  let onSendMessage: (String) -> Bool
  let onSelectMCPServerIDs: ([UUID]) -> Void
  let onOpenAudioModels: () -> Void
  @State private var composerHeight: CGFloat = 0

  static func == (lhs: WorkspaceChatMainColumn, rhs: WorkspaceChatMainColumn) -> Bool {
    ObjectIdentifier(lhs.chatState) == ObjectIdentifier(rhs.chatState)
      && lhs.workspace == rhs.workspace
      && lhs.context == rhs.context
      && lhs.sessionID == rhs.sessionID
      && ObjectIdentifier(lhs.modelManagementState)
        == ObjectIdentifier(rhs.modelManagementState)
      && lhs.appBehaviorSettings == rhs.appBehaviorSettings
      && lhs.mcpServers == rhs.mcpServers
      && lhs.mcpServerStatuses == rhs.mcpServerStatuses
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

      ZStack(alignment: .bottom) {
        ChatTranscriptHost(
          chatState: chatState,
          modelState: modelManagementState.state.modelState,
          appBehaviorSettings: appBehaviorSettings,
          assistantSpeechService: assistantSpeechService,
          bottomContentInset: composerHeight
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        WorkspaceChatComposerHost(
          chatState: chatState,
          workspace: workspace,
          modelManagementState: modelManagementState,
          mcpServers: mcpServers,
          mcpServerStatuses: mcpServerStatuses,
          previewState: previewState,
          speechInputController: speechInputController,
          onSendMessage: onSendMessage,
          onSelectMCPServerIDs: onSelectMCPServerIDs,
          onOpenAudioModels: onOpenAudioModels
        )
        .background {
          GeometryReader { proxy in
            Color.clear
              .preference(
                key: ComposerHeightPreferenceKey.self,
                value: proxy.size.height
              )
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onPreferenceChange(ComposerHeightPreferenceKey.self) { height in
        composerHeight = height
      }

      WorkspaceTerminalSlot(
        context: context,
        isWorkspaceTerminalVisible: $isWorkspaceTerminalVisible
      )
      .equatable()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct ComposerHeightPreferenceKey: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
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
  let chatState: ChatFeatureState
  let context: WorkspaceChatContext
  let sessionID: ChatSession.ID?
  @Binding var isModelContextDebugVisible: Bool

  static func == (lhs: WorkspaceDebugSlot, rhs: WorkspaceDebugSlot) -> Bool {
    ObjectIdentifier(lhs.chatState) == ObjectIdentifier(rhs.chatState)
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
        chatState: chatState,
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
  let onCreateSession: (Workspace.ID) -> ChatSession.ID?
  let onOpenWorkspaceInFinder: () -> Void
  let onOpenWorkspaceInVisualStudioCode: () -> Void

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
        Button(action: onOpenWorkspaceInVisualStudioCode) {
          Label {
            Text("Open in VS Code")
          } icon: {
            WorkspaceOpenAppIcon(.visualStudioCode)
          }
        }

        Button(action: onOpenWorkspaceInFinder) {
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
