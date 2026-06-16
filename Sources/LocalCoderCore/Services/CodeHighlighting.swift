import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterCSS
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
  case css
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
    case "css":
      self = .css
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
      "unit": .number,
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

  private static let cssDimensionRegex: NSRegularExpression? = try? NSRegularExpression(
    pattern:
      #"(?<![A-Za-z0-9_.-])(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?:px|em|rem|vh|vw|vmin|vmax|ch|ex|cm|mm|in|pt|pc|fr|deg|rad|turn|s|ms|dpi|dpcm|dppx|%)"#
  )

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
    let highlightSource = CodeHighlightSource(code: code)
    let parser = Parser()
    try parser.setLanguage(configuration.language)

    guard
      let tree = parser.parse(highlightSource.parseCode),
      let query = configuration.queries[.highlights]
    else {
      return .plain(code: code, language: language)
    }

    let ranges =
      query
      .execute(in: tree)
      .resolve(with: .init(string: highlightSource.parseCode))
      .highlights()

    let spans = nonOverlappingSpans(
      from: ranges,
      source: highlightSource,
      language: language,
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
    source: CodeHighlightSource,
    language: CodeLanguage,
    theme: CodeHighlightTheme
  ) -> [HighlightSpan] {
    var candidateSpans = ranges.flatMap { namedRange -> [HighlightSpan] in
      guard
        namedRange.range.location >= 0,
        namedRange.range.length > 0,
        namedRange.range.upperBound <= source.parseUTF16Length,
        let style = theme.style(for: namedRange.name)
      else {
        return []
      }

      return source.originalRanges(for: namedRange.range).map { originalRange in
        HighlightSpan(
          range: originalRange,
          style: style,
          captureName: namedRange.name
        )
      }
    }
    candidateSpans.append(contentsOf: syntheticSpans(for: language, source: source))

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

  private func syntheticSpans(
    for language: CodeLanguage,
    source: CodeHighlightSource
  ) -> [HighlightSpan] {
    switch language {
    case .css:
      cssDimensionSpans(source: source)
    default:
      []
    }
  }

  private func cssDimensionSpans(source: CodeHighlightSource) -> [HighlightSpan] {
    guard let regex = Self.cssDimensionRegex else {
      return []
    }

    let fullRange = NSRange(location: 0, length: source.parseUTF16Length)
    return regex.matches(in: source.parseCode, range: fullRange).flatMap { match in
      source.originalRanges(for: match.range).map { originalRange in
        HighlightSpan(
          range: originalRange,
          style: .number,
          captureName: "number.dimension"
        )
      }
    }
  }
}

private struct CodeHighlightSource {
  let originalCode: String
  let parseCode: String
  let parseUTF16Length: Int
  private let originalUTF16OffsetsByParseOffset: [Int]?

  init(code: String) {
    originalCode = code

    guard let numberedCode = NumberedCodeLineMapper(code: code).strippedCode() else {
      parseCode = code
      parseUTF16Length = code.utf16.count
      originalUTF16OffsetsByParseOffset = nil
      return
    }

    parseCode = numberedCode.code
    parseUTF16Length = numberedCode.originalOffsetsByParseOffset.count
    originalUTF16OffsetsByParseOffset = numberedCode.originalOffsetsByParseOffset
  }

  func originalRanges(for parseRange: NSRange) -> [HighlightTextRange] {
    guard let originalUTF16OffsetsByParseOffset else {
      return [HighlightTextRange(location: parseRange.location, length: parseRange.length)]
    }

    let lowerBound = parseRange.location
    let upperBound = parseRange.upperBound
    guard
      lowerBound >= 0,
      lowerBound < upperBound,
      upperBound <= originalUTF16OffsetsByParseOffset.count
    else {
      return []
    }

    var ranges: [HighlightTextRange] = []
    var currentLowerBound = originalUTF16OffsetsByParseOffset[lowerBound]
    var previousOffset = currentLowerBound

    for parseOffset in (lowerBound + 1)..<upperBound {
      let originalOffset = originalUTF16OffsetsByParseOffset[parseOffset]
      if originalOffset == previousOffset + 1 {
        previousOffset = originalOffset
      } else {
        ranges.append(
          HighlightTextRange(
            location: currentLowerBound,
            length: previousOffset - currentLowerBound + 1
          ))
        currentLowerBound = originalOffset
        previousOffset = originalOffset
      }
    }

    ranges.append(
      HighlightTextRange(
        location: currentLowerBound,
        length: previousOffset - currentLowerBound + 1
      ))
    return ranges
  }
}

