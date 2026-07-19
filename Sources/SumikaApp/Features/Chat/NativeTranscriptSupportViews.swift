import AppKit
import SumikaCore

// Leaf AppKit views shared across the transcript cell, its subviews, and the
// coordinator: the markdown table renderer, the two bespoke buttons, and the
// attachment image popover. They hold no transcript state and were previously
// file-private inside AppKitChatTranscriptRepresentable; they are module-internal
// now so their call sites in the other transcript files keep reaching them.

final class NativeTranscriptTableView: NSView {
  private let table: NativeMarkdownTable
  private let rows: [[NativeMarkdownTableCell]]
  private let labels: [[NSTextField]]

  override var isFlipped: Bool {
    true
  }

  init(table: NativeMarkdownTable) {
    self.table = table
    self.rows = NativeMarkdownTableMetrics.normalizedRows(for: table)
    self.labels = rows.map { row in
      row.map { cell in
        let label = NSTextField(labelWithAttributedString: cell.attributedString)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.isSelectable = true
        label.allowsEditingTextAttributes = true
        label.drawsBackground = false
        label.isBordered = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
      }
    }
    super.init(frame: .zero)

    wantsLayer = false
    setContentHuggingPriority(.defaultLow, for: .horizontal)
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    setContentHuggingPriority(.required, for: .vertical)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Markdown table")

    for row in labels {
      for label in row {
        addSubview(label)
      }
    }
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    let width = measuredWidth
    return NSSize(
      width: NativeMarkdownTableMetrics.preferredWidth(for: table),
      height: NativeMarkdownTableMetrics.height(for: table, width: width)
    )
  }

  override func setFrameSize(_ newSize: NSSize) {
    let oldWidth = frame.width
    super.setFrameSize(newSize)
    guard abs(oldWidth - newSize.width) >= 1 else {
      return
    }
    invalidateIntrinsicContentSize()
    needsDisplay = true
  }

  override func layout() {
    ChatDiagnostics.measure("Transcript markdown table layout", category: .transcript) {
      super.layout()
      guard !rows.isEmpty else {
        return
      }
      let columnWidth = NativeMarkdownTableMetrics.columnWidth(for: table, width: measuredWidth)
      var rowOriginY = NativeMarkdownTableMetrics.borderWidth
      for (rowIndex, row) in rows.enumerated() {
        let rowHeight = NativeMarkdownTableMetrics.rowHeight(for: row, columnWidth: columnWidth)
        var columnOriginX = NativeMarkdownTableMetrics.borderWidth
        for columnIndex in row.indices {
          let label = labels[rowIndex][columnIndex]
          label.frame = NSRect(
            x: columnOriginX + NativeMarkdownTableMetrics.horizontalPadding,
            y: rowOriginY + NativeMarkdownTableMetrics.verticalPadding,
            width: max(columnWidth - NativeMarkdownTableMetrics.horizontalPadding * 2, 12),
            height: max(rowHeight - NativeMarkdownTableMetrics.verticalPadding * 2, 12)
          )
          columnOriginX += columnWidth + NativeMarkdownTableMetrics.separatorWidth
        }
        rowOriginY += rowHeight + NativeMarkdownTableMetrics.separatorWidth
      }
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    ChatDiagnostics.measure("Transcript markdown table draw", category: .transcript) {
      super.draw(dirtyRect)
      guard !rows.isEmpty else {
        return
      }

      let boundsPath = NSBezierPath(
        roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
        xRadius: NativeMarkdownTableMetrics.cornerRadius,
        yRadius: NativeMarkdownTableMetrics.cornerRadius
      )
      NSColor.secondaryLabelColor.withAlphaComponent(0.045).setFill()
      boundsPath.fill()
      NSColor.secondaryLabelColor.withAlphaComponent(0.14).setStroke()
      boundsPath.lineWidth = NativeMarkdownTableMetrics.borderWidth
      boundsPath.stroke()

      let columnWidth = NativeMarkdownTableMetrics.columnWidth(for: table, width: measuredWidth)
      let rowHeights = rows.map { row in
        NativeMarkdownTableMetrics.rowHeight(for: row, columnWidth: columnWidth)
      }

      if !table.header.isEmpty, let headerHeight = rowHeights.first {
        let headerRect = NSRect(
          x: NativeMarkdownTableMetrics.borderWidth,
          y: NativeMarkdownTableMetrics.borderWidth,
          width: bounds.width - NativeMarkdownTableMetrics.borderWidth * 2,
          height: headerHeight
        )
        NSColor.secondaryLabelColor.withAlphaComponent(0.075).setFill()
        headerRect.fill()
      }

      NSColor.secondaryLabelColor.withAlphaComponent(0.10).setStroke()
      let separatorPath = NSBezierPath()
      var rowSeparatorY = NativeMarkdownTableMetrics.borderWidth
      for rowHeight in rowHeights.dropLast() {
        rowSeparatorY += rowHeight + NativeMarkdownTableMetrics.separatorWidth / 2
        separatorPath.move(
          to: NSPoint(x: NativeMarkdownTableMetrics.borderWidth, y: rowSeparatorY))
        separatorPath.line(
          to: NSPoint(x: bounds.width - NativeMarkdownTableMetrics.borderWidth, y: rowSeparatorY)
        )
        rowSeparatorY += NativeMarkdownTableMetrics.separatorWidth / 2
      }

      var columnSeparatorX = NativeMarkdownTableMetrics.borderWidth + columnWidth
      for _ in 1..<max(table.columnCount, 1) {
        separatorPath.move(
          to: NSPoint(x: columnSeparatorX, y: NativeMarkdownTableMetrics.borderWidth))
        separatorPath.line(
          to: NSPoint(
            x: columnSeparatorX,
            y: bounds.height - NativeMarkdownTableMetrics.borderWidth)
        )
        columnSeparatorX += columnWidth + NativeMarkdownTableMetrics.separatorWidth
      }
      separatorPath.lineWidth = NativeMarkdownTableMetrics.separatorWidth
      separatorPath.stroke()
    }
  }

  private var measuredWidth: CGFloat {
    let width =
      bounds.width > 0
      ? bounds.width
      : NativeMarkdownTableMetrics.preferredWidth(
        for: table)
    return max(width, 220)
  }
}

final class NativeActionButton: NSButton {
  var actionHandler: (() -> Void)?

