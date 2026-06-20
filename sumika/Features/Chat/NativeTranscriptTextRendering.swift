import AppKit
import Foundation
import Markdown
import SumikaCore

struct NativeTranscriptMarkdownCache {
  private var attributedStringsByText: [String: NSAttributedString] = [:]

  var cachedEntryCount: Int {
    attributedStringsByText.count
  }

  mutating func attributedString(for markdown: String) -> NSAttributedString {
    if let cached = attributedStringsByText[markdown] {
      return cached
    }
    let attributedString = NativeTranscriptMarkdownRenderer.attributedString(for: markdown)
    attributedStringsByText[markdown] = attributedString
    return attributedString
  }

  mutating func prune(activeTexts: Set<String>) {
    attributedStringsByText = attributedStringsByText.filter { activeTexts.contains($0.key) }
  }
}

enum NativeTranscriptMarkdownRenderer {
  static func attributedString(for markdown: String) -> NSAttributedString {
    renderMarkdown(markdown)
  }

  static func measuredHeight(for markdown: String, width: CGFloat) -> CGFloat {
    measuredHeight(for: attributedString(for: markdown), width: width)
  }

  static func measuredHeight(for attributedString: NSAttributedString, width: CGFloat) -> CGFloat {
    let rect = attributedString.boundingRect(
      with: NSSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    return ceil(rect.height)
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

  private static func renderMarkdown(_ markdown: String) -> NSAttributedString {
    let source = markdown.isEmpty ? " " : markdown
    let document = Document(parsing: source)
    let renderer = NativeTranscriptMarkdownASTRenderer()
    return renderer.render(document)
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

private final class NativeTranscriptMarkdownASTRenderer {
  private let result = NSMutableAttributedString()

  func render(_ document: Document) -> NSAttributedString {
    renderBlockChildren(of: document, depth: 0, quoteDepth: 0)
    if result.length == 0 {
      appendText(
        " ",
        attributes: inlineAttributes(
          font: .systemFont(ofSize: NSFont.systemFontSize),
          paragraphStyle: NativeTranscriptMarkdownRenderer.paragraphStyle()
        )
      )
    }
    NativeTranscriptMarkdownRenderer.applyLinks(to: result, sourceText: result.string)
    return result
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
      renderTable(table, depth: depth, quoteDepth: quoteDepth)

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

  private func renderTable(_ table: Table, depth: Int, quoteDepth: Int) {
    if !table.head.isEmpty {
      renderTableRow(table.head, depth: depth, quoteDepth: quoteDepth, isHeader: true)
    }
    for row in table.body.children {
      guard let row = row as? Table.Row else {
        continue
      }
      appendNewlineIfNeeded()
      renderTableRow(row, depth: depth, quoteDepth: quoteDepth, isHeader: false)
    }
  }

  private func renderTableRow(
    _ row: Markup,
    depth: Int,
    quoteDepth: Int,
    isHeader: Bool
  ) {
    appendBlockPrefix(depth: depth, quoteDepth: quoteDepth)
    let font: NSFont =
      isHeader
      ? .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
      : .systemFont(ofSize: NSFont.systemFontSize)
    let style = InlineStyle(
      font: font,
      paragraphStyle: NativeTranscriptMarkdownRenderer.paragraphStyle(spacingAfter: 2)
    )
    for (index, cell) in row.children.enumerated() {
      if index > 0 {
        appendText(
          " | ",
          attributes: inlineAttributes(
            font: .systemFont(ofSize: NSFont.systemFontSize),
            color: .secondaryLabelColor,
            paragraphStyle: style.paragraphStyle
          )
        )
      }
      renderInlineChildren(of: cell, style: style)
    }
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
    guard result.length > 0, !result.string.hasSuffix("\n") else {
      return
    }
    result.append(NSAttributedString(string: "\n"))
  }

  private func appendNewlineIfNeeded() {
    guard !result.string.hasSuffix("\n") else {
      return
    }
    result.append(NSAttributedString(string: "\n"))
  }

  private func appendText(_ text: String, attributes: [NSAttributedString.Key: Any]) {
    result.append(NSAttributedString(string: text, attributes: attributes))
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

  static func measuredHeight(for code: String, width: CGFloat) -> CGFloat {
    let attributedString = plainAttributedString(
      code: code.isEmpty ? " " : code,
      language: nil
    )
    return NativeTranscriptMarkdownRenderer.measuredHeight(
      for: attributedString,
      width: width
    )
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
