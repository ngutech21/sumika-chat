import Foundation
import SumikaCore

nonisolated public protocol CodeHighlightingBackend: Sendable {
  func highlight(
    code: String,
    language: CodeLanguage?,
    theme: CodeHighlightTheme
  ) async throws -> HighlightedCode
}

nonisolated extension CodeLanguage {
  public var displayName: String {
    switch self {
    case .bash:
      "Bash"
    case .css:
      "CSS"
    case .html:
      "HTML"
    case .javascript:
      "JavaScript"
    case .json:
      "JSON"
    case .python:
      "Python"
    case .typescript:
      "TypeScript"
    }
  }
}

nonisolated public struct HighlightedCode: Equatable, Sendable {
  public var code: String
  public var language: CodeLanguage?
  public var spans: [HighlightSpan]

  public init(
    code: String,
    language: CodeLanguage?,
    spans: [HighlightSpan]
  ) {
    self.code = code
    self.language = language
    self.spans = spans
  }

  public static func plain(code: String, language: CodeLanguage?) -> HighlightedCode {
    HighlightedCode(code: code, language: language, spans: [])
  }
}

nonisolated public struct HighlightSpan: Equatable, Sendable {
  public var range: HighlightTextRange
  public var style: CodeHighlightStyle
  public var captureName: String

  public init(
    range: HighlightTextRange,
    style: CodeHighlightStyle,
    captureName: String
  ) {
    self.range = range
    self.style = style
    self.captureName = captureName
  }
}

nonisolated public struct HighlightTextRange: Equatable, Sendable {
  public var location: Int
  public var length: Int

  public init(location: Int, length: Int) {
    self.location = location
    self.length = length
  }

  public var upperBound: Int {
    location + length
  }

  public var nsRange: NSRange {
    NSRange(location: location, length: length)
  }
}

nonisolated public enum CodeHighlightStyle: String, Equatable, Hashable, Sendable {
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

nonisolated public struct CodeHighlightTheme: Equatable, Hashable, Sendable {
  public var stylesByCapturePrefix: [String: CodeHighlightStyle]

  public init(stylesByCapturePrefix: [String: CodeHighlightStyle]) {
    self.stylesByCapturePrefix = stylesByCapturePrefix
  }

  public func style(for captureName: String) -> CodeHighlightStyle? {
    let components = captureName.split(separator: ".").map(String.init)
    for componentCount in stride(from: components.count, through: 1, by: -1) {
      let prefix = components.prefix(componentCount).joined(separator: ".")
      if let style = stylesByCapturePrefix[prefix] {
        return style
      }
    }
    return nil
  }

  public static let chat = CodeHighlightTheme(
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

nonisolated public struct CodeHighlightBlockID: Equatable, Hashable, Sendable {
  public var rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

nonisolated public struct CodeHighlightRequest: Equatable, Sendable {
  public var blockID: CodeHighlightBlockID
  public var version: Int
  public var code: String
  public var language: CodeLanguage?
  public var theme: CodeHighlightTheme
  public var isClosed: Bool

  public init(
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

nonisolated public struct CodeHighlightResult: Equatable, Sendable {
  public var blockID: CodeHighlightBlockID
  public var version: Int
  public var highlightedCode: HighlightedCode
  public var cacheHit: Bool

  public init(
    blockID: CodeHighlightBlockID,
    version: Int,
    highlightedCode: HighlightedCode,
    cacheHit: Bool
  ) {
    self.blockID = blockID
    self.version = version
    self.highlightedCode = highlightedCode
    self.cacheHit = cacheHit
  }
}

public actor StreamingCodeHighlighter {
  private let backend: any CodeHighlightingBackend
  private let debounce: Duration
  private let highlighterVersion: String
  private var latestVersionsByBlockID: [CodeHighlightBlockID: Int] = [:]
  private var cache: [CodeHighlightCacheKey: HighlightedCode] = [:]

  public init(
    backend: any CodeHighlightingBackend,
    debounce: Duration = .milliseconds(150),
    highlighterVersion: String = "tree-sitter-v1"
  ) {
    self.backend = backend
    self.debounce = debounce
    self.highlighterVersion = highlighterVersion
  }

  public func highlight(_ request: CodeHighlightRequest) async -> CodeHighlightResult? {
    latestVersionsByBlockID[request.blockID] = request.version

    guard !request.code.isEmpty, request.language != nil else {
      return currentResult(
        for: request,
        highlightedCode: .plain(code: request.code, language: request.language),
        cacheHit: false
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
        return currentResult(for: request, highlightedCode: cachedHighlight, cacheHit: true)
      }

      let highlightedCode = await highlightCode(
        request.code,
        language: request.language,
        theme: request.theme
      )
      cache[cacheKey] = highlightedCode
      return currentResult(for: request, highlightedCode: highlightedCode, cacheHit: false)
    }

    guard let stablePrefixEndIndex = request.code.lastStableLineEndIndex else {
      return currentResult(
        for: request,
        highlightedCode: .plain(code: request.code, language: request.language),
        cacheHit: false
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

    return currentResult(for: request, highlightedCode: highlightedCode, cacheHit: false)
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
    highlightedCode: HighlightedCode,
    cacheHit: Bool
  ) -> CodeHighlightResult? {
    guard isCurrent(request) else {
      return nil
    }

    return CodeHighlightResult(
      blockID: request.blockID,
      version: request.version,
      highlightedCode: highlightedCode,
      cacheHit: cacheHit
    )
  }

  private func isCurrent(_ request: CodeHighlightRequest) -> Bool {
    latestVersionsByBlockID[request.blockID] == request.version
  }
}

nonisolated public struct CodeHighlightCacheKey: Equatable, Hashable, Sendable {
  public var language: CodeLanguage?
  public var codeHash: UInt64
  public var theme: CodeHighlightTheme
  public var highlighterVersion: String

  public init(
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

  public init(
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
