import SumikaCore
import SwiftUI

struct ChatTranscriptHost: View {
  let chatState: ChatFeatureState
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
        chatState.approveToolCall(id: toolCallID, in: context, sessionID: sessionID)
      },
      onApproveToolCallBatch: { anchorID in
        chatState.approveToolCallBatch(
          containing: anchorID,
          in: context,
          sessionID: sessionID
        )
      },
      onResumeAutomaticApprovalBatch: { anchorID in
        chatState.resumeAutomaticApprovalBatch(
          containing: anchorID,
          in: context,
          sessionID: sessionID
        )
      },
      onDenyToolCall: { toolCallID in
        chatState.denyToolCall(id: toolCallID)
      },
      onAnswerAskUser: { toolCallID, answer in
        chatState.answerAskUserToolCall(
          id: toolCallID,
          answer: answer,
          in: context,
          sessionID: sessionID
        )
      }
    )
  }
}
