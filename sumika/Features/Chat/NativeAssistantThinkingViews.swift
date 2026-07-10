import AppKit
import SumikaCore

// Assistant reasoning ("thinking") transcript views: the fixed-height
// reasoning ticker and the collapsible thinking panel, plus the small status
// indicator factory they share. Split out of AppKitChatTranscriptRepresentable.

// A fixed-height window onto the tail of the live reasoning text: the text
// view is pinned to the bottom and grows upward past the clipped top edge, so
// new lines push old ones out of view like a feed. The fixed intrinsic height
// keeps the transcript row from ever resizing while the model thinks.
final class NativeReasoningTickerView: NSView {
  private static let visibleLineCount: CGFloat = 3

  private let textView = NativeStreamingTextView()
  private let fadeMask = CAGradientLayer()
  private let fixedHeight: CGFloat

  init(font: NSFont) {
    let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
    fixedHeight = ceil(lineHeight * Self.visibleLineCount)
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true

    // Fades the oldest visible line out toward the top edge; the mask also
    // clips the text that has scrolled past the window. Layer origin is
    // bottom-left, so the fade-to-clear sits at the visual top.
    fadeMask.colors = [
      NSColor.black.cgColor,
      NSColor.black.cgColor,
      NSColor.clear.cgColor,
    ]
    fadeMask.locations = [0, NSNumber(value: 1 - (1 / Self.visibleLineCount)), 1]
    layer?.mask = fadeMask

    textView.isSelectable = false
    addSubview(textView)
    NSLayoutConstraint.activate([
      textView.leadingAnchor.constraint(equalTo: leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: trailingAnchor),
      textView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: fixedHeight)
  }

  // The ticker is an ambient preview, not an interaction target: clicks fall
  // through to the row so they cannot grab focus or start a text selection.
  override func hitTest(_: NSPoint) -> NSView? {
    nil
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fadeMask.frame = bounds
    CATransaction.commit()
  }

  func setAttributedText(_ attributedString: NSAttributedString) {
    textView.setAttributedText(attributedString)
  }

  func appendAttributedText(_ attributedString: NSAttributedString) {
    textView.appendAttributedText(attributedString)
  }

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  var textForTesting: String {
    textView.string
  }
}

final class NativeAssistantThinkingView: NSView {
  private let stack = NSStackView()
  private let header = NSStackView()
  private let statusHost = NSView()
  private let titleLabel = NSTextField(wrappingLabelWithString: "Reasoning")
  private let disclosureButton = NativeActionButton(title: "")
  private let toggleThinkingExpansion: (String) -> Void
  private var statusView: NSView?
  private var tickerView: NativeReasoningTickerView?
  private var contentTextView: NativeStreamingTextView?
  private var currentRowID: String
  private var currentContent = ""
  private var currentTickerContent = ""
  private var currentStatus: AssistantThinkingMessage.DeliveryStatus?

  init(
    message: AssistantThinkingMessage,
    rowID: String,
    state: NativeTranscriptCellState,
    toggleThinkingExpansion: @escaping (String) -> Void
  ) {
    self.currentRowID = rowID
    self.toggleThinkingExpansion = toggleThinkingExpansion
    super.init(frame: .zero)
    setupLayout()
    update(message: message, rowID: rowID, state: state)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(
    message: AssistantThinkingMessage,
    rowID: String,
    state: NativeTranscriptCellState
  ) {
    currentRowID = rowID
    let isExpanded = state.isThinkingExpanded
    updateStatus(message.deliveryStatus)
    titleLabel.stringValue = Self.reasoningTitle(for: message)
    updateDisclosureButton(isExpanded: isExpanded)
    updateTicker(for: message, isExpanded: isExpanded)
    updateContent(message.content, isExpanded: isExpanded)
  }

  private func setupLayout() {
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.distribution = .gravityAreas
    stack.spacing = 5
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    header.orientation = .horizontal
    header.alignment = .centerY
    header.distribution = .fill
    header.spacing = 7
    stack.addArrangedSubview(header)

    statusHost.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      statusHost.widthAnchor.constraint(equalToConstant: 13),
      statusHost.heightAnchor.constraint(equalToConstant: 13),
    ])
    header.addArrangedSubview(statusHost)

    titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    titleLabel.textColor = .tertiaryLabelColor
    titleLabel.maximumNumberOfLines = 1
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    header.addArrangedSubview(titleLabel)

    disclosureButton.translatesAutoresizingMaskIntoConstraints = false
    disclosureButton.bezelStyle = .inline
    disclosureButton.isBordered = false
    disclosureButton.controlSize = .small
    disclosureButton.setButtonType(.momentaryPushIn)
    disclosureButton.imagePosition = .imageOnly
    disclosureButton.contentTintColor = .tertiaryLabelColor
    disclosureButton.actionHandler = { [weak self] in
      guard let self else {
        return
      }
      toggleThinkingExpansion(currentRowID)
    }
    NSLayoutConstraint.activate([
      disclosureButton.widthAnchor.constraint(equalToConstant: 18),
      disclosureButton.heightAnchor.constraint(equalToConstant: 18),
    ])
    header.addArrangedSubview(disclosureButton)
  }

