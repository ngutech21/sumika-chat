import AppKit
import SumikaCore
import SwiftUI

struct WorkspaceChatComposerHost: View {
  let chatState: ChatFeatureState
  let workspace: Workspace
  let modelManagementState: ModelManagementFeatureState
  let mcpServers: [MCPServerConfig]
  let mcpServerStatuses: [MCPServerStatus]
  let previewState: WorkspacePreviewFeatureState
  let speechInputController: ComposerSpeechInputController
  let onSendMessage: (MessageSubmission) async -> Bool
  let onSelectMCPServerIDs: ([UUID]) -> Void
  let onOpenAudioModels: () -> Void

  private static let slashCommandParser = SlashCommandParser()
  @State private var composerErrorMessage: String?

  private var onSend: (MessageSubmission) async -> Bool {
    { submission in
      switch handleLocalSlashCommand(submission.text) {
      case .handled(let shouldClearDraft):
        return shouldClearDraft
      case .notHandled:
        break
      }

      return await onSendMessage(submission)
    }
  }

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = Self._printChanges()
    #endif

    let localDownloadedModels = downloadedModels
    let modelState = modelManagementState.state
    let presentation = chatState.composer
    let composerState = presentation.session
    let isGenerating = presentation.isGenerating
    let selectedComposerModel = composerSelectedModel(from: localDownloadedModels)

    ChatComposer(
      attachments: composerState.pendingAttachments,
      availableModels: localDownloadedModels,
      selectedModel: selectedComposerModel,
      modelState: modelState.modelState,
      interactionMode: composerState.interactionMode,
      skillCatalog: presentation.skillCatalog,
      sessionOptionsConfiguration: ChatComposerOptions.Configuration(
        interactionMode: composerState.interactionMode,
        reasoningSelection: composerState.reasoningSelection,
        reasoningCapability: selectedComposerModel.reasoningCapability,
        toolApprovalPolicy: composerState.toolApprovalPolicy,
        canChangeReasoning: presentation.canChangeInteractionMode,
        canEnableAutomaticToolApproval: presentation.canEnableAutomaticToolApproval,
        servers: mcpServers,
        statuses: mcpServerStatuses,
        selectedServerIDs: composerState.selectedMCPServerIDs,
        canChangeMCPSelection: presentation.canChangeMCPServerSelection,
        onSetReasoningSelection: chatState.setReasoningSelection,
        onEnableAutomaticToolApproval: chatState.enableAutomaticToolApproval,
        onDisableAutomaticToolApproval: chatState.disableAutomaticToolApproval,
        onSelectServerIDs: onSelectMCPServerIDs
      ),
      todoState: composerState.todoState,
      canChangeModel: !localDownloadedModels.isEmpty && modelManagementState.canChangeModel,
      canChangeInteractionMode: presentation.canChangeInteractionMode,
      canSend: modelManagementState.canSend,
      canRunLocalCommand: !isGenerating,
      isGenerating: isGenerating,
      isPreparingTurn: presentation.isPreparingTurn,
      errorMessage: presentedErrorMessage,
      onSelectInteractionMode: chatState.setInteractionMode,
      onSelectModel: selectModel(_:),
      onLoadModel: loadSelectedModel,
      onAddAttachments: chooseAttachments,
      onDropAttachments: chatState.addAttachments,
      onRemoveAttachment: chatState.removeAttachment,
      speechInputController: speechInputController,
      onOpenAudioModels: onOpenAudioModels,
      onRefreshSkills: chatState.refreshSkillCatalog,
      onSend: onSend,
      onCancel: chatState.cancelGeneration
    )
  }

  private var downloadedModels: [ManagedModel] {
    modelManagementState.downloadedModels
  }

  private var presentedErrorMessage: String? {
    composerErrorMessage
      ?? previewState.errorMessage
      ?? modelManagementState.errorMessage
      ?? chatState.composer.errorMessage
  }

  private func composerSelectedModel(from downloadedModels: [ManagedModel]) -> ManagedModel {
    let selectedModel = modelManagementState.state.selectedModel
    if downloadedModels.contains(selectedModel) {
      return selectedModel
    }

    return downloadedModels.first ?? selectedModel
  }

  private func selectModel(_ model: ManagedModel) {
    clearLocalPresentationErrors()
    guard chatState.activateSelectedConversation() else {
      return
    }
    modelManagementState.selectConversationModel(model)
  }

  private func loadSelectedModel() {
    clearLocalPresentationErrors()
    modelManagementState.loadAvailableModelForConversation()
  }

  private func handleLocalSlashCommand(_ draft: String) -> LocalSlashCommandResult {
    let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedDraft.hasPrefix("/") else {
      clearLocalPresentationErrors()
      return .notHandled
    }

    let name = String(trimmedDraft.dropFirst().prefix { !$0.isWhitespace })
    guard let descriptor = SlashCommandRegistry.descriptor(named: name) else {
      // Unknown command text: leave it for the normal send path.
      clearLocalPresentationErrors()
      return .notHandled
    }

    guard let command = Self.slashCommandParser.parse(trimmedDraft) else {
      previewState.clearError()
      composerErrorMessage = descriptor.usage
      return .handled(shouldClearDraft: false)
    }

    composerErrorMessage = nil
    switch command {
    case .preview(let path):
      guard
        previewState.showHTMLPreview(
          path: path,
          in: workspace
        )
      else {
        return .handled(shouldClearDraft: false)
      }
    case .show(let path):
      guard
        previewState.showFilePreview(
          path: path,
          in: workspace
        )
      else {
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
    panel.message = "Choose text, image, or DOCX files to add as model context."
    panel.prompt = "Add"

    if panel.runModal() == .OK {
      chatState.addAttachments(from: panel.urls)
    }
  }

  private func clearLocalPresentationErrors() {
    composerErrorMessage = nil
    previewState.clearError()
  }

  private enum LocalSlashCommandResult {
    case notHandled
    case handled(shouldClearDraft: Bool)
  }
}
