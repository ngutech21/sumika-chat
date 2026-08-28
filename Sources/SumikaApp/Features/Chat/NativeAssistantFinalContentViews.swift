import AppKit
import SumikaCore

final class NativeAssistantFinalContentView: NSView {
  typealias AttachmentViewBuilder = ([ChatAttachment], String, Bool) -> NSView
  typealias ActionsProvider = () -> NativeTranscriptCellActions?

  private let stack = NativeReusableRowViewStyle.verticalStack(spacing: 8)
  private let attachmentHost = NativeReusableRowViewStyle.verticalStack(spacing: 0)
  private let blockStack = NativeReusableRowViewStyle.verticalStack(spacing: 8)
  private let actionsProvider: ActionsProvider
  private let makeAttachmentView: AttachmentViewBuilder
  private var entries: [Entry] = []
  private var entryWidthConstraints: [NSLayoutConstraint] = []
  private var attachments: [ChatAttachment] = []
  private var attachmentRowID: String?
  private var attachmentAssetsRevision: Int?
  private var actions: NativeTranscriptCellActions?

  init(
    actionsProvider: @escaping ActionsProvider,
    makeAttachmentView: @escaping AttachmentViewBuilder
  ) {
    self.actionsProvider = actionsProvider
    self.makeAttachmentView = makeAttachmentView
    super.init(frame: .zero)

    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    attachmentHost.isHidden = true
    stack.addArrangedSubview(attachmentHost)
    blockStack.isHidden = true
    stack.addArrangedSubview(blockStack)
    NSLayoutConstraint.activate([
      attachmentHost.widthAnchor.constraint(equalTo: stack.widthAnchor),
      blockStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(
    item: RenderedChatTurnItem,
    rowID: String,
    assetsRevision: Int
  ) {
    guard let actions = actionsProvider() else {
      return
    }
    self.actions = actions
    updateAttachments(
      item.nativeAttachments,
      rowID: rowID,
      assetsRevision: assetsRevision
    )

    var displayBlocks: [DisplayBlock] = []
    if item.assistantRenderBlocks.isEmpty {
      if !item.content.isEmpty {
        displayBlocks.append(
          .markdown(.text(NativeTranscriptMarkdownRenderer.linkifiedPlainText(item.content)))
        )
      }
    } else {
      for block in item.assistantRenderBlocks {
        switch block {
        case .paragraph(let paragraph):
          displayBlocks.append(
            contentsOf: actions.markdownBlocks(paragraph.text).map(DisplayBlock.markdown)
          )
        case .codeBlock(let codeBlock):
          actions.requestCodeHighlight(rowID, codeBlock)
          let highlightedCode = actions.highlightedCode(rowID, codeBlock)
          displayBlocks.append(
            .code(
              codeBlock,
              attributedCode(for: codeBlock, highlightedCode: highlightedCode),
              hasHighlight: highlightedCode != nil
            )
          )
        }
      }
    }

    reconcile(displayBlocks)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    actions = nil
  }

  private func updateAttachments(
    _ newAttachments: [ChatAttachment],
    rowID: String,
    assetsRevision: Int
  ) {
    guard
      attachments != newAttachments
        || attachmentRowID != rowID
        || attachmentAssetsRevision != assetsRevision
    else {
      return
    }
    attachments = newAttachments
    attachmentRowID = rowID
    attachmentAssetsRevision = assetsRevision
    NativeReusableRowViewStyle.removeAllArrangedSubviews(from: attachmentHost)
    if !newAttachments.isEmpty {
      attachmentHost.addArrangedSubview(makeAttachmentView(newAttachments, rowID, false))
    }
    attachmentHost.isHidden = newAttachments.isEmpty
  }

  private func reconcile(_ blocks: [DisplayBlock]) {
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
        entryWidthConstraints.remove(at: index).isActive = false
        let entry = entries.remove(at: index)
        blockStack.removeArrangedSubview(entry.view)
        entry.view.removeFromSuperview()
      }
    } else if blocks.count > entries.count {
      for block in blocks.dropFirst(entries.count) {
        appendEntry(makeEntry(for: block))
      }
    }

    blockStack.isHidden = entries.isEmpty
  }

  private func replaceEntry(at index: Int, with entry: Entry) {
    let oldEntry = entries[index]
    entryWidthConstraints.remove(at: index).isActive = false
    blockStack.removeArrangedSubview(oldEntry.view)
    oldEntry.view.removeFromSuperview()
    entries[index] = entry
    blockStack.insertArrangedSubview(entry.view, at: index)
    let widthConstraint = entry.view.widthAnchor.constraint(equalTo: blockStack.widthAnchor)
    widthConstraint.isActive = true
    entryWidthConstraints.insert(widthConstraint, at: index)
  }

  private func appendEntry(_ entry: Entry) {
    entries.append(entry)
    blockStack.addArrangedSubview(entry.view)
    let widthConstraint = entry.view.widthAnchor.constraint(equalTo: blockStack.widthAnchor)
    widthConstraint.isActive = true
    entryWidthConstraints.append(widthConstraint)
  }

  private func makeEntry(for block: DisplayBlock) -> Entry {
    switch block {
    case .markdown(.text(let attributedString)):
      let textView = NativeTranscriptTextView { [weak self] url in
        self?.actions?.openLink(url)
      }
      textView.setAttributedText(attributedString)
      return .text(textView)
    case .markdown(.table(let table)):
      let tableView = NativeTranscriptTableView(
        table: table,
        openLink: { [weak self] url in
          self?.actions?.openLink(url)
        }
      )
      return .table(tableView)
    case .code(let codeBlock, let attributedCode, let hasHighlight):
      let codeLabel = NativeReusableRowViewStyle.textLabel("")
      codeLabel.attributedStringValue = attributedCode
      codeLabel.font = .monospacedSystemFont(
        ofSize: NativeTranscriptMarkdownRenderer.bodyFontSize,
        weight: .regular
      )
      let codeView = NativeCodeBlockView(
        codeBlock: codeBlock,
        codeLabel: codeLabel,
        hasHighlightedCode: hasHighlight
      )
      let container = NativeReusableRowViewStyle.paddedContainer(
        codeLabel,
        fillColor: NSColor.secondaryLabelColor.withAlphaComponent(0.08),
        cornerRadius: 8
      )
      container.layer?.borderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor
      container.layer?.borderWidth = 1
      codeView.addArrangedSubview(container)
      return .code(codeView)
    }
  }

  private func attributedCode(
    for codeBlock: AssistantRenderBlock.CodeBlock,
    highlightedCode: HighlightedCode?
  ) -> NSAttributedString {
    highlightedCode.map(NativeTranscriptCodeRenderer.attributedString)
      ?? NativeTranscriptCodeRenderer.plainAttributedString(
        code: codeBlock.text.isEmpty ? " " : codeBlock.text,
        language: CodeLanguage(fenceLanguage: codeBlock.language)
      )
  }

  private enum DisplayBlock {
    case markdown(NativeMarkdownBlock)
    case code(
      AssistantRenderBlock.CodeBlock,
      NSAttributedString,
      hasHighlight: Bool
    )
  }

  private enum Entry {
    case text(NativeTranscriptTextView)
    case table(NativeTranscriptTableView)
    case code(NativeCodeBlockView)

    var view: NSView {
      switch self {
      case .text(let view):
        view
      case .table(let view):
        view
      case .code(let view):
        view
      }
    }

    func update(with block: DisplayBlock) -> Bool {
      switch (self, block) {
      case (.text(let view), .markdown(.text(let attributedString))):
        view.setAttributedText(attributedString)
        return true
      case (.table(let view), .markdown(.table(let table))):
        view.update(table: table)
        return true
      case (
        .code(let view),
        .code(let codeBlock, let attributedCode, let hasHighlight)
      ):
        view.update(
          codeBlock: codeBlock,
          attributedCode: attributedCode,
          hasHighlightedCode: hasHighlight
        )
        return true
      default:
        return false
      }
    }
  }
}

final class NativeAssistantFooterView: NSStackView {
  typealias ActionsProvider = () -> NativeTranscriptCellActions?

