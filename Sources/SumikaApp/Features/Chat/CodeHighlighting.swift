import Foundation
import SumikaCore

nonisolated protocol CodeHighlightingBackend: Sendable {
  func highlight(
    code: String,
    language: CodeLanguage?,
    theme: CodeHighlightTheme
  ) async throws -> HighlightedCode
}

nonisolated struct HighlightedCode: Equatable, Sendable {
  var code: String
  var language: CodeLanguage?
  var spans: [HighlightSpan]

  static func plain(code: String, language: CodeLanguage?) -> HighlightedCode {
    HighlightedCode(code: code, language: language, spans: [])
  }
}

nonisolated struct HighlightSpan: Equatable, Sendable {
  var range: HighlightTextRange
  var style: CodeHighlightStyle
}

nonisolated struct HighlightTextRange: Equatable, Sendable {
  var location: Int
  var length: Int

  init(location: Int, length: Int) {
    self.location = location
    self.length = length
  }

  var upperBound: Int {
    location + length
  }

  var nsRange: NSRange {
    NSRange(location: location, length: length)
  }
}

nonisolated enum CodeHighlightStyle: String, Equatable, Hashable, Sendable {
  case attribute
  case comment
  case constant
  case function
  case keyword
  case number
  case operatorToken
  case property
  case punctuation
  case string
  case type
  case variable
}

nonisolated struct CodeHighlightTheme: Equatable, Hashable, Sendable {
  var stylesByCapturePrefix: [String: CodeHighlightStyle]

  func style(for captureName: String) -> CodeHighlightStyle? {
    let components = captureName.split(separator: ".").map(String.init)
    for componentCount in stride(from: components.count, through: 1, by: -1) {
      let prefix = components.prefix(componentCount).joined(separator: ".")
      if let style = stylesByCapturePrefix[prefix] {
        return style
      }
    }
    return nil
  }

  static let chat = CodeHighlightTheme(
    stylesByCapturePrefix: [
      "attribute": .attribute,
      "boolean": .constant,
      "comment": .comment,
      "constant": .constant,
      "constructor": .function,
      "doctype": .keyword,
      "function": .function,
      "keyword": .keyword,
      "label": .property,
      "number": .number,
      "operator": .operatorToken,
      "property": .property,
      "punctuation": .punctuation,
      "string": .string,
      "tag": .type,
      "tag.delimiter": .punctuation,
      "type": .type,
      "unit": .number,
      "variable": .variable,
    ]
  )
}

nonisolated struct CodeHighlightBlockID: Equatable, Hashable, Sendable {
  var rawValue: String
}

nonisolated struct CodeHighlightRequest: Equatable, Sendable {
  var blockID: CodeHighlightBlockID
  var version: Int
  var code: String
  var language: CodeLanguage?
  var theme: CodeHighlightTheme
  var isClosed: Bool

  init(
    blockID: CodeHighlightBlockID,
    version: Int,
    code: String,
    language: CodeLanguage?,
    theme: CodeHighlightTheme = .chat,
    isClosed: Bool
  ) {
    self.blockID = blockID
    self.version = version
    self.code = code
    self.language = language
    self.theme = theme
    self.isClosed = isClosed
  }
}

nonisolated struct CodeHighlightResult: Equatable, Sendable {
  var blockID: CodeHighlightBlockID
  var version: Int
  var highlightedCode: HighlightedCode
}

actor StreamingCodeHighlighter {
  private let backend: any CodeHighlightingBackend
  private let debounce: Duration
  private let highlighterVersion: String
  private var latestVersionsByBlockID: [CodeHighlightBlockID: Int] = [:]
  private var cache: [CodeHighlightCacheKey: HighlightedCode] = [:]

  init(
    backend: any CodeHighlightingBackend,
    debounce: Duration = .milliseconds(150),
    highlighterVersion: String = "tree-sitter-v1"
  ) {
    self.backend = backend
    self.debounce = debounce
    self.highlighterVersion = highlighterVersion
  }

  func highlight(_ request: CodeHighlightRequest) async -> CodeHighlightResult? {
    latestVersionsByBlockID[request.blockID] = request.version

    guard !request.code.isEmpty, request.language != nil else {
      return currentResult(
        for: request,
        highlightedCode: .plain(code: request.code, language: request.language)
      )
    }

    if request.isClosed {
      let cacheKey = CodeHighlightCacheKey(
        code: request.code,
        language: request.language,
        theme: request.theme,
        highlighterVersion: highlighterVersion
      )
      if let cachedHighlight = cache[cacheKey] {
        return currentResult(for: request, highlightedCode: cachedHighlight)
      }

      let highlightedCode = await highlightCode(
        request.code,
        language: request.language,
        theme: request.theme
      )
      cache[cacheKey] = highlightedCode
      return currentResult(for: request, highlightedCode: highlightedCode)
    }

    guard let stablePrefixEndIndex = request.code.lastStableLineEndIndex else {
      return currentResult(
        for: request,
        highlightedCode: .plain(code: request.code, language: request.language)
      )
    }

    do {
      try await Task.sleep(for: debounce)
    } catch {
      return nil
    }

    guard isCurrent(request) else {
      return nil
    }

    let stablePrefix = String(request.code[..<stablePrefixEndIndex])
    let highlightedPrefix = await highlightCode(
      stablePrefix,
      language: request.language,
      theme: request.theme
    )
    let highlightedCode = HighlightedCode(
      code: request.code,
      language: request.language,
      spans: highlightedPrefix.spans
    )

    return currentResult(for: request, highlightedCode: highlightedCode)
  }

  private func highlightCode(
    _ code: String,
    language: CodeLanguage?,
    theme: CodeHighlightTheme
  ) async -> HighlightedCode {
    do {
      return try await backend.highlight(code: code, language: language, theme: theme)
    } catch {
      return .plain(code: code, language: language)
    }
  }

  private func currentResult(
    for request: CodeHighlightRequest,
    highlightedCode: HighlightedCode
  ) -> CodeHighlightResult? {
    guard isCurrent(request) else {
      return nil
    }

    return CodeHighlightResult(
      blockID: request.blockID,
      version: request.version,
      highlightedCode: highlightedCode
    )
  }

  private func isCurrent(_ request: CodeHighlightRequest) -> Bool {
    latestVersionsByBlockID[request.blockID] == request.version
  }
}

nonisolated struct CodeHighlightCacheKey: Equatable, Hashable, Sendable {
  var language: CodeLanguage?
  var codeHash: UInt64
  var theme: CodeHighlightTheme
  var highlighterVersion: String

  init(
    language: CodeLanguage?,
    codeHash: UInt64,
    theme: CodeHighlightTheme,
    highlighterVersion: String
  ) {
    self.language = language
    self.codeHash = codeHash
    self.theme = theme
    self.highlighterVersion = highlighterVersion
  }

  init(
    code: String,
    language: CodeLanguage?,
    theme: CodeHighlightTheme,
    highlighterVersion: String
  ) {
    self.init(
      language: language,
      codeHash: code.stableUTF8Hash,
      theme: theme,
      highlighterVersion: highlighterVersion
    )
  }
}

nonisolated extension String {
  fileprivate var lastStableLineEndIndex: String.Index? {
    guard let newlineIndex = lastIndex(of: "\n") else {
      return nil
    }
    return index(after: newlineIndex)
  }

  fileprivate var stableUTF8Hash: UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 1_099_511_628_211
    }
    return hash
  }
}
