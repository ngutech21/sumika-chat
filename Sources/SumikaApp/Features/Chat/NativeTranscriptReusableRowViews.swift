import AppKit
import SumikaCore

// Persistent content views used by recycled transcript cells. Each view owns a
// stable AppKit hierarchy and rebinds row data in place as the table reuses its
// small visible-cell pool.

final class NativeTranscriptMarkdownBlocksView: NSStackView {
  private var entries: [Entry] = []
  private let openLink: (URL) -> Void

  init(openLink: @escaping (URL) -> Void) {
    self.openLink = openLink
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    distribution = .gravityAreas
    spacing = 8
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(blocks: [NativeMarkdownBlock]) {
    let sharedCount = min(entries.count, blocks.count)
    if sharedCount > 0 {
      for index in 0..<sharedCount {
        guard !entries[index].update(with: blocks[index]) else {
          continue
        }
        replaceEntry(at: index, with: makeEntry(for: blocks[index]))
      }
    }

    if entries.count > blocks.count {
      for index in stride(from: entries.count - 1, through: blocks.count, by: -1) {
        let entry = entries.remove(at: index)
        removeArrangedSubview(entry.view)
        entry.view.removeFromSuperview()
      }
    } else if blocks.count > entries.count {
      for block in blocks.dropFirst(entries.count) {
        let entry = makeEntry(for: block)
        entries.append(entry)
        addArrangedSubview(entry.view)
      }
    }

    isHidden = entries.isEmpty
  }

  private func replaceEntry(at index: Int, with entry: Entry) {
    let oldEntry = entries[index]
    removeArrangedSubview(oldEntry.view)
    oldEntry.view.removeFromSuperview()
    entries[index] = entry
    insertArrangedSubview(entry.view, at: index)
  }

  private func makeEntry(for block: NativeMarkdownBlock) -> Entry {
    switch block {
    case .text(let attributedString):
      let textView = NativeTranscriptTextView(openLink: openLink)
      textView.setAttributedText(attributedString)
      return .text(textView)
    case .table(let table):
      return .table(NativeTranscriptTableView(table: table, openLink: openLink))
    }
  }

  private enum Entry {
    case text(NativeTranscriptTextView)
    case table(NativeTranscriptTableView)

    var view: NSView {
      switch self {
      case .text(let view):
        view
      case .table(let view):
        view
      }
    }

    func update(with block: NativeMarkdownBlock) -> Bool {
      switch (self, block) {
      case (.text(let view), .text(let attributedString)):
        view.setAttributedText(attributedString)
        return true
      case (.table(let view), .table(let table)):
        view.update(table: table)
        return true
      default:
        return false
      }
    }
  }
}

final class NativeUserMessageView: NSView {
  typealias AttachmentViewBuilder = ([ChatAttachment], String, Bool) -> NSView

  private static let bubbleHorizontalInset: CGFloat = 10

  private let stack = NativeReusableRowViewStyle.verticalStack(spacing: 4)
  private let attachmentHost = NativeReusableRowViewStyle.verticalStack(spacing: 0)
  private let markdownView: NativeTranscriptMarkdownBlocksView
  private let bubble = NSView()
  private let copyButton = NativeReusableRowViewStyle.iconButton()
  private let makeAttachmentView: AttachmentViewBuilder
  private var attachments: [ChatAttachment] = []
  private var attachmentRowID: String?
  private var attachmentAssetsRevision: Int?
  private var bubblePreferredWidthConstraint: NSLayoutConstraint?

