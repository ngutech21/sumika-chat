import AppKit
import SumikaCore
import SwiftUI

struct ChatTranscript: View {
  let turns: [ChatTurn]
  let selectedModel: ManagedModel
  let modelState: ModelLoadState
  let isGenerating: Bool
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
      ChatTranscriptScrollContent(
        items: items,
        showsGenerationIndicator: shouldShowTranscriptGenerationIndicator(for: items),
        accessibilityValue: modelState.accessibilityValue,
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

  private func shouldShowTranscriptGenerationIndicator(for items: [RenderedChatTurnItem]) -> Bool {
    isGenerating && !items.contains(where: \.shouldShowAssistantPlaceholder)
  }
}

private struct ChatTranscriptScrollContent: View {
  let items: [RenderedChatTurnItem]
  let showsGenerationIndicator: Bool
  let accessibilityValue: String
  let onApproveToolCall: (ToolCallRecord.ID) -> Void
  let onDenyToolCall: (ToolCallRecord.ID) -> Void
  let onAnswerAskUser: (ToolCallRecord.ID, String) -> Void

  var body: some View {
    ScrollViewReader { scrollProxy in
      ScrollView(.vertical, showsIndicators: true) {
        LazyVStack(spacing: 0) {
          ForEach(items) { item in
            ChatBubble(
              item: item,
              onApproveToolCall: onApproveToolCall,
              onDenyToolCall: onDenyToolCall,
              onAnswerAskUser: onAnswerAskUser
            )
            .padding(.vertical, 6)
            .id(item.id)
          }

          if showsGenerationIndicator {
            TranscriptGenerationIndicator()
              .padding(.vertical, 6)
              .id(generationIndicatorID)
          }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .top)
      }
      .accessibilityIdentifier("chat.transcript")
      .accessibilityValue(accessibilityValue)
      .onAppear {
        scrollToBottom(with: scrollProxy)
      }
      .onChange(of: scrollAnchorID) { _, _ in
        scrollToBottom(with: scrollProxy)
      }
      .onChange(of: scrollTarget) { _, _ in
        scrollToBottom(with: scrollProxy)
      }
    }
  }

  private var scrollTarget: ChatTranscriptScrollTarget? {
    if showsGenerationIndicator {
      return ChatTranscriptScrollTarget(id: generationIndicatorID, revision: items.count)
    }
    guard let item = items.last else {
      return nil
    }
    return ChatTranscriptScrollTarget(id: item.id, revision: item.scrollRevision)
  }

  private var scrollAnchorID: String? {
    if showsGenerationIndicator {
      return generationIndicatorID
    }
    return items.last?.id
  }

  private func scrollToBottom(with scrollProxy: ScrollViewProxy) {
    guard let scrollAnchorID else {
      return
    }
    DispatchQueue.main.async {
      scrollProxy.scrollTo(scrollAnchorID, anchor: .bottom)
    }
  }

  private let generationIndicatorID = "chat.transcript.generationIndicator"
}

private struct ChatTranscriptScrollTarget: Equatable {
  let id: String
  let revision: Int
}

private struct ChatBubble: View {
  let item: RenderedChatTurnItem
  let onApproveToolCall: (ToolCallRecord.ID) -> Void
  let onDenyToolCall: (ToolCallRecord.ID) -> Void
  let onAnswerAskUser: (ToolCallRecord.ID, String) -> Void
  @State private var didCopy = false

  var body: some View {
    HStack(alignment: .top) {
      if item.isDisplayedAsUser {
        Spacer(minLength: 80)
      }

      VStack(alignment: item.isDisplayedAsUser ? .trailing : .leading, spacing: item.stackSpacing) {
        if item.shouldShowAssistantPlaceholder {
          AssistantPlaceholderView(item: item)
        } else {
          if item.isDisplayedAsUser && !item.attachments.isEmpty {
            SentAttachmentList(attachments: item.attachments)
          }

          VStack(alignment: item.isDisplayedAsUser ? .trailing : .leading, spacing: 8) {
            MessageContentText(
              item: item.item,
              toolCallRecord: item.toolCallRecord,
              generationMetrics: item.generationMetrics,
              assistantRenderBlocks: item.assistantRenderBlocks,
              onApproveToolCall: onApproveToolCall,
              onDenyToolCall: onDenyToolCall,
              onAnswerAskUser: onAnswerAskUser
            )
            .textSelection(.enabled)

            if item.visibleGenerationMetrics != nil || item.canCopyAssistantMessageContent {
              HStack(spacing: 8) {
                if item.canCopyAssistantMessageContent {
                  copyButton
                }
                if let metrics = item.visibleGenerationMetrics {
                  GenerationMetricsView(metrics: metrics)
                }
              }
            }
          }
          .padding(item.contentPadding)
          .background(item.messageBubbleBackground, in: item.messageBubbleShape)

          if item.canCopyUserMessageContent {
            HStack(spacing: 8) {
              copyButton
            }
          }
        }
      }
      .frame(
        maxWidth: item.maximumBubbleWidth,
        alignment: item.isDisplayedAsUser ? .trailing : .leading
      )

      if item.isDisplayedAsUser {
        Color.clear
          .frame(width: 24)
      } else {
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

  private var copyButton: some View {
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
    .accessibilityElement(children: .combine)
    .accessibilityLabel(item.assistantPlaceholderTitle)
    .accessibilityIdentifier("chat.generationSpinner")
  }
}

private struct TranscriptGenerationIndicator: View {
  var body: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 6) {
        Label("Sumika Chat", systemImage: "cpu")
          .font(.caption)
          .foregroundStyle(.secondary)

        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)

          Text("Generating")
        }
        .foregroundStyle(.secondary)
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
        AttachmentPreview(
          attachment: attachment,
          style: .sent
        )
      }
    }
  }
}

