import SwiftUI

struct WorkspaceChatView: View {
  @Bindable var controller: ChatSessionController
  let workspace: Workspace
  let sessionID: CodingSession.ID?
  let onAddAttachments: () -> Void

  private var onSend: () -> Void {
    {
      if let sessionID {
        controller.sendMessage(in: workspace, sessionID: sessionID)
      } else {
        controller.sendMessage(in: workspace)
      }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      ChatTranscript(
        messages: controller.chatSession.messages,
        selectedModel: controller.modelRuntime.selectedModel,
        modelState: controller.modelRuntime.modelState
      )

      Divider()

      ChatComposer(
        draft: $controller.draft,
        attachments: controller.chatSession.attachments,
        availableModels: controller.modelRuntime.availableModels,
        selectedModel: controller.modelRuntime.selectedModel,
        modelState: controller.modelRuntime.modelState,
        contextUsage: controller.contextUsage,
        processUsage: controller.modelRuntime.processUsage,
        canChangeModel: !controller.isGenerating && controller.modelRuntime.canChangeModel,
        isSelectedModelDownloaded: controller.modelRuntime.isModelDownloaded(
          controller.modelRuntime.selectedModel),
        canSend: controller.canSend,
        isGenerating: controller.isGenerating,
        errorMessage: controller.errorMessage,
        onSelectModel: selectModel(_:),
        onLoadModel: loadSelectedModel,
        onAddAttachments: onAddAttachments,
        onDropAttachments: controller.addAttachments,
        onRemoveAttachment: controller.removeAttachment,
        onSend: onSend,
        onCancel: controller.cancelGeneration
      )
    }
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
    controller.modelRuntime.loadSelectedModel()
  }
}
