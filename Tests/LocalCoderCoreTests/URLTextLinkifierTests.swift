import Foundation
import Testing

@testable import LocalCoderCore

struct URLTextLinkifierTests {
  @Test
  func detectsSingleHTTPSURL() throws {
    let text = "Read https://example.com/path?q=1 for details."

    let links = URLTextLinkifier.links(in: text)

    #expect(linkTexts(in: text, links: links) == ["https://example.com/path?q=1"])
    #expect(links.map(\.url.absoluteString) == ["https://example.com/path?q=1"])
  }

  @Test
  func detectsMultipleURLs() {
    let text = "Open https://example.com and http://localhost:3000/status"

    let links = URLTextLinkifier.links(in: text)

    #expect(
      linkTexts(in: text, links: links) == [
        "https://example.com",
        "http://localhost:3000/status",
      ])
  }

  @Test
  func excludesTrailingPunctuation() {
    let text = "Docs: https://example.com/a, https://example.com/b. https://example.com/c]"

    let links = URLTextLinkifier.links(in: text)

    #expect(
      linkTexts(in: text, links: links) == [
        "https://example.com/a",
        "https://example.com/b",
        "https://example.com/c",
      ])
  }

  @Test
  func keepsBalancedURLParenthesesButTrimsWrapperParenthesis() {
    let text = "See https://example.com/a(b) and (https://example.com/wrapped)."

    let links = URLTextLinkifier.links(in: text)

    #expect(
      linkTexts(in: text, links: links) == [
        "https://example.com/a(b)",
        "https://example.com/wrapped",
      ])
  }

  @Test
  func rejectsNonWebSchemesAndBareDomains() {
    let text = "Ignore file:///tmp/a mailto:user@example.com and example.com"

    let links = URLTextLinkifier.links(in: text)

    #expect(links.isEmpty)
  }

  @Test
  func attributedStringPreservesVisibleTextAndAppliesLinkAttribute() {
    let text = "Read https://example.com/path?q=1."

    let attributedText = URLTextLinkifier.attributedString(for: text)

    #expect(String(attributedText.characters) == text)
    #expect(linkURLs(in: attributedText) == ["https://example.com/path?q=1"])
  }

  private func linkTexts(in text: String, links: [DetectedURLTextLink]) -> [String] {
    links.map { String(text[$0.range]) }
  }

  private func linkURLs(in attributedText: AttributedString) -> [String] {
    attributedText.runs.compactMap { run in
      run.link?.absoluteString
    }
  }
}
