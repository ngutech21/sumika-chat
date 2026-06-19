import SumikaCore
import SwiftUI

struct WorkspaceChatComposerHost: View {
  let controller: ChatSessionController
  let workspace: Workspace
  let sessionID: ChatSession.ID?
  let onAddAttachments: () -> Void
  let onPreviewCommand: (String) -> Bool
  let onShowCommand: (String) -> Bool

  private let slashCommandParser = SlashCommandParser()

  private var onSend: (String) -> Bool {
    { submittedDraft in
      switch handleLocalSlashCommand(submittedDraft) {
      case .handled(let shouldClearDraft):
        return shouldClearDraft
      case .notHandled:
        break
      }

      controller.draft = submittedDraft
      if let sessionID {
        controller.sendMessage(in: workspace, sessionID: sessionID)
      } else {
        controller.sendMessage(in: workspace)
      }
      return controller.draft.isEmpty
    }
  }

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = Self._printChanges()
    #endif

    let localDownloadedModels = downloadedModels
    let isGenerating = controller.isGenerating
    let isInputBlocked = controller.isInputBlocked

    ChatComposer(
      attachments: controller.chatSession.pendingAttachments,
      activeAttachments: controller.activeAttachmentContextAttachments,
      availableModels: localDownloadedModels,
      selectedModel: composerSelectedModel(from: localDownloadedModels),
      modelState: controller.modelRuntime.modelState,
      interactionMode: controller.chatSession.interactionMode,
      todoState: visibleTodoState,
      contextUsage: controller.contextUsage,
      canChangeModel: !localDownloadedModels.isEmpty && !isGenerating
        && controller.modelRuntime.canChangeModel,
      canChangeInteractionMode: !isGenerating && !isInputBlocked,
      canSend: controller.modelRuntime.modelState == .ready && !isGenerating && !isInputBlocked,
      canRunLocalCommand: !isGenerating && !isInputBlocked,
      isGenerating: isGenerating,
      isInputBlocked: isInputBlocked,
      errorMessage: controller.errorMessage,
      onSelectInteractionMode: controller.setInteractionMode,
      onSelectModel: selectModel(_:),
      onLoadModel: loadSelectedModel,
      onAddAttachments: onAddAttachments,
      onDropAttachments: controller.addAttachments,
      onRemoveAttachment: controller.removeAttachment,
      onSend: onSend,
      onCancel: controller.cancelGeneration
    )
  }

  private var visibleTodoState: TodoState? {
    guard controller.chatSession.interactionMode == .agent,
      let todoState = controller.chatSession.todoState,
      !todoState.items.isEmpty
    else {
      return nil
    }
    return todoState
  }

  private var downloadedModels: [ManagedModel] {
    controller.modelRuntime.availableModels.filter { controller.modelRuntime.isModelDownloaded($0) }
  }

  private func composerSelectedModel(from downloadedModels: [ManagedModel]) -> ManagedModel {
    if downloadedModels.contains(controller.modelRuntime.selectedModel) {
      return controller.modelRuntime.selectedModel
    }

    return downloadedModels.first ?? controller.modelRuntime.selectedModel
  }

  private func selectModel(_ model: ManagedModel) {
    guard !controller.isGenerating, controller.modelRuntime.canChangeModel else {
      return
    }

    controller.prepareForModelRuntimeAction(cancelGeneration: false, invalidateContext: true)
    controller.modelRuntime.selectModel(model)
  }

  private func loadSelectedModel() {
    controller.prepareForModelRuntimeAction(cancelGeneration: false, invalidateContext: true)
    guard !downloadedModels.isEmpty else {
      controller.errorMessage = "Download a model from Models first."
      return
    }

    if !downloadedModels.contains(controller.modelRuntime.selectedModel),
      let downloadedModel = downloadedModels.first
    {
      controller.modelRuntime.selectModel(downloadedModel)
    }
    controller.modelRuntime.loadSelectedModel()
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

    guard let command = slashCommandParser.parse(trimmedDraft) else {
      controller.errorMessage = descriptor.usage
      return .handled(shouldClearDraft: false)
    }

    switch command {
    case .preview(let path):
      guard onPreviewCommand(path) else {
        return .handled(shouldClearDraft: false)
      }
    case .show(let path):
      guard onShowCommand(path) else {
        return .handled(shouldClearDraft: false)
      }
    }
    return .handled(shouldClearDraft: true)
  }

  private enum LocalSlashCommandResult {
    case notHandled
    case handled(shouldClearDraft: Bool)
  }
}