private struct MessageContentText: View {
  let item: ChatTurnItem
  let toolCallRecord: ToolCallRecord?
  let generationMetrics: ChatGenerationMetrics?
  let assistantRenderBlocks: [AssistantRenderBlock]
  let onApproveToolCall: (ToolCallRecord.ID) -> Void
  let onDenyToolCall: (ToolCallRecord.ID) -> Void
  let onAnswerAskUser: (ToolCallRecord.ID, String) -> Void

  @ViewBuilder
  var body: some View {
    switch item {
    case .tool:
      if let toolCallRecord {
        ToolExecutionSummaryView(
          toolCallRecord: toolCallRecord,
          generationMetrics: generationMetrics,
          onApprove: onApproveToolCall,
          onDeny: onDenyToolCall,
          onAnswerAskUser: onAnswerAskUser
        )
      }
    case .assistantMessage:
      AssistantMessageContent(blocks: assistantRenderBlocks)
    case .userMessage(let message):
      Text(URLTextLinkifier.attributedString(for: message.content))
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct LinkedText: NSViewRepresentable {
  let text: String
  let font: NSFont
  var textColor: NSColor = .labelColor
  var linkColor: NSColor = .linkColor

  func makeNSView(context: Context) -> LinkTextView {
    let textView = LinkTextView()
    textView.delegate = context.coordinator
    textView.drawsBackground = false
    textView.isEditable = false
    textView.isSelectable = true
    textView.isAutomaticLinkDetectionEnabled = false
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.heightTracksTextView = false
    textView.minSize = .zero
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    return textView
  }

  func updateNSView(_ textView: LinkTextView, context _: Context) {
    textView.textStorage?.setAttributedString(attributedString)
    textView.invalidateIntrinsicContentSize()
    textView.window?.invalidateCursorRects(for: textView)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  private var attributedString: NSAttributedString {
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [
        .font: font,
        .foregroundColor: textColor,
      ]
    )
    for link in URLTextLinkifier.links(in: text) {
      let range = NSRange(link.range, in: text)
      attributedString.addAttributes(
        [
          .link: link.url,
          .foregroundColor: linkColor,
          .underlineStyle: NSUnderlineStyle.single.rawValue,
        ],
        range: range
      )
    }
    return attributedString
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    func textView(
      _: NSTextView,
      clickedOnLink link: Any,
      at _: Int
    ) -> Bool {
      guard let url = link as? URL else {
        return false
      }
      NSWorkspace.shared.open(url)
      return true
    }
  }
}

final class LinkTextView: NSTextView {
  override var intrinsicContentSize: NSSize {
    guard let layoutManager, let textContainer else {
      return super.intrinsicContentSize
    }

    layoutManager.ensureLayout(for: textContainer)
    let usedRect = layoutManager.usedRect(for: textContainer)
    return NSSize(width: NSView.noIntrinsicMetric, height: ceil(usedRect.height))
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    textContainer?.containerSize = NSSize(
      width: newSize.width,
      height: CGFloat.greatestFiniteMagnitude
    )
    invalidateIntrinsicContentSize()
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    guard let textStorage, let layoutManager, let textContainer else {
      return
    }

    let fullRange = NSRange(location: 0, length: textStorage.length)
    textStorage.enumerateAttribute(.link, in: fullRange) { value, range, _ in
      guard value != nil else {
        return
      }

      let glyphRange = layoutManager.glyphRange(
        forCharacterRange: range,
        actualCharacterRange: nil
      )
      layoutManager.enumerateEnclosingRects(
        forGlyphRange: glyphRange,
        withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
        in: textContainer
      ) { rect, _ in
        self.addCursorRect(
          rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y),
          cursor: .pointingHand
        )
      }
    }
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
  var messageBubbleShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
  }

  var messageBubbleBackground: Color {
    // Only the user message keeps a bubble now; the assistant renders as plain,
    // quieter free text. The user bubble adopts the muted gray the assistant
    // bubble used to have (no more accent blue).
    showsBubble ? Color.secondary.opacity(0.12) : .clear
  }

  var showsBubble: Bool {
    isDisplayedAsUser
  }

  var stackSpacing: CGFloat {
    isToolItem ? 2 : 6
  }

  var contentPadding: CGFloat {
    showsBubble ? 10 : 0
  }

  var maximumBubbleWidth: CGFloat {
    isToolItem ? 460 : 680
  }

  fileprivate var accessibilityIdentifier: String {
    switch item {
    case .assistantMessage:
      "chat.assistantMessage"
    case .userMessage:
      "chat.userMessage"
    case .tool:
      "chat.toolCallMessage"
    }
  }

  var isDisplayedAsUser: Bool {
    if case .userMessage = item {
      return true
    }
    return false
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
    case .tool:
      false
    }
  }

  var canCopyUserMessageContent: Bool {
    isDisplayedAsUser && canCopyMessageContent
  }

  var canCopyAssistantMessageContent: Bool {
    !isDisplayedAsUser && canCopyMessageContent
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
    case .tool:
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
    case .tool:
      true
    case .assistantMessage, .userMessage:
      false
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
