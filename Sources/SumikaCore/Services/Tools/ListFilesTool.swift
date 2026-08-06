import Foundation

package struct ListFilesInput: Codable, Equatable, Sendable {
  package let path: String?
}

package struct ListFilesResult: Codable, Equatable, Sendable {
  package var root: WorkspaceRelativePath
  package var entries: [WorkspaceFileEntry]
  package var truncated: Bool

  package init(
    root: WorkspaceRelativePath,
    entries: [WorkspaceFileEntry],
    truncated: Bool = false
  ) {
    self.root = root
    self.entries = entries
    self.truncated = truncated
  }
}

nonisolated extension ListFilesResult {
  var preview: ToolResultPreview {
    ToolResultPreview(
      text: entries.isEmpty
        ? "(empty)"
        : entries.map { entry in
          entry.kind == .directory ? entry.path.rawValue + "/" : entry.path.rawValue
        }.joined(separator: "\n"),
      truncated: truncated,
      affectedPaths: [root.rawValue]
    )
  }
}

nonisolated extension ToolDefinition {
  package static let listFiles = ToolDefinition(
    name: .listFiles,
    description:
      "List files and folders in a workspace-relative directory. Use this to explore project structure before choosing a path.",
    parameters: [
      ToolParameterDefinition(
        name: "path",
        description: "Workspace-relative directory path. Defaults to root.",
        isRequired: false
      )
    ],
    capabilities: [.readWorkspace],
    riskLevel: .low
  )
}

struct ListFilesToolExecutor: TypedToolExecutor {
  static let codec = ToolCodec<ListFilesInput>(
    definition: ToolDefinition.listFiles,
    makePayload: ToolCallPayload.listFiles,
    extractInput: { payload in
      guard case .listFiles(let input) = payload else {
        throw ToolInputDecodingError.payloadMismatch(
          expected: ToolDefinition.listFiles.name.rawValue,
          actual: payload.toolName.rawValue
        )
      }
      return input
    },
    validateInput: { input in
      try ToolArgumentValidation.validateOptionalPath(input.path)
    }
  )

  private let maxDepth: Int
  private let maxEntries: Int
  private let fileDiscovery: WorkspaceFileDiscovery

  init(
    maxDepth: Int = 0,
    maxEntries: Int = 300,
    fileDiscovery: WorkspaceFileDiscovery = WorkspaceFileDiscovery()
  ) {
    self.maxDepth = maxDepth
    self.maxEntries = maxEntries
    self.fileDiscovery = fileDiscovery
  }

  func evaluatePermission(
    _ input: ListFilesInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    do {
      let resolvedPath = try context.workspace.resolveAllowedPath(input.path ?? ".")
      return ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Listing files inside the workspace is allowed.",
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

  func run(_ input: ListFilesInput, context: ToolContext) async -> ToolResultPayload {
    let path = input.path ?? "."
    var resolvedURL: URL?

    do {
      return try await context.workspace.withAsyncSecurityScopedAccess {
        let rootURL = try context.workspace.resolveAllowedPath(path)
        resolvedURL = rootURL
        let rootPath = context.workspace.relativePath(for: rootURL)
        let workspaceRootURL = try context.workspace.resolveAllowedPath(".")
        var entries: [WorkspaceFileEntry] = []
        var truncated = false
        try await appendEntries(
          at: rootURL,
          workspaceRootURL: workspaceRootURL,
          depth: 0,
          entries: &entries,
          truncated: &truncated
        )

        return .listFiles(
          ListFilesResult(
            root: rootPath,
            entries: entries,
            truncated: truncated
          )
        )
      }
    } catch {
      return .failure(
        ToolFailure(
          toolName: .listFiles,
          path: ToolResultFailureMapper.relativePath(
            for: path, resolvedURL: resolvedURL, workspace: context.workspace),
          reason: ToolResultFailureMapper.reason(from: error)
        )
      )
    }
  }

  private func appendEntries(
    at url: URL,
    workspaceRootURL: URL,
    depth: Int,
    entries: inout [WorkspaceFileEntry],
    truncated: inout Bool
  ) async throws {
    guard depth <= maxDepth else {
      return
    }

    let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
    guard resourceValues.isDirectory == true else {
      if entries.count >= maxEntries {
        truncated = true
      } else {
        let path = WorkspaceRelativePath(
          rawValue: lexicalRelativePath(for: url, rootURL: workspaceRootURL))
        entries.append(WorkspaceFileEntry(path: path, kind: .file))
      }
      return
    }

    let children = try await fileDiscovery.directChildren(
      at: url,
      relativeTo: workspaceRootURL
    )

    for child in children {
      guard entries.count < maxEntries else {
        truncated = true
        return
      }

      entries.append(
        WorkspaceFileEntry(
          path: WorkspaceRelativePath(rawValue: child.relativePath),
          kind: child.kind
        ))

      // A subdirectory is shown as a "name/" entry the model can descend into with a
      // follow-up list_files call. Not expanding it is by design (flat listing), NOT
      // truncation — `truncated` must only reflect the maxEntries cap, otherwise every
      // listing that contains a subdirectory falsely signals "there is more", which
      // makes small models re-list instead of progressing.
      if child.kind == .directory, depth < maxDepth {
        try await appendEntries(
          at: child.url,
          workspaceRootURL: workspaceRootURL,
          depth: depth + 1,
          entries: &entries,
          truncated: &truncated
        )
      }
    }
  }

  private func lexicalRelativePath(for url: URL, rootURL: URL) -> String {
    let rootPath = rootURL.standardizedFileURL.path(percentEncoded: false)
    let candidatePath = url.standardizedFileURL.path(percentEncoded: false)
    guard candidatePath.hasPrefix(rootPath + "/") else {
      return candidatePath
    }
    return String(candidatePath.dropFirst(rootPath.count + 1))
  }
}
