import Foundation

nonisolated struct GlobFilesInput: Decodable, Sendable {
  let pattern: String
  let path: String?
}

nonisolated struct GlobFilesToolExecutor: TypedToolExecutor {
  static let definition = ToolDefinition.globFiles

  private let maxResults: Int
  private let skippedNames: Set<String>

  init(
    maxResults: Int = 300,
    skippedNames: Set<String> = WorkspaceFileEnumeration.skippedNames
  ) {
    self.maxResults = maxResults
    self.skippedNames = skippedNames
  }

  func evaluatePermission(
    _ input: GlobFilesInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    do {
      let resolvedPath = try context.workspace.resolveAllowedPath(input.path ?? ".")
      return ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Finding files inside the workspace is allowed.",
        riskLevel: .low,
        normalizedPaths: [resolvedPath.path(percentEncoded: false)]
      )
    } catch {
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: error.localizedDescription,
        riskLevel: .low
      )
    }
  }

  func run(_ input: GlobFilesInput, context: ToolContext) async -> ToolResultPreview {
    do {
      return try context.workspace.withSecurityScopedAccess {
        let rootURL = try context.workspace.resolveAllowedPath(input.path ?? ".")
        let matcher = try GlobPatternMatcher(pattern: input.pattern)
        var results: [String] = []
        var truncated = false

        try WorkspaceFileEnumeration.enumerateFiles(
          at: rootURL,
          skippedNames: skippedNames
        ) { _, relativePath in
          if matcher.matches(relativePath) {
            results.append(relativePath)
          }

          if results.count >= maxResults {
            truncated = true
            return false
          }

          return true
        }

        return ToolResultPreview(
          status: .success,
          text: results.isEmpty ? "(no matches)" : results.joined(separator: "\n"),
          truncated: truncated,
          affectedPaths: [rootURL.path(percentEncoded: false)]
        )
      }
    } catch {
      return ToolResultPreview(
        status: .failed,
        text: error.localizedDescription
      )
    }
  }
}

nonisolated struct SearchFilesInput: Decodable, Sendable {
  let pattern: String
  let path: String?
  let include: String?
}

nonisolated struct SearchFilesToolExecutor: TypedToolExecutor {
  static let definition = ToolDefinition.searchFiles

  private let maxMatches: Int
  private let maxSnippetLength: Int
  private let maxFileBytes: Int
  private let skippedNames: Set<String>

  init(
    maxMatches: Int = 200,
    maxSnippetLength: Int = 240,
    maxFileBytes: Int = 2 * 1024 * 1024,
    skippedNames: Set<String> = WorkspaceFileEnumeration.skippedNames
  ) {
    self.maxMatches = maxMatches
    self.maxSnippetLength = maxSnippetLength
    self.maxFileBytes = maxFileBytes
    self.skippedNames = skippedNames
  }

  func evaluatePermission(
    _ input: SearchFilesInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    do {
      let resolvedPath = try context.workspace.resolveAllowedPath(input.path ?? ".")
      return ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Searching files inside the workspace is allowed.",
        riskLevel: .low,
        normalizedPaths: [resolvedPath.path(percentEncoded: false)]
      )
    } catch {
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: error.localizedDescription,
        riskLevel: .low
      )
    }
  }

  func run(_ input: SearchFilesInput, context: ToolContext) async -> ToolResultPreview {
    do {
      return try context.workspace.withSecurityScopedAccess {
        let rootURL = try context.workspace.resolveAllowedPath(input.path ?? ".")
        let searchPattern = SearchPattern(pattern: input.pattern)
        let includeMatcher = try input.include.map(GlobPatternMatcher.init(pattern:))
        var results: [String] = []
        var truncated = false

        try WorkspaceFileEnumeration.enumerateFiles(
          at: rootURL,
          skippedNames: skippedNames
        ) { fileURL, relativePath in
          if !Self.shouldSearch(
            relativePath: relativePath,
            fileName: fileURL.lastPathComponent,
            includeMatcher: includeMatcher
          ) {
            return true
          }

          let fileMatches = try Self.matches(
            in: fileURL,
            relativePath: relativePath,
            pattern: searchPattern,
            limits: SearchFileScanLimits(
              maxSnippetLength: maxSnippetLength,
              maxFileBytes: maxFileBytes,
              remainingMatchCount: maxMatches - results.count
            )
          )
          results.append(contentsOf: fileMatches.matches)

          if results.count >= maxMatches || fileMatches.truncated {
            truncated = true
          }

          return results.count < maxMatches
        }

        return ToolResultPreview(
          status: .success,
          text: results.isEmpty ? "(no matches)" : results.joined(separator: "\n"),
          truncated: truncated,
          affectedPaths: [rootURL.path(percentEncoded: false)]
        )
      }
    } catch {
      return ToolResultPreview(
        status: .failed,
        text: error.localizedDescription
      )
    }
  }

  private static func shouldSearch(
    relativePath: String,
    fileName: String,
    includeMatcher: GlobPatternMatcher?
  ) -> Bool {
    guard let includeMatcher else {
      return true
    }

    return includeMatcher.matches(relativePath) || includeMatcher.matches(fileName)
  }

  private static func matches(
    in url: URL,
    relativePath: String,
    pattern: SearchPattern,
    limits: SearchFileScanLimits
  ) throws -> (matches: [String], truncated: Bool) {
    guard limits.remainingMatchCount > 0 else {
      return ([], true)
    }

    let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
    if let fileSize = resourceValues.fileSize, fileSize > limits.maxFileBytes {
      return ([], true)
    }

    guard let content = try? String(contentsOf: url, encoding: .utf8) else {
      return ([], false)
    }

    var matches: [String] = []
    var lineNumber = 1
    for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
      var normalizedLine = String(line)
      if normalizedLine.hasSuffix("\r") {
        normalizedLine.removeLast()
      }

      if pattern.matches(normalizedLine) {
        matches.append(
          "\(relativePath):\(lineNumber): \(snippet(from: normalizedLine, maxLength: limits.maxSnippetLength))"
        )
      }

      if matches.count >= limits.remainingMatchCount {
        return (matches, true)
      }

      lineNumber += 1
    }

    return (matches, false)
  }

  private static func snippet(from line: String, maxLength: Int) -> String {
    let compactLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard compactLine.count > maxLength else {
      return compactLine
    }

    return String(compactLine.prefix(max(maxLength - 3, 0))) + "..."
  }
}

