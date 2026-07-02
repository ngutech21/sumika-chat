import Foundation

public struct SearchFilesInput: Codable, Equatable, Sendable {
  public let pattern: String
  public let path: String?
  public let include: String?
}

public struct SearchFilesToolExecutor: TypedToolExecutor {
  public static let codec = ToolCodec<SearchFilesInput>(
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

  public init(
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

  public func evaluatePermission(
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

  public func run(_ input: SearchFilesInput, context: ToolContext) async -> ToolResultPayload {
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
  public let maxSnippetLength: Int
  public let maxFileBytes: Int
  public let remainingMatchCount: Int
}
