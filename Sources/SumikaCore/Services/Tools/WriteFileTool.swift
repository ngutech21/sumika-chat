import Foundation

public struct WriteFileInput: Codable, Equatable, Sendable {
  public let path: String
  public let content: String
}

nonisolated extension ToolDefinition {
  public static let writeFile = ToolDefinition(
    name: .writeFile,
    description:
      "Create a new workspace text file or intentionally replace an entire small file. Prefer edit_file for targeted changes to existing files.",
    parameters: [
      ToolParameterDefinition(
        name: "path",
        description: "Workspace-relative file path.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "content",
        description:
          "Complete UTF-8 file content written exactly as provided. Replaces the entire file.",
        isRequired: true,
        supportsHeredocPayload: true
      ),
    ],
    exampleArguments: [
      "path": .string("Sources/AppState.swift"),
      "content": .string("import Foundation\n"),
    ],
    capabilities: [.writeWorkspace],
    riskLevel: .high
  )
}

public struct WriteFileToolExecutor: TypedToolExecutor {
  public static let codec = ToolCodec<WriteFileInput>(
    definition: ToolDefinition.writeFile,
    makePayload: ToolCallPayload.writeFile,
    extractInput: { payload in
      guard case .writeFile(let input) = payload else {
        throw ToolInputDecodingError.payloadMismatch(
          expected: ToolDefinition.writeFile.name.rawValue,
          actual: payload.toolName.rawValue
        )
      }
      return input
    },
    validateInput: { input in
      try ToolArgumentValidation.requireNonEmptyPath(input.path)
    }
  )

  public init() {}

  public func evaluatePermission(
    _ input: WriteFileInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    do {
      let resolvedPath = try context.workspace.resolveAllowedPath(input.path)
      return ToolPermissionEvaluation(
        decision: .requiresApproval,
        reason: "Writing files inside the workspace requires approval.",
        riskLevel: .high,
        normalizedPaths: [resolvedPath.path(percentEncoded: false)],
        workspaceRelativePaths: [context.workspace.relativePath(for: resolvedPath)]
      )
    } catch {
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: error.localizedDescription,
        riskLevel: .high
      )
    }
  }

  public func run(_ input: WriteFileInput, context: ToolContext) async -> ToolResultPayload {
    var resolvedURL: URL?
    do {
      return try context.workspace.withSecurityScopedAccess {
        let resolvedPathURL = try context.workspace.resolveAllowedPath(input.path)
        resolvedURL = resolvedPathURL
        let relativePath = context.workspace.relativePath(for: resolvedPathURL)
        try FileManager.default.createDirectory(
          at: resolvedPathURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try input.content.write(to: resolvedPathURL, atomically: true, encoding: .utf8)
        return .writeFile(
          .success(path: relativePath, bytesWritten: input.content.utf8.count)
        )
      }
    } catch {
      return .writeFile(
        .failed(
          path: ToolResultFailureMapper.relativePath(
            for: input.path, resolvedURL: resolvedURL, workspace: context.workspace),
          reason: ToolResultFailureMapper.reason(from: error)
        )
      )
    }
  }
}
