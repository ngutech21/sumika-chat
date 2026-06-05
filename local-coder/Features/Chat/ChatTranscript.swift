import AppKit
import LocalCoderCore
import MarkdownUI
import SwiftUI

struct ChatTranscript: View {
  let turns: [ChatTurn]
  let toolCalls: [ToolCallRecord]
  let selectedModel: ManagedModel
  let modelState: ModelLoadState
  let onApproveToolCall: (ToolCallRecord.ID) -> Void
  let onDenyToolCall: (ToolCallRecord.ID) -> Void

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 12) {
        if transcriptItems.isEmpty {
          ContentUnavailableView(
            emptyStateTitle,
            systemImage: "bubble.left.and.bubble.right",
            description: Text(emptyStateDescription)
          )
          .frame(maxWidth: .infinity, minHeight: 360)
          .accessibilityIdentifier("chat.emptyState")
        } else {
          ForEach(transcriptItems) { item in
            ChatBubble(
              message: item.message,
              toolCallRecord: item.toolCallRecord,
              onApproveToolCall: onApproveToolCall,
              onDenyToolCall: onDenyToolCall
            )
          }
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityIdentifier("chat.transcript")
    .accessibilityValue(modelState.accessibilityValue)
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
      "Loading \(selectedModel.displayName). You can write a prompt once it is ready."
    case .failed:
      "Loading failed. Select or load a model below before writing a prompt."
    case .notLoaded:
      "Select and load a Gemma model below before writing a prompt."
    }
  }

  private var transcriptItems: [RenderedChatTurnItem] {
    let recordsByID = Dictionary(toolCalls.map { ($0.id, $0) }) { _, latest in latest }
    return turns.flatMap { turn in
      turn.items.enumerated().compactMap { offset, item in
        switch item {
        case .userMessage(let message), .assistantMessage(let message):
          return RenderedChatTurnItem(
            id: "\(turn.id.uuidString):\(offset):message:\(message.id.uuidString)",
            message: message,
            toolCallRecord: nil
          )
        case .toolCall(let id):
          guard let record = recordsByID[id] else {
            return nil
          }
          return RenderedChatTurnItem(
            id: "\(turn.id.uuidString):\(offset):toolCall:\(id.uuidString)",
            message: ChatMessage(id: id, toolCall: ToolCallModelMessage(request: record.request)),
            toolCallRecord: record
          )
        case .toolResult(let id):
          guard let record = recordsByID[id] else {
            return nil
          }
          return RenderedChatTurnItem(
            id: "\(turn.id.uuidString):\(offset):toolResult:\(id.uuidString)",
            message: ChatMessage(id: id, toolResult: ToolResultModelMessage(record: record)),
            toolCallRecord: record
          )
        }
      }
    }
  }
}

private struct RenderedChatTurnItem: Identifiable {
  let id: String
  let message: ChatMessage
  let toolCallRecord: ToolCallRecord?
}

private struct ChatBubble: View {
  let message: ChatMessage
  let toolCallRecord: ToolCallRecord?
  let onApproveToolCall: (ToolCallRecord.ID) -> Void
  let onDenyToolCall: (ToolCallRecord.ID) -> Void
  @State private var didCopy = false

