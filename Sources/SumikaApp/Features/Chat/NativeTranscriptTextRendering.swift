import AppKit
import Foundation
import Markdown
import SumikaCore

struct NativeTranscriptMarkdownCache {
  private var blocksByText: [String: [NativeMarkdownBlock]] = [:]

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  var cachedEntryCount: Int {
    blocksByText.count
  }

  mutating func blocks(for markdown: String) -> [NativeMarkdownBlock] {
    if let cached = blocksByText[markdown] {
      return cached
    }
    let blocks = NativeTranscriptMarkdownRenderer.blocks(for: markdown)
    blocksByText[markdown] = blocks
    return blocks
  }

  mutating func prune(activeTexts: Set<String>) {
    blocksByText = blocksByText.filter { activeTexts.contains($0.key) }
  }
}

enum NativeMarkdownBlock {
  case text(NSAttributedString)
  case table(NativeMarkdownTable)
}

struct NativeMarkdownTable {
  var header: [NativeMarkdownTableCell]
  var rows: [[NativeMarkdownTableCell]]

  var columnCount: Int {
    max(header.count, rows.map(\.count).max() ?? 0)
  }

  var isEmpty: Bool {
    columnCount == 0
  }
}

struct NativeMarkdownTableCell {
  var attributedString: NSAttributedString
}

enum NativeTranscriptMarkdownRenderer {
  static func blocks(for markdown: String) -> [NativeMarkdownBlock] {
    renderMarkdown(markdown)
  }

  static func linkifiedPlainText(_ text: String) -> NSAttributedString {
    let attributedString = NSMutableAttributedString(
      string: text.isEmpty ? " " : text,
      attributes: [
        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        .foregroundColor: NSColor.labelColor,
      ]
    )
    applyLinks(to: attributedString, sourceText: attributedString.string)
    return attributedString
  }

  private static func renderMarkdown(_ markdown: String) -> [NativeMarkdownBlock] {
    let source = markdown.isEmpty ? " " : markdown
    let document = Document(parsing: source)
    let renderer = NativeTranscriptMarkdownASTRenderer()
    return renderer.renderBlocks(document)
  }

  static func applyLinks(to attributedString: NSMutableAttributedString, sourceText: String) {
    for link in URLTextLinkifier.links(in: sourceText) {
      attributedString.addAttributes(
        [
          .link: link.url,
          .foregroundColor: NSColor.linkColor,
          .underlineStyle: NSUnderlineStyle.single.rawValue,
        ],
        range: NSRange(link.range, in: sourceText)
      )
    }
  }

  static func paragraphStyle(
    spacingBefore: CGFloat = 0,
    spacingAfter: CGFloat = 0
  ) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 2
    style.paragraphSpacingBefore = spacingBefore
    style.paragraphSpacing = spacingAfter
    return style
  }

  static func listParagraphStyle(indent: CGFloat = 18) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 2
    style.paragraphSpacing = 2
    style.headIndent = indent
    style.firstLineHeadIndent = 0
    return style
  }

  static func headingFontSize(for level: Int) -> CGFloat {
    switch level {
    case 1:
      NSFont.systemFontSize + 4
    case 2:
      NSFont.systemFontSize + 2
    default:
      NSFont.systemFontSize + 1
    }
  }
}

private final class NativeTranscriptInlineAccumulator {
  private let result: NSMutableAttributedString

  init(result: NSMutableAttributedString) {
    self.result = result
  }

  func renderInlineChildren(of markup: Markup, style: NativeTranscriptInlineStyle) {
    for child in markup.children {
      renderInline(child, style: style)
    }
  }

