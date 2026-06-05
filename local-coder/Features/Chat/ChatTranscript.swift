import AppKit
import LocalCoderCore
import MarkdownUI
import SwiftUI

struct ChatTranscript: View {
  let turns: [ChatTurn]
  let toolCalls: [ToolCallRecord]
  let selectedModel: ManagedModel
  let modelState: ModelLoadState
  let isGenerating: Bool
  let onApproveToolCall: (ToolCallRecord.ID) -> Void
  let onDenyToolCall: (ToolCallRecord.ID) -> Void

  var body: some View {
    ScrollViewReader { scrollProxy in
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

            if shouldShowTranscriptGenerationIndicator {
              TranscriptGenerationIndicator()
            }
          }

          Color.clear
            .frame(height: 1)
            .id(Self.bottomAnchorID)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityIdentifier("chat.transcript")
      .accessibilityValue(modelState.accessibilityValue)
      .onAppear {
        scrollToBottom(with: scrollProxy, animated: false)
      }
      .onChange(of: scrollSignature) {
        scrollToBottom(with: scrollProxy)
      }
      .onChange(of: isGenerating) {
        scrollToBottom(with: scrollProxy)
      }
    }
  }

  private static let bottomAnchorID = "chat.transcript.bottom"

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
      let turnGenerationMetrics = turn.items.compactMap(\.generationMetrics).last
      return turn.items.enumerated().compactMap { offset, item in
        switch item {
        case .userMessage(let message):
          return RenderedChatTurnItem(
            id: "\(turn.id.uuidString):\(offset):message:\(message.id.uuidString)",
            item: item,
            toolCallRecord: nil,
            generationMetrics: nil
          )
        case .assistantMessage(let message):
          return RenderedChatTurnItem(
            id: "\(turn.id.uuidString):\(offset):message:\(message.id.uuidString)",
            item: item,
            toolCallRecord: nil,
            generationMetrics: message.generationMetrics
          )
        case .toolCall(let id):
          guard let record = recordsByID[id] else {
            return nil
          }
          return RenderedChatTurnItem(
            id: "\(turn.id.uuidString):\(offset):toolCall:\(id.uuidString)",
            item: item,
            toolCallRecord: record,
            generationMetrics: turnGenerationMetrics
          )
        case .toolResult(let id):
          guard let record = recordsByID[id] else {
            return nil
          }
          return RenderedChatTurnItem(
            id: "\(turn.id.uuidString):\(offset):toolResult:\(id.uuidString)",
            item: item,
            toolCallRecord: record,
            generationMetrics: turnGenerationMetrics
          )
        }
      }
    }
  }

  private var shouldShowTranscriptGenerationIndicator: Bool {
    isGenerating && !transcriptItems.contains { $0.shouldShowAssistantPlaceholder }
  }

  private var scrollSignature: String {
    let turnSignature = turns.map { turn in
      let itemSignature = turn.items.map { item in
        switch item {
        case .userMessage(let message):
          return
            "user:\(message.id.uuidString):\(message.content.count):\(message.attachments.count)"
        case .assistantMessage(let message):
          return [
            "assistant",
            message.id.uuidString,
            "\(message.content.count)",
            message.deliveryStatus.rawValue,
            "\(message.generationMetrics?.generatedTokenCount ?? 0)",
          ].joined(separator: ":")
        case .toolCall(let id):
          return "toolCall:\(id.uuidString)"
        case .toolResult(let id):
          return "toolResult:\(id.uuidString)"
        }
      }
      .joined(separator: ",")
      return "\(turn.id.uuidString):\(turn.status.rawValue):\(itemSignature)"
    }
    .joined(separator: "|")

    let toolSignature = toolCalls.map { record in
      "\(record.id.uuidString):\(record.status.rawValue)"
    }
    .joined(separator: "|")

    return "\(turnSignature)#\(toolSignature)#generating:\(isGenerating)"
  }

  private func scrollToBottom(with scrollProxy: ScrollViewProxy, animated: Bool = true) {
    Task { @MainActor in
      if animated {
        withAnimation(.easeOut(duration: 0.18)) {
          scrollProxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
      } else {
        scrollProxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
      }
    }
  }
}

private struct RenderedChatTurnItem: Identifiable {
  let id: String
  let item: ChatTurnItem
  let toolCallRecord: ToolCallRecord?
  let generationMetrics: ChatGenerationMetrics?
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