  var body: some View {
    HStack(alignment: .top) {
      if message.isDisplayedAsUser {
        Spacer(minLength: 80)
      }

      VStack(alignment: message.isDisplayedAsUser ? .trailing : .leading, spacing: 6) {
        Label(message.displayTitle, systemImage: message.displaySystemImage)
          .font(.caption)
          .foregroundStyle(.secondary)

        if message.shouldShowAssistantPlaceholder {
          Label(
            message.assistantPlaceholderTitle,
            systemImage: message.assistantPlaceholderSystemImage
          )
          .foregroundStyle(.secondary)
          .padding(10)
          .background(Color.secondary.opacity(0.12))
          .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
          VStack(alignment: message.isDisplayedAsUser ? .trailing : .leading, spacing: 8) {
            MessageContentText(
              message: message,
              toolCallRecord: toolCallRecord,
              onApproveToolCall: onApproveToolCall,
              onDenyToolCall: onDenyToolCall
            )
            .textSelection(.enabled)

            if let metrics = message.generationMetrics {
              GenerationMetricsView(metrics: metrics)
            }
          }
          .padding(10)
          .background(messageBubbleBackground)
          .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        if message.isDisplayedAsUser && !message.attachments.isEmpty {
          SentAttachmentList(attachments: message.attachments)
        }

        if message.canCopyAssistantContent {
          HStack(spacing: 8) {
            Button {
              copyMessageToClipboard()
            } label: {
              Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(didCopy ? "Copied" : "Copy")
            .accessibilityLabel("Copy assistant message")
          }
        }
      }
      .frame(maxWidth: 680, alignment: message.isDisplayedAsUser ? .trailing : .leading)

      if !message.isDisplayedAsUser {
        Spacer(minLength: 80)
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityIdentifier(message.accessibilityIdentifier)
  }

  private func copyMessageToClipboard() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(message.content, forType: .string)
    didCopy = true

    Task {
      try? await Task.sleep(for: .seconds(1.2))
      didCopy = false
    }
  }
}

private struct GenerationMetricsView: View {
  let metrics: ChatGenerationMetrics

  var body: some View {
    Text(metrics.visibleSummary)
      .font(.caption2)
      .foregroundStyle(.secondary)
      .help(metrics.detailSummary)
      .accessibilityLabel(metrics.accessibilitySummary)
      .accessibilityIdentifier("chat.generationMetrics")
  }
}

private struct SentAttachmentList: View {
  let attachments: [ChatAttachment]

  var body: some View {
    VStack(alignment: .trailing, spacing: 4) {
      ForEach(attachments) { attachment in
        Label(attachment.displayName, systemImage: "doc.text")
          .font(.caption)
          .lineLimit(1)
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(Color.secondary.opacity(0.12))
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .help(attachment.displayPath)
      }
    }
  }
}

private struct MessageContentText: View {
  let message: ChatMessage
  let toolCallRecord: ToolCallRecord?
  let onApproveToolCall: (ToolCallRecord.ID) -> Void
  let onDenyToolCall: (ToolCallRecord.ID) -> Void

  @ViewBuilder
  var body: some View {
    switch message.payload {
    case .toolCall(let payload):
      ToolCallSummaryView(
        toolCall: payload.toolCall,
        toolCallRecord: toolCallRecord,
        onApprove: onApproveToolCall,
        onDeny: onDenyToolCall
      )
    case .toolResult(let toolResult):
      ToolResultSummaryView(toolResult: toolResult, toolCallRecord: toolCallRecord)
    case .assistant(let payload):
      Markdown(AssistantMarkdownPreprocessor.renderableContent(for: payload.content))
        .markdownTheme(.chatMessage)
        .markdownCodeSyntaxHighlighter(ChatCodeSyntaxHighlighter())
    case .user(let payload):
      Text(payload.content)
    case .system(let payload):
      Text(payload.content)
    }
  }
}

private struct ChatCodeSyntaxHighlighter: CodeSyntaxHighlighter {
  func highlightCode(_ code: String, language: String?) -> Text {
    _ = language
    return Text(code)
  }
}

extension Theme {
  static let chatMessage = Theme()
    .text {
      ForegroundColor(.primary)
      FontSize(13)
    }
    .code {
      FontFamilyVariant(.monospaced)
      FontSize(.em(0.92))
      ForegroundColor(.primary)
      BackgroundColor(.secondary.opacity(0.16))
    }
    .link {
      ForegroundColor(.accentColor)
      UnderlineStyle(.single)
    }
    .paragraph { configuration in
      configuration.label
        .relativeLineSpacing(.em(0.2))
        .markdownMargin(top: 0, bottom: 8)
    }
    .listItem { configuration in
      configuration.label
        .markdownMargin(top: 2, bottom: 2)
    }
    .blockquote { configuration in
      HStack(spacing: 0) {
        Rectangle()
          .fill(Color.secondary.opacity(0.45))
          .frame(width: 3)
        configuration.label
          .padding(.leading, 8)
          .markdownTextStyle {
            ForegroundColor(.secondary)
          }
      }
      .markdownMargin(top: 4, bottom: 8)
    }
    .codeBlock { configuration in
      ScrollView(.horizontal, showsIndicators: true) {
        configuration.label
          .markdownTextStyle {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
            BackgroundColor(nil)
          }
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .markdownMargin(top: 4, bottom: 8)
    }
}

extension ChatGenerationMetrics {
  var visibleSummary: String {
    guard let durationMs else {
      return "\(generatedTokenCount) tokens"
    }

    return "\(generatedTokenCount) tokens · \(formattedDuration(durationMs))"
  }

  var detailSummary: String {
    "\(visibleSummary) · \(tokensPerSecond.formatted(.number.precision(.fractionLength(1)))) tokens/s"
  }

  var accessibilitySummary: String {
    guard let durationMs else {
      return "\(generatedTokenCount) generated tokens"
    }

    return "\(generatedTokenCount) generated tokens in \(formattedDuration(durationMs))"
  }

  private func formattedDuration(_ durationMs: Double) -> String {
    let durationSeconds = durationMs / 1000
    if durationSeconds < 10 {
      return "\(durationSeconds.formatted(.number.precision(.fractionLength(1)))) s"
    }
    return "\(durationSeconds.formatted(.number.precision(.fractionLength(0)))) s"
  }
}

extension ChatBubble {
  var messageBubbleBackground: Color {
    message.isDisplayedAsUser ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.12)
  }
}

extension ChatMessage {
  fileprivate var accessibilityIdentifier: String {
    switch payload {
    case .assistant:
      "chat.assistantMessage"
    case .user:
      "chat.userMessage"
    case .system:
      "chat.systemMessage"
    case .toolCall:
      "chat.toolCallMessage"
    case .toolResult:
      "chat.toolResultMessage"
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