private struct NumberedCodeLineMapper {
  let code: String

  func strippedCode() -> (code: String, originalOffsetsByParseOffset: [Int])? {
    let originalCodeUnits = Array(code.utf16)
    let lineRanges = lineRanges(in: originalCodeUnits)
    let numberedLineCount = lineRanges.filter { lineRange in
      numberedContentStart(
        in: originalCodeUnits, lineStart: lineRange.start, lineEnd: lineRange.end)
        != nil
    }.count
    let contentLineCount = lineRanges.filter { $0.start < $0.end }.count

    guard
      numberedLineCount >= 2,
      numberedLineCount * 3 >= max(contentLineCount, 1) * 2
    else {
      return nil
    }

    var parseCodeUnits: [UInt16] = []
    var originalOffsetsByParseOffset: [Int] = []

    for lineRange in lineRanges {
      let contentStart =
        numberedContentStart(
          in: originalCodeUnits,
          lineStart: lineRange.start,
          lineEnd: lineRange.end
        ) ?? lineRange.start

      appendCodeUnits(
        originalCodeUnits,
        in: contentStart..<lineRange.end,
        to: &parseCodeUnits,
        originalOffsetsByParseOffset: &originalOffsetsByParseOffset
      )

      if let newlineOffset = lineRange.newlineOffset {
        appendCodeUnits(
          originalCodeUnits,
          in: newlineOffset..<(newlineOffset + 1),
          to: &parseCodeUnits,
          originalOffsetsByParseOffset: &originalOffsetsByParseOffset
        )
      }
    }

    return (
      code: String(decoding: parseCodeUnits, as: UTF16.self),
      originalOffsetsByParseOffset: originalOffsetsByParseOffset
    )
  }

  private func lineRanges(in codeUnits: [UInt16]) -> [LineRange] {
    var ranges: [LineRange] = []
    var lineStart = 0
    var offset = 0

    while offset < codeUnits.count {
      if codeUnits[offset] == 10 {
        ranges.append(LineRange(start: lineStart, end: offset, newlineOffset: offset))
        lineStart = offset + 1
      }
      offset += 1
    }

    if lineStart < codeUnits.count || codeUnits.isEmpty {
      ranges.append(LineRange(start: lineStart, end: codeUnits.count, newlineOffset: nil))
    }

    return ranges
  }

  private func numberedContentStart(
    in codeUnits: [UInt16],
    lineStart: Int,
    lineEnd: Int
  ) -> Int? {
    var offset = lineStart
    while offset < lineEnd, (48...57).contains(Int(codeUnits[offset])) {
      offset += 1
    }

    guard offset > lineStart, offset < lineEnd, codeUnits[offset] == 58 else {
      return nil
    }

    offset += 1
    if offset < lineEnd, codeUnits[offset] == 32 || codeUnits[offset] == 9 {
      offset += 1
    }

    return offset
  }

  private func appendCodeUnits(
    _ codeUnits: [UInt16],
    in range: Range<Int>,
    to parseCodeUnits: inout [UInt16],
    originalOffsetsByParseOffset: inout [Int]
  ) {
    for offset in range {
      parseCodeUnits.append(codeUnits[offset])
      originalOffsetsByParseOffset.append(offset)
    }
  }

  private struct LineRange {
    var start: Int
    var end: Int
    var newlineOffset: Int?
  }
}

private enum ParserLanguage: Hashable {
  case bash
  case css
  case html
  case json
  case python
  case typescript

  init(codeLanguage: CodeLanguage) {
    switch codeLanguage {
    case .bash:
      self = .bash
    case .css:
      self = .css
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
    case .css:
      language = Language(language: tree_sitter_css())
      name = "CSS"
      bundleName = "TreeSitterCSS_TreeSitterCSS"
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
        let queriesURL =
          candidate
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
    case "TreeSitterCSS_TreeSitterCSS":
      return "tree-sitter-css"
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
