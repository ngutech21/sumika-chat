import SumikaCore
import SwiftUI

struct ChatTranscriptHost: View {
  let controller: ChatSessionController
  let workspace: Workspace

  var body: some View {
    ChatTranscript(
      turns: controller.chatSession.turns,
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
  }
}