  private func renderInline(_ markup: Markup, style: NativeTranscriptInlineStyle) {
    switch markup {
    case let text as Text:
      appendText(text.string, attributes: inlineAttributes(style: style))

    case let code as InlineCode:
      appendText(
        code.code,
        attributes: inlineAttributes(
          style: style,
          font: .monospacedSystemFont(ofSize: style.font.pointSize * 0.92, weight: .regular),
          backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.16)
        )
      )

    case is SoftBreak:
      appendText(" ", attributes: inlineAttributes(style: style))

    case is LineBreak:
      appendText("\n", attributes: inlineAttributes(style: style))

    case let strong as Strong:
      renderInlineChildren(of: strong, style: style.withFontTrait(.boldFontMask))

    case let emphasis as Emphasis:
      renderInlineChildren(of: emphasis, style: style.withFontTrait(.italicFontMask))

    case let link as Link:
      let linkStyle = style.withLink(URL(string: link.destination ?? ""))
      if link.isEmpty, let destination = link.destination {
        appendText(destination, attributes: inlineAttributes(style: linkStyle))
      } else {
        renderInlineChildren(of: link, style: linkStyle)
      }

    case let strikethrough as Strikethrough:
      renderInlineChildren(of: strikethrough, style: style.withStrikethrough())

    default:
      if let plain = markup as? any PlainTextConvertibleMarkup {
        appendText(plain.plainText, attributes: inlineAttributes(style: style))
      } else if !markup.isEmpty {
        renderInlineChildren(of: markup, style: style)
      } else {
        appendText(markup.format(), attributes: inlineAttributes(style: style))
      }
    }
  }

  private func appendText(_ text: String, attributes: [NSAttributedString.Key: Any]) {
    result.append(NSAttributedString(string: text, attributes: attributes))
  }

  private func inlineAttributes(
    style: NativeTranscriptInlineStyle,
    font: NSFont? = nil,
    color: NSColor? = nil,
    backgroundColor: NSColor? = nil
  ) -> [NSAttributedString.Key: Any] {
    var attributes: [NSAttributedString.Key: Any] = [
      .font: font ?? style.font,
      .foregroundColor: color ?? style.color,
      .paragraphStyle: style.paragraphStyle,
    ]
    if let backgroundColor {
      attributes[.backgroundColor] = backgroundColor
    }
    if let linkURL = style.linkURL {
      attributes[.link] = linkURL
      attributes[.foregroundColor] = NSColor.linkColor
      attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
    }
    if style.isStrikethrough {
      attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
    }
    return attributes
  }
}

private struct NativeTranscriptInlineStyle {
  var font: NSFont
  var color: NSColor = .labelColor
  var paragraphStyle: NSParagraphStyle
  var linkURL: URL?
  var isStrikethrough = false

  func withFontTrait(_ trait: NSFontTraitMask) -> NativeTranscriptInlineStyle {
    var copy = self
    copy.font = NSFontManager.shared.convert(font, toHaveTrait: trait)
    return copy
  }

  func withLink(_ url: URL?) -> NativeTranscriptInlineStyle {
    var copy = self
    copy.linkURL = url
    return copy
  }

  func withStrikethrough() -> NativeTranscriptInlineStyle {
    var copy = self
    copy.isStrikethrough = true
    return copy
  }
}

private final class NativeTranscriptMarkdownASTRenderer {
  private var blocks: [NativeMarkdownBlock] = []
  private let textResult = NSMutableAttributedString()

  func renderBlocks(_ document: Document) -> [NativeMarkdownBlock] {
    renderBlockChildren(of: document, depth: 0, quoteDepth: 0)
    flushTextBlock()
    if blocks.isEmpty {
      appendText(
        " ",
        attributes: inlineAttributes(
          font: .systemFont(ofSize: NSFont.systemFontSize),
          paragraphStyle: NativeTranscriptMarkdownRenderer.paragraphStyle()
        )
      )
      flushTextBlock()
    }
    return blocks
  }

  private func renderBlockChildren(of markup: Markup, depth: Int, quoteDepth: Int) {
    for child in markup.children {
      appendBlockSeparatorIfNeeded()
      renderBlock(child, depth: depth, quoteDepth: quoteDepth)
    }
  }