  init(
    openLink: @escaping (URL) -> Void,
    makeAttachmentView: @escaping AttachmentViewBuilder
  ) {
    markdownView = NativeTranscriptMarkdownBlocksView(openLink: openLink)
    self.makeAttachmentView = makeAttachmentView
    super.init(frame: .zero)

    stack.alignment = .trailing
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    attachmentHost.alignment = .trailing
    attachmentHost.isHidden = true
    stack.addArrangedSubview(attachmentHost)

    bubble.wantsLayer = true
    bubble.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.06).cgColor
    bubble.layer?.cornerRadius = 10
    bubble.addSubview(markdownView)
    markdownView.translatesAutoresizingMaskIntoConstraints = false
    let preferredBubbleWidth = bubble.widthAnchor.constraint(equalToConstant: 1)
    preferredBubbleWidth.priority = .defaultHigh
    bubblePreferredWidthConstraint = preferredBubbleWidth
    stack.addArrangedSubview(bubble)
    NSLayoutConstraint.activate([
      markdownView.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
      markdownView.leadingAnchor.constraint(
        equalTo: bubble.leadingAnchor,
        constant: Self.bubbleHorizontalInset
      ),
      markdownView.trailingAnchor.constraint(
        equalTo: bubble.trailingAnchor,
        constant: -Self.bubbleHorizontalInset
      ),
      markdownView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),
      bubble.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
      preferredBubbleWidth,
    ])

    stack.addArrangedSubview(copyButton)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(
    message: UserTurnMessage,
    rowID: String,
    assetsRevision: Int,
    isCopied: Bool,
    maximumBubbleWidth: CGFloat,
    actions: NativeTranscriptCellActions
  ) {
    if attachments != message.attachments
      || attachmentRowID != rowID
      || attachmentAssetsRevision != assetsRevision
    {
      attachments = message.attachments
      attachmentRowID = rowID
      attachmentAssetsRevision = assetsRevision
      NativeReusableRowViewStyle.removeAllArrangedSubviews(from: attachmentHost)
      if !message.attachments.isEmpty {
        attachmentHost.addArrangedSubview(
          makeAttachmentView(message.attachments, rowID, true)
        )
      }
      attachmentHost.isHidden = message.attachments.isEmpty
    }

    let hasContent = !message.content.isEmpty
    let blocks = hasContent ? actions.markdownBlocks(message.content) : []
    markdownView.update(blocks: blocks)
    bubblePreferredWidthConstraint?.constant = Self.preferredBubbleWidth(
      for: blocks,
      maximumWidth: maximumBubbleWidth
    )
    bubble.isHidden = !hasContent
    copyButton.isHidden = !hasContent
    if hasContent {
      copyButton.configureIcon(
        systemSymbolName: isCopied ? "checkmark" : "doc.on.doc",
        accessibilityLabel: isCopied ? "Copied" : "Copy message",
        tintColor: .secondaryLabelColor
      )
      copyButton.actionHandler = {
        actions.copy(rowID, message.content)
      }
    } else {
      copyButton.actionHandler = nil
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    copyButton.actionHandler = nil
  }

  private static func preferredBubbleWidth(
    for blocks: [NativeMarkdownBlock],
    maximumWidth: CGFloat
  ) -> CGFloat {
    let contentWidth = blocks.reduce(CGFloat.zero) { width, block in
      let blockWidth: CGFloat
      switch block {
      case .text(let attributedString):
        blockWidth = attributedString.size().width
      case .table(let table):
        blockWidth = NativeMarkdownTableMetrics.preferredWidth(for: table)
      }
      return max(width, blockWidth)
    }
    let paddedWidth = ceil(contentWidth) + bubbleHorizontalInset * 2
    return min(maximumWidth, paddedWidth)
  }
}

final class NativeGenerationIndicatorView: NSStackView {
  private let titleLabel = NativeReusableRowViewStyle.secondaryLabel("")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    orientation = .horizontal
    alignment = .centerY
    distribution = .gravityAreas
    spacing = 8

    let spinner = NSProgressIndicator()
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    spinner.startAnimation(nil)
    addArrangedSubview(spinner)
    addArrangedSubview(titleLabel)
  }

