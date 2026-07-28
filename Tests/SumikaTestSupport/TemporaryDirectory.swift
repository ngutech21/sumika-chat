import Foundation
import Testing

package func withTemporaryDirectory<Result>(
  named prefix: String = "sumika-tests",
  _ body: (URL) throws -> Result
) throws -> Result {
  let directory = try makeTemporaryDirectory(named: prefix)
  defer {
    removeTemporaryDirectory(directory)
  }
  return try body(directory)
}

package func withTemporaryDirectory<Result>(
  named prefix: String = "sumika-tests",
  isolation: isolated (any Actor)? = #isolation,
  _ body: (URL) async throws -> Result
) async throws -> Result {
  _ = isolation
  let directory = try makeTemporaryDirectory(named: prefix)
  defer {
    removeTemporaryDirectory(directory)
  }
  return try await body(directory)
}

package struct TemporaryDirectoryTrait: SuiteTrait, TestTrait, TestScoping {
  package var isRecursive: Bool {
    true
  }

  private let prefix: String

  package init(named prefix: String = "sumika-tests") {
    self.prefix = prefix
  }

  package func provideScope(
    for test: Test,
    testCase: Test.Case?,
    performing function: @Sendable () async throws -> Void
  ) async throws {
    try await withTemporaryDirectory(named: prefix) { directory in
      try await TemporaryDirectoryContext.$current.withValue(directory) {
        try await function()
      }
    }
  }
}

package func scopedTemporaryDirectory() throws -> URL {
  guard let directory = TemporaryDirectoryContext.current else {
    throw MissingTemporaryDirectoryScopeError()
  }
  return directory
}

package func removeTemporaryItemIfPresent(
  _ url: URL,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
    return
  }
  do {
    try FileManager.default.removeItem(at: url)
  } catch {
    Issue.record(
      error,
      "Failed to remove temporary test item at \(url.path(percentEncoded: false))",
      sourceLocation: sourceLocation
    )
  }
}

private enum TemporaryDirectoryContext {
  @TaskLocal static var current: URL?
}

private struct MissingTemporaryDirectoryScopeError: Error {}

private func makeTemporaryDirectory(named prefix: String) throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "\(prefix)-\(UUID().uuidString)",
    directoryHint: .isDirectory
  )
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: false
  )
  return directory
}

private func removeTemporaryDirectory(_ directory: URL) {
  try? FileManager.default.removeItem(at: directory)
}
