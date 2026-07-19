import Foundation
import SumikaCore
import Testing

@testable import SumikaApp

struct TreeSitterCodeHighlightingBackendTests {
  @Test
  func unsupportedLanguageFallsBackToPlainCode() async throws {
    let backend = SwiftTreeSitterCodeHighlightingBackend()

    let highlighted = try await backend.highlight(
      code: "let value = 42",
      language: nil,
      theme: .chat
    )

    #expect(highlighted == .plain(code: "let value = 42", language: nil))
  }

  @Test
  func emptyCodeFallsBackToPlainCode() async throws {
    let backend = SwiftTreeSitterCodeHighlightingBackend()

    let highlighted = try await backend.highlight(
      code: "",
      language: .json,
      theme: .chat
    )

    #expect(highlighted == .plain(code: "", language: .json))
  }

  @Test
  func highlightsJSONCode() async throws {
    let highlighted = try await SwiftTreeSitterCodeHighlightingBackend().highlight(
      code: #"{"name": "value", "count": 2}"#,
      language: .json,
      theme: .chat
    )

    expect(highlighted, contains: .string)
    expect(highlighted, contains: .number)
  }

  @Test
  func highlightsPythonCode() async throws {
    let highlighted = try await SwiftTreeSitterCodeHighlightingBackend().highlight(
      code: """
        def greet():
            # note
            return "hi"
        """,
      language: .python,
      theme: .chat
    )

    expect(highlighted, contains: .keyword)
    expect(highlighted, contains: .comment)
    expect(highlighted, contains: .string)
  }

  @Test
  func highlightsBashCode() async throws {
    let highlighted = try await SwiftTreeSitterCodeHighlightingBackend().highlight(
      code: """
        echo "hi" # note
        """,
      language: .bash,
      theme: .chat
    )

    expect(highlighted, contains: .comment)
    expect(highlighted, contains: .string)
  }

  @Test
  func highlightsCSSCode() async throws {
    let highlighted = try await SwiftTreeSitterCodeHighlightingBackend().highlight(
      code: """
        body {
          color: #87CEEB;
          width: 800px;
          margin: 0;
          /* note */
        }
        """,
      language: .css,
      theme: .chat
    )

    #expect(highlighted.language == .css)
    expect(highlighted, contains: .property)
    expect(highlighted, contains: .number)
    expect(highlighted, contains: .comment)
    #expect(highlighted.containsText("800px", styledAs: .number))
  }

  @Test
  func highlightsNumberedCSSCodeFromShowFileOutput() async throws {
    let code = """
      1: body {
      2:   display: flex;
      3:   background-color: #87CEEB;
      4:   margin: 0;
      5:   /* note */
      6: }
      """
    let highlighted = try await SwiftTreeSitterCodeHighlightingBackend().highlight(
      code: code,
      language: .css,
      theme: .chat
    )

    #expect(highlighted.language == .css)
    expect(highlighted, contains: .property)
    expect(highlighted, contains: .number)
    expect(highlighted, contains: .comment)
    #expect(
      highlighted.containsText("display", styledAs: .property),
      "Expected property highlighting to map back onto the original numbered code."
    )
  }

  @Test
  func splitsNumberedMultilineCSSHighlightsAcrossLinePrefixes() async throws {
    let code = """
      1: body {
      2:   /*
      3:   note
      4:   */
      5: }
      """
    let highlighted = try await SwiftTreeSitterCodeHighlightingBackend().highlight(
      code: code,
      language: .css,
      theme: .chat
    )

    #expect(highlighted.containsStyledSubstring("/*", styledAs: .comment))
    #expect(highlighted.containsStyledSubstring("note", styledAs: .comment))
    #expect(highlighted.containsStyledSubstring("*/", styledAs: .comment))
    #expect(!highlighted.containsStyledSubstring("3:   note", styledAs: .comment))
  }

  @Test
  func highlightsJavaScriptThroughTypeScriptParser() async throws {
    let highlighted = try await SwiftTreeSitterCodeHighlightingBackend().highlight(
      code: """
        function greet(name) {
          const value = "hi"
          return value
        }
        """,
      language: .javascript,
      theme: .chat
    )

    #expect(highlighted.language == .javascript)
    expect(highlighted, contains: .keyword)
    expect(highlighted, contains: .string)
  }

  @Test
  func highlightsHTMLCode() async throws {
    let highlighted = try await SwiftTreeSitterCodeHighlightingBackend().highlight(
      code: """
        <!DOCTYPE html>
        <html lang="en">
          <body class="page">Hello</body>
        </html>
        """,
      language: .html,
      theme: .chat
    )

    expect(highlighted, contains: .type)
    expect(highlighted, contains: .attribute)
    expect(highlighted, contains: .string)
  }

  @Test
  func highlightsTypeScriptCode() async throws {
    let highlighted = try await SwiftTreeSitterCodeHighlightingBackend().highlight(
      code: """
        const count: number = 1
        """,
      language: .typescript,
      theme: .chat
    )

    expect(highlighted, contains: .keyword)
    expect(highlighted, contains: .type)
    expect(highlighted, contains: .number)
  }
  private func expect(
    _ highlighted: HighlightedCode,
    contains style: CodeHighlightStyle,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(
      highlighted.spans.contains { $0.style == style },
      "Expected \(style.rawValue) span in \(highlighted.spans)",
      sourceLocation: sourceLocation
    )
  }
}

extension HighlightedCode {
  fileprivate func containsText(_ text: String, styledAs style: CodeHighlightStyle) -> Bool {
    spans.contains { span in
      guard span.style == style, let range = Range(span.range.nsRange, in: code) else {
        return false
      }
      return code[range] == text
    }
  }

  fileprivate func containsStyledSubstring(
    _ text: String,
    styledAs style: CodeHighlightStyle
  ) -> Bool {
    spans.contains { span in
      guard span.style == style, let range = Range(span.range.nsRange, in: code) else {
        return false
      }
      return code[range].contains(text)
    }
  }
}