  convenience init(title: String) {
    self.init(frame: .zero)
    update(title: title)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(title: String) {
    titleLabel.stringValue = title
  }
}

final class NativeToolCallView: NSView {
  private let stack = NativeReusableRowViewStyle.verticalStack(spacing: 5)
  private let header = NativeTranscriptDisclosureHeaderView()
  private let statusHost = NSView()
  private let spinner = NSProgressIndicator()
  private let statusImage = NSImageView()
  private let nameLabel = NativeReusableRowViewStyle.textLabel("")
  private let summaryLabel = NativeReusableRowViewStyle.secondaryLabel("")
  private let disclosureButton = NativeReusableRowViewStyle.iconButton()
  private let dynamicHost = NativeReusableRowViewStyle.verticalStack(spacing: 5)
  private var actions: NativeTranscriptCellActions?
  private var currentRowID: String?
  private var currentHasDetails = false
  private var currentStatus: ToolCallStatus?
  private var askUserPopUpButton: NSPopUpButton?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setupLayout()
  }

  convenience init() {
    self.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(
    record: ToolCallRecord,
    generationMetrics: ChatGenerationMetrics?,
    batchPresentation: ToolApprovalBatchPresentation?,
    rowID: String,
    state: NativeTranscriptCellState,
    actions: NativeTranscriptCellActions
  ) {
    self.actions = actions
    currentRowID = rowID
    askUserPopUpButton = nil

    let toolCall = record.transcriptToolCall
    currentHasDetails = record.hasNativeToolDetails || generationMetrics != nil
    updateStatus(record.status)
    nameLabel.stringValue = toolCall.toolName.rawValue

    if let preview = toolCall.nativeHeaderPreview {
      summaryLabel.stringValue = preview.text
      summaryLabel.lineBreakMode = preview.lineBreakMode
      summaryLabel.setAccessibilityLabel(preview.accessibilityLabel)
      summaryLabel.isHidden = false
    } else {
      summaryLabel.stringValue = ""
      summaryLabel.isHidden = true
    }

    if currentHasDetails {
      disclosureButton.isHidden = false
      disclosureButton.actionHandler = { [weak self] in
        self?.toggleExpansion()
      }
      header.actionHandler = { [weak self] in
        self?.toggleExpansion()
      }
      disclosureButton.configureIcon(
        systemSymbolName: state.isToolExpanded ? "chevron.down" : "chevron.right",
        accessibilityLabel: state.isToolExpanded ? "Hide details" : "Show details",
        tintColor: .tertiaryLabelColor
      )
    } else {
      disclosureButton.isHidden = true
      disclosureButton.actionHandler = nil
      header.actionHandler = nil
    }

    rebuildDynamicContent(
      record: record,
      generationMetrics: generationMetrics,
      batchPresentation: batchPresentation,
      rowID: rowID,
      state: state,
      actions: actions
    )
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    if currentStatus?.nativeIsInProgress == true {
      spinner.stopAnimation(nil)
      currentStatus = nil
    }
    actions = nil
    currentRowID = nil
    currentHasDetails = false
    askUserPopUpButton = nil
    header.actionHandler = nil
    disclosureButton.actionHandler = nil
    NativeReusableRowViewStyle.removeAllArrangedSubviews(from: dynamicHost)
    dynamicHost.isHidden = true
  }

  private func setupLayout() {
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 5
    header.distribution = .fill
    stack.addArrangedSubview(header)
    header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

    statusHost.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      statusHost.widthAnchor.constraint(equalToConstant: 12),
      statusHost.heightAnchor.constraint(equalToConstant: 12),
    ])
    header.addArrangedSubview(statusHost)

    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    statusHost.addSubview(spinner)

