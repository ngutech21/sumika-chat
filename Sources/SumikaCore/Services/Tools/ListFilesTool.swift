import Foundation

public struct ListFilesInput: Codable, Equatable, Sendable {
  public let path: String?
}

public struct ListFilesResult: Codable, Equatable, Sendable {
  public var root: WorkspaceRelativePath
  public var entries: [WorkspaceFileEntry]
  public var truncated: Bool

  public init(
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
  public static let listFiles = ToolDefinition(
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
    exampleArguments: [
      "path": .string(".")
    ],
    capabilities: [.readWorkspace],
    riskLevel: .low
  )
}

public struct ListFilesToolExecutor: TypedToolExecutor {
  public static let codec = ToolCodec<ListFilesInput>(
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
  private let skippedNames: Set<String>

  public init(
    maxDepth: Int = 0,
    maxEntries: Int = 300,
    skippedNames: Set<String> = [
      ".DS_Store",
    ]
  ) {
    self.maxDepth = maxDepth
    self.maxEntries = maxEntries
    self.skippedNames = skippedNames
  }

  public func evaluatePermission(
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

  public func run(_ input: ListFilesInput, context: ToolContext) async -> ToolResultPayload {
    let path = input.path ?? "."
    var resolvedURL: URL?

    do {
      return try context.workspace.withSecurityScopedAccess {
        let rootURL = try context.workspace.resolveAllowedPath(path)
        resolvedURL = rootURL
        let rootPath = context.workspace.relativePath(for: rootURL)
        var entries: [String] = []
        var truncated = false
        try appendEntries(
          at: rootURL,
          displayPrefix: "",
          depth: 0,
          entries: &entries,
          truncated: &truncated
        )

        return .listFiles(
          ListFilesResult(
            root: rootPath,
            entries: entries.map { entry in
              let isDirectory = entry.hasSuffix("/")
              let path = isDirectory ? String(entry.dropLast()) : entry
              let workspacePath =
                rootPath.rawValue == "." ? path : rootPath.rawValue + "/" + path
              return WorkspaceFileEntry(
                path: WorkspaceRelativePath(rawValue: workspacePath),
                kind: isDirectory ? .directory : .file
              )
            },
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
    displayPrefix: String,
    depth: Int,
    entries: inout [String],
    truncated: inout Bool
  ) throws {
    guard entries.count < maxEntries else {
      truncated = true
      return
    }
    guard depth <= maxDepth else {
      truncated = true
      return
    }

    let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
    guard resourceValues.isDirectory == true else {
      entries.append(displayPrefix.isEmpty ? url.lastPathComponent : displayPrefix)
      return
    }

    let children = try FileManager.default.contentsOfDirectory(
      at: url,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: []
    )
    .filter { !skippedNames.contains($0.lastPathComponent) }
    .sorted { lhs, rhs in
      lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
    }

    for child in children {
      guard entries.count < maxEntries else {
        truncated = true
        return
      }

      let childValues = try child.resourceValues(forKeys: [.isDirectoryKey])
      let isDirectory = childValues.isDirectory == true
      let relativePath =
        displayPrefix.isEmpty
        ? child.lastPathComponent
        : displayPrefix + "/" + child.lastPathComponent
      entries.append(isDirectory ? relativePath + "/" : relativePath)

      if isDirectory {
        if depth < maxDepth {
          try appendEntries(
            at: child,
            displayPrefix: relativePath,
            depth: depth + 1,
            entries: &entries,
            truncated: &truncated
          )
        } else {
          truncated = true
        }
      }
    }
  }
}
