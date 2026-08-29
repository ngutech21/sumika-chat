import AppKit
import Testing

@testable import SumikaApp
@testable import SumikaCore

@MainActor
struct NativeTranscriptTextRenderingTests {
  @Test
  func markdownRendererStylesInlineMarkdownAndLists() {
    let rendered = combinedTextBlocks(
      NativeTranscriptMarkdownRenderer.blocks(
        for: """
          # Title
          - **bold**
          - *italic*
          `code`
          """
      )
    )

    #expect(rendered.string.contains("Title"))
    #expect(rendered.string.contains("• bold"))
    #expect(rendered.string.contains("• italic"))
    #expect(rendered.string.contains("code"))
    #expect(rendered.hasFontTrait(.boldFontMask, inText: "Title"))
    #expect(rendered.hasFontTrait(.boldFontMask, inText: "bold"))
    #expect(rendered.hasFontTrait(.italicFontMask, inText: "italic"))
    #expect(rendered.hasMonospacedFont(inText: "code"))
    #expect(
      rendered.foregroundColor(inText: "code")
        == NativeTranscriptMarkdownRenderer.inlineCodeColor
    )
    #expect(!rendered.hasBackgroundColor(inText: "code"))
    #expect(rendered.fontSize(inText: "Title") > NSFont.systemFontSize)
  }

  @Test
  func markdownRendererUsesReadableBodyTypographyAndSemiboldEmphasis() throws {
    let rendered = combinedTextBlocks(
      NativeTranscriptMarkdownRenderer.blocks(for: "Regular text with **strong emphasis**.")
    )

    #expect(
      rendered.font(inText: "Regular text")
        == NSFont.systemFont(ofSize: NativeTranscriptMarkdownRenderer.bodyFontSize)
    )
    #expect(
      rendered.font(inText: "strong emphasis")
        == NSFont.systemFont(
          ofSize: NativeTranscriptMarkdownRenderer.bodyFontSize,
          weight: .semibold
        )
    )
    let paragraphStyle = try #require(rendered.paragraphStyle(inText: "Regular text"))
    #expect(paragraphStyle.lineSpacing == NativeTranscriptMarkdownRenderer.bodyLineSpacing)
    #expect(
      paragraphStyle.paragraphSpacing
        == NativeTranscriptMarkdownRenderer.bodyParagraphSpacing
    )
  }

  @Test
  func markdownRendererAddsLinkAttributes() {
    let rendered = combinedTextBlocks(
      NativeTranscriptMarkdownRenderer.blocks(
        for: "[Sumika](https://example.com) and https://sumika.local"
      )
    )

    #expect(rendered.hasLink(inText: "Sumika"))
    #expect(rendered.hasLink(inText: "https://sumika.local"))
    #expect(rendered.hasUnderline(inText: "Sumika"))
    #expect(rendered.hasLinkColor(inText: "https://sumika.local"))
  }

  @Test
  func malformedMarkdownRemainsReadableAndPlainLinksStillWork() {
    let rendered = combinedTextBlocks(
      NativeTranscriptMarkdownRenderer.blocks(
        for: "[broken](http:// and https://sumika.local"
      )
    )

    #expect(rendered.string.contains("[broken](http://"))
    #expect(rendered.hasLink(inText: "https://sumika.local"))
  }

  @Test
  func markdownRendererHandlesNestedOrderedAndUnorderedLists() {
    let rendered = combinedTextBlocks(
      NativeTranscriptMarkdownRenderer.blocks(
        for: """
          1. Parent
             - Child
          2. Next
          """
      )
    )

    #expect(rendered.string.contains("1. Parent"))
    #expect(rendered.string.contains("  • Child"))
    #expect(rendered.string.contains("2. Next"))
  }

  @Test
  func markdownRendererProjectsTablesAsNativeBlocks() throws {
    let blocks = NativeTranscriptMarkdownRenderer.blocks(
      for: """
        Intro

        | Name | Value |
        | --- | --- |
        | Model | **Gemma** |
        """
    )

    #expect(blocks.count == 2)
    guard case .text(let text) = blocks[0] else {
      Issue.record("Expected leading text block")
      return
    }
    guard case .table(let table) = blocks[1] else {
      Issue.record("Expected table block")
      return
    }

    #expect(text.string.contains("Intro"))
    #expect(table.columnCount == 2)
    #expect(table.header[0].attributedString.string == "Name")
    #expect(table.rows[0][1].attributedString.string == "Gemma")
    #expect(table.header[0].attributedString.hasFontTrait(.boldFontMask, inText: "Name"))
    #expect(table.rows[0][1].attributedString.hasFontTrait(.boldFontMask, inText: "Gemma"))
  }

  @Test
  func markdownRendererKeepsInlineCodeAndLinksInsideTableCells() throws {
    let blocks = NativeTranscriptMarkdownRenderer.blocks(
      for: """
        | Kind | Value |
        | --- | --- |
        | Link | [Sumika](https://example.com) |
        | Code | `gemma` |
        """
    )
    let table = try tableBlock(in: blocks)

    #expect(table.rows[0][1].attributedString.hasLink(inText: "Sumika"))
    #expect(table.rows[1][1].attributedString.hasMonospacedFont(inText: "gemma"))
    #expect(
      table.rows[1][1].attributedString.foregroundColor(inText: "gemma")
        == NativeTranscriptMarkdownRenderer.inlineCodeColor
    )
    #expect(!table.rows[1][1].attributedString.hasBackgroundColor(inText: "gemma"))
  }

  @Test
  func markdownTableMeasurementHandlesWrappingCellContent() throws {
    let blocks = NativeTranscriptMarkdownRenderer.blocks(
      for: """
        | Name | Description |
        | --- | --- |
        | Gemma | This is a longer description that should wrap across multiple lines in a narrow transcript table cell. |
        """
    )
    let table = try tableBlock(in: blocks)

    let narrowHeight = NativeMarkdownTableMetrics.height(for: table, width: 260)
    let wideHeight = NativeMarkdownTableMetrics.height(for: table, width: 640)

    #expect(narrowHeight > 0)
    #expect(wideHeight > 0)
    #expect(narrowHeight > wideHeight)
  }

  @Test
  func markdownTableUsesReadablePreferredWidthWhenRenderedWithoutSiblingText() throws {
    let blocks = NativeTranscriptMarkdownRenderer.blocks(
      for: """
        | Robot Name | Model Type | Primary Function |
        | --- | --- | --- |
        | Aero-X1 | Aerial Drone | Surveillance & Mapping |
        """
    )
    let table = try tableBlock(in: blocks)

    #expect(NativeMarkdownTableMetrics.preferredWidth(for: table) >= 450)
    #expect(
      NativeMarkdownTableMetrics.effectiveWidth(for: table, width: 680)
        == NativeMarkdownTableMetrics.preferredWidth(for: table)
    )
  }

  @Test
  func markdownRendererKeepsBlockQuotesReadable() {
    let rendered = combinedTextBlocks(
      NativeTranscriptMarkdownRenderer.blocks(for: "> quoted **text**")
    )

    #expect(rendered.string.contains("> quoted text"))
    #expect(rendered.hasFontTrait(.boldFontMask, inText: "text"))
  }

  @Test
  func skillPreviewMarkdownAllowsOnlyWebLinksAndRendersImageAltText() throws {
    let rendered = combinedTextBlocks(
      NativeTranscriptMarkdownRenderer.skillPreviewBlocks(
        for: "[Web](https://example.com) [Relative](guide.md) ![Diagram](https://example.com/a.png)"
      )
    )
    let webRange = (rendered.string as NSString).range(of: "Web")
    let relativeRange = (rendered.string as NSString).range(of: "Relative")
    let imageRange = (rendered.string as NSString).range(of: "Diagram")

    #expect(
      rendered.attribute(.link, at: webRange.location, effectiveRange: nil) as? URL
        == URL(string: "https://example.com")
    )
    #expect(rendered.attribute(.link, at: relativeRange.location, effectiveRange: nil) == nil)
    #expect(imageRange.location != NSNotFound)
    #expect(rendered.attribute(.attachment, at: imageRange.location, effectiveRange: nil) == nil)
    #expect(rendered.attribute(.link, at: imageRange.location, effectiveRange: nil) == nil)
  }

  @Test
  func userMessageRendererProjectsSkillAsIconAndDisplayNameWithTooltip() throws {
    let tooltip = "Review a diff on standards and spec"
    let rendered = combinedTextBlocks(
      NativeUserMessageRenderer.blocks(
        for: skillMessage(
          content: "Use $code-review",
          name: "code-review",
          description: "Full review description.",
          metadata: SkillInterfaceMetadata(
            displayName: "Code Review",
            shortDescription: tooltip
          )
        )
      )
    )
    let iconRange = (rendered.string as NSString).range(of: "\u{fffc}")
    let labelRange = (rendered.string as NSString).range(of: "Code Review")

    #expect(iconRange.location != NSNotFound)
    #expect(labelRange.location != NSNotFound)
    #expect(rendered.attribute(.attachment, at: iconRange.location, effectiveRange: nil) != nil)
    #expect(
      rendered.attribute(.toolTip, at: iconRange.location, effectiveRange: nil) as? String
        == tooltip)
    #expect(
      rendered.attribute(.toolTip, at: labelRange.location, effectiveRange: nil) as? String
        == tooltip)
    #expect(rendered.attribute(.toolTip, at: iconRange.location + 1, effectiveRange: nil) == nil)
    let previewLink = try #require(
      rendered.attribute(.skillPreviewLink, at: labelRange.location, effectiveRange: nil)
        as? NativeSkillPreviewLink
    )
    #expect(previewLink.request.displayName == "Code Review")
    #expect(previewLink.request.skill.content.contains("Full review description."))
    #expect(
      (rendered.attribute(.link, at: iconRange.location, effectiveRange: nil) as? URL)?.scheme
        == "sumika-skill-preview"
    )
    #expect(rendered.attribute(.link, at: iconRange.location + 1, effectiveRange: nil) == nil)
    #expect(
      rendered.attribute(.underlineStyle, at: labelRange.location, effectiveRange: nil) == nil)
    #expect(rendered.foregroundColor(inText: "Code Review") == NSColor.linkColor)
    #expect(
      rendered.font(inText: "Code Review")
        == NSFont.systemFont(
          ofSize: NativeTranscriptMarkdownRenderer.bodyFontSize,
          weight: .medium
        )
    )
  }

  @Test
  func userMessageRendererUsesPersistedSkillFallbacks() {
    let rendered = combinedTextBlocks(
      NativeUserMessageRenderer.blocks(
        for: skillMessage(
          content: "$testing",
          name: "testing",
          description: "Run all focused tests."
        )
      )
    )
    let labelRange = (rendered.string as NSString).range(of: "$testing")

    #expect(rendered.string.contains("\u{fffc} $testing"))
    #expect(
      rendered.attribute(.toolTip, at: labelRange.location, effectiveRange: nil) as? String
        == "Run all focused tests."
    )
  }

  @Test
  func userMessageRendererHandlesEmphasisTablesAndUTF16SourceRanges() throws {
    let content = "🧪 **$code-review**\n\n| Skill |\n| --- |\n| $code-review |"
    let blocks = NativeUserMessageRenderer.blocks(
      for: skillMessage(
        content: content,
        name: "code-review",
        description: "Review changes.",
        metadata: SkillInterfaceMetadata(displayName: "Code Review")
      )
    )
    let text = combinedTextBlocks(blocks)
    let table = try tableBlock(in: blocks)

    #expect(text.string.contains("🧪 \u{fffc} Code Review"))
    #expect(!text.string.contains("$code-review"))
    #expect(table.rows[0][0].attributedString.string.contains("\u{fffc} Code Review"))
    #expect(
      table.rows[0][0].attributedString.attribute(
        .toolTip,
        at: 0,
        effectiveRange: nil
      ) as? String == "Review changes."
    )
  }

  @Test
  func userMessageRendererMapsDecodedMarkdownSourceAroundSkillMentions() {
    let cases = [
      (content: "&amp; $review", prefix: "& "),
      (content: "\\* $review", prefix: "* "),
      (content: "&#36;review $review", prefix: "$review "),
    ]

    for testCase in cases {
      let rendered = combinedTextBlocks(
        NativeUserMessageRenderer.blocks(
          for: skillMessage(
            content: testCase.content,
            name: "review",
            description: "Review changes.",
            metadata: SkillInterfaceMetadata(displayName: "Review")
          )
        )
      )

      #expect(rendered.string == "\(testCase.prefix)\u{fffc} Review")
      #expect(rendered.string.components(separatedBy: "\u{fffc}").count - 1 == 1)
    }
  }

  @Test
  func userMessageRendererLeavesSkillTokensInsideCodeAndLinksUnchanged() {
    let content = "`$code-review` and [$code-review](https://example.com) then $code-review"
    let rendered = combinedTextBlocks(
      NativeUserMessageRenderer.blocks(
        for: skillMessage(
          content: content,
          name: "code-review",
          description: "Review changes.",
          metadata: SkillInterfaceMetadata(displayName: "Code Review")
        )
      )
    )

    #expect(rendered.string.components(separatedBy: "$code-review").count - 1 == 2)
    #expect(rendered.string.components(separatedBy: "Code Review").count - 1 == 1)
    #expect(rendered.hasMonospacedFont(inText: "$code-review"))
    let secondRawRange = (rendered.string as NSString).range(
      of: "$code-review",
      options: [],
      range: NSRange(
        location: NSMaxRange((rendered.string as NSString).range(of: "$code-review")),
        length: (rendered.string as NSString).length
          - NSMaxRange((rendered.string as NSString).range(of: "$code-review"))
      )
    )
    #expect(rendered.attribute(.link, at: secondRawRange.location, effectiveRange: nil) != nil)
  }

  @Test
  func userMessageTooltipsBecomeAccessibilityHelpAndClearOnReuse() {
    let rendered = combinedTextBlocks(
      NativeUserMessageRenderer.blocks(
        for: skillMessage(
          content: "$code-review and $code-review",
          name: "code-review",
          description: "Review changes.",
          metadata: SkillInterfaceMetadata(
            displayName: "Code Review",
            shortDescription: "Review a diff"
          )
        )
      )
    )
    let textView = NativeTranscriptTextView()

    textView.setAttributedText(rendered)
    #expect(textView.accessibilityRole() == .staticText)
    #expect(textView.accessibilityHelp() == "Review a diff")

    textView.setAttributedText(NativeTranscriptMarkdownRenderer.linkifiedPlainText("Plain"))
    #expect(textView.accessibilityHelp() == nil)
  }

  @Test
  func userMessageCacheSeparatesIdenticalTextWithDifferentSkillSnapshots() {
    var cache = NativeUserMessageRenderCache()
    let first = skillMessage(
      content: "$review",
      name: "review",
      description: "First description.",
      metadata: SkillInterfaceMetadata(displayName: "Project Review")
    )
    let second = skillMessage(
      content: "$review",
      name: "review",
      scope: .personal,
      description: "Second description.",
      metadata: SkillInterfaceMetadata(displayName: "Personal Review")
    )

    let firstText = combinedTextBlocks(
      cache.blocks(for: first, rowID: "first", renderRevision: 1)
    )
    let secondText = combinedTextBlocks(
      cache.blocks(for: second, rowID: "second", renderRevision: 1)
    )
    _ = cache.blocks(for: second, rowID: "first", renderRevision: 2)

    #expect(firstText.string.contains("Project Review"))
    #expect(secondText.string.contains("Personal Review"))
    #expect(cache.cachedEntryCount == 2)
    cache.prune(
      activeKeys: [NativeUserMessageRenderCache.Key(rowID: "first", renderRevision: 2)]
    )
    #expect(cache.cachedEntryCount == 1)
  }

  @Test
  func markdownCacheReusesRenderedBlocksAndPrunesInactiveEntries() {
    var cache = NativeTranscriptMarkdownCache()

    _ = cache.blocks(for: "**one**")
    _ = cache.blocks(for: "**one**")
    _ = cache.blocks(for: "**two**")

    #expect(cache.cachedEntryCount == 2)

    cache.prune(activeTexts: ["**two**"])
    #expect(cache.cachedEntryCount == 1)
  }

  @Test
  func codeRendererMapsHighlightSpansToAppKitColors() {
    let highlighted = HighlightedCode(
      code: "let value = \"hi\"",
      language: .javascript,
      spans: [
        HighlightSpan(
          range: HighlightTextRange(location: 0, length: 3),
          style: .keyword
        ),
        HighlightSpan(
          range: HighlightTextRange(location: 12, length: 4),
          style: .string
        ),
      ]
    )

    let rendered = NativeTranscriptCodeRenderer.attributedString(for: highlighted)

    #expect(rendered.foregroundColor(inText: "let") == NSColor.systemPink)
    #expect(rendered.foregroundColor(inText: "\"hi\"") == NSColor.systemGreen)
    #expect(
      rendered.paragraphStyle(inText: "let")?.lineSpacing
        == NativeTranscriptMarkdownRenderer.bodyLineSpacing
    )
  }

  @Test
  func codeHighlightStoreIgnoresStaleResults() throws {
    let store = NativeTranscriptCodeHighlightStore()
    let firstBlock = codeBlock(id: "block", code: "let old = 1")
    let secondBlock = codeBlock(id: "block", code: "let new = 2")
    let firstKey = try #require(store.beginHighlight(rowID: "row", for: firstBlock))
    let secondKey = try #require(store.beginHighlight(rowID: "row", for: secondBlock))
    var updatedRows: [String] = []

    let accepted = store.completeHighlight(
      CodeHighlightResult(
        blockID: CodeHighlightBlockID(rawValue: "row#block"),
        version: firstKey.version,
        highlightedCode: .plain(code: "let old = 1", language: .javascript)
      ),
      for: firstKey,
      rowID: "row",
      onUpdate: { updatedRows.append($0) }
    )

    #expect(accepted == false)
    #expect(updatedRows.isEmpty)
    #expect(store.highlightedCode(rowID: "row", codeBlock: secondBlock) == nil)
    #expect(secondKey.version == 2)
  }

  @Test
  func codeHighlightStoreScopesLocalBlockIDsByRow() throws {
    let store = NativeTranscriptCodeHighlightStore()
    let firstBlock = codeBlock(id: "block", code: "let first = 1")
    let secondBlock = codeBlock(id: "block", code: "let second = 2")
    let firstKey = try #require(store.beginHighlight(rowID: "first-row", for: firstBlock))
    let secondKey = try #require(store.beginHighlight(rowID: "second-row", for: secondBlock))
    var updatedRows: [String] = []

    let firstAccepted = store.completeHighlight(
      CodeHighlightResult(
        blockID: CodeHighlightBlockID(rawValue: "first-row#block"),
        version: firstKey.version,
        highlightedCode: .plain(code: "let first = 1", language: .javascript)
      ),
      for: firstKey,
      rowID: "first-row",
      onUpdate: { updatedRows.append($0) }
    )
    let secondAccepted = store.completeHighlight(
      CodeHighlightResult(
        blockID: CodeHighlightBlockID(rawValue: "second-row#block"),
        version: secondKey.version,
        highlightedCode: .plain(code: "let second = 2", language: .javascript)
      ),
      for: secondKey,
      rowID: "second-row",
      onUpdate: { updatedRows.append($0) }
    )

    #expect(firstAccepted)
    #expect(secondAccepted)
    #expect(updatedRows == ["first-row", "second-row"])
    #expect(
      store.highlightedCode(rowID: "first-row", codeBlock: firstBlock)?.code == "let first = 1")
    #expect(
      store.highlightedCode(rowID: "second-row", codeBlock: secondBlock)?.code == "let second = 2")
    #expect(firstKey.version == 1)
    #expect(secondKey.version == 1)
  }

  @Test
  func codeHighlightStoreCachesAcceptedResultsAndSkipsDuplicateRequests() throws {
    let store = NativeTranscriptCodeHighlightStore()
    let block = codeBlock(id: "block", code: "let value = 1")
    let key = try #require(store.beginHighlight(rowID: "row", for: block))
    var updatedRows: [String] = []

    let accepted = store.completeHighlight(
      CodeHighlightResult(
        blockID: CodeHighlightBlockID(rawValue: "row#block"),
        version: key.version,
        highlightedCode: .plain(code: "let value = 1", language: .javascript)
      ),
      for: key,
      rowID: "row",
      onUpdate: { updatedRows.append($0) }
    )

    #expect(accepted)
    #expect(updatedRows == ["row"])
    #expect(store.cachedEntryCount == 1)
    #expect(store.highlightedCode(rowID: "row", codeBlock: block)?.code == "let value = 1")
    #expect(store.beginHighlight(rowID: "row", for: block) == nil)
  }

  @Test
  func codeHighlightStorePrunesInactiveHighlights() throws {
    let store = NativeTranscriptCodeHighlightStore()
    let block = codeBlock(id: "block", code: "let value = 1")
    let key = try #require(store.beginHighlight(rowID: "row", for: block))

    _ = store.completeHighlight(
      CodeHighlightResult(
        blockID: CodeHighlightBlockID(rawValue: "row#block"),
        version: key.version,
        highlightedCode: .plain(code: "let value = 1", language: .javascript)
      ),
      for: key,
      rowID: "row",
      onUpdate: { _ in }
    )

    store.prune(activeDescriptors: [])

    #expect(store.cachedEntryCount == 0)
    #expect(store.highlightedCode(rowID: "row", codeBlock: block) == nil)
  }
}

