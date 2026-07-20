import AppKit
import SumikaCore
import SwiftUI

struct WorkspaceChatComposerHost: View {
  let controller: ChatSessionController
  let modelManagementState: ModelManagementFeatureState
  let context: WorkspaceChatContext
  let sessionID: ChatSession.ID?
  let mcpServers: [MCPServerConfig]
  let mcpServerStatuses: [MCPServerStatus]
  let previewState: WorkspacePreviewFeatureState
  let speechInputController: ComposerSpeechInputController
  let onSendMessage: (String, WorkspaceChatContext, ChatSession.ID?) -> Bool
  let onSelectMCPServerIDs: ([UUID]) -> Void
  let onOpenAudioModels: () -> Void

  private static let slashCommandParser = SlashCommandParser()

  private var onSend: (String) -> Bool {
    { submittedDraft in
      switch handleLocalSlashCommand(submittedDraft) {
      case .handled(let shouldClearDraft):
        return shouldClearDraft
      case .notHandled:
        break
      }

      return onSendMessage(submittedDraft, context, sessionID)
    }
  }

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = Self._printChanges()
    #endif

    let localDownloadedModels = downloadedModels
    let modelState = modelManagementState.state
    let composerState = controller.composerSessionState
    let isGenerating = controller.isGenerating

    ChatComposer(
      attachments: composerState.pendingAttachments,
      activeAttachments: composerState.activeAttachments,
      availableModels: localDownloadedModels,
      selectedModel: composerSelectedModel(from: localDownloadedModels),
      modelState: modelState.modelState,
      interactionMode: composerState.interactionMode,
      sessionOptionsConfiguration: ChatComposerOptions.Configuration(
        interactionMode: composerState.interactionMode,
        reasoningEnabled: composerState.reasoningEnabled,
        toolApprovalPolicy: composerState.toolApprovalPolicy,
        canChangeReasoning: controller.canChangeInteractionMode,
        canEnableAutomaticToolApproval: controller.canEnableAutomaticToolApproval,
        servers: mcpServers,
        statuses: mcpServerStatuses,
        selectedServerIDs: composerState.selectedMCPServerIDs,
        canChangeMCPSelection: controller.canChangeMCPServerSelection,
        onSetReasoningEnabled: controller.setReasoningEnabled,
        onEnableAutomaticToolApproval: {
          controller.enableAutomaticToolApproval(in: toolWorkspace)
        },
        onDisableAutomaticToolApproval: controller.disableAutomaticToolApproval,
        onSelectServerIDs: onSelectMCPServerIDs
      ),
      todoState: composerState.todoState,
      contextUsage: controller.contextUsage,
      canChangeModel: !localDownloadedModels.isEmpty && modelManagementState.canChangeModel,
      canChangeInteractionMode: controller.canChangeInteractionMode,
      canSend: modelManagementState.canSend,
      canRunLocalCommand: !isGenerating,
      isGenerating: isGenerating,
      errorMessage: controller.errorMessage,
      onSelectInteractionMode: controller.setInteractionMode,
      onSelectModel: selectModel(_:),
      onLoadModel: loadSelectedModel,
      onAddAttachments: chooseAttachments,
      onDropAttachments: controller.addAttachments,
      onRemoveAttachment: controller.removeAttachment,
      speechInputController: speechInputController,
      onOpenAudioModels: onOpenAudioModels,
      onSend: onSend,
      onCancel: controller.cancelGeneration
    )
  }

  private var downloadedModels: [ManagedModel] {
    modelManagementState.downloadedModels
  }

  private var toolWorkspace: Workspace {
    context.workspace(containing: sessionID ?? controller.chatSession.id)
  }

  private func composerSelectedModel(from downloadedModels: [ManagedModel]) -> ManagedModel {
    let selectedModel = modelManagementState.state.selectedModel
    if downloadedModels.contains(selectedModel) {
      return selectedModel
    }

    return downloadedModels.first ?? selectedModel
  }

  private func selectModel(_ model: ManagedModel) {
    modelManagementState.selectConversationModel(model)
  }

  private func loadSelectedModel() {
    modelManagementState.loadAvailableModelForConversation()
  }

  private func handleLocalSlashCommand(_ draft: String) -> LocalSlashCommandResult {
    let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedDraft.hasPrefix("/") else {
      return .notHandled
    }

    let name = String(trimmedDraft.dropFirst().prefix { !$0.isWhitespace })
    guard let descriptor = SlashCommandRegistry.descriptor(named: name) else {
      // Unknown command text: leave it for the normal send path.
      return .notHandled
    }

    guard let command = Self.slashCommandParser.parse(trimmedDraft) else {
      controller.errorMessage = descriptor.usage
      return .handled(shouldClearDraft: false)
    }

    switch command {
    case .preview(let path):
      guard runPreviewCommand(path: path) else {
        return .handled(shouldClearDraft: false)
      }
    case .show(let path):
      guard runShowCommand(path: path) else {
        return .handled(shouldClearDraft: false)
      }
    }
    return .handled(shouldClearDraft: true)
  }

  private func chooseAttachments() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.canCreateDirectories = false
    panel.message = "Choose text files to add as model context."
    panel.prompt = "Add"

    if panel.runModal() == .OK {
      controller.addAttachments(from: panel.urls)
    }
  }

  private func runPreviewCommand(path: String) -> Bool {
    do {
      try previewState.showHTMLPreview(path: path, in: context.workspaceWithoutSessions)
      controller.errorMessage = nil
      return true
    } catch {
      controller.errorMessage = error.localizedDescription
      return false
    }
  }

  private func runShowCommand(path: String) -> Bool {
    do {
      try previewState.showFilePreview(path: path, in: context.workspaceWithoutSessions)
      controller.errorMessage = nil
      return true
    } catch {
      controller.errorMessage = error.localizedDescription
      return false
    }
  }

  private enum LocalSlashCommandResult {
    case notHandled
    case handled(shouldClearDraft: Bool)
  }
}
