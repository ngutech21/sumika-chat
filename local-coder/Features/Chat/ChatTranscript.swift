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
              item: item,
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
        case .userMessage(let message):
          return RenderedChatTurnItem(
            id: "\(turn.id.uuidString):\(offset):message:\(message.id.uuidString)",
            item: item,
            toolCallRecord: nil
          )
        case .assistantMessage(let message):
          return RenderedChatTurnItem(
            id: "\(turn.id.uuidString):\(offset):message:\(message.id.uuidString)",
            item: item,
            toolCallRecord: nil
          )
        case .toolCall(let id):
          guard let record = recordsByID[id] else {
            return nil
          }
          return RenderedChatTurnItem(
            id: "\(turn.id.uuidString):\(offset):toolCall:\(id.uuidString)",
            item: item,
            toolCallRecord: record
          )
        case .toolResult(let id):
          guard let record = recordsByID[id] else {
            return nil
          }
          return RenderedChatTurnItem(
            id: "\(turn.id.uuidString):\(offset):toolResult:\(id.uuidString)",
            item: item,
            toolCallRecord: record
          )
        }
      }
    }
  }
}

private struct RenderedChatTurnItem: Identifiable {
  let id: String
  let item: ChatTurnItem
  let toolCallRecord: ToolCallRecord?
}

private struct ChatBubble: View {
  let item: RenderedChatTurnItem
  let onApproveToolCall: (ToolCallRecord.ID) -> Void
  let onDenyToolCall: (ToolCallRecord.ID) -> Void
  @State private var didCopy = false

  var body: some View {
    HStack(alignment: .top) {
      if item.isDisplayedAsUser {
        Spacer(minLength: 80)
      }

      VStack(alignment: item.isDisplayedAsUser ? .trailing : .leading, spacing: 6) {
        Label(item.displayTitle, systemImage: item.displaySystemImage)
          .font(.caption)
          .foregroundStyle(.secondary)

        if item.shouldShowAssistantPlaceholder {
          Label(
            item.assistantPlaceholderTitle,
            systemImage: item.assistantPlaceholderSystemImage
          )
          .foregroundStyle(.secondary)
          .padding(10)
          .background(Color.secondary.opacity(0.12))
          .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
          VStack(alignment: item.isDisplayedAsUser ? .trailing : .leading, spacing: 8) {
            MessageContentText(
              item: item.item,
              toolCallRecord: item.toolCallRecord,
              onApproveToolCall: onApproveToolCall,
              onDenyToolCall: onDenyToolCall
            )
            .textSelection(.enabled)

            if let metrics = item.generationMetrics {
              GenerationMetricsView(metrics: metrics)
            }
          }
          .padding(10)
          .background(item.messageBubbleBackground)
          .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        if item.isDisplayedAsUser && !item.attachments.isEmpty {
          SentAttachmentList(attachments: item.attachments)
        }

        if item.canCopyAssistantContent {
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
      .frame(maxWidth: 680, alignment: item.isDisplayedAsUser ? .trailing : .leading)

      if !item.isDisplayedAsUser {
        Spacer(minLength: 80)
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityIdentifier(item.accessibilityIdentifier)
  }

  private func copyMessageToClipboard() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(item.content, forType: .string)
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
  let item: ChatTurnItem
  let toolCallRecord: ToolCallRecord?
  let onApproveToolCall: (ToolCallRecord.ID) -> Void
  let onDenyToolCall: (ToolCallRecord.ID) -> Void

  @ViewBuilder
  var body: some View {
    switch item {
    case .toolCall:
      if let toolCallRecord {
        ToolCallSummaryView(
          toolCall: ToolCallModelMessage(request: toolCallRecord.request),
          toolCallRecord: toolCallRecord,
          onApprove: onApproveToolCall,
          onDeny: onDenyToolCall
        )
      }
    case .toolResult:
      if let toolCallRecord {
        ToolResultSummaryView(
          toolResult: ToolResultModelMessage(record: toolCallRecord),
          toolCallRecord: toolCallRecord
        )
      }
    case .assistantMessage(let message):
      Markdown(AssistantMarkdownPreprocessor.renderableContent(for: message.content))
        .markdownTheme(.chatMessage)
        .markdownCodeSyntaxHighlighter(ChatCodeSyntaxHighlighter())
    case .userMessage(let message):
      Text(message.content)
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
    return "\(generatedTokenCount) tokens · \(formattedDuration(durationMs))"
  }

  var detailSummary: String {
    "\(visibleSummary) · \(tokensPerSecond.formatted(.number.precision(.fractionLength(1)))) tokens/s"
  }

  var accessibilitySummary: String {
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

extension RenderedChatTurnItem {
  var messageBubbleBackground: Color {
    isDisplayedAsUser ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.12)
  }

  fileprivate var accessibilityIdentifier: String {
    switch item {
    case .assistantMessage:
      "chat.assistantMessage"
    case .userMessage:
      "chat.userMessage"
    case .toolCall:
      "chat.toolCallMessage"
    case .toolResult:
      "chat.toolResultMessage"
    }
  }

  var isDisplayedAsUser: Bool {
    if case .userMessage = item {
      return true
    }
    return false
  }

  var displayTitle: String {
    switch item {
    case .userMessage:
      "You"
    case .assistantMessage, .toolCall, .toolResult:
      "Local Coder"
    }
  }

  var displaySystemImage: String {
    switch item {
    case .userMessage:
      "person.crop.circle"
    case .assistantMessage:
      "cpu"
    case .toolCall:
      "wrench.and.screwdriver"
    case .toolResult:
      "checkmark.circle"
    }
  }

  var shouldShowAssistantPlaceholder: Bool {
    assistantMessage?.shouldShowAssistantPlaceholder ?? false
  }

  var assistantPlaceholderTitle: String {
    assistantMessage?.assistantPlaceholderTitle ?? "Generating"
  }

  var assistantPlaceholderSystemImage: String {
    assistantMessage?.assistantPlaceholderSystemImage ?? "sparkles"
  }

  var generationMetrics: ChatGenerationMetrics? {
    assistantMessage?.generationMetrics
  }

  var attachments: [ChatAttachment] {
    guard case .userMessage(let message) = item else {
      return []
    }
    return message.attachments
  }

  var canCopyAssistantContent: Bool {
    assistantMessage?.canCopyAssistantContent ?? false
  }

  var content: String {
    switch item {
    case .userMessage(let message):
      message.content
    case .assistantMessage(let message):
      message.content
    case .toolCall, .toolResult:
      ""
    }
  }

  private var assistantMessage: AssistantTurnMessage? {
    guard case .assistantMessage(let message) = item else {
      return nil
    }
    return message
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
