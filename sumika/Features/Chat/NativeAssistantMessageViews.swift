import AppKit
import SumikaCore

// Assistant message + live-streaming transcript views: the finalized message
// view and the TextKit-backed streaming block/code/text views that keep
// per-flush cost O(delta). Split out of AppKitChatTranscriptRepresentable.

final class NativeAssistantMessageView: NSView {
  typealias PlaceholderBuilder = (String) -> NSView
  typealias ContentBuilder = (RenderedChatTurnItem, String, NativeTranscriptCellState) -> NSView?
  typealias StreamingBlocksBuilder = (String) -> NativeStreamingAssistantBlocksView

  private let stack = NSStackView()
  private let makePlaceholderView: PlaceholderBuilder
  private let makeFinalContentView: ContentBuilder
  private let makeFooterView: ContentBuilder
  private let makeStreamingBlocksView: StreamingBlocksBuilder
  private var contentView: NSView?
  private var footerView: NSView?
  private var streamingTextView: NativeStreamingTextView?
  private var streamingBlocksView: NativeStreamingAssistantBlocksView?
  private var currentStreamingContent = ""
  private var contentMode: ContentMode?

  init(
    item: RenderedChatTurnItem,
    rowID: String,
    state: NativeTranscriptCellState,
    assetsRevision: Int,
    makePlaceholderView: @escaping PlaceholderBuilder,
    makeFinalContentView: @escaping ContentBuilder,
    makeFooterView: @escaping ContentBuilder,
    makeStreamingBlocksView: @escaping StreamingBlocksBuilder
  ) {
    self.makePlaceholderView = makePlaceholderView
    self.makeFinalContentView = makeFinalContentView
    self.makeFooterView = makeFooterView
    self.makeStreamingBlocksView = makeStreamingBlocksView
    super.init(frame: .zero)
    setupStack()
    update(item: item, rowID: rowID, state: state, assetsRevision: assetsRevision)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(
    item: RenderedChatTurnItem,
    rowID: String,
    state: NativeTranscriptCellState,
    assetsRevision: Int
  ) {
    updateContent(item: item, rowID: rowID, state: state, assetsRevision: assetsRevision)
    if item.isStreamingAssistantMessage {
      replaceFooterView(nil)
    } else {
      replaceFooterView(makeFooterView(item, rowID, state))
    }
  }

  private func setupStack() {
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.distribution = .gravityAreas
    stack.spacing = 8
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  private func updateContent(
    item: RenderedChatTurnItem,
    rowID: String,
    state: NativeTranscriptCellState,
    assetsRevision: Int
  ) {
    if item.shouldShowAssistantPlaceholder {
      let mode = ContentMode.placeholder(item.assistantPlaceholderTitle)
      if contentMode != mode {
        replaceContentView(makePlaceholderView(item.assistantPlaceholderTitle))
        resetStreamingText()
        contentMode = mode
      }
      return
    }

    if item.isStreamingAssistantMessage {
      guard item.nativeAttachments.isEmpty else {
        let mode = ContentMode.streamingStructured(
          revision: item.renderRevision,
          assetsRevision: assetsRevision
        )
        if contentMode != mode {
          replaceContentView(makeFinalContentView(item, rowID, state))
          resetStreamingText()
          contentMode = mode
        }
        return
      }

      if item.assistantRenderBlocks.isEmpty {
        updatePlainStreamingText(item.content)
      } else {
        updateStreamingBlocks(item, rowID: rowID)
      }
      return
    }

    // Rebuild only when the content itself or an async asset (attachment
    // thumbnail) changed. Copy/speech state lives in the separately rebuilt
    // footer, and finished code highlights are applied in place via
    // NativeCodeBlockView, so neither needs a content rebuild anymore.
    let mode = ContentMode.final(
      revision: item.renderRevision,
      assetsRevision: assetsRevision
    )
    if contentMode != mode {
      replaceContentView(makeFinalContentView(item, rowID, state))
      resetStreamingText()
      contentMode = mode
    }
  }

  // Streams the message as structured blocks: everything before the last
  // markdown boundary is frozen into final block views, only the volatile
  // tail is re-rendered per flush. See NativeStreamingAssistantBlocksView.
  private func updateStreamingBlocks(_ item: RenderedChatTurnItem, rowID: String) {
    if contentMode != .streamingBlocks || streamingBlocksView == nil {
      let blocksView = makeStreamingBlocksView(rowID)
      resetStreamingText()
      streamingBlocksView = blocksView
      replaceContentView(blocksView)
      blocksView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
      contentMode = .streamingBlocks
    }

    streamingBlocksView?.update(item: item)
    invalidateIntrinsicContentSize()
    needsLayout = true
  }

  private func updatePlainStreamingText(_ content: String) {
    if contentMode != .streamingPlain || streamingTextView == nil {
      let textView = NativeStreamingTextView()
      streamingTextView = textView
      currentStreamingContent = ""
      replaceContentView(textView)
      textView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
      contentMode = .streamingPlain
    }

    guard let streamingTextView else {
      return
    }

    if content.hasPrefix(currentStreamingContent) {
      let suffix = String(content.dropFirst(currentStreamingContent.count))
      if !suffix.isEmpty {
        streamingTextView.appendAttributedText(
          Self.streamingAttributedString(for: suffix, usesPlaceholderForEmpty: false)
        )
      }
    } else {
      streamingTextView.setAttributedText(Self.streamingAttributedString(for: content))
    }

    currentStreamingContent = content
    invalidateIntrinsicContentSize()
    needsLayout = true
  }

  private func replaceContentView(_ view: NSView?) {
    if let contentView {
      stack.removeArrangedSubview(contentView)
      contentView.removeFromSuperview()
    }
    contentView = view
    guard let view else {
      invalidateIntrinsicContentSize()
      return
    }

    let index =
      footerView.flatMap { footer in stack.arrangedSubviews.firstIndex { $0 === footer } }
      ?? stack.arrangedSubviews.count
    stack.insertArrangedSubview(view, at: index)
    invalidateIntrinsicContentSize()
  }

  private func replaceFooterView(_ view: NSView?) {
    if let footerView {
      stack.removeArrangedSubview(footerView)
      footerView.removeFromSuperview()
    }
    footerView = view
    guard let view else {
      invalidateIntrinsicContentSize()
      return
    }

    stack.addArrangedSubview(view)
    invalidateIntrinsicContentSize()
  }

  private func resetStreamingText() {
    streamingTextView = nil
    streamingBlocksView = nil
    currentStreamingContent = ""
  }

  private static func streamingAttributedString(
    for text: String,
    usesPlaceholderForEmpty: Bool = true
  ) -> NSAttributedString {
    let source = text.isEmpty && usesPlaceholderForEmpty ? " " : text
    let attributedString = NSMutableAttributedString(
      string: source,
      attributes: [
        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        .foregroundColor: NSColor.labelColor,
      ]
    )
    NativeTranscriptMarkdownRenderer.applyLinks(to: attributedString, sourceText: source)
    return attributedString
  }

  private enum ContentMode: Equatable {
    case placeholder(String)
    case streamingPlain
    case streamingBlocks
    case streamingStructured(revision: Int, assetsRevision: Int)
    case final(revision: Int, assetsRevision: Int)
  }
}

// Renders a streaming assistant message as structured blocks while it is
// still growing. Content arrives append-only, so every markdown boundary that
// has passed (fence lines, blank lines) is final: those segments are built
// exactly once through the same builders as the final message and never
// touched again. Only the volatile tail after the last boundary is
// re-rendered per flush, so per-flush cost stays proportional to the tail.
final class NativeStreamingAssistantBlocksView: NSStackView {
  typealias MarkdownBlocksProvider = (String) -> [NativeMarkdownBlock]
  typealias MarkdownBlockViewBuilder = (NativeMarkdownBlock) -> NSView
  typealias FinalCodeBlockViewBuilder = (AssistantRenderBlock.CodeBlock) -> NSView

  private let markdownBlocks: MarkdownBlocksProvider
  private let makeMarkdownBlockView: MarkdownBlockViewBuilder
  private let makeFinalCodeBlockView: FinalCodeBlockViewBuilder

  private var trackedContent = ""
  private var finalizedCoreBlockCount = 0
  private var finalizedParagraphUTF16Length = 0
  private var finalizedViewCount = 0

  // The tail region always sits after the finalized views: a sub-stack for
  // the live markdown tail and/or a streaming code view for an open fence.
  private let markdownTailStack = NSStackView()
  private var markdownTailLabel: NSTextField?
  private var codeTailView: NativeStreamingCodeBlockView?

  init(
    markdownBlocks: @escaping MarkdownBlocksProvider,
    makeMarkdownBlockView: @escaping MarkdownBlockViewBuilder,
    makeFinalCodeBlockView: @escaping FinalCodeBlockViewBuilder
  ) {
    self.markdownBlocks = markdownBlocks
    self.makeMarkdownBlockView = makeMarkdownBlockView
    self.makeFinalCodeBlockView = makeFinalCodeBlockView
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    distribution = .gravityAreas
    spacing = 8

    markdownTailStack.orientation = .vertical
    markdownTailStack.alignment = .leading
    markdownTailStack.distribution = .gravityAreas
    markdownTailStack.spacing = 8
    // Hidden while empty so the stack spacing does not leave a phantom gap;
    // NSStackView detaches hidden arranged subviews from layout.
    markdownTailStack.isHidden = true
    addArrangedSubview(markdownTailStack)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(item: RenderedChatTurnItem) {
    if !item.content.hasPrefix(trackedContent) {
      resetAllSegments()
    }
    trackedContent = item.content

    let blocks = item.assistantRenderBlocks
    guard !blocks.isEmpty else {
      resetAllSegments()
      trackedContent = item.content
      return
    }

    let lastIndex = blocks.count - 1
    while finalizedCoreBlockCount < lastIndex {
      finalizeBlock(blocks[finalizedCoreBlockCount])
      finalizedCoreBlockCount += 1
    }

    guard finalizedCoreBlockCount == lastIndex else {
      return
    }

    switch blocks[lastIndex] {
    case .paragraph(let paragraph):
      clearCodeTail()
      updateMarkdownTail(paragraph.text)
    case .codeBlock(let codeBlock) where !codeBlock.isClosed:
      clearMarkdownTail()
      updateCodeTail(codeBlock)
    case .codeBlock(let codeBlock):
      finalizeBlock(.codeBlock(codeBlock))
      finalizedCoreBlockCount += 1
      clearMarkdownTail()
      clearCodeTail()
    }
  }

  private func finalizeBlock(_ block: AssistantRenderBlock) {
    switch block {
    case .paragraph(let paragraph):
      let remainder = utf16Suffix(of: paragraph.text, from: finalizedParagraphUTF16Length)
      finalizedParagraphUTF16Length = 0
      clearMarkdownTail()
      appendFinalizedMarkdown(String(remainder))
    case .codeBlock(let codeBlock):
      clearCodeTail()
      insertFinalizedView(makeFinalCodeBlockView(codeBlock))
    }
  }

  private func updateMarkdownTail(_ paragraphText: String) {
    var remainder = utf16Suffix(of: paragraphText, from: finalizedParagraphUTF16Length)

    if let boundary = remainder.range(of: "\n\n", options: .backwards) {
      let completed = String(remainder[..<boundary.lowerBound])
      finalizedParagraphUTF16Length = boundary.upperBound.utf16Offset(in: paragraphText)
      clearMarkdownTail()
      appendFinalizedMarkdown(completed)
      remainder = utf16Suffix(of: paragraphText, from: finalizedParagraphUTF16Length)
    }

    guard !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      clearMarkdownTail()
      return
    }

    let tailBlocks = markdownBlocks(String(remainder))
    if tailBlocks.count == 1,
      case .text(let attributedString) = tailBlocks[0],
      let markdownTailLabel
    {
      markdownTailLabel.attributedStringValue = attributedString
      return
    }

    clearMarkdownTail()
    markdownTailStack.isHidden = tailBlocks.isEmpty
    for block in tailBlocks {
      let view = makeMarkdownBlockView(block)
      markdownTailStack.addArrangedSubview(view)
      if tailBlocks.count == 1, let label = view as? NSTextField {
        markdownTailLabel = label
      }
    }
  }

  private func updateCodeTail(_ codeBlock: AssistantRenderBlock.CodeBlock) {
    let tailView: NativeStreamingCodeBlockView
    if let codeTailView {
      tailView = codeTailView
    } else {
      tailView = NativeStreamingCodeBlockView()
      codeTailView = tailView
      addArrangedSubview(tailView)
      tailView.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
    tailView.update(codeBlock: codeBlock)
  }

  private func appendFinalizedMarkdown(_ text: String) {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return
    }
    for block in markdownBlocks(text) {
      insertFinalizedView(makeMarkdownBlockView(block))
    }
  }

  private func insertFinalizedView(_ view: NSView) {
    insertArrangedSubview(view, at: finalizedViewCount)
    finalizedViewCount += 1
  }

  private func clearMarkdownTail() {
    markdownTailLabel = nil
    markdownTailStack.isHidden = true
    for view in markdownTailStack.arrangedSubviews {
      markdownTailStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
  }

  private func clearCodeTail() {
    guard let codeTailView else {
      return
    }
    removeArrangedSubview(codeTailView)
    codeTailView.removeFromSuperview()
    self.codeTailView = nil
  }

  private func resetAllSegments() {
    clearMarkdownTail()
    clearCodeTail()
    for view in arrangedSubviews where view !== markdownTailStack {
      removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    trackedContent = ""
    finalizedCoreBlockCount = 0
    finalizedParagraphUTF16Length = 0
    finalizedViewCount = 0
  }

  private func utf16Suffix(of text: String, from offset: Int) -> Substring {
    guard offset > 0 else {
      return text[...]
    }
    guard offset <= text.utf16.count else {
      return text[text.endIndex...]
    }
    return text[String.Index(utf16Offset: offset, in: text)...]
  }
}

// The live view for a still-open fenced code block: same chrome as the final
// NativeCodeBlockView (which replaces it once the fence closes), but the code
// streams into a TextKit-backed text view so appends stay O(delta).
final class NativeStreamingCodeBlockView: NSStackView {
  private let languageLabel: NSTextField
  private let textView = NativeStreamingTextView()
  private var codeText = ""
  private var language: String?

  init() {
    languageLabel = NSTextField(wrappingLabelWithString: "")
    languageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    languageLabel.textColor = .secondaryLabelColor
    languageLabel.maximumNumberOfLines = 1
    languageLabel.isHidden = true
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    distribution = .gravityAreas
    spacing = 4

    addArrangedSubview(languageLabel)

    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor =
      NSColor.secondaryLabelColor.withAlphaComponent(0.08).cgColor
    container.layer?.cornerRadius = 8
    container.layer?.borderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor
    container.layer?.borderWidth = 1
    container.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(textView)
    NSLayoutConstraint.activate([
      textView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
      textView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
      textView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
      textView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
    ])
    addArrangedSubview(container)
    container.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(codeBlock: AssistantRenderBlock.CodeBlock) {
    if codeBlock.language != language {
      language = codeBlock.language
      let name = codeBlock.language ?? ""
      languageLabel.stringValue = name
      languageLabel.isHidden = name.isEmpty
    }

    let text = codeBlock.text
    if !codeText.isEmpty, text.hasPrefix(codeText) {
      let suffix = String(text.dropFirst(codeText.count))
      if !suffix.isEmpty {
        textView.appendAttributedText(Self.codeAttributedString(for: suffix))
      }
    } else {
      textView.setAttributedText(Self.codeAttributedString(for: text.isEmpty ? " " : text))
    }
    codeText = text
  }

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  var codeTextForTesting: String {
    textView.string
  }

  private static func codeAttributedString(for text: String) -> NSAttributedString {
    NSAttributedString(
      string: text,
      attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        .foregroundColor: NSColor.labelColor,
      ]
    )
  }
}

final class NativeCodeBlockView: NSStackView {
  let codeBlock: AssistantRenderBlock.CodeBlock
  private let codeLabel: NSTextField
  private var hasHighlightedCode: Bool

  init(
    codeBlock: AssistantRenderBlock.CodeBlock,
    codeLabel: NSTextField,
    hasHighlightedCode: Bool
  ) {
    self.codeBlock = codeBlock
    self.codeLabel = codeLabel
    self.hasHighlightedCode = hasHighlightedCode
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    distribution = .gravityAreas
    spacing = 4
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // Metric-neutral by construction: the highlighted string is the same code in
  // the same monospaced font, spans only recolor. No relayout or height
  // invalidation is needed, so a finished highlight never rebuilds the row.
  func applyHighlightedCodeIfNeeded(_ highlightedCode: HighlightedCode?) {
    guard !hasHighlightedCode, let highlightedCode else {
      return
    }
    codeLabel.attributedStringValue = NativeTranscriptCodeRenderer.attributedString(
      for: highlightedCode
    )
    hasHighlightedCode = true
  }
}

// Non-scrolling, self-sizing text view for live streaming text. Unlike an
// NSTextField label, TextKit keeps its layout between updates: appending a
// suffix relayouts only the affected tail lines instead of re-measuring the
// whole text, keeping per-flush cost O(delta) while a long message streams.
final class NativeStreamingTextView: NSTextView {
  // The manually assembled TextKit 1 stack only retains downwards
  // (storage -> layout manager -> container); the view must keep the storage
  // alive itself.
  private let streamingStorage: NSTextStorage

  init() {
    let storage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(
      containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    )
    container.widthTracksTextView = true
    container.lineFragmentPadding = 0
    storage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(container)
    streamingStorage = storage
    super.init(frame: .zero, textContainer: container)
    translatesAutoresizingMaskIntoConstraints = false
    isEditable = false
    isSelectable = true
    drawsBackground = false
    textContainerInset = .zero
    isVerticallyResizable = false
    isHorizontallyResizable = false
    minSize = .zero
    maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
    setContentHuggingPriority(.defaultHigh, for: .vertical)
    // Read-only transcript text: expose it to VoiceOver like the NSTextField
    // labels it replaced, not as an editable "text entry area".
    setAccessibilityRole(.staticText)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // The width is pinned to the full content column because NSTextView has no
  // intrinsic width. Without these overrides a short streamed line would turn
  // the whole column into an I-beam/selection strip whose clicks also steal
  // first-responder focus from the composer; confine interaction to the text.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let superview, let layoutManager, let textContainer else {
      return super.hitTest(point)
    }
    let localPoint = convert(point, from: superview)
    let usedRect = layoutManager.usedRect(for: textContainer)
    guard localPoint.x <= usedRect.maxX + textContainerOrigin.x else {
      return nil
    }
    return super.hitTest(point)
  }

  override func resetCursorRects() {
    guard let layoutManager, let textContainer else {
      super.resetCursorRects()
      return
    }
    let usedRect = layoutManager.usedRect(for: textContainer)
    let textRect = NSRect(
      x: 0,
      y: 0,
      width: usedRect.maxX + textContainerOrigin.x,
      height: bounds.height
    )
    addCursorRect(textRect.intersection(bounds), cursor: .iBeam)
  }

  override var intrinsicContentSize: NSSize {
    guard let layoutManager, let textContainer else {
      return super.intrinsicContentSize
    }
    layoutManager.ensureLayout(for: textContainer)
    let usedRect = layoutManager.usedRect(for: textContainer)
    return NSSize(width: NSView.noIntrinsicMetric, height: ceil(usedRect.height))
  }

  // The intrinsic height depends on the wrapping width, which only exists
  // after a layout pass has assigned the frame.
  override func setFrameSize(_ newSize: NSSize) {
    let widthChanged = abs(frame.width - newSize.width) >= 0.5
    super.setFrameSize(newSize)
    if widthChanged {
      invalidateIntrinsicContentSize()
    }
  }

  func setAttributedText(_ attributedString: NSAttributedString) {
    streamingStorage.setAttributedString(attributedString)
    invalidateIntrinsicContentSize()
  }

  func appendAttributedText(_ attributedString: NSAttributedString) {
    streamingStorage.append(attributedString)
    invalidateIntrinsicContentSize()
  }
}
