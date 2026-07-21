import SumikaCore
import SwiftUI

struct ChatTranscriptHost: View {
  let chatState: ChatFeatureState
  let modelState: ModelLoadState
  let appBehaviorSettings: AppBehaviorSettings
  let assistantSpeechService: AssistantSpeechService
  var bottomContentInset: CGFloat = 0

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = Self._printChanges()
    #endif

    let presentation = chatState.transcript
    ChatTranscript(
      turns: presentation.turns,
      modelState: modelState,
      isGenerating: presentation.isGenerating,
      toolApprovalPolicy: presentation.toolApprovalPolicy,
      appBehaviorSettings: appBehaviorSettings,
      assistantSpeechService: assistantSpeechService,
      bottomContentInset: bottomContentInset,
      onApproveToolCall: { toolCallID in
        chatState.approveToolCall(id: toolCallID)
      },
      onApproveToolCallBatch: { anchorID in
        chatState.approveToolCallBatch(containing: anchorID)
      },
      onResumeAutomaticApprovalBatch: { anchorID in
        chatState.resumeAutomaticApprovalBatch(containing: anchorID)
      },
      onDenyToolCall: { toolCallID in
        chatState.denyToolCall(id: toolCallID)
      },
      onAnswerAskUser: { toolCallID, answer in
        chatState.answerAskUserToolCall(
          id: toolCallID,
          answer: answer
        )
      }
    )
  }
}
