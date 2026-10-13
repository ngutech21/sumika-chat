import Foundation

package struct WorkspaceFileLocation: Equatable, Sendable {
  package let absolutePath: String
  package let relativePath: WorkspaceRelativePath
  package let isRegularFile: Bool

  package init(
    absolutePath: String, relativePath: WorkspaceRelativePath, isRegularFile: Bool = true
  ) {
    self.absolutePath = absolutePath
    self.relativePath = relativePath
    self.isRegularFile = isRegularFile
  }
}

package protocol WorkspaceFileIO: Sendable {
  func resolve(path: String, in workspace: Workspace) async throws -> WorkspaceFileLocation
  func read(path: String, in workspace: Workspace, offset: Int, maxBytes: Int?) async throws -> Data
  func withReader<Result: Sendable>(
    path: String, in workspace: Workspace,
    _ operation:
      @Sendable (@escaping @Sendable (Int, Int) async throws -> Data) async throws -> Result
  ) async throws -> Result
  func write(
    path: String, in workspace: Workspace, data: Data, expectedContents: Data?
  ) async throws
  func listDirectory(path: String, in workspace: Workspace) async throws -> [String]
  func missingPathSuggestions(path: String, in workspace: Workspace) async
    -> [MissingPathSuggestion]
}

extension WorkspaceFileIO {
  package func withReader<Result: Sendable>(
    path: String, in workspace: Workspace,
    _ operation:
      @Sendable (@escaping @Sendable (Int, Int) async throws -> Data) async throws -> Result
  ) async throws -> Result {
    try await operation { offset, maxBytes in
      try await read(path: path, in: workspace, offset: offset, maxBytes: maxBytes)
    }
  }

  package func missingPathSuggestions(
    path _: String, in _: Workspace
  ) async -> [MissingPathSuggestion] { [] }

  func failureReason(
    for error: Error, path: String, location: WorkspaceFileLocation?, in workspace: Workspace
  ) async -> ToolFailureReason {
    guard ToolResultFailureMapper.isFileNotFound(error) else {
      return ToolResultFailureMapper.reason(from: error)
    }
    return .fileNotFound(
      path: location?.relativePath ?? WorkspaceRelativePath(rawValue: path),
      suggestions: await missingPathSuggestions(path: path, in: workspace)
    )
  }
}

package enum WorkspaceFileIOError: LocalizedError, Sendable {
  case contentChanged
  case invalidReadRange

  package var errorDescription: String? {
    switch self {
    case .contentChanged:
      "The file changed before the edit could be written. Read it again before retrying."
    case .invalidReadRange:
      "File read offsets and byte limits must not be negative."
    }
  }
}

struct LocalWorkspaceFileIO: WorkspaceFileIO {
  func resolve(
    path: String, in workspace: Workspace
  ) async throws -> WorkspaceFileLocation {
    try await Self.perform(in: workspace) {
      let url = try workspace.resolveAllowedPath(path)
      return WorkspaceFileLocation(
        absolutePath: url.path(percentEncoded: false),
        relativePath: workspace.relativePath(for: url),
        isRegularFile: (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile)
          ?? false
      )
    }
  }

  func read(
    path: String, in workspace: Workspace, offset: Int, maxBytes: Int?
  ) async throws -> Data {
    guard offset >= 0, maxBytes.map({ $0 >= 0 }) ?? true else {
      throw WorkspaceFileIOError.invalidReadRange
    }
    return try await Self.perform(in: workspace) {
      let url = try workspace.resolveAllowedPath(path)
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      try handle.seek(toOffset: UInt64(offset))
      if let maxBytes {
        return try handle.read(upToCount: maxBytes) ?? Data()
      }
      return try handle.readToEnd() ?? Data()
    }
  }

  func withReader<Result: Sendable>(
    path: String, in workspace: Workspace,
    _ operation:
      @Sendable (@escaping @Sendable (Int, Int) async throws -> Data) async throws -> Result
  ) async throws -> Result {
    try await workspace.withAsyncSecurityScopedAccess {
      let reader = try await Self.perform(in: workspace) {
        try LocalWorkspaceFileReader(url: workspace.resolveAllowedPath(path))
      }
      do {
        let result = try await operation { offset, maxBytes in
          try await reader.read(offset: offset, maxBytes: maxBytes)
        }
        await reader.close()
        return result
      } catch {
        await reader.close()
        throw error
      }
    }
  }

  func write(
    path: String, in workspace: Workspace, data: Data, expectedContents: Data?
  ) async throws {
    try await Self.perform(in: workspace) {
      let url = try workspace.resolveAllowedPath(path)
      if let expectedContents {
        guard try Data(contentsOf: url) == expectedContents else {
          throw WorkspaceFileIOError.contentChanged
        }
      } else {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
      }
      try Task.checkCancellation()
      try data.write(to: url, options: .atomic)
    }
  }

  func listDirectory(path: String, in workspace: Workspace) async throws -> [String] {
    try await Self.perform(in: workspace) {
      let url = try workspace.resolveAllowedPath(path)
      return try FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))
    }
  }

  func missingPathSuggestions(
    path: String, in workspace: Workspace
  ) async -> [MissingPathSuggestion] {
    await workspace.withAsyncSecurityScopedAccess {
      await WorkspacePathSuggestionResolver().suggestions(
        forMissingPath: path, workspace: workspace)
    }
  }

  private static func perform<Result: Sendable>(
    in workspace: Workspace, _ operation: @escaping @Sendable () throws -> Result
  ) async throws -> Result {
    let task = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      return try workspace.withSecurityScopedAccess(operation)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}

private actor LocalWorkspaceFileReader {
  private let handle: FileHandle

  init(url: URL) throws {
    handle = try FileHandle(forReadingFrom: url)
  }

  func read(offset: Int, maxBytes: Int) throws -> Data {
    try Task.checkCancellation()
    guard offset >= 0, maxBytes >= 0 else { throw WorkspaceFileIOError.invalidReadRange }
    try handle.seek(toOffset: UInt64(offset))
    return try handle.read(upToCount: maxBytes) ?? Data()
  }

  func close() {
    try? handle.close()
  }
}
