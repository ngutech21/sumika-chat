import AppKit
import Testing

@testable import SumikaApp
@testable import SumikaCore

@MainActor
struct NativeTranscriptTextRenderingTests {
  @Test
  func markdownRendererStylesInlineMarkdownAndLists() {
    let rendered = NativeTranscriptMarkdownRenderer.attributedString(
      for: """
        # Title
        - **bold**
        - *italic*
        `code`
        """
    )

    #expect(rendered.string.contains("Title"))
    #expect(rendered.string.contains("• bold"))
    #expect(rendered.string.contains("• italic"))
    #expect(rendered.string.contains("code"))
    #expect(rendered.hasFontTrait(.boldFontMask, inText: "Title"))
    #expect(rendered.hasFontTrait(.boldFontMask, inText: "bold"))
    #expect(rendered.hasFontTrait(.italicFontMask, inText: "italic"))
    #expect(rendered.hasMonospacedFont(inText: "code"))
    #expect(rendered.hasBackgroundColor(inText: "code"))
    #expect(rendered.fontSize(inText: "Title") > NSFont.systemFontSize)
  }

  @Test
  func markdownRendererAddsLinkAttributes() {
    let rendered = NativeTranscriptMarkdownRenderer.attributedString(
      for: "[Sumika](https://example.com) and https://sumika.local"
    )

    #expect(rendered.hasLink(inText: "Sumika"))
    #expect(rendered.hasLink(inText: "https://sumika.local"))
    #expect(rendered.hasUnderline(inText: "Sumika"))
    #expect(rendered.hasLinkColor(inText: "https://sumika.local"))
  }

  @Test
  func malformedMarkdownRemainsReadableAndPlainLinksStillWork() {
    let rendered = NativeTranscriptMarkdownRenderer.attributedString(
      for: "[broken](http:// and https://sumika.local"
    )

    #expect(rendered.string.contains("[broken](http://"))
    #expect(rendered.hasLink(inText: "https://sumika.local"))
  }

  @Test
  func markdownRendererHandlesNestedOrderedAndUnorderedLists() {
    let rendered = NativeTranscriptMarkdownRenderer.attributedString(
      for: """
        1. Parent
           - Child
        2. Next
        """
    )

    #expect(rendered.string.contains("1. Parent"))
    #expect(rendered.string.contains("  • Child"))
    #expect(rendered.string.contains("2. Next"))
  }

  @Test
  func markdownRendererKeepsTablesReadableAndStylesHeader() {
    let rendered = NativeTranscriptMarkdownRenderer.attributedString(
      for: """
        | Name | Value |
        | --- | --- |
        | Model | Gemma |
        | State | Ready |
        """
    )

    #expect(rendered.string.contains("Name | Value"))
    #expect(rendered.string.contains("Model | Gemma"))
    #expect(rendered.string.contains("State | Ready"))
    #expect(rendered.hasFontTrait(.boldFontMask, inText: "Name"))
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
    #expect(table.rows[1][1].attributedString.hasBackgroundColor(inText: "gemma"))
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
    let rendered = NativeTranscriptMarkdownRenderer.attributedString(
      for: "> quoted **text**"
    )

    #expect(rendered.string.contains("> quoted text"))
    #expect(rendered.hasFontTrait(.boldFontMask, inText: "text"))
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
          style: .keyword,
          captureName: "keyword"
        ),
        HighlightSpan(
          range: HighlightTextRange(location: 12, length: 4),
          style: .string,
          captureName: "string"
        ),
      ]
    )

    let rendered = NativeTranscriptCodeRenderer.attributedString(for: highlighted)

    #expect(rendered.foregroundColor(inText: "let") == NSColor.systemPink)
    #expect(rendered.foregroundColor(inText: "\"hi\"") == NSColor.systemGreen)
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
        highlightedCode: .plain(code: "let old = 1", language: .javascript),
        cacheHit: false
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
        highlightedCode: .plain(code: "let first = 1", language: .javascript),
        cacheHit: false
      ),
      for: firstKey,
      rowID: "first-row",
      onUpdate: { updatedRows.append($0) }
    )
    let secondAccepted = store.completeHighlight(
      CodeHighlightResult(
        blockID: CodeHighlightBlockID(rawValue: "second-row#block"),
        version: secondKey.version,
        highlightedCode: .plain(code: "let second = 2", language: .javascript),
        cacheHit: false
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
        highlightedCode: .plain(code: "let value = 1", language: .javascript),
        cacheHit: false
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
        highlightedCode: .plain(code: "let value = 1", language: .javascript),
        cacheHit: false
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
