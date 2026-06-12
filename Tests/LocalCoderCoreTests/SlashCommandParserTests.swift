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

  @Test
  func parsesShowPath() {
    let parser = SlashCommandParser()

    #expect(parser.parse("/show uv.lock") == .show(path: "uv.lock"))
    #expect(parser.parse("  /show Sources/App.swift  ") == .show(path: "Sources/App.swift"))
  }

  @Test
  func rejectsShowWithoutPath() {
    let parser = SlashCommandParser()

    #expect(parser.parse("/show") == nil)
    #expect(parser.parse("/show   ") == nil)
  }

  @Test
  func matchingByPrefixSuggestsCommands() {
    #expect(SlashCommandRegistry.matching(prefix: "s").map(\.name) == ["show"])
    #expect(SlashCommandRegistry.matching(prefix: "pre").map(\.name) == ["preview"])
    #expect(SlashCommandRegistry.matching(prefix: "SH").map(\.name) == ["show"])
    #expect(SlashCommandRegistry.matching(prefix: "").map(\.name) == ["show", "preview"])
    #expect(SlashCommandRegistry.matching(prefix: "zzz").isEmpty)
  }

  @Test
  func descriptorLookupIsExactAndCaseInsensitive() {
    #expect(SlashCommandRegistry.descriptor(named: "show")?.name == "show")
    #expect(SlashCommandRegistry.descriptor(named: "Preview")?.name == "preview")
    #expect(SlashCommandRegistry.descriptor(named: "previewer") == nil)
    #expect(SlashCommandRegistry.descriptor(named: "show")?.usage == "Usage: /show <path>")
  }
}
