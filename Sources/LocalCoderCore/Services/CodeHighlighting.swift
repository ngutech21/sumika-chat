import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterHTML
import TreeSitterJSON
import TreeSitterPython
import TreeSitterTypeScript

public protocol CodeHighlightingBackend: Sendable {
  func highlight(
    code: String,
    language: CodeLanguage?,
    theme: CodeHighlightTheme
  ) async throws -> HighlightedCode
}

public enum CodeLanguage: String, CaseIterable, Equatable, Hashable, Sendable {
  case bash
  case html
  case javascript
  case json
  case python
  case typescript

  public init?(fenceLanguage: String?) {
    guard
      let rawLanguage = fenceLanguage?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased(),
      !rawLanguage.isEmpty
    else {
      return nil
    }

    let normalizedLanguage = rawLanguage.split(whereSeparator: { $0 == " " || $0 == "\t" }).first
      .map(String.init)
    switch normalizedLanguage {
    case "bash", "sh", "shell", "zsh":
      self = .bash
    case "html", "htm":
      self = .html
    case "js", "javascript", "mjs", "cjs":
      self = .javascript
    case "json":
      self = .json
    case "py", "python", "python3":
      self = .python
    case "ts", "typescript":
      self = .typescript
    default:
      return nil
    }
  }

  public init?(filePath: String) {
    let trimmedPath = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPath.isEmpty else {
      return nil
    }

    let fileName = trimmedPath.split(separator: "/").last.map(String.init) ?? trimmedPath
    guard
      let dotIndex = fileName.lastIndex(of: "."),
      dotIndex < fileName.index(before: fileName.endIndex)
    else {
      return nil
    }

    self.init(fenceLanguage: String(fileName[fileName.index(after: dotIndex)...]))
  }