  private func renderBlock(_ markup: Markup, depth: Int, quoteDepth: Int) {
    switch markup {
    case let heading as Heading:
      let font = NSFont.systemFont(
        ofSize: NativeTranscriptMarkdownRenderer.headingFontSize(for: heading.level),
        weight: .semibold
      )
      appendBlockPrefix(depth: depth, quoteDepth: quoteDepth)
      renderInlineChildren(
        of: heading,
        style: InlineStyle(
          font: font,
          paragraphStyle: NativeTranscriptMarkdownRenderer.paragraphStyle(
            spacingBefore: heading.level == 1 ? 2 : 1,
            spacingAfter: 4
          )
        )
      )

    case let paragraph as Paragraph:
      appendBlockPrefix(depth: depth, quoteDepth: quoteDepth)
      renderInlineChildren(
        of: paragraph,
        style: InlineStyle(
          font: .systemFont(ofSize: NSFont.systemFontSize),
          paragraphStyle: NativeTranscriptMarkdownRenderer.paragraphStyle(spacingAfter: 3)
        )
      )

    case let list as UnorderedList:
      renderList(list, depth: depth, quoteDepth: quoteDepth, marker: { _ in "•" })

    case let list as OrderedList:
      let start = Int(list.startIndex)
      renderList(list, depth: depth, quoteDepth: quoteDepth) { index in
        "\(start + index)."
      }

    case let quote as BlockQuote:
      renderBlockChildren(of: quote, depth: depth, quoteDepth: quoteDepth + 1)

    case let table as Table:
      flushTextBlock()
      let nativeTable = projectTable(table)
      if nativeTable.isEmpty {
        renderFallback(table)
      } else {
        blocks.append(.table(nativeTable))
      }

    case let codeBlock as CodeBlock:
      appendBlockPrefix(depth: depth, quoteDepth: quoteDepth)
      appendText(
        codeBlock.code,
        attributes: inlineAttributes(
          font: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
          paragraphStyle: NativeTranscriptMarkdownRenderer.paragraphStyle(spacingAfter: 3)
        )
      )

    case is ThematicBreak:
      appendBlockPrefix(depth: depth, quoteDepth: quoteDepth)
      appendText(
        "-----",
        attributes: inlineAttributes(
          font: .systemFont(ofSize: NSFont.systemFontSize),
          color: .secondaryLabelColor,
          paragraphStyle: NativeTranscriptMarkdownRenderer.paragraphStyle(spacingAfter: 3)
        )
      )

    default:
      appendBlockPrefix(depth: depth, quoteDepth: quoteDepth)
      renderFallback(markup)
    }
  }

  private func renderList(
    _ list: Markup,
    depth: Int,
    quoteDepth: Int,
    marker: (Int) -> String
  ) {
    for (index, child) in list.children.enumerated() {
      guard let item = child as? ListItem else {
        appendBlockSeparatorIfNeeded()
        renderBlock(child, depth: depth, quoteDepth: quoteDepth)
        continue
      }
      if index > 0 {
        appendNewlineIfNeeded()
      }
      renderListItem(
        item,
        marker: marker(index),
        depth: depth,
        quoteDepth: quoteDepth
      )
    }
  }

  private func renderListItem(
    _ item: ListItem,
    marker: String,
    depth: Int,
    quoteDepth: Int
  ) {
    let children = Array(item.children)
    var didRenderFirstInlineBlock = false
    for child in children {
      switch child {
      case let paragraph as Paragraph where !didRenderFirstInlineBlock:
        appendListPrefix(marker: marker, depth: depth, quoteDepth: quoteDepth)
        renderInlineChildren(
          of: paragraph,
          style: InlineStyle(
            font: .systemFont(ofSize: NSFont.systemFontSize),
            paragraphStyle: NativeTranscriptMarkdownRenderer.listParagraphStyle(
              indent: CGFloat(depth + 1) * 18
            )
          )
        )
        didRenderFirstInlineBlock = true

      case let nested as UnorderedList:
        appendNewlineIfNeeded()
        renderList(nested, depth: depth + 1, quoteDepth: quoteDepth, marker: { _ in "•" })

      case let nested as OrderedList:
        appendNewlineIfNeeded()
        let start = Int(nested.startIndex)
        renderList(nested, depth: depth + 1, quoteDepth: quoteDepth) { index in
          "\(start + index)."
        }

      default:
        appendNewlineIfNeeded()
        renderBlock(child, depth: depth + 1, quoteDepth: quoteDepth)
      }
    }
    if children.isEmpty {
      appendListPrefix(marker: marker, depth: depth, quoteDepth: quoteDepth)
    }
  }