  private let speechButton = NativeReusableRowViewStyle.iconButton()
  private let copyButton = NativeReusableRowViewStyle.iconButton()
  private let metricsLabel = NativeReusableRowViewStyle.secondaryLabel("")
  private let totalDurationLabel = NativeReusableRowViewStyle.secondaryLabel("")
  private let actionsProvider: ActionsProvider

  init(actionsProvider: @escaping ActionsProvider) {
    self.actionsProvider = actionsProvider
    super.init(frame: .zero)
    orientation = .horizontal
    alignment = .centerY
    distribution = .gravityAreas
    spacing = 8
    addArrangedSubview(speechButton)
    addArrangedSubview(copyButton)
    addArrangedSubview(metricsLabel)
    addArrangedSubview(totalDurationLabel)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @discardableResult
  func update(
    item: RenderedChatTurnItem,
    rowID: String,
    state: NativeTranscriptCellState
  ) -> Bool {
    guard let actions = actionsProvider() else {
      isHidden = true
      return false
    }
    if state.isSpeechEnabled, let spokenText = item.nativeSpokenText {
      speechButton.isHidden = false
      speechButton.configureIcon(
        systemSymbolName: state.isSpeaking ? "stop.fill" : "play.fill",
        accessibilityLabel: state.isSpeaking ? "Stop reading message" : "Read message aloud",
        tintColor: .secondaryLabelColor
      )
      speechButton.actionHandler = {
        actions.toggleSpeech(rowID, spokenText)
      }
    } else {
      speechButton.isHidden = true
      speechButton.actionHandler = nil
    }

    if item.canNativeCopyMessageContent {
      copyButton.isHidden = false
      copyButton.configureIcon(
        systemSymbolName: state.isCopied ? "checkmark" : "doc.on.doc",
        accessibilityLabel: state.isCopied ? "Copied" : "Copy message",
        tintColor: .secondaryLabelColor
      )
      copyButton.actionHandler = {
        actions.copy(rowID, item.content)
      }
    } else {
      copyButton.isHidden = true
      copyButton.actionHandler = nil
    }

    if let metrics = item.visibleGenerationMetrics {
      metricsLabel.stringValue = metrics.visibleSummary
      metricsLabel.isHidden = false
    } else {
      metricsLabel.stringValue = ""
      metricsLabel.isHidden = true
    }

    if let totalDurationSummary = item.visibleTotalDurationSummary {
      totalDurationLabel.stringValue = totalDurationSummary
      totalDurationLabel.isHidden = false
    } else {
      totalDurationLabel.stringValue = ""
      totalDurationLabel.isHidden = true
    }

    let hasContent =
      !speechButton.isHidden
      || !copyButton.isHidden
      || !metricsLabel.isHidden
      || !totalDurationLabel.isHidden
    isHidden = !hasContent
    return hasContent
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    speechButton.actionHandler = nil
    copyButton.actionHandler = nil
  }
}
