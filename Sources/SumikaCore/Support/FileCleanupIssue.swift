import Foundation

#if canImport(OSLog)
  import OSLog
#endif

/// Operational diagnostics, never persisted and never containing file contents or names.
package struct FileCleanupIssue: Equatable, Sendable {
  let domain: String
  let code: Int

  init(_ error: any Error) {
    let error = error as NSError
    domain = error.domain
    code = error.code
    #if canImport(OSLog)
      let issue = self
      Logger(subsystem: SumikaTelemetry.subsystem, category: "StorageCleanup")
        .error("Cleanup failed: domain=\(issue.domain, privacy: .public) code=\(issue.code)")
    #endif
  }

  package static let message =
    "Some saved chat files or attachments could not be removed. Sumika will retry cleanup."
}

enum FileCleanupSafety {
  static func hasDirectory(at url: URL) throws -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    guard try isDirectory(at: url) else { throw CocoaError(.fileReadInvalidFileName) }
    return true
  }

  static func isDirectory(at url: URL) throws -> Bool {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    return values.isDirectory == true && values.isSymbolicLink != true
  }

  static func isRegularFile(at url: URL) throws -> Bool {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    return values.isRegularFile == true && values.isSymbolicLink != true
  }
}
