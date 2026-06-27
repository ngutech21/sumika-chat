import SumikaCore
import SwiftUI

struct ChatTranscript: View {
  let turns: [ChatTurn]
  let selectedModel: ManagedModel
  let modelState: ModelLoadState
  let isGenerating: Bool
  let appBehaviorSettings: AppBehaviorSettings
  let assistantSpeechService: AssistantSpeechService
  let onApproveToolCall: (ToolCallRecord.ID) -> Void
  let onDenyToolCall: (ToolCallRecord.ID) -> Void
  let onAnswerAskUser: (ToolCallRecord.ID, String) -> Void
  @State private var renderer = ChatTranscriptRenderer()

  var body: some View {
    let items = renderer.items(for: turns)

    if items.isEmpty {
      ZStack {
        ContentUnavailableView(
          emptyStateTitle,
          systemImage: "bubble.left.and.bubble.right",
          description: Text(emptyStateDescription)
        )
        .frame(maxWidth: .infinity, minHeight: 360)
        .accessibilityIdentifier("chat.emptyState")
      }
      .accessibilityIdentifier("chat.transcript")
      .accessibilityValue(modelState.accessibilityValue)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      AppKitChatTranscriptRepresentable(
        items: items,
        showsGenerationIndicator: ChatTranscriptGenerationIndicatorPolicy.shouldShow(
          isGenerating: isGenerating,
          items: items
        ),
        accessibilityValue: modelState.accessibilityValue,
        isSpeechEnabled: appBehaviorSettings.assistantSpeechEnabled,
        activeSpeechRowID: assistantSpeechService.activeRowID,
        onToggleSpeech: { rowID, text in
          assistantSpeechService.toggle(
            rowID: rowID,
            text: text,
            settings: appBehaviorSettings
          )
        },
        onApproveToolCall: onApproveToolCall,
        onDenyToolCall: onDenyToolCall,
        onAnswerAskUser: onAnswerAskUser
      )
    }
  }

  private var emptyStateTitle: String {
    switch modelState {
    case .ready:
      "\(selectedModel.displayName) Ready"
    case .loading:
      "Loading Model"
    case .failed:
      "Model Not Ready"
    case .notLoaded:
      "No Model Loaded"
    }
  }

  private var emptyStateDescription: String {
    switch modelState {
    case .ready:
      "Send a prompt with \(selectedModel.displayName) to start chatting."
    case .loading:
      "Loading \(selectedModel.displayName). You can write a prompt while it loads."
    case .failed:
      "Loading failed. You can revise your prompt, then load a model below."
    case .notLoaded:
      "Write a prompt anytime, then load a Gemma model below before sending."
    }
  }

}

enum ChatTranscriptGenerationIndicatorPolicy {
  static func shouldShow(isGenerating: Bool, items: [RenderedChatTurnItem]) -> Bool {
    isGenerating && !items.contains(where: \.isActiveTranscriptGenerationItem)
  }
}

extension ModelLoadState {
  fileprivate var accessibilityValue: String {
    switch self {
    case .notLoaded:
      "notLoaded"
    case .loading:
      "loading"
    case .ready:
      "ready"
    case .failed:
      "failed"
    }
  }
}
