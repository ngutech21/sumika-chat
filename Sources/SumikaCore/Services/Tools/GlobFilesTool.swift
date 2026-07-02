import Foundation

public struct GlobFilesInput: Codable, Equatable, Sendable {
  public let pattern: String
  public let path: String?
}

nonisolated extension ToolDefinition {
  public static let globFiles = ToolDefinition(
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
    exampleArguments: [
      "pattern": .string("**/*.swift"),
      "path": .string("."),
    ],
    capabilities: [.readWorkspace],
    riskLevel: .low
  )
}

public struct GlobFilesToolExecutor: TypedToolExecutor {
  public static let codec = ToolCodec<GlobFilesInput>(
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

  public init(
    maxResults: Int = 300,
    skippedNames: Set<String> = WorkspaceFileEnumeration.skippedNames
  ) {
    self.maxResults = maxResults
    self.skippedNames = skippedNames
  }

  public func evaluatePermission(
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

  public func run(_ input: GlobFilesInput, context: ToolContext) async -> ToolResultPayload {
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
