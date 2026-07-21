import Foundation

package struct GlobFilesInput: Codable, Equatable, Sendable {
  package let pattern: String
  package let path: String?
}

package struct GlobFilesResult: Codable, Equatable, Sendable {
  package var root: WorkspaceRelativePath
  package var pattern: String
  package var matches: [WorkspaceRelativePath]
  package var truncated: Bool

  package init(
    root: WorkspaceRelativePath,
    pattern: String,
    matches: [WorkspaceRelativePath],
    truncated: Bool = false
  ) {
    self.root = root
    self.pattern = pattern
    self.matches = matches
    self.truncated = truncated
  }
}

nonisolated extension GlobFilesResult {
  var preview: ToolResultPreview {
    ToolResultPreview(
      text: matches.isEmpty
        ? "(no matches)"
        : matches.map(\.rawValue).joined(separator: "\n"),
      truncated: truncated,
      affectedPaths: [root.rawValue]
    )
  }
}

nonisolated extension ToolDefinition {
  package static let globFiles = ToolDefinition(
    name: .globFiles,
    description:
      "Find workspace files by glob pattern. Use this when the target path or file type is unknown but a filename pattern is known.",
    parameters: [
      ToolParameterDefinition(
        name: "pattern",
        description: "Glob pattern for workspace-relative paths.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "path",
        description: "Workspace-relative search directory. Defaults to root.",
        isRequired: false
      ),
    ],
    capabilities: [.readWorkspace],
    riskLevel: .low
  )
}

struct GlobFilesToolExecutor: TypedToolExecutor {
  static let codec = ToolCodec<GlobFilesInput>(
    definition: ToolDefinition.globFiles,
    makePayload: ToolCallPayload.globFiles,
    extractInput: { payload in
      guard case .globFiles(let input) = payload else {
        throw ToolInputDecodingError.payloadMismatch(
          expected: ToolDefinition.globFiles.name.rawValue,
          actual: payload.toolName.rawValue
        )
      }
      return input
    },
    validateInput: { input in
      try ToolArgumentValidation.validateOptionalPath(input.path)
    }
  )

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

  func run(_ input: GlobFilesInput, context: ToolContext) async -> ToolResultPayload {
    var resolvedURL: URL?
    do {
      return try context.workspace.withSecurityScopedAccess {
        let rootURL = try context.workspace.resolveAllowedPath(input.path ?? ".")
        resolvedURL = rootURL
        let rootPath = context.workspace.relativePath(for: rootURL)
        let workspaceRootURL = try context.workspace.resolveAllowedPath(".")
        let matcher = try GlobPatternMatcher(pattern: input.pattern)
        var results: [String] = []
        var truncated = false

        try WorkspaceFileEnumeration.enumerateFiles(
          at: rootURL,
          relativeTo: workspaceRootURL,
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

        return .globFiles(
          GlobFilesResult(
            root: rootPath,
            pattern: input.pattern,
            matches: results.map(WorkspaceRelativePath.init(rawValue:)),
            truncated: truncated
          )
        )
      }
    } catch {
      return .failure(
        ToolFailure(
          toolName: .globFiles,
          path: ToolResultFailureMapper.relativePath(
            for: input.path ?? ".", resolvedURL: resolvedURL, workspace: context.workspace),
          reason: ToolResultFailureMapper.reason(from: error)
        )
      )
    }
  }
}