  public var displayName: String {
    switch self {
    case .bash:
      "Bash"
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

public struct HighlightedCode: Equatable, Sendable {
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

public struct HighlightSpan: Equatable, Sendable {
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

public struct HighlightTextRange: Equatable, Sendable {
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

public enum CodeHighlightStyle: String, Equatable, Hashable, Sendable {
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

public struct CodeHighlightTheme: Equatable, Hashable, Sendable {
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
      "variable": .variable,
    ]
  )
}

public struct CodeHighlightBlockID: Equatable, Hashable, Sendable {
  public var rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

public struct CodeHighlightRequest: Equatable, Sendable {
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

public struct CodeHighlightResult: Equatable, Sendable {
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

public struct CodeHighlightCacheKey: Equatable, Hashable, Sendable {
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

public actor SwiftTreeSitterCodeHighlightingBackend: CodeHighlightingBackend {
  private var configurations: [ParserLanguage: LanguageConfiguration] = [:]

  public init() {}

  public func highlight(
    code: String,
    language: CodeLanguage?,
    theme: CodeHighlightTheme = .chat
  ) async throws -> HighlightedCode {
    guard !code.isEmpty, let language else {
      return .plain(code: code, language: language)
    }

    do {
      return try highlightedCode(code: code, language: language, theme: theme)
    } catch {
      return .plain(code: code, language: language)
    }
  }

  private func highlightedCode(
    code: String,
    language: CodeLanguage,
    theme: CodeHighlightTheme
  ) throws -> HighlightedCode {
    let parserLanguage = ParserLanguage(codeLanguage: language)
    let configuration = try configuration(for: parserLanguage)
    let parser = Parser()
    try parser.setLanguage(configuration.language)

    guard
      let tree = parser.parse(code),
      let query = configuration.queries[.highlights]
    else {
      return .plain(code: code, language: language)
    }

    let ranges =
      query
      .execute(in: tree)
      .resolve(with: .init(string: code))
      .highlights()

    let spans = nonOverlappingSpans(
      from: ranges,
      codeUTF16Length: code.utf16.count,
      theme: theme
    )

    return HighlightedCode(code: code, language: language, spans: spans)
  }

  private func configuration(for language: ParserLanguage) throws -> LanguageConfiguration {
    if let configuration = configurations[language] {
      return configuration
    }

    let configuration = try language.configuration()
    configurations[language] = configuration
    return configuration
  }

  private func nonOverlappingSpans(
    from ranges: [NamedRange],
    codeUTF16Length: Int,
    theme: CodeHighlightTheme
  ) -> [HighlightSpan] {
    let candidateSpans = ranges.compactMap { namedRange -> HighlightSpan? in
      guard
        namedRange.range.location >= 0,
        namedRange.range.length > 0,
        namedRange.range.upperBound <= codeUTF16Length,
        let style = theme.style(for: namedRange.name)
      else {
        return nil
      }

      return HighlightSpan(
        range: HighlightTextRange(
          location: namedRange.range.location,
          length: namedRange.range.length
        ),
        style: style,
        captureName: namedRange.name
      )
    }

    let preferredSpans = candidateSpans.reversed()
    var selectedSpans: [HighlightSpan] = []

    for span in preferredSpans {
      let overlapsSelectedSpan = selectedSpans.contains { selectedSpan in
        span.range.location < selectedSpan.range.upperBound
          && selectedSpan.range.location < span.range.upperBound
      }

      if !overlapsSelectedSpan {
        selectedSpans.append(span)
      }
    }

    return selectedSpans.sorted {
      if $0.range.location != $1.range.location {
        return $0.range.location < $1.range.location
      }
      return $0.range.length < $1.range.length
    }
  }
}

private enum ParserLanguage: Hashable {
  case bash
  case html
  case json
  case python
  case typescript

  init(codeLanguage: CodeLanguage) {
    switch codeLanguage {
    case .bash:
      self = .bash
    case .html:
      self = .html
    case .javascript, .typescript:
      self = .typescript
    case .json:
      self = .json
    case .python:
      self = .python
    }
  }

  func configuration() throws -> LanguageConfiguration {
    let language: Language
    let name: String
    let bundleName: String

    switch self {
    case .bash:
      language = Language(language: tree_sitter_bash())
      name = "Bash"
      bundleName = "TreeSitterBash_TreeSitterBash"
    case .html:
      language = Language(language: tree_sitter_html())
      name = "HTML"
      bundleName = "TreeSitterHTML_TreeSitterHTML"
    case .json:
      language = Language(language: tree_sitter_json())
      name = "JSON"
      bundleName = "TreeSitterJSON_TreeSitterJSON"
    case .python:
      language = Language(language: tree_sitter_python())
      name = "Python"
      bundleName = "TreeSitterPython_TreeSitterPython"
    case .typescript:
      language = Language(language: tree_sitter_typescript())
      name = "TypeScript"
      bundleName = "TreeSitterTypeScript_TreeSitterTypeScript"
      let highlightsQuery = try Query(
        language: language,
        data: Data(Self.typeScriptHighlightsQuery.utf8)
      )
      return LanguageConfiguration(language, name: name, queries: [.highlights: highlightsQuery])
    }

    guard let queriesURL = Self.queriesURL(forBundleNamed: bundleName) else {
      return try LanguageConfiguration(language, name: name, bundleName: bundleName)
    }

    return try LanguageConfiguration(language, name: name, queriesURL: queriesURL)
  }

  private static func queriesURL(forBundleNamed bundleName: String) -> URL? {
    let bundledQueriesURL = candidateBundleContainers()
      .lazy
      .map { $0.appendingPathComponent("\(bundleName).bundle", isDirectory: true) }
      .flatMap { bundleURL in
        [
          bundleURL.appendingPathComponent("Contents/Resources/queries", isDirectory: true),
          bundleURL.appendingPathComponent("queries", isDirectory: true),
        ]
      }
      .first(where: isDirectory)

    if let bundledQueriesURL {
      return bundledQueriesURL
    }

    return checkoutQueriesURL(forBundleNamed: bundleName)
  }

  private static func checkoutQueriesURL(forBundleNamed bundleName: String) -> URL? {
    guard let checkoutName = checkoutName(forBundleNamed: bundleName) else {
      return nil
    }

    var roots = candidateBundleContainers()
    roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))

    for root in roots {
      var candidate = root.standardizedFileURL
      for _ in 0..<10 {
        let queriesURL = candidate
          .appendingPathComponent(".build", isDirectory: true)
          .appendingPathComponent("checkouts", isDirectory: true)
          .appendingPathComponent(checkoutName, isDirectory: true)
          .appendingPathComponent("queries", isDirectory: true)
        if isDirectory(queriesURL) {
          return queriesURL
        }
        let parent = candidate.deletingLastPathComponent()
        if parent.path == candidate.path {
          break
        }
        candidate = parent
      }
    }

    return nil
  }

  private static func checkoutName(forBundleNamed bundleName: String) -> String? {
    switch bundleName {
    case "TreeSitterBash_TreeSitterBash":
      return "tree-sitter-bash"
    case "TreeSitterHTML_TreeSitterHTML":
      return "tree-sitter-html"
    case "TreeSitterJSON_TreeSitterJSON":
      return "tree-sitter-json"
    case "TreeSitterPython_TreeSitterPython":
      return "tree-sitter-python"
    default:
      return nil
    }
  }

  private static func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  private static func candidateBundleContainers() -> [URL] {
    var urls: [URL] = []

    if let resourceURL = Bundle.main.resourceURL {
      urls.append(resourceURL)
    }

    urls.append(Bundle.main.bundleURL.deletingLastPathComponent())

    if let executablePath = CommandLine.arguments.first {
      appendContainers(forExecutableAt: URL(fileURLWithPath: executablePath), to: &urls)
    }

    for argumentIndex in CommandLine.arguments.indices {
      if CommandLine.arguments[argumentIndex] == "--test-bundle-path",
        CommandLine.arguments.indices.contains(argumentIndex + 1)
      {
        appendContainers(
          forExecutableAt: URL(fileURLWithPath: CommandLine.arguments[argumentIndex + 1]),
          to: &urls
        )
      } else if CommandLine.arguments[argumentIndex].contains(".xctest/") {
        appendContainers(
          forExecutableAt: URL(fileURLWithPath: CommandLine.arguments[argumentIndex]),
          to: &urls
        )
      }
    }

    for bundle in Bundle.allBundles {
      urls.append(bundle.bundleURL)
      urls.append(bundle.bundleURL.deletingLastPathComponent())
      if let resourceURL = bundle.resourceURL {
        urls.append(resourceURL)
      }
    }

    var seenPaths: Set<String> = []
    return urls.filter { url in
      let path = url.standardizedFileURL.path
      guard !seenPaths.contains(path) else {
        return false
      }
      seenPaths.insert(path)
      return true
    }
  }

  private static func appendContainers(forExecutableAt executableURL: URL, to urls: inout [URL]) {
    var executableContainer = executableURL.deletingLastPathComponent()
    for _ in 0..<8 {
      urls.append(executableContainer)
      executableContainer = executableContainer.deletingLastPathComponent()
    }
  }

  private static let typeScriptHighlightsQuery = #"""
    ; JavaScript-compatible syntax

    (comment) @comment
    (number) @number
    (string) @string
    (template_string) @string

    (function_declaration
      "function" @keyword.function
      name: (identifier) @function)
    (generator_function_declaration
      "function" @keyword.function
      name: (identifier) @function)
    (lexical_declaration
      kind: "const" @keyword)
    (lexical_declaration
      kind: "let" @keyword)
    (variable_declaration
      "var" @keyword)
    (return_statement
      "return" @keyword.return)
    (if_statement
      "if" @keyword.conditional)
    (for_statement
      "for" @keyword.repeat)
    (import_statement
      "import" @keyword.import)
    (export_statement
      "export" @keyword.import)
    (call_expression function: (identifier) @function.call)

    ; TypeScript-specific syntax

    [
      "abstract"
      "declare"
      "enum"
      "implements"
      "interface"
      "keyof"
      "namespace"
      "private"
      "protected"
      "public"
      "readonly"
      "override"
      "satisfies"
      "type"
    ] @keyword

    (predefined_type) @type.builtin
    (type_identifier) @type
    (required_parameter (identifier) @variable.parameter)
    (optional_parameter (identifier) @variable.parameter)
    """#
}

extension String {
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