  private func projectTable(_ table: Table) -> NativeMarkdownTable {
    let header =
      table.head.isEmpty
      ? []
      : projectTableRow(table.head, isHeader: true)
    let rows = table.body.children.compactMap { row -> [NativeMarkdownTableCell]? in
      guard let row = row as? Table.Row else {
        return nil
      }
      return projectTableRow(row, isHeader: false)
    }
    return NativeMarkdownTable(header: header, rows: rows)
  }

  private func projectTableRow(
    _ row: Markup,
    isHeader: Bool
  ) -> [NativeMarkdownTableCell] {
    row.children.map { cell in
      NativeMarkdownTableCell(
        attributedString: tableCellAttributedString(
          for: cell,
          isHeader: isHeader
        )
      )
    }
  }

  private func tableCellAttributedString(
    for cell: Markup,
    isHeader: Bool
  ) -> NSAttributedString {
    let cellResult = NSMutableAttributedString()
    let font: NSFont =
      isHeader
      ? .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
      : .systemFont(ofSize: NSFont.systemFontSize)
    let renderer = NativeTranscriptInlineAccumulator(result: cellResult)
    renderer.renderInlineChildren(
      of: cell,
      style: NativeTranscriptInlineStyle(
        font: font,
        paragraphStyle: NativeTranscriptMarkdownRenderer.paragraphStyle(spacingAfter: 0)
      )
    )
    if cellResult.length == 0 {
      cellResult.append(
        NSAttributedString(
          string: " ",
          attributes: inlineAttributes(
            font: font,
            paragraphStyle: NativeTranscriptMarkdownRenderer.paragraphStyle(spacingAfter: 0)
          )
        ))
    }
    NativeTranscriptMarkdownRenderer.applyLinks(to: cellResult, sourceText: cellResult.string)
    return cellResult
  }

  private func renderInlineChildren(of markup: Markup, style: InlineStyle) {
    for child in markup.children {
      renderInline(child, style: style)
    }
  }

