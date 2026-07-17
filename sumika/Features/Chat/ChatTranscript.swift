import SumikaCore
import SwiftUI

struct ChatTranscript: View {
  let turns: [ChatTurn]
  let modelState: ModelLoadState
  let isGenerating: Bool
  let toolApprovalPolicy: ToolApprovalPolicy
  let appBehaviorSettings: AppBehaviorSettings
  let assistantSpeechService: AssistantSpeechService
  var bottomContentInset: CGFloat = 0
  let onApproveToolCall: (ToolCallRecord.ID) -> Void
  let onApproveToolCallBatch: (ToolCallRecord.ID) -> Void
  let onResumeAutomaticApprovalBatch: (ToolCallRecord.ID) -> Void
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
      // Keep the empty-state message centered within the area the floating
      // composer leaves visible rather than behind it.
      .padding(.bottom, bottomContentInset)
    } else {
      AppKitChatTranscriptRepresentable(
        items: items,
        isGenerating: isGenerating,
        toolApprovalPolicy: toolApprovalPolicy,
        showsGenerationIndicator: ChatTranscriptGenerationIndicatorPolicy.shouldShow(
          isGenerating: isGenerating,
          turns: turns
        ),
        accessibilityValue: modelState.accessibilityValue,
        isSpeechEnabled: appBehaviorSettings.assistantSpeechEnabled,
        activeSpeechRowID: assistantSpeechService.activeRowID,
        bottomContentInset: bottomContentInset,
        onToggleSpeech: { rowID, text in
          assistantSpeechService.toggle(
            rowID: rowID,
            text: text,
            settings: appBehaviorSettings
          )
        },
        onApproveToolCall: onApproveToolCall,
        onApproveToolCallBatch: onApproveToolCallBatch,
        onResumeAutomaticApprovalBatch: onResumeAutomaticApprovalBatch,
        onDenyToolCall: onDenyToolCall,
        onAnswerAskUser: onAnswerAskUser
      )
    }
  }

  private var emptyStateTitle: String {
    switch modelState {
    case .ready:
      "What should we work on?"
    case .loading:
      "Getting ready"
    case .failed:
      "Model unavailable"
    case .notLoaded:
      "Start a local chat"
    }
  }

  private var emptyStateDescription: String {
    switch modelState {
    case .ready:
      "Ask about this workspace, attach files for context, or dictate a prompt to get started."
    case .loading:
      "You can draft your message while the local model loads."
    case .failed:
      "Check Models, then try loading again."
    case .notLoaded:
      "Write a prompt now, then load a local model before sending."
    }
  }

}

enum ChatTranscriptGenerationIndicatorPolicy {
  static func shouldShow(isGenerating: Bool, turns: [ChatTurn]) -> Bool {
    guard isGenerating else {
      return false
    }
    guard let activeTurn = turns.last(where: { $0.status == .running }) else {
      return true
    }

    return !activeTurn.items.contains { item in
      switch item {
      case .assistantThinking(let message):
        message.deliveryStatus == .streaming
      case .assistantMessage(let message):
        message.shouldShowAssistantPlaceholder
      case .userMessage, .tool:
        false
      }
    }
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
