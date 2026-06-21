import SumikaCore
import SwiftUI

struct ChatTranscriptHost: View {
  let controller: ChatSessionController
  let context: WorkspaceChatContext
  let sessionID: ChatSession.ID?

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = Self._printChanges()
    #endif

    ChatTranscript(
      turns: controller.chatSession.turns,
      selectedModel: controller.modelRuntime.selectedModel,
      modelState: controller.modelRuntime.modelState,
      isGenerating: controller.isGenerating,
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