  private func renderInline(_ markup: Markup, style: InlineStyle) {
    switch markup {
    case let text as Text:
      appendText(text.string, attributes: inlineAttributes(style: style))

    case let code as InlineCode:
      appendText(
        code.code,
        attributes: inlineAttributes(
          style: style,
          font: .monospacedSystemFont(ofSize: style.font.pointSize * 0.92, weight: .regular),
          backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.16)
        )
      )

    case is SoftBreak:
      appendText(" ", attributes: inlineAttributes(style: style))

    case is LineBreak:
      appendText("\n", attributes: inlineAttributes(style: style))

    case let strong as Strong:
      renderInlineChildren(of: strong, style: style.withFontTrait(.boldFontMask))

    case let emphasis as Emphasis:
      renderInlineChildren(of: emphasis, style: style.withFontTrait(.italicFontMask))

    case let link as Link:
      let linkStyle = style.withLink(URL(string: link.destination ?? ""))
      if link.isEmpty, let destination = link.destination {
        appendText(destination, attributes: inlineAttributes(style: linkStyle))
      } else {
        renderInlineChildren(of: link, style: linkStyle)
      }

    case let strikethrough as Strikethrough:
      renderInlineChildren(of: strikethrough, style: style.withStrikethrough())

    default:
      if markup.isEmpty {
        renderFallback(markup, style: style)
      } else {
        renderInlineChildren(of: markup, style: style)
      }
    }
  }

  private func renderFallback(
    _ markup: Markup,
    style: InlineStyle = InlineStyle(
      font: .systemFont(ofSize: NSFont.systemFontSize),
      paragraphStyle: NativeTranscriptMarkdownRenderer.paragraphStyle(spacingAfter: 3)
    )
  ) {
    if let plain = markup as? any PlainTextConvertibleMarkup {
      appendText(plain.plainText, attributes: inlineAttributes(style: style))
    } else if !markup.isEmpty {
      renderInlineChildren(of: markup, style: style)
    } else {
      appendText(markup.format(), attributes: inlineAttributes(style: style))
    }
  }

  private func appendBlockPrefix(depth: Int, quoteDepth: Int) {
    let prefix = blockPrefix(depth: depth, quoteDepth: quoteDepth)
    guard !prefix.isEmpty else {
      return
    }
    appendText(
      prefix,
      attributes: inlineAttributes(
        font: .systemFont(ofSize: NSFont.systemFontSize),
        color: .secondaryLabelColor,
        paragraphStyle: NativeTranscriptMarkdownRenderer.paragraphStyle(spacingAfter: 3)
      )
    )
  }

  private func appendListPrefix(marker: String, depth: Int, quoteDepth: Int) {
    appendBlockPrefix(depth: depth, quoteDepth: quoteDepth)
    appendText(
      "\(marker) ",
      attributes: inlineAttributes(
        font: .systemFont(ofSize: NSFont.systemFontSize),
        color: .secondaryLabelColor,
        paragraphStyle: NativeTranscriptMarkdownRenderer.listParagraphStyle(
          indent: CGFloat(depth + 1) * 18
        )
      )
    )
  }

  private func blockPrefix(depth: Int, quoteDepth: Int) -> String {
    let quotePrefix = String(repeating: "> ", count: quoteDepth)
    let indent = String(repeating: "  ", count: depth)
    return quotePrefix + indent
  }

  private func appendBlockSeparatorIfNeeded() {
    guard textResult.length > 0, !textResult.string.hasSuffix("\n") else {
      return
    }
    textResult.append(NSAttributedString(string: "\n"))
  }

  private func appendNewlineIfNeeded() {
    guard !textResult.string.hasSuffix("\n") else {
      return
    }
    textResult.append(NSAttributedString(string: "\n"))
  }

  private func appendText(_ text: String, attributes: [NSAttributedString.Key: Any]) {
    textResult.append(NSAttributedString(string: text, attributes: attributes))
  }

  private func flushTextBlock() {
    guard textResult.length > 0 else {
      return
    }
    NativeTranscriptMarkdownRenderer.applyLinks(to: textResult, sourceText: textResult.string)
    blocks.append(.text(NSAttributedString(attributedString: textResult)))
    textResult.deleteCharacters(in: NSRange(location: 0, length: textResult.length))
  }

  private func inlineAttributes(
    style: InlineStyle,
    font: NSFont? = nil,
    color: NSColor? = nil,
    backgroundColor: NSColor? = nil
  ) -> [NSAttributedString.Key: Any] {
    var attributes = inlineAttributes(
      font: font ?? style.font,
      color: color ?? style.color,
      paragraphStyle: style.paragraphStyle,
      backgroundColor: backgroundColor
    )
    if let linkURL = style.linkURL {
      attributes[.link] = linkURL
      attributes[.foregroundColor] = NSColor.linkColor
      attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
    }
    if style.isStrikethrough {
      attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
    }
    return attributes
  }

  private func inlineAttributes(
    font: NSFont,
    color: NSColor = .labelColor,
    paragraphStyle: NSParagraphStyle,
    backgroundColor: NSColor? = nil
  ) -> [NSAttributedString.Key: Any] {
    var attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: color,
      .paragraphStyle: paragraphStyle,
    ]
    if let backgroundColor {
      attributes[.backgroundColor] = backgroundColor
    }
    return attributes
  }

  private struct InlineStyle {
    var font: NSFont
    var color: NSColor = .labelColor
    var paragraphStyle: NSParagraphStyle
    var linkURL: URL?
    var isStrikethrough = false

    func withFontTrait(_ trait: NSFontTraitMask) -> InlineStyle {
      var copy = self
      copy.font = NSFontManager.shared.convert(font, toHaveTrait: trait)
      return copy
    }

    func withLink(_ url: URL?) -> InlineStyle {
      var copy = self
      copy.linkURL = url
      return copy
    }

    func withStrikethrough() -> InlineStyle {
      var copy = self
      copy.isStrikethrough = true
      return copy
    }
  }
}

enum NativeMarkdownTableMetrics {
  static let horizontalPadding: CGFloat = 9
  static let verticalPadding: CGFloat = 6
  static let borderWidth: CGFloat = 1
  static let separatorWidth: CGFloat = 1
  static let minimumRowHeight: CGFloat = 28
  static let minimumColumnWidth: CGFloat = 150
  static let maximumPreferredWidth: CGFloat = 620
  static let cornerRadius: CGFloat = 7