  init(title: String) {
    super.init(frame: .zero)
    self.title = title
    target = self
    action = #selector(performAction)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc private func performAction() {
    actionHandler?()
  }
}

final class NativeAttachmentPreviewButton: NSButton {
  var actionHandler: ((NSView) -> Void)?

  init() {
    super.init(frame: .zero)
    title = ""
    isBordered = false
    isTransparent = true
    bezelStyle = .inline
    imagePosition = .noImage
    setButtonType(.momentaryPushIn)
    focusRingType = .none
    target = self
    action = #selector(performAttachmentAction)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    bounds.contains(point) ? self : nil
  }

  override func accessibilityPerformPress() -> Bool {
    actionHandler?(self)
    return true
  }

  @objc private func performAttachmentAction() {
    actionHandler?(self)
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }
}

final class NativeAttachmentImagePreviewController: NSViewController {
  private let imageURL: URL?
  private let displayName: String

  init(imageURL: URL?, displayName: String) {
    self.imageURL = imageURL
    self.displayName = displayName
    super.init(nibName: nil, bundle: nil)
    preferredContentSize = NSSize(width: 640, height: 480)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    stack.translatesAutoresizingMaskIntoConstraints = false

    let root = NSView()
    root.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: root.topAnchor),
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])

    if let image = imageURL.flatMap(NSImage.init(contentsOf:)) {
      stack.addArrangedSubview(makeImageView(image))
    } else {
      stack.addArrangedSubview(makeUnavailableView())
    }

    let nameLabel = NSTextField(labelWithString: displayName)
    nameLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    nameLabel.textColor = .secondaryLabelColor
    nameLabel.lineBreakMode = .byTruncatingMiddle
    nameLabel.maximumNumberOfLines = 1
    stack.addArrangedSubview(nameLabel)

    self.view = root
  }

  private func makeImageView(_ image: NSImage) -> NSImageView {
    let imageView = NSImageView()
    imageView.image = image
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.translatesAutoresizingMaskIntoConstraints = false

    let fittedSize = fittedImageSize(for: image.size)
    NSLayoutConstraint.activate([
      imageView.widthAnchor.constraint(equalToConstant: fittedSize.width),
      imageView.heightAnchor.constraint(equalToConstant: fittedSize.height),
    ])
    preferredContentSize = NSSize(width: fittedSize.width + 24, height: fittedSize.height + 54)
    return imageView
  }

  private func makeUnavailableView() -> NSView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 8

    let imageView = NSImageView()
    imageView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
    imageView.image?.isTemplate = true
    imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
    imageView.contentTintColor = .secondaryLabelColor
    stack.addArrangedSubview(imageView)

    let label = NSTextField(labelWithString: "Image Unavailable")
    label.textColor = .secondaryLabelColor
    stack.addArrangedSubview(label)

    NSLayoutConstraint.activate([
      stack.widthAnchor.constraint(equalToConstant: 360),
      stack.heightAnchor.constraint(equalToConstant: 240),
    ])
    preferredContentSize = NSSize(width: 384, height: 294)
    return stack
  }

  private func fittedImageSize(for imageSize: NSSize) -> NSSize {
    let maximumSize = NSSize(width: 900, height: 700)
    guard imageSize.width > 0, imageSize.height > 0 else {
      return NSSize(width: 360, height: 240)
    }
    let scale = min(maximumSize.width / imageSize.width, maximumSize.height / imageSize.height, 1)
    return NSSize(
      width: max(1, imageSize.width * scale),
      height: max(1, imageSize.height * scale)
    )
  }
}
