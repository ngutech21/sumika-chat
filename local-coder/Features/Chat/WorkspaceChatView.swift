import LocalCoderCore
import SwiftUI

struct WorkspaceChatView: View {
  @Bindable var controller: ChatSessionController
  let workspace: Workspace
  let sessionID: ChatSession.ID?
  let onAddAttachments: () -> Void
  @State private var htmlPreview: HTMLPreviewState?
  @State private var htmlPreviewRefreshID = UUID()
  private let slashCommandParser = SlashCommandParser()
  private let htmlPreviewResolver = HTMLPreviewResolver()

  private var onSend: () -> Void {
    {
      if handleLocalSlashCommand() {
        return
      }

      if let sessionID {
        controller.sendMessage(in: workspace, sessionID: sessionID)
      } else {
        controller.sendMessage(in: workspace)
      }
    }
  }

  var body: some View {
    HStack(spacing: 0) {
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
          todoState: visibleTodoState,
          contextUsage: controller.contextUsage,
          processUsage: controller.modelRuntime.processUsage,
          canChangeModel: !downloadedModels.isEmpty && !controller.isGenerating
            && controller.modelRuntime.canChangeModel,
          canChangeInteractionMode: controller.canChangeInteractionMode,
          canSend: controller.canSend || canRunPreviewCommand,
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
        .zIndex(1)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      if let htmlPreview {
        HTMLPreviewPane(
          preview: htmlPreview,
          refreshID: htmlPreviewRefreshID,
          onRefresh: {
            htmlPreviewRefreshID = UUID()
          },
          onClose: {
            self.htmlPreview = nil
          }
        )
        .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
  }

  private var canRunPreviewCommand: Bool {
    !controller.isGenerating
      && !controller.isInputBlocked
      && slashCommandParser.parse(controller.draft) != nil
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

  private func handleLocalSlashCommand() -> Bool {
    let trimmedDraft = controller.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedDraft.hasPrefix("/preview") else {
      return false
    }

    guard case .preview(let path) = slashCommandParser.parse(trimmedDraft) else {
      controller.errorMessage = "Usage: /preview <path-to-html-file>"
      return true
    }

    do {
      htmlPreview = try htmlPreviewResolver.resolve(path: path, in: workspace)
      controller.draft = ""
      controller.errorMessage = nil
    } catch {
      controller.errorMessage = error.localizedDescription
    }
    return true
  }
}
