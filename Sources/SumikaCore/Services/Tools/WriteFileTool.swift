import Foundation

package struct WriteFileInput: Codable, Equatable, Sendable {
  package let path: String
  package let content: String
}

package enum WriteFileResult: Codable, Equatable, Sendable {
  case success(path: WorkspaceRelativePath, bytesWritten: Int)
  case failed(path: WorkspaceRelativePath?, reason: ToolFailureReason)
}

nonisolated extension WriteFileResult {
  var preview: ToolResultPreview {
    switch self {
    case .success(let path, let bytesWritten):
      return ToolResultPreview(
        text: "Wrote \(bytesWritten) bytes to \(path.rawValue).",
        affectedPaths: [path.rawValue]
      )
    case .failed(let path, let reason):
      return ToolResultPreview(
        status: reason.previewStatus,
        text: reason.message,
        affectedPaths: path.map { [$0.rawValue] } ?? []
      )
    }
  }
}

nonisolated extension ToolDefinition {
  package static let writeFile = ToolDefinition(
    name: .writeFile,
    description:
      "Write one workspace text file, replacing its current contents with the provided UTF-8 payload. Parent directories are created automatically. If the requested final file may exceed one response, including Markdown or prose, call write_file immediately with a compact valid scaffold; after success, add one named section per edit_file call. Do not draft the full file first or use placeholder comments.",
    parameters: [
      ToolParameterDefinition(
        name: "path",
        description: "Workspace-relative file path.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "content",
        description:
          "UTF-8 payload that becomes the file's entire current contents. It may be a finished small file or an intermediate scaffold; it need not be the final requested file.",
        isRequired: true,
        supportsHeredocPayload: true
      ),
    ],
    capabilities: [.writeWorkspace],
    riskLevel: .high
  )
}

struct WriteFileToolExecutor: TypedToolExecutor {
  static let codec = ToolCodec<WriteFileInput>(
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

  func evaluatePermission(
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

  func run(_ input: WriteFileInput, context: ToolContext) async -> ToolResultPayload {
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
