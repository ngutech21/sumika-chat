import LocalCoderCore
import SwiftUI

struct WorkspaceChatView: View {
  @Bindable var controller: ChatSessionController
  let workspace: Workspace
  let sessionID: ChatSession.ID?
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
        isGenerating: controller.isGenerating,
        onApproveToolCall: { toolCallID in
          controller.approveToolCall(id: toolCallID, in: workspace)
        },
        onDenyToolCall: { toolCallID in
          controller.denyToolCall(id: toolCallID)
        },
        onAnswerAskUser: { toolCallID, answer in
          controller.answerAskUserToolCall(id: toolCallID, answer: answer, in: workspace)
        }
      )

      ChatComposer(
        draft: $controller.draft,
        attachments: controller.chatSession.pendingAttachments,
        activeAttachments: controller.activeAttachmentContextAttachments,
        availableModels: downloadedModels,
        selectedModel: composerSelectedModel,
        modelState: controller.modelRuntime.modelState,
        interactionMode: controller.chatSession.interactionMode,
        contextUsage: controller.contextUsage,
        processUsage: controller.modelRuntime.processUsage,
        canChangeModel: !downloadedModels.isEmpty && !controller.isGenerating
          && controller.modelRuntime.canChangeModel,
        canChangeInteractionMode: controller.canChangeInteractionMode,
        canSend: controller.canSend,
        isGenerating: controller.isGenerating,
        isInputBlocked: controller.isInputBlocked,
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
      .overlay(alignment: .top) {
        if let todoState = visibleTodoState {
          TodoPlanPanel(todoState: todoState)
            .padding(.horizontal, 16)
            .alignmentGuide(.top) { dimensions in
              dimensions[.bottom] + 8
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
      }
      .zIndex(1)
    }
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

  private var composerSelectedModel: ManagedModel {
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
}
