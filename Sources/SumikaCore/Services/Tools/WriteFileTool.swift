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
        affectedPaths: [path]
      )
    case .failed(let path, let reason):
      return ToolResultPreview(
        status: reason.previewStatus,
        text: reason.message,
        affectedPaths: path.map { [$0] } ?? []
      )
    }
  }
}

nonisolated extension ToolDefinition {
  package static let writeFile = ToolDefinition(
    name: .writeFile,
    description:
      "Create or replace one text file. Prefer for ordinary new files or intentional full-file replacement; use edit_file for targeted changes. For generated data or bulk transformations, use a short, bounded script through run_command when it substantially reduces repetition. Parent directories are created automatically. Do not combine this call with another write_file/edit_file for the same file, including equivalent paths, in one response; wait for its result first.",
    parameters: [
      ToolParameterDefinition(
        name: "path",
        description: "Workspace-relative file path.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "content",
        description: "Entire file content after this call.",
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
  ) async -> ToolPermissionEvaluation {
    do {
      let location = try await context.fileIO.resolve(path: input.path, in: context.workspace)
      return ToolPermissionEvaluation(
        decision: .requiresApproval,
        reason: "Writing files inside the workspace requires approval.",
        riskLevel: .high,
        normalizedPaths: [location.absolutePath],
        workspaceRelativePaths: [location.relativePath]
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
    var location: WorkspaceFileLocation?
    do {
      let resolved = try await context.fileIO.resolve(path: input.path, in: context.workspace)
      location = resolved
      try await context.fileIO.write(
        path: resolved.absolutePath, in: context.workspace,
        data: Data(input.content.utf8), expectedContents: nil
      )
      return .writeFile(
        .success(path: resolved.relativePath, bytesWritten: input.content.utf8.count)
      )
    } catch {
      return .writeFile(
        .failed(
          path: location?.relativePath ?? WorkspaceRelativePath(rawValue: input.path),
          reason: await context.fileIO.failureReason(
            for: error, path: input.path, location: location, in: context.workspace
          )
        )
      )
    }
  }
}
