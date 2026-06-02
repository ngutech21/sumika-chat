import Foundation

nonisolated struct ToolContext: Sendable {
  let workspace: Workspace
}

nonisolated protocol TypedToolExecutor: Sendable {
  associatedtype Input: Decodable & Sendable

  static var definition: ToolDefinition { get }

  func evaluatePermission(_ input: Input, context: ToolContext) -> ToolPermissionEvaluation
  func run(_ input: Input, context: ToolContext) async -> ToolResultPreview
}

nonisolated struct AnyToolExecutor: Sendable {
  let definition: ToolDefinition
  private let runHandler: @Sendable (ToolCallRequest, ToolContext) async -> ToolCallRecord

  init<T: TypedToolExecutor>(_ tool: T) {
    definition = T.definition
    runHandler = { request, context in
      var record = Self.makePendingRecord(request: request)

      do {
        try Self.validateKnownArguments(request.arguments, definition: T.definition)
        let input = try ToolInputDecoder.decode(T.Input.self, from: request.arguments)
        let evaluation = tool.evaluatePermission(input, context: context)
        record.evaluation = evaluation

        // The current registry contains read-only tools only. If a future write, patch, or command
        // tool returns `.requiresApproval`, this fail-closed branch must become an approval handoff
        // instead of executing the tool.
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

        record.status = .running
        record.events.append(
          ToolCallEvent(
            actor: .tool,
            kind: .started,
            message: "Started \(request.toolName.rawValue)."
          )
        )

        let preview = await tool.run(input, context: context)
        record.resultPreview = preview

        switch preview.status {
        case .success:
          record.status = .completed
          record.events.append(
            ToolCallEvent(
              actor: .tool,
              kind: .completed,
              message: "Completed \(request.toolName.rawValue)."
            )
          )
        case .failed:
          record.status = .failed
          record.events.append(ToolCallEvent(actor: .tool, kind: .failed, message: preview.text))
        case .denied:
          record.status = .denied
          record.events.append(ToolCallEvent(actor: .tool, kind: .denied, message: preview.text))
        }

        return record
      } catch {
        let message =
          "Invalid arguments for \(T.definition.name.rawValue): \(error.localizedDescription)"
        record.status = .failed
        record.evaluation = ToolPermissionEvaluation(
          decision: .denied,
          reason: message,
          riskLevel: T.definition.riskLevel
        )
        record.resultPreview = ToolResultPreview(status: .failed, text: message)
        record.events.append(ToolCallEvent(actor: .system, kind: .failed, message: message))
        return record
      }
    }
  }

  func run(_ request: ToolCallRequest, context: ToolContext) async -> ToolCallRecord {
    await runHandler(request, context)
  }

  private static func makePendingRecord(request: ToolCallRequest) -> ToolCallRecord {
    ToolCallRecord(
      request: request,
      status: .pending,
      evaluation: ToolPermissionEvaluation(
        decision: .denied,
        reason: "Tool call has not been evaluated.",
        riskLevel: .low
      ),
      events: [
        ToolCallEvent(
          actor: .assistant,
          kind: .requested,
          message: "Requested \(request.toolName.rawValue)."
        )
      ]
    )
  }

  private static func validateKnownArguments(
    _ arguments: ToolCallArguments,
    definition: ToolDefinition
  ) throws {
    let knownArguments = Set(definition.parameters.map(\.name))
    let unknownArguments = Set(arguments.keys).subtracting(knownArguments)
    guard unknownArguments.isEmpty else {
      throw ToolInputDecodingError.unknownArguments(unknownArguments.sorted())
    }
  }
}

nonisolated struct ToolExecutorRegistry: Sendable {
  static let readOnly = ToolExecutorRegistry([
    AnyToolExecutor(ReadFileToolExecutor()),
    AnyToolExecutor(ListFilesToolExecutor()),
  ])

  private let orderedExecutors: [AnyToolExecutor]
  private let executorsByName: [ToolName: AnyToolExecutor]

  init(_ executors: [AnyToolExecutor] = []) {
    orderedExecutors = executors
    executorsByName = Dictionary(
      uniqueKeysWithValues: executors.map { executor in
        (executor.definition.name, executor)
      })
  }

  init(executors: [ToolName: AnyToolExecutor]) {
    self.init(
      executors.sorted { lhs, rhs in
        lhs.key.rawValue.localizedStandardCompare(rhs.key.rawValue) == .orderedAscending
      }.map(\.value))
  }

  var toolRegistry: ToolRegistry {
    ToolRegistry(tools: orderedExecutors.map(\.definition))
  }

  var definitions: [ToolDefinition] {
    orderedExecutors.map(\.definition)
  }

  func executor(for toolName: ToolName) -> AnyToolExecutor? {
    executorsByName[toolName]
  }
}

nonisolated struct ReadFileInput: Decodable, Sendable {
  let path: String
}

