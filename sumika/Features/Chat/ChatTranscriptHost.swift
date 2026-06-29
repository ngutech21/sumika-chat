import SumikaCore
import SwiftUI

struct ChatTranscriptHost: View {
  let controller: ChatSessionController
  let context: WorkspaceChatContext
  let sessionID: ChatSession.ID?
  let appBehaviorSettings: AppBehaviorSettings
  let assistantSpeechService: AssistantSpeechService

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = Self._printChanges()
    #endif

    ChatTranscript(
      turns: controller.chatSession.turns,
      modelState: controller.modelRuntime.modelState,
      isGenerating: controller.isGenerating,
      appBehaviorSettings: appBehaviorSettings,
      assistantSpeechService: assistantSpeechService,
      onApproveToolCall: { toolCallID in
        controller.approveToolCall(id: toolCallID, in: toolWorkspace)
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