    statusImage.translatesAutoresizingMaskIntoConstraints = false
    statusImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
    statusImage.setAccessibilityElement(false)
    statusHost.addSubview(statusImage)
    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: statusHost.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: statusHost.centerYAnchor),
      spinner.widthAnchor.constraint(equalToConstant: 12),
      spinner.heightAnchor.constraint(equalToConstant: 12),
      statusImage.topAnchor.constraint(equalTo: statusHost.topAnchor),
      statusImage.leadingAnchor.constraint(equalTo: statusHost.leadingAnchor),
      statusImage.trailingAnchor.constraint(equalTo: statusHost.trailingAnchor),
      statusImage.bottomAnchor.constraint(equalTo: statusHost.bottomAnchor),
    ])

    nameLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
    nameLabel.maximumNumberOfLines = 1
    nameLabel.lineBreakMode = .byClipping
    nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    header.addArrangedSubview(nameLabel)

    summaryLabel.maximumNumberOfLines = 1
    summaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    header.addArrangedSubview(summaryLabel)

    disclosureButton.actionHandler = { [weak self] in
      self?.toggleExpansion()
    }
    header.addArrangedSubview(disclosureButton)
    header.addArrangedSubview(NativeReusableRowViewStyle.spacer())

    dynamicHost.isHidden = true
    stack.addArrangedSubview(dynamicHost)
    dynamicHost.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
  }

  private func updateStatus(_ status: ToolCallStatus) {
    guard currentStatus != status else {
      return
    }
    currentStatus = status
    if status.nativeIsInProgress {
      statusImage.isHidden = true
      spinner.isHidden = false
      spinner.startAnimation(nil)
    } else {
      spinner.stopAnimation(nil)
      spinner.isHidden = true
      statusImage.isHidden = false
      statusImage.image = NativeTranscriptSymbolImages.image(
        named: status.nativeQuietSystemImage
      )
      statusImage.contentTintColor = status.nativeQuietColor
    }
  }

  private func rebuildDynamicContent(
    record: ToolCallRecord,
    generationMetrics: ChatGenerationMetrics?,
    batchPresentation: ToolApprovalBatchPresentation?,
    rowID: String,
    state: NativeTranscriptCellState,
    actions: NativeTranscriptCellActions
  ) {
    NativeReusableRowViewStyle.removeAllArrangedSubviews(from: dynamicHost)

    if state.isToolExpanded, currentHasDetails {
      dynamicHost.addArrangedSubview(makeDetails(record: record, metrics: generationMetrics))
    }

    if record.status == .awaitingApproval,
      batchPresentation?.showsApprovalActions != false
    {
      dynamicHost.addArrangedSubview(
        makeApprovalActions(
          record: record,
          batchPresentation: batchPresentation,
          state: state,
          actions: actions
        )
      )
    }

    if record.status == .awaitingUserAnswer, let input = record.nativeAskUserInput {
      dynamicHost.addArrangedSubview(
        makeAskUserView(
          input: input,
          selectedAnswer: state.askUserSelection,
          isEnabled: state.isToolActionEnabled,
          rowID: rowID,
          toolCallID: record.id,
          actions: actions
        )
      )
    }

    dynamicHost.isHidden = dynamicHost.arrangedSubviews.isEmpty
  }

  private func makeDetails(record: ToolCallRecord, metrics: ChatGenerationMetrics?) -> NSView {
    let detailStack = NativeReusableRowViewStyle.verticalStack(spacing: 5)
    let details = NativeToolDetailContent(record: record)
    for line in details.argumentLines + details.permissionLines {
      detailStack.addArrangedSubview(NativeReusableRowViewStyle.secondaryLabel(line))
    }
    if let outputText = details.outputText {
      if let title = details.outputTitle {
        detailStack.addArrangedSubview(NativeReusableRowViewStyle.secondaryLabel(title))
      }
      detailStack.addArrangedSubview(
        NativeReusableRowViewStyle.paddedContainer(
          NativeReusableRowViewStyle.codeLabel(outputText),
          fillColor: NSColor.secondaryLabelColor.withAlphaComponent(0.08),
          cornerRadius: 6
        )
      )
    }
    if !details.affectedPaths.isEmpty {
      detailStack.addArrangedSubview(
        NativeReusableRowViewStyle.secondaryLabel(
          "Affected: \(details.affectedPaths.joined(separator: ", "))"
        )
      )
    }
    if !details.flags.isEmpty {
      detailStack.addArrangedSubview(
        NativeReusableRowViewStyle.secondaryLabel(details.flags.joined(separator: " · "))
      )
    }
    if let metrics {
      detailStack.addArrangedSubview(
        NativeReusableRowViewStyle.secondaryLabel(metrics.visibleSummary)
      )
    }
    return detailStack
  }

  private func makeApprovalActions(
    record: ToolCallRecord,
    batchPresentation: ToolApprovalBatchPresentation?,
    state: NativeTranscriptCellState,
    actions: NativeTranscriptCellActions
  ) -> NSView {
    let row = NativeReusableRowViewStyle.horizontalStack(spacing: 8)
    let toolName = record.transcriptToolCall.toolName.rawValue
    if state.toolApprovalPolicy == .automatic {
      if batchPresentation?.showsResumeAutomation ?? true {
        let anchorID = batchPresentation?.anchorID ?? record.id
        row.addArrangedSubview(
          NativeReusableRowViewStyle.smallButton(
            title: "Resume automation",
            accessibilityIdentifier: "chat.tool.resumeAutomation.\(anchorID.uuidString)",
            accessibilityLabel: "Resume automatic tool approval",
            isEnabled: state.isToolActionEnabled
          ) {
            actions.resumeAutomation(anchorID)
          }
        )
      }
    } else {
      let approvalGroupCount = batchPresentation?.approvalGroupCount ?? 1
      if let batchPresentation, batchPresentation.showsApproveAll {
        let approveAllAccessibilityIdentifier =
          "chat.tool.approveAll.\(batchPresentation.anchorID.uuidString)"
        row.addArrangedSubview(
          NativeReusableRowViewStyle.smallButton(
            title: "Approve all (\(batchPresentation.pendingApprovalCount))",
            accessibilityIdentifier: approveAllAccessibilityIdentifier,
            accessibilityLabel: "Approve all \(batchPresentation.pendingApprovalCount) tool calls",
            isEnabled: state.isToolActionEnabled
          ) {
            actions.approveAll(batchPresentation.anchorID)
          }
        )
      }
      row.addArrangedSubview(
        NativeReusableRowViewStyle.smallButton(
          title: approvalGroupCount > 1 ? "Approve \(approvalGroupCount) edits" : "Approve",
          accessibilityIdentifier: "chat.tool.approve.\(record.id.uuidString)",
          accessibilityLabel: approvalGroupCount > 1
            ? "Approve \(approvalGroupCount) atomic edit_file calls"
            : "Approve \(toolName) tool call",
          isEnabled: state.isToolActionEnabled
        ) {
          actions.approve(record.id)
        }
      )
      row.addArrangedSubview(
        NativeReusableRowViewStyle.smallButton(
          title: approvalGroupCount > 1 ? "Deny \(approvalGroupCount) edits" : "Deny",
          accessibilityIdentifier: "chat.tool.deny.\(record.id.uuidString)",
          accessibilityLabel: approvalGroupCount > 1
            ? "Deny \(approvalGroupCount) atomic edit_file calls"
            : "Deny \(toolName) tool call",
          isEnabled: state.isToolActionEnabled
        ) {
          actions.deny(record.id)
        }
      )
    }
    row.addArrangedSubview(NativeReusableRowViewStyle.spacer())
    return row
  }

  private func makeAskUserView(
    input: AskUserInput,
    selectedAnswer: String?,
    isEnabled: Bool,
    rowID: String,
    toolCallID: ToolCallRecord.ID,
    actions: NativeTranscriptCellActions
  ) -> NSView {
    let askStack = NativeReusableRowViewStyle.verticalStack(spacing: 6)
    let questionView = NativeTranscriptTextView { url in
      actions.openLink(url)
    }
    questionView.setAttributedText(
      NativeTranscriptMarkdownRenderer.linkifiedPlainText(input.question)
    )
    askStack.addArrangedSubview(questionView)
    guard !input.options.isEmpty else {
      return askStack
    }

    let selectedOption =
      selectedAnswer.flatMap { input.options.contains($0) ? $0 : nil }
      ?? input.options[0]
    let row = NativeReusableRowViewStyle.horizontalStack(spacing: 7)
    let popup = NSPopUpButton()
    popup.addItems(withTitles: input.options)
    popup.selectItem(withTitle: selectedOption)
    popup.controlSize = .small
    popup.target = self
    popup.action = #selector(askUserSelectionChanged(_:))
    popup.identifier = NSUserInterfaceItemIdentifier(rowID)
    popup.isEnabled = isEnabled
    askUserPopUpButton = popup
    row.addArrangedSubview(popup)
    row.addArrangedSubview(
      NativeReusableRowViewStyle.smallButton(title: "Send", isEnabled: isEnabled) { [weak self] in
        let answer = self?.askUserPopUpButton?.selectedItem?.title ?? selectedOption
        actions.answerAskUser(rowID, toolCallID, answer)
      }
    )
    row.addArrangedSubview(NativeReusableRowViewStyle.spacer())
    askStack.addArrangedSubview(row)
    return askStack
  }

  private func toggleExpansion() {
    guard currentHasDetails, let currentRowID, let actions else {
      return
    }
    actions.toggleToolExpansion(currentRowID)
  }

  @objc private func askUserSelectionChanged(_ sender: NSPopUpButton) {
    guard let rowID = sender.identifier?.rawValue, let title = sender.selectedItem?.title else {
      return
    }
    actions?.updateAskUserSelection(rowID, title)
  }
}

