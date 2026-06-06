import Testing

@testable import LocalCoderCore

struct CodeHighlightingTests {
  @Test
  func normalizesFenceLanguageAliases() {
    #expect(CodeLanguage(fenceLanguage: "json") == .json)
    #expect(CodeLanguage(fenceLanguage: "py") == .python)
    #expect(CodeLanguage(fenceLanguage: "python3") == .python)
    #expect(CodeLanguage(fenceLanguage: "sh") == .bash)
    #expect(CodeLanguage(fenceLanguage: "shell") == .bash)
    #expect(CodeLanguage(fenceLanguage: "zsh") == .bash)
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