private func codeBlock(id: String, code: String) -> AssistantRenderBlock.CodeBlock {
  AssistantRenderBlock.CodeBlock(
    id: AssistantRenderBlock.BlockID(rawValue: id),
    language: "js",
    text: code,
    isClosed: true
  )
}

private func combinedTextBlocks(_ blocks: [NativeMarkdownBlock]) -> NSAttributedString {
  let result = NSMutableAttributedString()
  for block in blocks {
    guard case .text(let attributedString) = block else {
      continue
    }
    if result.length > 0 {
      result.append(NSAttributedString(string: "\n"))
    }
    result.append(attributedString)
  }
  return result
}

private func tableBlock(in blocks: [NativeMarkdownBlock]) throws -> NativeMarkdownTable {
  for block in blocks {
    if case .table(let table) = block {
      return table
    }
  }
  Issue.record("Expected table block")
  throw TestFailure()
}

private struct TestFailure: Error {}

private func skillMessage(
  content: String,
  name: String,
  scope: SkillScope = .project,
  description: String,
  metadata: SkillInterfaceMetadata? = nil
) -> UserTurnMessage {
  let skillContent = "---\nname: \(name)\ndescription: \(description)\n---\nInstructions"
  let skill = ActivatedSkill(
    id: SkillID(scope: scope, name: name),
    portablePath: scope == .project
      ? ".agents/skills/\(name)/SKILL.md"
      : "$HOME/.agents/skills/\(name)/SKILL.md",
    contentHash: ChatAttachmentStore.contentSHA256(for: Data(skillContent.utf8)),
    content: skillContent,
    interfaceMetadata: metadata
  )
  let mentions = allRanges(of: "$\(name)", in: content).map {
    ActivatedSkillMention(id: skill.id, range: $0)
  }
  return UserTurnMessage(
    content: content,
    promptContext: CurrentPromptContext.empty(.focusedFileDefault)
      .appendingActivatedSkills([skill]),
    activatedSkillMentions: mentions
  )
}