enum NativeReusableRowViewStyle {
  static func verticalStack(spacing: CGFloat) -> NSStackView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.distribution = .gravityAreas
    stack.spacing = spacing
    return stack
  }

  static func horizontalStack(spacing: CGFloat) -> NSStackView {
    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.distribution = .gravityAreas
    stack.spacing = spacing
    return stack
  }

  static func textLabel(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.maximumNumberOfLines = 0
    label.lineBreakMode = .byWordWrapping
    label.isSelectable = true
    label.allowsEditingTextAttributes = true
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }

  static func secondaryLabel(_ text: String) -> NSTextField {
    let label = textLabel(text)
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    label.textColor = .secondaryLabelColor
    return label
  }

  static func codeLabel(_ text: String) -> NSTextField {
    let label = textLabel("")
    label.attributedStringValue = NativeTranscriptCodeRenderer.plainAttributedString(
      code: text,
      language: nil
    )
    label.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    return label
  }

  static func iconButton() -> NativeActionButton {
    let button = NativeActionButton(title: "")
    button.translatesAutoresizingMaskIntoConstraints = false
    button.imagePosition = .imageOnly
    button.bezelStyle = .inline
    button.isBordered = false
    button.controlSize = .small
    button.setButtonType(.momentaryPushIn)
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 18),
      button.heightAnchor.constraint(equalToConstant: 18),
    ])
    return button
  }

  static func smallButton(
    title: String,
    accessibilityIdentifier: String? = nil,
    accessibilityLabel: String? = nil,
    isEnabled: Bool = true,
    action: @escaping () -> Void
  ) -> NativeActionButton {
    let button = NativeActionButton(title: title)
    button.controlSize = .small
    button.bezelStyle = .rounded
    button.setButtonType(.momentaryPushIn)
    button.isEnabled = isEnabled
    if let accessibilityIdentifier {
      button.setAccessibilityIdentifier(accessibilityIdentifier)
    }
    if let accessibilityLabel {
      button.setAccessibilityLabel(accessibilityLabel)
    }
    button.actionHandler = action
    return button
  }

  static func paddedContainer(
    _ view: NSView,
    fillColor: NSColor,
    cornerRadius: CGFloat
  ) -> NSView {
    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor = fillColor.cgColor
    container.layer?.cornerRadius = cornerRadius
    container.addSubview(view)
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      view.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
      view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
      view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
      view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
    ])
    return container
  }

  static func spacer() -> NSView {
    let view = NSView()
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
  }

  static func removeAllArrangedSubviews(from stack: NSStackView) {
    for view in stack.arrangedSubviews {
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
  }
}
