import SumikaCore
import SwiftUI

struct WorkspaceChatView: View {
  let controller: ChatSessionController
  let context: WorkspaceChatContext
  let sessionID: ChatSession.ID?
  let browserToolService: HTMLPreviewBrowserToolService
  @Binding var isModelContextDebugVisible: Bool
  @Binding var isWorkspaceTerminalVisible: Bool
  let isSidebarCollapsed: Bool
  let onToggleSidebar: () -> Void
  let onOpenWorkspaceInFinder: () -> Void
  let onOpenWorkspaceInVisualStudioCode: () -> Void
  @State private var previewState = WorkspacePreviewFeatureState()

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
        previewState: previewState,
        isWorkspaceTerminalVisible: $isWorkspaceTerminalVisible,
        isSidebarCollapsed: isSidebarCollapsed,
        onToggleSidebar: onToggleSidebar,
        onOpenWorkspaceInFinder: onOpenWorkspaceInFinder,
        onOpenWorkspaceInVisualStudioCode: onOpenWorkspaceInVisualStudioCode
      )

      WorkspacePreviewSlot(
        previewState: previewState,
        browserToolService: browserToolService
      )

      WorkspaceDebugSlot(
        controller: controller,
        context: context,
        sessionID: sessionID,
        isModelContextDebugVisible: $isModelContextDebugVisible
      )
    }
    .onDisappear {
      Task {
        await browserToolService.clear()
      }
    }
  }

}

private struct WorkspaceChatMainColumn: View {
  let controller: ChatSessionController
  let context: WorkspaceChatContext
  let sessionID: ChatSession.ID?
  let previewState: WorkspacePreviewFeatureState
  @Binding var isWorkspaceTerminalVisible: Bool
  let isSidebarCollapsed: Bool
  let onToggleSidebar: () -> Void
  let onOpenWorkspaceInFinder: () -> Void
  let onOpenWorkspaceInVisualStudioCode: () -> Void

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = Self._printChanges()
    #endif

    VStack(spacing: 0) {
      WorkspaceChatHeader(
        workspaceName: context.name,
        isSidebarCollapsed: isSidebarCollapsed,
        onToggleSidebar: onToggleSidebar,
        isWorkspaceTerminalVisible: isWorkspaceTerminalVisible,
        onToggleTerminal: {
          isWorkspaceTerminalVisible.toggle()
        },
        onOpenWorkspaceInFinder: onOpenWorkspaceInFinder,
        onOpenWorkspaceInVisualStudioCode: onOpenWorkspaceInVisualStudioCode
      )

      ChatTranscriptHost(
        controller: controller,
        context: context
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      WorkspaceChatComposerHost(
        controller: controller,
        context: context,
        sessionID: sessionID,
        previewState: previewState
      )

      WorkspaceTerminalSlot(
        context: context,
        isWorkspaceTerminalVisible: $isWorkspaceTerminalVisible
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct WorkspaceTerminalSlot: View {
  let context: WorkspaceChatContext
  @Binding var isWorkspaceTerminalVisible: Bool

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

private struct WorkspacePreviewSlot: View {
  let previewState: WorkspacePreviewFeatureState
  let browserToolService: HTMLPreviewBrowserToolService

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

private struct WorkspaceDebugSlot: View {
  let controller: ChatSessionController
  let context: WorkspaceChatContext
  let sessionID: ChatSession.ID?
  @Binding var isModelContextDebugVisible: Bool

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

private struct WorkspaceChatHeader: View {
  let workspaceName: String
  let isSidebarCollapsed: Bool
  let onToggleSidebar: () -> Void
  let isWorkspaceTerminalVisible: Bool
  let onToggleTerminal: () -> Void
  let onOpenWorkspaceInFinder: () -> Void
  let onOpenWorkspaceInVisualStudioCode: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Button(action: onToggleSidebar) {
        Image(systemName: "sidebar.left")
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
      .help(isSidebarCollapsed ? "Show sidebar" : "Hide sidebar")
      .accessibilityLabel(isSidebarCollapsed ? "Show sidebar" : "Hide sidebar")
      .accessibilityIdentifier("workspace.sidebarToggleButton")

      Text(workspaceName)
        .font(.headline)
        .lineLimit(1)
        .truncationMode(.tail)

      Spacer()

      Button(action: onToggleTerminal) {
        Image(systemName: isWorkspaceTerminalVisible ? "terminal.fill" : "terminal")
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
      .help(isWorkspaceTerminalVisible ? "Hide workspace terminal" : "Show workspace terminal")
      .accessibilityLabel(
        isWorkspaceTerminalVisible ? "Hide workspace terminal" : "Show workspace terminal"
      )
      .accessibilityIdentifier("workspace.terminalToggleButton")

      Button(action: onOpenWorkspaceInFinder) {
        Image(systemName: "folder")
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
      .help("Open workspace in Finder")
      .accessibilityLabel("Open workspace in Finder")
      .accessibilityIdentifier("workspace.openInFinderButton")

      Button(action: onOpenWorkspaceInVisualStudioCode) {
        Image(systemName: "curlybraces")
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
      .help("Open workspace in Visual Studio Code")
      .accessibilityLabel("Open workspace in Visual Studio Code")
      .accessibilityIdentifier("workspace.openInVSCodeButton")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity)
    .background(.bar)
    .overlay(alignment: .bottom) {
      Divider()
    }
  }
}
