import Testing

@testable import SumikaCore

struct CodeHighlightingTests {
  @Test
  func normalizesFenceLanguageAliases() {
    #expect(CodeLanguage(fenceLanguage: "json") == .json)
    #expect(CodeLanguage(fenceLanguage: "py") == .python)
    #expect(CodeLanguage(fenceLanguage: "python3") == .python)
    #expect(CodeLanguage(fenceLanguage: "sh") == .bash)
    #expect(CodeLanguage(fenceLanguage: "shell") == .bash)
    #expect(CodeLanguage(fenceLanguage: "zsh") == .bash)
    #expect(CodeLanguage(fenceLanguage: "css") == .css)
    #expect(CodeLanguage(fenceLanguage: "scss") == nil)
    #expect(CodeLanguage(fenceLanguage: "html") == .html)
    #expect(CodeLanguage(fenceLanguage: "htm") == .html)
    #expect(CodeLanguage(fenceLanguage: "js") == .javascript)
    #expect(CodeLanguage(fenceLanguage: "mjs") == .javascript)
    #expect(CodeLanguage(fenceLanguage: "cjs") == .javascript)
    #expect(CodeLanguage(fenceLanguage: "ts") == .typescript)
    #expect(CodeLanguage(fenceLanguage: "tsx") == nil)
    #expect(CodeLanguage(fenceLanguage: "swift") == nil)
  }

  @Test
  func normalizesFilePathExtensions() {
    #expect(CodeLanguage(filePath: "hello.py") == .python)
    #expect(CodeLanguage(filePath: "scripts/deploy.sh") == .bash)
    #expect(CodeLanguage(filePath: "style.css") == .css)
    #expect(CodeLanguage(filePath: "styles/app.scss") == nil)
    #expect(CodeLanguage(filePath: "site/index.html") == .html)
    #expect(CodeLanguage(filePath: "site/partial.htm") == .html)
    #expect(CodeLanguage(filePath: "package.json") == .json)
    #expect(CodeLanguage(filePath: "src/app.js") == .javascript)
    #expect(CodeLanguage(filePath: "src/app.ts") == .typescript)
    #expect(CodeLanguage(filePath: "src/app.tsx") == nil)
    #expect(CodeLanguage(filePath: "README.md") == nil)
  }

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

  @Test
  func streamingOpenBlockHighlightsOnlyStablePrefix() async {
    let backend = SpyCodeHighlightingBackend()
    let highlighter = StreamingCodeHighlighter(backend: backend, debounce: .zero)

    let result = await highlighter.highlight(
      CodeHighlightRequest(
        blockID: CodeHighlightBlockID(rawValue: "block-1"),
        version: 1,
        code: "print(\"hi\")\nret",
        language: .python,
        isClosed: false
      )
    )

    #expect(result?.highlightedCode.code == "print(\"hi\")\nret")
    #expect(result?.highlightedCode.spans.map(\.range.upperBound).max() == 12)
    #expect(await backend.requestedCodes() == ["print(\"hi\")\n"])
  }

  @Test
  func streamingOpenBlockWithoutStableLineStaysPlain() async {
    let backend = SpyCodeHighlightingBackend()
    let highlighter = StreamingCodeHighlighter(backend: backend, debounce: .zero)

    let result = await highlighter.highlight(
      CodeHighlightRequest(
        blockID: CodeHighlightBlockID(rawValue: "block-1"),
        version: 1,
        code: "ret",
        language: .python,
        isClosed: false
      )
    )

    #expect(result?.highlightedCode == .plain(code: "ret", language: .python))
    #expect(await backend.requestedCodes().isEmpty)
  }

  @Test
  func streamingClosedBlockHighlightsFullCode() async {
    let backend = SpyCodeHighlightingBackend()
    let highlighter = StreamingCodeHighlighter(backend: backend, debounce: .zero)

    let result = await highlighter.highlight(
      CodeHighlightRequest(
        blockID: CodeHighlightBlockID(rawValue: "block-1"),
        version: 1,
        code: "print(\"hi\")",
        language: .python,
        isClosed: true
      )
    )

    #expect(result?.highlightedCode.code == "print(\"hi\")")
    #expect(result?.highlightedCode.spans.map(\.range.upperBound).max() == 11)
    #expect(result?.cacheHit == false)
    #expect(await backend.requestedCodes() == ["print(\"hi\")"])
  }

  @Test
  func streamingClosedBlockUsesCache() async {
    let backend = SpyCodeHighlightingBackend()
    let highlighter = StreamingCodeHighlighter(backend: backend, debounce: .zero)
    let blockID = CodeHighlightBlockID(rawValue: "block-1")
    let code = #"{"name":"value"}"#

    let first = await highlighter.highlight(
      CodeHighlightRequest(
        blockID: blockID,
        version: 1,
        code: code,
        language: .json,
        isClosed: true
      )
    )
    let second = await highlighter.highlight(
      CodeHighlightRequest(
        blockID: blockID,
        version: 2,
        code: code,
        language: .json,
        isClosed: true
      )
    )

    #expect(first?.cacheHit == false)
    #expect(second?.cacheHit == true)
    #expect(await backend.requestedCodes() == [code])
  }

  @Test
  func streamingOpenBlocksAreNotCached() async {
    let backend = SpyCodeHighlightingBackend()
    let highlighter = StreamingCodeHighlighter(backend: backend, debounce: .zero)
    let blockID = CodeHighlightBlockID(rawValue: "block-1")
    let code = "echo \"hi\"\n"

    _ = await highlighter.highlight(
      CodeHighlightRequest(
        blockID: blockID,
        version: 1,
        code: code,
        language: .bash,
        isClosed: false
      )
    )
    _ = await highlighter.highlight(
      CodeHighlightRequest(
        blockID: blockID,
        version: 2,
        code: code,
        language: .bash,
        isClosed: false
      )
    )

    #expect(await backend.requestedCodes() == [code, code])
  }

  @Test
  func streamingStaleResultsAreDiscarded() async throws {
    let backend = SpyCodeHighlightingBackend(delay: .milliseconds(30))
    let highlighter = StreamingCodeHighlighter(backend: backend, debounce: .zero)
    let blockID = CodeHighlightBlockID(rawValue: "block-1")

    let firstTask = Task {
      await highlighter.highlight(
        CodeHighlightRequest(
          blockID: blockID,
          version: 1,
          code: "echo \"old\"\n",
          language: .bash,
          isClosed: false
        )
      )
    }
    try await Task.sleep(for: .milliseconds(5))
    let second = await highlighter.highlight(
      CodeHighlightRequest(
        blockID: blockID,
        version: 2,
        code: "echo \"new\"\n",
        language: .bash,
        isClosed: false
      )
    )
    let first = await firstTask.value

    #expect(first == nil)
    #expect(second?.version == 2)
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

private actor SpyCodeHighlightingBackend: CodeHighlightingBackend {
  private let delay: Duration?
  private var codes: [String] = []

  init(delay: Duration? = nil) {
    self.delay = delay
  }

  func highlight(
    code: String,
    language: CodeLanguage?,
    theme: CodeHighlightTheme
  ) async throws -> HighlightedCode {
    if let delay {
      try await Task.sleep(for: delay)
    }

    codes.append(code)
    return HighlightedCode(
      code: code,
      language: language,
      spans: [
        HighlightSpan(
          range: HighlightTextRange(location: 0, length: code.utf16.count),
          style: .keyword,
          captureName: "keyword"
        )
      ]
    )
  }

  func requestedCodes() -> [String] {
    codes
  }
}
