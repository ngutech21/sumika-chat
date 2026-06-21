import AppKit
import SumikaCore
import SwiftUI

struct WorkspaceChatComposerHost: View {
  let controller: ChatSessionController
  let context: WorkspaceChatContext
  let sessionID: ChatSession.ID?
  let previewState: WorkspacePreviewFeatureState

  private static let slashCommandParser = SlashCommandParser()

  private var onSend: (String) -> Bool {
    { submittedDraft in
      switch handleLocalSlashCommand(submittedDraft) {
      case .handled(let shouldClearDraft):
        return shouldClearDraft
      case .notHandled:
        break
      }

      if let sessionID {
        return controller.sendMessage(
          prompt: submittedDraft,
          in: context.workspace(containing: sessionID),
          sessionID: sessionID
        )
      }
      return controller.sendMessage(prompt: submittedDraft, in: context.workspaceWithoutSessions)
    }
  }

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = Self._printChanges()
    #endif

    let localDownloadedModels = downloadedModels
    let composerState = controller.composerSessionState
    let isGenerating = controller.isGenerating

    ChatComposer(
      attachments: composerState.pendingAttachments,
      activeAttachments: composerState.activeAttachments,
      availableModels: localDownloadedModels,
      selectedModel: composerSelectedModel(from: localDownloadedModels),
      modelState: controller.modelRuntime.modelState,
      interactionMode: composerState.interactionMode,
      todoState: composerState.todoState,
      contextUsage: controller.contextUsage,
      canChangeModel: !localDownloadedModels.isEmpty && !isGenerating
        && controller.modelRuntime.canChangeModel,
      canChangeInteractionMode: !isGenerating,
      canSend: controller.modelRuntime.modelState == .ready && !isGenerating,
      canRunLocalCommand: !isGenerating,
      isGenerating: isGenerating,
      errorMessage: controller.errorMessage,
      onSelectInteractionMode: controller.setInteractionMode,
      onSelectModel: selectModel(_:),
      onLoadModel: loadSelectedModel,
      onAddAttachments: chooseAttachments,
      onDropAttachments: controller.addAttachments,
      onRemoveAttachment: controller.removeAttachment,
      onSend: onSend,
      onCancel: controller.cancelGeneration
    )
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