nonisolated private struct SearchFileScanLimits {
  let maxSnippetLength: Int
  let maxFileBytes: Int
  let remainingMatchCount: Int
}

nonisolated enum WorkspaceFileEnumeration {
  static let skippedNames: Set<String> = [".git", "DerivedData", ".build", "build", ".swiftpm"]

  static func enumerateFiles(
    at rootURL: URL,
    skippedNames: Set<String>,
    visit: (URL, String) throws -> Bool
  ) throws {
    guard !skippedNames.contains(rootURL.lastPathComponent) else {
      return
    }

    let rootPath = rootURL.path(percentEncoded: false)
    _ = try enumerateFiles(
      at: rootURL,
      rootPath: rootPath,
      skippedNames: skippedNames,
      visit: visit
    )
  }

  private static func enumerateFiles(
    at directoryURL: URL,
    rootPath: String,
    skippedNames: Set<String>,
    visit: (URL, String) throws -> Bool
  ) throws -> Bool {
    let children = try FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
      options: [.skipsPackageDescendants]
    )
    .sorted { lhs, rhs in
      lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
    }

    for child in children {
      let name = child.lastPathComponent
      let resourceValues = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
      if resourceValues.isDirectory == true {
        guard !skippedNames.contains(name) else {
          continue
        }

        guard
          try enumerateFiles(
            at: child,
            rootPath: rootPath,
            skippedNames: skippedNames,
            visit: visit
          )
        else {
          return false
        }
        continue
      }

      guard resourceValues.isRegularFile == true else {
        continue
      }

      let filePath = child.path(percentEncoded: false)
      let relativePath =
        filePath.hasPrefix(rootPath + "/")
        ? String(filePath.dropFirst(rootPath.count + 1))
        : name

      guard try visit(child, relativePath) else {
        return false
      }
    }

    return true
  }
}

nonisolated struct GlobPatternMatcher {
  private let regex: NSRegularExpression

  init(pattern: String) throws {
    regex = try NSRegularExpression(pattern: Self.regularExpressionPattern(for: pattern))
  }

  func matches(_ value: String) -> Bool {
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return regex.firstMatch(in: value, range: range) != nil
  }

  private static func regularExpressionPattern(for pattern: String) -> String {
    var output = "^"
    var index = pattern.startIndex

    while index < pattern.endIndex {
      let character = pattern[index]
      let nextIndex = pattern.index(after: index)

      if character == "*" {
        if nextIndex < pattern.endIndex, pattern[nextIndex] == "*" {
          let afterGlobstar = pattern.index(after: nextIndex)
          if afterGlobstar < pattern.endIndex, pattern[afterGlobstar] == "/" {
            output += "(?:.*/)?"
            index = pattern.index(after: afterGlobstar)
          } else {
            output += ".*"
            index = afterGlobstar
          }
        } else {
          output += "[^/]*"
          index = nextIndex
        }
      } else if character == "?" {
        output += "[^/]"
        index = nextIndex
      } else {
        output += NSRegularExpression.escapedPattern(for: String(character))
        index = nextIndex
      }
    }

    return output + "$"
  }
}

nonisolated struct SearchPattern {
  private let regex: NSRegularExpression?
  private let literal: String

  init(pattern: String) {
    regex = try? NSRegularExpression(pattern: pattern)
    literal = pattern
  }

  func matches(_ line: String) -> Bool {
    if let regex {
      return regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line))
        != nil
    }

    return line.contains(literal)
  }
}
