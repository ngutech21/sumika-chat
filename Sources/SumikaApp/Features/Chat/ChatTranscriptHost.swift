import SumikaCore
import SwiftUI

struct ChatTranscriptHost: View {
  let controller: ChatSessionController
  let context: WorkspaceChatContext
  let sessionID: ChatSession.ID?
  let modelState: ModelLoadState
  let appBehaviorSettings: AppBehaviorSettings
  let assistantSpeechService: AssistantSpeechService
  var bottomContentInset: CGFloat = 0

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = Self._printChanges()
    #endif

    ChatTranscript(
      turns: controller.chatSession.turns,
      modelState: modelState,
      isGenerating: controller.isGenerating,
      toolApprovalPolicy: controller.chatSession.toolApprovalPolicy,
      appBehaviorSettings: appBehaviorSettings,
      assistantSpeechService: assistantSpeechService,
      bottomContentInset: bottomContentInset,
      onApproveToolCall: { toolCallID in
        controller.approveToolCall(id: toolCallID, in: toolWorkspace)
      },
      onApproveToolCallBatch: { anchorID in
        controller.approveToolCallBatch(containing: anchorID, in: toolWorkspace)
      },
      onResumeAutomaticApprovalBatch: { anchorID in
        controller.resumeAutomaticApprovalBatch(containing: anchorID, in: toolWorkspace)
      },
      onDenyToolCall: { toolCallID in
        controller.denyToolCall(id: toolCallID)
      },
      onAnswerAskUser: { toolCallID, answer in
        controller.answerAskUserToolCall(
          id: toolCallID,
          answer: answer,
          in: toolWorkspace
        )
      }
    )
  }

  private var toolWorkspace: Workspace {
    context.workspace(containing: sessionID ?? controller.chatSession.id)
  }
}
