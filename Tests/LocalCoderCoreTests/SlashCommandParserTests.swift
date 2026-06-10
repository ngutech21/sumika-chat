import Testing

@testable import LocalCoderCore

struct SlashCommandParserTests {
  @Test
  func parsesPreviewPath() {
    let parser = SlashCommandParser()

    #expect(parser.parse("/preview index.html") == .preview(path: "index.html"))
    #expect(parser.parse("  /preview docs/page.htm  ") == .preview(path: "docs/page.htm"))
  }

  @Test
  func rejectsPreviewWithoutPath() {
    let parser = SlashCommandParser()

    #expect(parser.parse("/preview") == nil)
    #expect(parser.parse("/preview   ") == nil)
  }

  @Test
  func rejectsCommandsThatOnlySharePrefix() {
    let parser = SlashCommandParser()

    #expect(parser.parse("/previewer index.html") == nil)
    #expect(parser.parse("preview index.html") == nil)
  }
}