nonisolated struct ReadFileToolExecutor: TypedToolExecutor {
  static let definition = ToolDefinition.readFile

  private let maxBytes: Int

  init(maxBytes: Int = 40 * 1024) {
    self.maxBytes = maxBytes
  }

  func evaluatePermission(
    _ input: ReadFileInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    do {
      let resolvedPath = try context.workspace.resolveAllowedPath(input.path)
      return ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Reading files inside the workspace is allowed.",
        riskLevel: .low,
        normalizedPaths: [resolvedPath.path(percentEncoded: false)]
      )
    } catch {
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: error.localizedDescription,
        riskLevel: .low
      )
    }
  }

  func run(_ input: ReadFileInput, context: ToolContext) async -> ToolResultPreview {
    let didStartSecurityScope = context.workspace.rootURL.startAccessingSecurityScopedResource()
    defer {
      if didStartSecurityScope {
        context.workspace.rootURL.stopAccessingSecurityScopedResource()
      }
    }

    do {
      let resolvedURL = try context.workspace.resolveAllowedPath(input.path)
      let preview = try Self.readPreview(from: resolvedURL, maxBytes: maxBytes)
      guard let content = preview.content else {
        return ToolResultPreview(
          status: .failed,
          text: "File is not valid UTF-8 text.",
          affectedPaths: [resolvedURL.path(percentEncoded: false)]
        )
      }

      return ToolResultPreview(
        status: .success,
        text: content,
        truncated: preview.truncated,
        affectedPaths: [resolvedURL.path(percentEncoded: false)]
      )
    } catch {
      return ToolResultPreview(
        status: .failed,
        text: error.localizedDescription
      )
    }
  }

  private static func readPreview(
    from url: URL,
    maxBytes: Int
  ) throws -> (content: String?, truncated: Bool) {
    let previewByteLimit = max(maxBytes, 0)
    let bytesToRead = previewByteLimit + 1
    let fileHandle = try FileHandle(forReadingFrom: url)
    defer {
      try? fileHandle.close()
    }

    let data = try fileHandle.read(upToCount: bytesToRead) ?? Data()
    let truncated = data.count > previewByteLimit
    let previewData = data.prefix(previewByteLimit)

    guard truncated else {
      return (String(data: previewData, encoding: .utf8), false)
    }

    return (utf8StringDroppingPartialSuffix(from: previewData), true)
  }

  private static func utf8StringDroppingPartialSuffix(from data: Data) -> String? {
    if let string = String(data: data, encoding: .utf8) {
      return string
    }

    guard !data.isEmpty else {
      return ""
    }

    for droppedByteCount in 1...min(3, data.count) {
      let shortenedData = data.dropLast(droppedByteCount)
      if let string = String(data: shortenedData, encoding: .utf8) {
        return string
      }
    }

    return nil
  }

}

nonisolated struct ListFilesInput: Decodable, Sendable {
  let path: String?
}

nonisolated struct ListFilesToolExecutor: TypedToolExecutor {
  static let definition = ToolDefinition.listFiles

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
      ".DS_Store",
    ]
  ) {
    self.maxDepth = maxDepth
    self.maxEntries = maxEntries
    self.skippedNames = skippedNames
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
        normalizedPaths: [resolvedPath.path(percentEncoded: false)]
      )
    } catch {
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: error.localizedDescription,
        riskLevel: .low
      )
    }
  }

  func run(_ input: ListFilesInput, context: ToolContext) async -> ToolResultPreview {
    let path = input.path ?? "."
    let didStartSecurityScope = context.workspace.rootURL.startAccessingSecurityScopedResource()
    defer {
      if didStartSecurityScope {
        context.workspace.rootURL.stopAccessingSecurityScopedResource()
      }
    }

    do {
      let rootURL = try context.workspace.resolveAllowedPath(path)
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

nonisolated enum ToolInputDecodingError: LocalizedError, Equatable {
  case unknownArguments([String])

  var errorDescription: String? {
    switch self {
    case .unknownArguments(let arguments):
      "Unknown argument(s): \(arguments.joined(separator: ", "))."
    }
  }
}

nonisolated enum ToolInputDecoder {
  static func decode<Input: Decodable>(
    _ inputType: Input.Type,
    from arguments: ToolCallArguments
  ) throws -> Input {
    let data = try JSONEncoder().encode(arguments)
    return try JSONDecoder().decode(inputType, from: data)
  }
}

nonisolated struct ToolOrchestrator: Sendable {
  private let executorRegistry: ToolExecutorRegistry

  init(
    executorRegistry: ToolExecutorRegistry = .readOnly
  ) {
    self.executorRegistry = executorRegistry
  }

  var toolRegistry: ToolRegistry {
    executorRegistry.toolRegistry
  }

  func execute(request: ToolCallRequest, workspace: Workspace) async -> ToolCallRecord {
    guard request.workspaceID == workspace.id else {
      let message = "Tool call workspace does not match the active workspace."
      return ToolCallRecord(
        request: request,
        status: .denied,
        evaluation: ToolPermissionEvaluation(
          decision: .denied,
          reason: message,
          riskLevel: .high
        ),
        events: [
          ToolCallEvent(
            actor: .assistant,
            kind: .requested,
            message: "Requested \(request.toolName.rawValue)."
          ),
          ToolCallEvent(actor: .system, kind: .denied, message: message),
        ],
        resultPreview: ToolResultPreview(status: .denied, text: message)
      )
    }

    guard let executor = executorRegistry.executor(for: request.toolName) else {
      let message = "Unknown tool: \(request.toolName.rawValue)."
      return ToolCallRecord(
        request: request,
        status: .failed,
        evaluation: ToolPermissionEvaluation(
          decision: .denied,
          reason: message,
          riskLevel: .high
        ),
        events: [
          ToolCallEvent(
            actor: .assistant,
            kind: .requested,
            message: "Requested \(request.toolName.rawValue)."
          ),
          ToolCallEvent(actor: .system, kind: .failed, message: message),
        ],
        resultPreview: ToolResultPreview(status: .failed, text: message)
      )
    }

    return await executor.run(
      request,
      context: ToolContext(workspace: workspace)
    )
  }
}