  private func updateStatus(_ status: AssistantThinkingMessage.DeliveryStatus) {
    guard currentStatus != status else {
      return
    }
    currentStatus = status
    statusView?.removeFromSuperview()

    let view = nativeThinkingStatusIndicator(status: status)
    statusView = view
    statusHost.addSubview(view)
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      view.centerXAnchor.constraint(equalTo: statusHost.centerXAnchor),
      view.centerYAnchor.constraint(equalTo: statusHost.centerYAnchor),
    ])
  }

  private func updateDisclosureButton(isExpanded: Bool) {
    let accessibilityLabel = isExpanded ? "Hide reasoning" : "Show reasoning"
    disclosureButton.image = NSImage(
      systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
      accessibilityDescription: nil
    )
    disclosureButton.image?.isTemplate = true
    disclosureButton.contentTintColor = .tertiaryLabelColor
    disclosureButton.toolTip = accessibilityLabel
    disclosureButton.setAccessibilityLabel(accessibilityLabel)
  }

  // While streaming collapsed, the row shows a fixed three-line window onto
  // the live reasoning tail instead of the growing full text: the row height
  // stays constant, so the transcript neither grows nor scrolls while the
  // model thinks.
  private func updateTicker(for message: AssistantThinkingMessage, isExpanded: Bool) {
    guard message.deliveryStatus == .streaming, !isExpanded, !message.content.isEmpty else {
      removeTickerView()
      return
    }

    let window = Self.tickerWindow(for: message.content)
    let ticker = ensureTickerView()
    if window.hasPrefix(currentTickerContent) {
      let suffix = String(window.dropFirst(currentTickerContent.count))
      if !suffix.isEmpty {
        ticker.appendAttributedText(
          Self.thinkingAttributedString(for: suffix, usesPlaceholderForEmpty: false)
        )
      }
    } else {
      ticker.setAttributedText(Self.thinkingAttributedString(for: window))
    }
    currentTickerContent = window
  }

  private func ensureTickerView() -> NativeReasoningTickerView {
    if let tickerView {
      return tickerView
    }
    let ticker = NativeReasoningTickerView(font: .systemFont(ofSize: NSFont.systemFontSize))
    tickerView = ticker
    stack.insertArrangedSubview(ticker, at: 1)
    ticker.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    return ticker
  }

  private func removeTickerView() {
    currentTickerContent = ""
    guard let tickerView else {
      return
    }
    stack.removeArrangedSubview(tickerView)
    tickerView.removeFromSuperview()
    self.tickerView = nil
  }

  // Only the trailing lines are visible, so the ticker feeds a bounded tail
  // window instead of the whole reasoning text. The window is cut at a
  // paragraph boundary: reflowing a partially cut first paragraph would shift
  // the wrapping of the visible lines between flushes.
  static func tickerWindow(for content: String) -> String {
    let window = content.suffix(2400)
    guard window.count == 2400, let newlineIndex = window.firstIndex(of: "\n") else {
      return String(window)
    }
    return String(window[window.index(after: newlineIndex)...])
  }

  static func reasoningTitle(for message: AssistantThinkingMessage) -> String {
    guard message.deliveryStatus == .complete, let duration = message.reasoningDuration else {
      return "Reasoning"
    }
    return "Reasoned for \(formattedReasoningDuration(duration))"
  }

  private static func formattedReasoningDuration(_ duration: TimeInterval) -> String {
    let totalSeconds = max(1, Int(duration.rounded()))
    guard totalSeconds >= 60 else {
      return "\(totalSeconds)s"
    }
    return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
  }

  private func updateContent(_ content: String, isExpanded: Bool) {
    guard isExpanded, !content.isEmpty else {
      removeContentTextView()
      return
    }

    let textView = ensureContentTextView()
    if content.hasPrefix(currentContent) {
      let suffix = String(content.dropFirst(currentContent.count))
      if !suffix.isEmpty {
        textView.appendAttributedText(
          Self.thinkingAttributedString(for: suffix, usesPlaceholderForEmpty: false)
        )
      }
    } else {
      textView.setAttributedText(Self.thinkingAttributedString(for: content))
    }

    currentContent = content
    invalidateIntrinsicContentSize()
    needsLayout = true
  }

  private func ensureContentTextView() -> NativeStreamingTextView {
    if let contentTextView {
      return contentTextView
    }

    let textView = NativeStreamingTextView()
    contentTextView = textView
    stack.addArrangedSubview(textView)
    textView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    return textView
  }

  private func removeContentTextView() {
    guard let contentTextView else {
      currentContent = ""
      return
    }
    stack.removeArrangedSubview(contentTextView)
    contentTextView.removeFromSuperview()
    self.contentTextView = nil
    currentContent = ""
    invalidateIntrinsicContentSize()
  }

  private static func thinkingAttributedString(
    for text: String,
    usesPlaceholderForEmpty: Bool = true
  ) -> NSAttributedString {
    let source = text.isEmpty && usesPlaceholderForEmpty ? " " : text
    let attributedString = NSMutableAttributedString(
      string: source,
      attributes: [
        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        .foregroundColor: NSColor.secondaryLabelColor,
      ]
    )
    NativeTranscriptMarkdownRenderer.applyLinks(to: attributedString, sourceText: source)
    return attributedString
  }

}

private func nativeThinkingStatusIndicator(
  status: AssistantThinkingMessage.DeliveryStatus
) -> NSView {
  if status == .streaming {
    let spinner = NSProgressIndicator()
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.startAnimation(nil)
    NSLayoutConstraint.activate([
      spinner.widthAnchor.constraint(equalToConstant: 13),
      spinner.heightAnchor.constraint(equalToConstant: 13),
    ])
    spinner.setAccessibilityElement(false)
    return spinner
  }

  let imageView = NSImageView()
  imageView.translatesAutoresizingMaskIntoConstraints = false
  imageView.image = NSImage(systemSymbolName: "brain", accessibilityDescription: nil)
  imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
  imageView.contentTintColor = .tertiaryLabelColor
  imageView.setAccessibilityElement(false)
  NSLayoutConstraint.activate([
    imageView.widthAnchor.constraint(equalToConstant: 13),
    imageView.heightAnchor.constraint(equalToConstant: 13),
  ])
  return imageView
}
