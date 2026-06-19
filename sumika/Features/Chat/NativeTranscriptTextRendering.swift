import AppKit
import Foundation
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
    do {
      return try renderMarkdown(markdown)
    } catch {
      return linkifiedPlainText(markdown)
    }
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

  private static func renderMarkdown(_ markdown: String) throws -> NSAttributedString {
    let source = markdown.isEmpty ? " " : markdown
    let result = NSMutableAttributedString()
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false)

    for (index, lineSubstring) in lines.enumerated() {
      let line = String(lineSubstring)
      let renderedLine = try renderLine(line)
      result.append(renderedLine)
      if index < lines.index(before: lines.endIndex) {
        result.append(NSAttributedString(string: "\n"))
      }
    }

    return result
  }

  private static func renderLine(_ line: String) throws -> NSAttributedString {
    if line.trimmingCharacters(in: .whitespaces).isEmpty {
      return NSAttributedString(string: line)
    }

    if let heading = headingContent(in: line) {
      return try inlineMarkdown(
        heading.text,
        prefix: "",
        font: .systemFont(ofSize: headingFontSize(for: heading.level), weight: .semibold),
        paragraphStyle: paragraphStyle(spacingBefore: heading.level == 1 ? 2 : 1, spacingAfter: 4)
      )
    }

    if let listItem = unorderedListContent(in: line) {
      return try inlineMarkdown(
        listItem,
        prefix: "• ",
        font: .systemFont(ofSize: NSFont.systemFontSize),
        paragraphStyle: listParagraphStyle()
      )
    }

    if let numberedItem = numberedListContent(in: line) {
      return try inlineMarkdown(
        numberedItem.text,
        prefix: "\(numberedItem.ordinal). ",
        font: .systemFont(ofSize: NSFont.systemFontSize),
        paragraphStyle: listParagraphStyle()
      )
    }

    return try inlineMarkdown(
      line,
      prefix: "",
      font: .systemFont(ofSize: NSFont.systemFontSize),
      paragraphStyle: paragraphStyle(spacingAfter: 3)
    )
  }

  private static func inlineMarkdown(
    _ markdown: String,
    prefix: String,
    font: NSFont,
    paragraphStyle: NSParagraphStyle
  ) throws -> NSAttributedString {
    let parsed = try AttributedString(
      markdown: markdown,
      options: AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace
      )
    )
    let attributedString = NSMutableAttributedString()
    if !prefix.isEmpty {
      attributedString.append(
        NSAttributedString(
          string: prefix,
          attributes: [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle,
          ]
        ))
    }
    attributedString.append(NSAttributedString(parsed))

    let fullRange = NSRange(location: 0, length: attributedString.length)
    attributedString.addAttributes(
      [
        .font: font,
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: paragraphStyle,
      ],
      range: fullRange
    )
    applyInlinePresentation(to: attributedString, baseFont: font)
    applyExistingLinks(to: attributedString)
    applyLinks(to: attributedString, sourceText: attributedString.string)
    return attributedString
  }

  private static func applyInlinePresentation(
    to attributedString: NSMutableAttributedString,
    baseFont: NSFont
  ) {
    let fullRange = NSRange(location: 0, length: attributedString.length)
    attributedString.enumerateAttribute(.inlinePresentationIntent, in: fullRange) {
      value, range, _ in
      guard let rawValue = value as? Int else {
        return
      }

      let isItalic = rawValue & 1 != 0
      let isBold = rawValue & 2 != 0
      let isCode = rawValue & 4 != 0
      if isCode {
        attributedString.addAttributes(
          [
            .font: NSFont.monospacedSystemFont(
              ofSize: baseFont.pointSize * 0.92,
              weight: .regular
            ),
            .backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.16),
          ],
          range: range
        )
        return
      }

      var font = baseFont
      if isBold {
        font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
      }
      if isItalic {
        font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
      }
      attributedString.addAttribute(.font, value: font, range: range)
    }
  }

  private static func applyExistingLinks(to attributedString: NSMutableAttributedString) {
    let fullRange = NSRange(location: 0, length: attributedString.length)
    attributedString.enumerateAttribute(.link, in: fullRange) { value, range, _ in
      guard value != nil else {
        return
      }
      attributedString.addAttributes(
        [
          .foregroundColor: NSColor.linkColor,
          .underlineStyle: NSUnderlineStyle.single.rawValue,
        ],
        range: range
      )
    }
  }

  private static func applyLinks(to attributedString: NSMutableAttributedString, sourceText: String)
  {
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

  private static func headingContent(in line: String) -> (level: Int, text: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let markerCount = trimmed.prefix(while: { $0 == "#" }).count
    guard markerCount > 0, markerCount <= 6 else {
      return nil
    }
    let markerEndIndex = trimmed.index(trimmed.startIndex, offsetBy: markerCount)
    guard markerEndIndex < trimmed.endIndex, trimmed[markerEndIndex] == " " else {
      return nil
    }
    let textStartIndex = trimmed.index(after: markerEndIndex)
    return (markerCount, String(trimmed[textStartIndex...]))
  }

  private static func unorderedListContent(in line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    for marker in ["- ", "* "] where trimmed.hasPrefix(marker) {
      return String(trimmed.dropFirst(marker.count))
    }
    return nil
  }

  private static func numberedListContent(in line: String) -> (ordinal: Int, text: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard let dotIndex = trimmed.firstIndex(of: ".") else {
      return nil
    }
    let ordinalText = String(trimmed[..<dotIndex])
    guard let ordinal = Int(ordinalText), ordinal > 0 else {
      return nil
    }
    let textStartIndex = trimmed.index(after: dotIndex)
    guard textStartIndex < trimmed.endIndex, trimmed[textStartIndex] == " " else {
      return nil
    }
    let contentStartIndex = trimmed.index(after: textStartIndex)
    let text = contentStartIndex < trimmed.endIndex ? String(trimmed[contentStartIndex...]) : ""
    return (ordinal, text)
  }

  private static func paragraphStyle(
    spacingBefore: CGFloat = 0,
    spacingAfter: CGFloat = 0
  ) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 2
    style.paragraphSpacingBefore = spacingBefore
    style.paragraphSpacing = spacingAfter
    return style
  }

  private static func listParagraphStyle() -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 2
    style.paragraphSpacing = 2
    style.headIndent = 18
    style.firstLineHeadIndent = 0
    return style
  }

  private static func headingFontSize(for level: Int) -> CGFloat {
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