  static func height(for table: NativeMarkdownTable, width: CGFloat) -> CGFloat {
    guard !table.isEmpty else {
      return 0
    }
    let rows = normalizedRows(for: table)
    guard !rows.isEmpty else {
      return 0
    }
    let columnWidth = self.columnWidth(for: table, width: effectiveWidth(for: table, width: width))
    let rowHeights = rows.map { row in
      rowHeight(for: row, columnWidth: columnWidth)
    }
    let separatorHeight = CGFloat(max(0, rowHeights.count - 1)) * separatorWidth
    return ceil(rowHeights.reduce(0, +) + separatorHeight + borderWidth * 2)
  }

  static func effectiveWidth(for table: NativeMarkdownTable, width: CGFloat) -> CGFloat {
    min(width, preferredWidth(for: table))
  }

  static func preferredWidth(for table: NativeMarkdownTable) -> CGFloat {
    let columnCount = max(table.columnCount, 1)
    let separatorSpace = CGFloat(max(0, columnCount - 1)) * separatorWidth
    let borderSpace = borderWidth * 2
    let contentWidth = CGFloat(columnCount) * minimumColumnWidth
    return min(contentWidth + separatorSpace + borderSpace, maximumPreferredWidth)
  }

  static func columnWidth(for table: NativeMarkdownTable, width: CGFloat) -> CGFloat {
    let columnCount = max(table.columnCount, 1)
    let separatorSpace = CGFloat(max(0, columnCount - 1)) * separatorWidth
    let contentWidth = max(width - borderWidth * 2 - separatorSpace, CGFloat(columnCount) * 44)
    return floor(contentWidth / CGFloat(columnCount))
  }

  static func normalizedRows(for table: NativeMarkdownTable) -> [[NativeMarkdownTableCell]] {
    let emptyCell = NativeMarkdownTableCell(attributedString: NSAttributedString(string: " "))
    let columnCount = max(table.columnCount, 1)
    let allRows = (table.header.isEmpty ? [] : [table.header]) + table.rows
    return allRows.map { row in
      if row.count >= columnCount {
        return Array(row.prefix(columnCount))
      }
      return row + Array(repeating: emptyCell, count: columnCount - row.count)
    }
  }

  static func rowHeight(
    for row: [NativeMarkdownTableCell],
    columnWidth: CGFloat
  ) -> CGFloat {
    let textWidth = max(columnWidth - horizontalPadding * 2, 12)
    let textHeight = row.reduce(CGFloat(0)) { maxHeight, cell in
      max(maxHeight, measuredTextHeight(cell.attributedString, width: textWidth))
    }
    return max(minimumRowHeight, ceil(textHeight + verticalPadding * 2))
  }

  private static func measuredTextHeight(
    _ attributedString: NSAttributedString,
    width: CGFloat
  ) -> CGFloat {
    let measuredString =
      attributedString.length == 0
      ? NSAttributedString(
        string: " ",
        attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
      )
      : attributedString
    let rect = measuredString.boundingRect(
      with: NSSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    return ceil(rect.height)
  }
}

enum NativeTranscriptCodeRenderer {
  static func attributedString(for highlightedCode: HighlightedCode) -> NSAttributedString {
    let code = highlightedCode.code.isEmpty ? " " : highlightedCode.code
    let attributedString = NSMutableAttributedString(
      string: code,
      attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        .foregroundColor: NSColor.labelColor,
      ]
    )
    for span in highlightedCode.spans {
      guard span.range.location >= 0, span.range.upperBound <= attributedString.length else {
        continue
      }
      attributedString.addAttribute(
        .foregroundColor,
        value: color(for: span.style),
        range: span.range.nsRange
      )
    }
    return attributedString
  }

  static func plainAttributedString(
    code: String,
    language: CodeLanguage?
  ) -> NSAttributedString {
    attributedString(for: .plain(code: code, language: language))
  }

  static func color(for style: CodeHighlightStyle) -> NSColor {
    switch style {
    case .attribute:
      .systemPurple
    case .comment:
      .secondaryLabelColor
    case .constant:
      .systemOrange
    case .function:
      .systemBlue
    case .keyword:
      .systemPink
    case .number:
      .systemOrange
    case .operatorToken:
      .systemGray
    case .property:
      .systemTeal
    case .punctuation:
      .secondaryLabelColor
    case .string:
      .systemGreen
    case .type:
      .systemIndigo
    case .variable:
      .labelColor
    }
  }
}
