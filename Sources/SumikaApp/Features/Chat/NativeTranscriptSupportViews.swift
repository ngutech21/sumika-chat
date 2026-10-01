import AppKit
import SumikaCore

// Leaf AppKit views shared across the transcript cell, its subviews, and the
// coordinator: the markdown table renderer and the two bespoke buttons.
// They hold no transcript state and were previously
// file-private inside AppKitChatTranscriptRepresentable; they are module-internal
// now so their call sites in the other transcript files keep reaching them.

final class NativeTranscriptTableView: NSView {
  private var table: NativeMarkdownTable
  private var rows: [[NativeMarkdownTableCell]]
  private var labels: [[NativeTranscriptTextView]] = []
  private let openLink: (URL) -> Void
  private let openSkillPreview: ((SkillPreviewRequest) -> Void)?

  override var isFlipped: Bool {
    true
  }

  init(
    table: NativeMarkdownTable,
    openLink: @escaping (URL) -> Void,
    openSkillPreview: ((SkillPreviewRequest) -> Void)? = nil
  ) {
    self.table = table
    self.rows = NativeMarkdownTableMetrics.normalizedRows(for: table)
    self.openLink = openLink
    self.openSkillPreview = openSkillPreview
    super.init(frame: .zero)

    wantsLayer = false
    setContentHuggingPriority(.defaultLow, for: .horizontal)
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    setContentHuggingPriority(.required, for: .vertical)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Markdown table")

    rebuildLabels()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(table: NativeMarkdownTable) {
    self.table = table
    rows = NativeMarkdownTableMetrics.normalizedRows(for: table)

    let hasReusableShape =
      labels.count == rows.count
      && zip(labels, rows).allSatisfy { labels, row in labels.count == row.count }
    if hasReusableShape {
      for (rowIndex, row) in rows.enumerated() {
        for (columnIndex, cell) in row.enumerated() {
          labels[rowIndex][columnIndex].setAttributedText(cell.attributedString)
        }
      }
    } else {
      rebuildLabels()
    }

    invalidateIntrinsicContentSize()
    needsLayout = true
    needsDisplay = true
  }

  private func rebuildLabels() {
    for row in labels {
      for label in row {
        label.removeFromSuperview()
      }
    }
    labels = rows.map { row in
      row.map { cell in
        let textView = NativeTranscriptTextView(
          openLink: openLink,
          openSkillPreview: openSkillPreview
        )
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.setAttributedText(cell.attributedString)
        addSubview(textView)
        return textView
      }
    }
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

@MainActor
enum NativeTranscriptSymbolImages {
  private static var imagesByName: [String: NSImage] = [:]

  static func image(named systemSymbolName: String) -> NSImage? {
    if let cachedImage = imagesByName[systemSymbolName] {
      return cachedImage
    }
    let image = NSImage(
      systemSymbolName: systemSymbolName,
      accessibilityDescription: nil
    )
    image?.isTemplate = true
    if let image {
      imagesByName[systemSymbolName] = image
    }
    return image
  }
}

final class NativeActionButton: NSButton {
  var actionHandler: (() -> Void)?
  private var configuredSystemSymbolName: String?
  private var configuredAccessibilityLabel: String?
  private var configuredTintColor: NSColor?

  // These borderless icon controls have fixed 16/18-point constraints. AppKit's
  // default implementation resolves symbol metrics every time tooltip tracking
  // asks for their alignment rect, even though it ultimately returns the frame.
  override var alignmentRectInsets: NSEdgeInsets {
    NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
  }

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

  func configureIcon(
    systemSymbolName: String,
    accessibilityLabel: String,
    tintColor: NSColor
  ) {
    if configuredSystemSymbolName != systemSymbolName {
      image = NativeTranscriptSymbolImages.image(named: systemSymbolName)
      configuredSystemSymbolName = systemSymbolName
    }

    if configuredTintColor?.isEqual(tintColor) != true {
      contentTintColor = tintColor
      configuredTintColor = tintColor
    }

    if configuredAccessibilityLabel != accessibilityLabel {
      toolTip = accessibilityLabel
      setAccessibilityLabel(accessibilityLabel)
      configuredAccessibilityLabel = accessibilityLabel
    }
  }
}

final class NativeTranscriptDisclosureHeaderView: NSStackView {
  var actionHandler: (() -> Void)?

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard actionHandler != nil, bounds.contains(point) else {
      return super.hitTest(point)
    }
    if let hitView = super.hitTest(point), hitView.isInsideButton(until: self) {
      return hitView
    }
    return self
  }

  override func mouseUp(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard bounds.contains(point) else {
      return
    }
    performDisclosureAction()
  }

  func performDisclosureAction() {
    actionHandler?()
  }
}

extension NSView {
  fileprivate func isInsideButton(until ancestor: NSView) -> Bool {
    var view: NSView? = self
    while let currentView = view, currentView !== ancestor {
      if currentView is NSButton {
        return true
      }
      view = currentView.superview
    }
    return false
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
    frame.contains(point) ? self : nil
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