private func allRanges(of token: String, in text: String) -> [NSRange] {
  let source = text as NSString
  var result: [NSRange] = []
  var searchRange = NSRange(location: 0, length: source.length)
  while searchRange.length > 0 {
    let range = source.range(of: token, options: [], range: searchRange)
    guard range.location != NSNotFound else {
      break
    }
    result.append(range)
    let nextLocation = NSMaxRange(range)
    searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
  }
  return result
}

extension NSAttributedString {
  fileprivate func hasLink(inText text: String) -> Bool {
    attribute(.link, inText: text) != nil
  }

  fileprivate func hasUnderline(inText text: String) -> Bool {
    attribute(.underlineStyle, inText: text) != nil
  }

  fileprivate func hasLinkColor(inText text: String) -> Bool {
    foregroundColor(inText: text) == NSColor.linkColor
  }

  fileprivate func foregroundColor(inText text: String) -> NSColor? {
    attribute(.foregroundColor, inText: text) as? NSColor
  }

  fileprivate func hasBackgroundColor(inText text: String) -> Bool {
    attribute(.backgroundColor, inText: text) != nil
  }

  fileprivate func fontSize(inText text: String) -> CGFloat {
    guard let font = attribute(.font, inText: text) as? NSFont else {
      return 0
    }
    return font.pointSize
  }

  fileprivate func font(inText text: String) -> NSFont? {
    attribute(.font, inText: text) as? NSFont
  }

  fileprivate func paragraphStyle(inText text: String) -> NSParagraphStyle? {
    attribute(.paragraphStyle, inText: text) as? NSParagraphStyle
  }

  fileprivate func hasFontTrait(_ trait: NSFontTraitMask, inText text: String) -> Bool {
    guard let font = attribute(.font, inText: text) as? NSFont else {
      return false
    }
    return NSFontManager.shared.traits(of: font).contains(trait)
  }

  fileprivate func hasMonospacedFont(inText text: String) -> Bool {
    guard let font = attribute(.font, inText: text) as? NSFont else {
      return false
    }
    return font.fontDescriptor.symbolicTraits.contains(.monoSpace)
  }

  fileprivate func attribute(_ key: NSAttributedString.Key, inText text: String) -> Any? {
    let range = (string as NSString).range(of: text)
    guard range.location != NSNotFound else {
      return nil
    }
    return attribute(key, at: range.location, effectiveRange: nil)
  }
}
