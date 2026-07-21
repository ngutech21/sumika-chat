import Foundation

package struct SearchFilesInput: Codable, Equatable, Sendable {
  package let pattern: String
  package let path: String?
  package let include: String?
}

package struct SearchFilesResult: Codable, Equatable, Sendable {
  package var root: WorkspaceRelativePath
  package var pattern: String
  package var matches: [SearchFileMatch]
  package var truncated: Bool

  package init(
    root: WorkspaceRelativePath,
    pattern: String,
    matches: [SearchFileMatch],
    truncated: Bool = false
  ) {
    self.root = root
    self.pattern = pattern
    self.matches = matches
    self.truncated = truncated
  }
}

nonisolated extension SearchFilesResult {
  var preview: ToolResultPreview {
    ToolResultPreview(
      text: matches.isEmpty
        ? "(no matches)"
        : matches.map { "\($0.path.rawValue):\($0.line): \($0.snippet)" }
          .joined(separator: "\n"),
      truncated: truncated,
      affectedPaths: [root.rawValue]
    )
  }
}

nonisolated extension ToolDefinition {
  package static let searchFiles = ToolDefinition(
    name: .searchFiles,
    description:
      "Search text contents of workspace files. Use this to locate symbols, strings, errors, or relevant code before reading or editing files.",
    parameters: [
      ToolParameterDefinition(
        name: "pattern",
        description: "Regex or literal search pattern.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "path",
        description: "Workspace-relative search directory. Defaults to root.",
        isRequired: false
      ),
      ToolParameterDefinition(
        name: "include",
        description: "Glob file-name filter.",
        isRequired: false
      ),
    ],
    capabilities: [.readWorkspace],
    riskLevel: .low
  )
}

struct SearchFilesToolExecutor: TypedToolExecutor {
  static let codec = ToolCodec<SearchFilesInput>(
    definition: ToolDefinition.searchFiles,
    makePayload: ToolCallPayload.searchFiles,
    extractInput: { payload in
      guard case .searchFiles(let input) = payload else {
        throw ToolInputDecodingError.payloadMismatch(
          expected: ToolDefinition.searchFiles.name.rawValue,
          actual: payload.toolName.rawValue
        )
      }
      return input
    },
    validateInput: { input in
      try ToolArgumentValidation.validateOptionalPath(input.path)
    }
  )

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
        normalizedPaths: [resolvedPath.path(percentEncoded: false)],
        workspaceRelativePaths: [context.workspace.relativePath(for: resolvedPath)]
      )
    } catch {
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: error.localizedDescription,
        riskLevel: .low
      )
    }
  }

  func run(_ input: SearchFilesInput, context: ToolContext) async -> ToolResultPayload {
    var resolvedURL: URL?
    do {
      return try context.workspace.withSecurityScopedAccess {
        let rootURL = try context.workspace.resolveAllowedPath(input.path ?? ".")
        resolvedURL = rootURL
        let rootPath = context.workspace.relativePath(for: rootURL)
        let workspaceRootURL = try context.workspace.resolveAllowedPath(".")
        let searchPattern = SearchPattern(pattern: input.pattern)
        let includeMatcher = try input.include.map(GlobPatternMatcher.init(pattern:))
        var results: [SearchFileMatch] = []
        var truncated = false

        try WorkspaceFileEnumeration.enumerateFiles(
          at: rootURL,
          relativeTo: workspaceRootURL,
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

        return .searchFiles(
          SearchFilesResult(
            root: rootPath,
            pattern: input.pattern,
            matches: results,
            truncated: truncated
          )
        )
      }
    } catch {
      return .failure(
        ToolFailure(
          toolName: .searchFiles,
          path: ToolResultFailureMapper.relativePath(
            for: input.path ?? ".", resolvedURL: resolvedURL, workspace: context.workspace),
          reason: ToolResultFailureMapper.reason(from: error)
        )
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
  ) throws -> (matches: [SearchFileMatch], truncated: Bool) {
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

    var matches: [SearchFileMatch] = []
    var lineNumber = 1
    for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
      var normalizedLine = String(line)
      if normalizedLine.hasSuffix("\r") {
        normalizedLine.removeLast()
      }

      if pattern.matches(normalizedLine) {
        matches.append(
          SearchFileMatch(
            path: WorkspaceRelativePath(rawValue: relativePath),
            line: lineNumber,
            snippet: snippet(from: normalizedLine, maxLength: limits.maxSnippetLength)
          )
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
  package let maxSnippetLength: Int
  package let maxFileBytes: Int
  package let remainingMatchCount: Int
}