      VStack(alignment: item.isDisplayedAsUser ? .trailing : .leading, spacing: item.stackSpacing) {
        if item.showsAuthorLabel {
          Label(item.displayTitle, systemImage: item.displaySystemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if item.shouldShowAssistantPlaceholder {
          AssistantPlaceholderView(item: item)
        } else {
          VStack(alignment: item.isDisplayedAsUser ? .trailing : .leading, spacing: 8) {
            MessageContentText(
              item: item.item,
              toolCallRecord: item.toolCallRecord,
              generationMetrics: item.generationMetrics,
              onApproveToolCall: onApproveToolCall,
              onDenyToolCall: onDenyToolCall
            )
            .textSelection(.enabled)

            if let metrics = item.visibleGenerationMetrics {
              GenerationMetricsView(metrics: metrics)
            }
          }
          .padding(item.contentPadding)
          .background(item.messageBubbleBackground)
          .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        if item.isDisplayedAsUser && !item.attachments.isEmpty {
          SentAttachmentList(attachments: item.attachments)
        }

        if item.canCopyMessageContent {
          HStack(spacing: 8) {
            Button {
              copyMessageToClipboard()
            } label: {
              Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(didCopy ? "Copied" : "Copy")
            .accessibilityLabel(item.copyAccessibilityLabel)
          }
        }
      }
      .frame(
        maxWidth: item.maximumBubbleWidth,
        alignment: item.isDisplayedAsUser ? .trailing : .leading
      )

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

private struct AssistantPlaceholderView: View {
  let item: RenderedChatTurnItem

  var body: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)

      Label(
        item.assistantPlaceholderTitle,
        systemImage: item.assistantPlaceholderSystemImage
      )
      .labelStyle(.titleAndIcon)
    }
    .foregroundStyle(.secondary)
    .padding(10)
    .background(Color.secondary.opacity(0.12))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(item.assistantPlaceholderTitle)
    .accessibilityIdentifier("chat.generationSpinner")
  }
}

private struct TranscriptGenerationIndicator: View {
  var body: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 6) {
        Label("Local Coder", systemImage: "cpu")
          .font(.caption)
          .foregroundStyle(.secondary)

        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)

          Text("Generating")
        }
        .foregroundStyle(.secondary)
        .padding(10)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Generating")
        .accessibilityIdentifier("chat.generationSpinner")
      }
      .frame(maxWidth: 680, alignment: .leading)

      Spacer(minLength: 80)
    }
    .frame(maxWidth: .infinity)
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
  let generationMetrics: ChatGenerationMetrics?
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
          generationMetrics: generationMetrics,
          onApprove: onApproveToolCall,
          onDeny: onDenyToolCall
        )
      }
    case .toolResult:
      if let toolCallRecord {
        ToolResultSummaryView(
          toolResult: ToolResultModelMessage(record: toolCallRecord),
          toolCallRecord: toolCallRecord,
          generationMetrics: generationMetrics
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

  var stackSpacing: CGFloat {
    isToolItem ? 2 : 6
  }

  var contentPadding: CGFloat {
    isToolItem ? 6 : 10
  }

  var maximumBubbleWidth: CGFloat {
    isToolItem ? 520 : 680
  }

  var showsAuthorLabel: Bool {
    !isToolItem
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

  var visibleGenerationMetrics: ChatGenerationMetrics? {
    isToolItem ? nil : generationMetrics
  }

  var attachments: [ChatAttachment] {
    guard case .userMessage(let message) = item else {
      return []
    }
    return message.attachments
  }

  var canCopyMessageContent: Bool {
    switch item {
    case .userMessage(let message):
      !message.content.isEmpty
    case .assistantMessage(let message):
      message.canCopyAssistantContent
    case .toolCall, .toolResult:
      false
    }
  }

  var copyAccessibilityLabel: String {
    isDisplayedAsUser ? "Copy user message" : "Copy assistant message"
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

  private var isToolItem: Bool {
    switch item {
    case .toolCall, .toolResult:
      true
    case .assistantMessage, .userMessage:
      false
    }
  }
}

extension ChatTurnItem {
  fileprivate var generationMetrics: ChatGenerationMetrics? {
    guard case .assistantMessage(let message) = self else {
      return nil
    }
    return message.generationMetrics
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
