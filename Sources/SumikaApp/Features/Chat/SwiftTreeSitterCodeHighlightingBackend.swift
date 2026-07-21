import Foundation
import SumikaCore
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterCSS
import TreeSitterHTML
import TreeSitterJSON
import TreeSitterPython
import TreeSitterTypeScript

actor SwiftTreeSitterCodeHighlightingBackend: CodeHighlightingBackend {
  private var configurations: [ParserLanguage: LanguageConfiguration] = [:]

  nonisolated private static let cssDimensionRegex: NSRegularExpression? =
    try? NSRegularExpression(
      pattern:
        #"(?<![A-Za-z0-9_.-])(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?:px|em|rem|vh|vw|vmin|vmax|ch|ex|cm|mm|in|pt|pc|fr|deg|rad|turn|s|ms|dpi|dpcm|dppx|%)"#
    )

  init() {}

  func highlight(
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

    // Resolve overlaps greedily in preference order (later candidates win). Selected spans
    // are kept disjoint and sorted by location, so each candidate is tested only against its
    // two nearest neighbors via binary search instead of scanning every previously selected
    // span, which was quadratic for code blocks that produce thousands of spans.
    var selectedSpans: [HighlightSpan] = []

    for span in candidateSpans.reversed() {
      let insertionIndex = sortedSpanInsertionIndex(for: span.range.location, in: selectedSpans)

      let overlapsFollowingSpan =
        insertionIndex < selectedSpans.count
        && selectedSpans[insertionIndex].range.location < span.range.upperBound
      let overlapsPrecedingSpan =
        insertionIndex > 0
        && selectedSpans[insertionIndex - 1].range.upperBound > span.range.location

      if !overlapsFollowingSpan, !overlapsPrecedingSpan {
        selectedSpans.insert(span, at: insertionIndex)
      }
    }

    return selectedSpans
  }

  /// Returns the index at which a span starting at `location` belongs in `spans`, which is
  /// maintained sorted by `range.location`. Selected spans are pairwise disjoint, so their
  /// locations are unique and a standard lower-bound binary search is sufficient.
  private func sortedSpanInsertionIndex(
    for location: Int,
    in spans: [HighlightSpan]
  ) -> Int {
    var low = 0
    var high = spans.count
    while low < high {
      let mid = (low + high) / 2
      if spans[mid].range.location < location {
        low = mid + 1
      } else {
        high = mid
      }
    }
    return low
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

nonisolated private struct CodeHighlightSource {
  let parseCode: String
  let parseUTF16Length: Int
  private let originalUTF16OffsetsByParseOffset: [Int]?

  init(code: String) {
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

nonisolated private struct NumberedCodeLineMapper {
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

nonisolated private enum ParserLanguage: Hashable {
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
