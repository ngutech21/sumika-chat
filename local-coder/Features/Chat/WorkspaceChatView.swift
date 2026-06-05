import LocalCoderCore
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
        turns: controller.chatSession.turns,
        toolCalls: controller.chatSession.toolCalls,
        selectedModel: controller.modelRuntime.selectedModel,
        modelState: controller.modelRuntime.modelState,
        onApproveToolCall: { toolCallID in
          controller.approveToolCall(id: toolCallID, in: workspace)
        },
        onDenyToolCall: { toolCallID in
          controller.denyToolCall(id: toolCallID)
        }
      )

      Divider()

      ChatComposer(
        draft: $controller.draft,
        attachments: controller.chatSession.pendingAttachments,
        availableModels: controller.modelRuntime.availableModels,
        selectedModel: controller.modelRuntime.selectedModel,
        modelState: controller.modelRuntime.modelState,
        interactionMode: controller.chatSession.interactionMode,
        contextUsage: controller.contextUsage,
        processUsage: controller.modelRuntime.processUsage,
        canChangeModel: !controller.isGenerating && controller.modelRuntime.canChangeModel,
        canChangeInteractionMode: controller.canChangeInteractionMode,
        isSelectedModelDownloaded: controller.modelRuntime.isModelDownloaded(
          controller.modelRuntime.selectedModel),
        canSend: controller.canSend,
        isGenerating: controller.isGenerating,
        isInputBlocked: controller.hasPendingApproval,
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
