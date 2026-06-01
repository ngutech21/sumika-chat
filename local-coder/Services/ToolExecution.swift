import Foundation

protocol ToolExecutor: Sendable {
  func execute(request: ToolCallRequest, workspace: Workspace) async -> ToolResultPreview
}

struct ToolExecutorRegistry: Sendable {
  static let readOnly = ToolExecutorRegistry()

  private let executors: [ToolName: any ToolExecutor]

  init(
    executors: [ToolName: any ToolExecutor] = [
      .readFile: ReadFileToolExecutor(),
      .listFiles: ListFilesToolExecutor()
    ]
  ) {
    self.executors = executors
  }

  func executor(for toolName: ToolName) -> (any ToolExecutor)? {
    executors[toolName]
  }
}

struct ReadFileToolExecutor: ToolExecutor {
  private let maxBytes: Int

  init(maxBytes: Int = 40 * 1024) {
    self.maxBytes = maxBytes
  }

  func execute(request: ToolCallRequest, workspace: Workspace) async -> ToolResultPreview {
    guard case .string(let path)? = request.arguments["path"] else {
      return ToolResultPreview(
        status: .failed,
        text: "read_file requires a string path argument."
      )
    }

    let didStartSecurityScope = workspace.rootURL.startAccessingSecurityScopedResource()
    defer {
      if didStartSecurityScope {
        workspace.rootURL.stopAccessingSecurityScopedResource()
      }
    }

    do {
      let resolvedURL = try workspace.resolveAllowedPath(path)
      let data = try Data(contentsOf: resolvedURL)
      guard let content = String(data: data, encoding: .utf8) else {
        return ToolResultPreview(
          status: .failed,
          text: "File is not valid UTF-8 text.",
          affectedPaths: [resolvedURL.path(percentEncoded: false)]
        )
      }

      let truncated = data.count > maxBytes
      let text = truncated ? Self.prefix(content, maxUTF8Bytes: maxBytes) : content
      return ToolResultPreview(
        status: .success,
        text: text,
        truncated: truncated,
        affectedPaths: [resolvedURL.path(percentEncoded: false)]
      )
    } catch {
      return ToolResultPreview(
        status: .failed,
        text: error.localizedDescription
      )
    }
  }

  private static func prefix(_ text: String, maxUTF8Bytes: Int) -> String {
    var result = ""
    result.reserveCapacity(min(text.count, maxUTF8Bytes))
    var usedBytes = 0

    for character in text {
      let byteCount = String(character).utf8.count
      guard usedBytes + byteCount <= maxUTF8Bytes else {
        break
      }

      result.append(character)
      usedBytes += byteCount
    }

    return result
  }
}

struct ListFilesToolExecutor: ToolExecutor {
  private let maxDepth: Int
  private let maxEntries: Int
  private let skippedNames: Set<String>

  init(
    maxDepth: Int = 4,
    maxEntries: Int = 300,
    skippedNames: Set<String> = [
      ".git",
      "node_modules",
      ".build",
      "DerivedData",
      ".swiftpm",
      "dist",
      "build",
      ".cache",
      ".DS_Store"
    ]
  ) {
    self.maxDepth = maxDepth
    self.maxEntries = maxEntries
    self.skippedNames = skippedNames
  }

  func execute(request: ToolCallRequest, workspace: Workspace) async -> ToolResultPreview {
    let path: String
    switch request.arguments["path"] {
    case nil:
      path = "."
    case .string(let value):
      path = value
    default:
      return ToolResultPreview(
        status: .failed,
        text: "list_files path must be a string when provided."
      )
    }

    let didStartSecurityScope = workspace.rootURL.startAccessingSecurityScopedResource()
    defer {
      if didStartSecurityScope {
        workspace.rootURL.stopAccessingSecurityScopedResource()
      }
    }

    do {
      let rootURL = try workspace.resolveAllowedPath(path)
      var entries: [String] = []
      var truncated = false
      try appendEntries(
        at: rootURL,
        displayPrefix: "",
        depth: 0,
        entries: &entries,
        truncated: &truncated
      )

      return ToolResultPreview(
        status: .success,
        text: entries.isEmpty ? "(empty)" : entries.joined(separator: "\n"),
        truncated: truncated,
        affectedPaths: [rootURL.path(percentEncoded: false)]
      )
    } catch {
      return ToolResultPreview(
        status: .failed,
        text: error.localizedDescription
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

struct ToolOrchestrator: Sendable {
  private let permissionEvaluator: ToolPermissionEvaluator
  private let executorRegistry: ToolExecutorRegistry

  init(
    permissionEvaluator: ToolPermissionEvaluator = ToolPermissionEvaluator(),
    executorRegistry: ToolExecutorRegistry = .readOnly
  ) {
    self.permissionEvaluator = permissionEvaluator
    self.executorRegistry = executorRegistry
  }

  func execute(request: ToolCallRequest, workspace: Workspace) async -> ToolCallRecord {
    let requestedEvent = ToolCallEvent(
      actor: .assistant,
      kind: .requested,
      message: "Requested \(request.toolName.rawValue)."
    )
    let evaluation = permissionEvaluator.evaluate(request, in: workspace)
    var record = ToolCallRecord(
      request: request,
      status: .pending,
      evaluation: evaluation,
      events: [requestedEvent]
    )

    guard evaluation.decision == .allowed else {
      let preview = ToolResultPreview(
        status: .denied,
        text: evaluation.reason,
        affectedPaths: evaluation.normalizedPaths
      )
      record.status = .denied
      record.resultPreview = preview
      record.events.append(
        ToolCallEvent(actor: .system, kind: .denied, message: evaluation.reason)
      )
      return record
    }

    guard let executor = executorRegistry.executor(for: request.toolName) else {
      let message = "Unknown tool: \(request.toolName.rawValue)."
      record.status = .failed
      record.resultPreview = ToolResultPreview(status: .failed, text: message)
      record.events.append(ToolCallEvent(actor: .system, kind: .failed, message: message))
      return record
    }

    record.status = .running
    record.events.append(
      ToolCallEvent(actor: .tool, kind: .started, message: "Started \(request.toolName.rawValue).")
    )

    let preview = await executor.execute(request: request, workspace: workspace)
    record.resultPreview = preview

    switch preview.status {
    case .success:
      record.status = .completed
      record.events.append(
        ToolCallEvent(
          actor: .tool, kind: .completed, message: "Completed \(request.toolName.rawValue).")
      )
    case .failed:
      record.status = .failed
      record.events.append(ToolCallEvent(actor: .tool, kind: .failed, message: preview.text))
    case .denied:
      record.status = .denied
      record.events.append(ToolCallEvent(actor: .tool, kind: .denied, message: preview.text))
    }

    return record
  }
}
