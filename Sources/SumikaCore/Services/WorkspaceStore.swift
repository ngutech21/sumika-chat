import Foundation

#if canImport(OSLog)
  import OSLog
#endif

public protocol WorkspaceStoring: Sendable {
  func loadLibrary() async -> WorkspaceLibraryLoadResult
  func saveLibrary(_ library: WorkspaceLibrary) async throws
}

/// The loaded library plus every issue the load had to work around. An empty
/// `issues` array means the on-disk state was read back verbatim.
public struct WorkspaceLibraryLoadResult: Equatable, Sendable {
  public let library: WorkspaceLibrary
  public let issues: [WorkspaceLibraryLoadIssue]

  public init(library: WorkspaceLibrary, issues: [WorkspaceLibraryLoadIssue] = []) {
    self.library = library
    self.issues = issues
  }
}

public enum WorkspaceLibraryLoadIssue: Equatable, Sendable {
  /// The library file exists but could not be read. The file was left in
  /// place, so persisting over it would destroy whatever it still contains.
  case readFailed(message: String)
  /// The library file could not be decoded at all. The original file was
  /// moved to `backupPath` (when possible) before an empty library was
  /// returned.
  case decodeFailed(message: String, backupPath: String?)
  /// Decoding succeeded but individual elements were dropped. A copy of the
  /// original file was saved to `backupPath` (when possible) because the next
  /// save rewrites the library without the dropped elements.
  case droppedElements(details: [String], backupPath: String?)

  /// Persisting over the on-disk file is only safe when the original bytes
  /// are preserved elsewhere or were decoded completely.
  public var isSafeToPersistOver: Bool {
    switch self {
    case .readFailed:
      false
    case .decodeFailed, .droppedElements:
      true
    }
  }
}

public actor WorkspaceStore: WorkspaceStoring {
  nonisolated private let libraryURL: URL

  public init(
    libraryURL: URL = LocalModelDirectory.defaultBaseURL
      .deletingLastPathComponent()
      .appending(path: "workspaces.json", directoryHint: .notDirectory)
  ) {
    self.libraryURL = libraryURL
  }

  public func loadLibrary() async -> WorkspaceLibraryLoadResult {
    let data: Data
    do {
      data = try Data(contentsOf: libraryURL)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      // No library on disk yet (first launch) — a clean empty library is the
      // correct result, not a failure.
      return WorkspaceLibraryLoadResult(library: WorkspaceLibrary())
    } catch {
      let message = String(reflecting: error)
      logIssue("Failed to read workspace library; starting empty. error=\(message)")
      return WorkspaceLibraryLoadResult(
        library: WorkspaceLibrary(),
        issues: [.readFailed(message: message)]
      )
    }

    let diagnostics = DecodeDiagnostics()
    do {
      let library = try Self.makeDecoder(diagnostics: diagnostics).decode(
        WorkspaceLibrary.self,
        from: data
      )
      guard diagnostics.droppedElements.isEmpty else {
        // The next save persists the pruned library, so preserve the complete
        // original bytes first.
        let backupPath = backUpLibraryFile(suffix: "partial", keepOriginal: true)
        let details = diagnostics.summaries
        logIssue(
          "Dropped \(details.count) undecodable workspace library element(s); backup=\(backupPath ?? "unavailable") details=\(details.joined(separator: "; "))"
        )
        return WorkspaceLibraryLoadResult(
          library: library,
          issues: [.droppedElements(details: details, backupPath: backupPath)]
        )
      }
      return WorkspaceLibraryLoadResult(library: library)
    } catch {
      // The file exists but cannot be decoded. Returning an empty library
      // would let the next save destroy it, so move the original aside and
      // surface the failure loudly instead of swallowing it.
      let backupPath = backUpLibraryFile(suffix: "corrupt", keepOriginal: false)
      let message = String(reflecting: error)
      logIssue(
        "Failed to decode workspace library; starting empty. backup=\(backupPath ?? "unavailable") error=\(message)"
      )
      return WorkspaceLibraryLoadResult(
        library: WorkspaceLibrary(),
        issues: [.decodeFailed(message: message, backupPath: backupPath)]
      )
    }
  }

  public func saveLibrary(_ library: WorkspaceLibrary) async throws {
    try FileManager.default.createDirectory(
      at: libraryURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let data = try Self.makeEncoder().encode(library)
    try data.write(to: libraryURL, options: .atomic)
  }

  private func backUpLibraryFile(suffix: String, keepOriginal: Bool) -> String? {
    let fileManager = FileManager.default
    let timestamp = Self.makeBackupTimestampFormatter().string(from: Date())
    var backupURL = libraryURL.appendingPathExtension("\(suffix)-\(timestamp)")
    var attempt = 1
    while fileManager.fileExists(atPath: backupURL.path(percentEncoded: false)) {
      backupURL = libraryURL.appendingPathExtension("\(suffix)-\(timestamp)-\(attempt)")
      attempt += 1
    }

    do {
      if keepOriginal {
        try fileManager.copyItem(at: libraryURL, to: backupURL)
      } else {
        try fileManager.moveItem(at: libraryURL, to: backupURL)
      }
      return backupURL.path(percentEncoded: false)
    } catch {
      logIssue(
        "Failed to back up workspace library file. error=\(String(reflecting: error))"
      )
      return nil
    }
  }

  nonisolated private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  nonisolated private static func makeDecoder(diagnostics: DecodeDiagnostics) -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.userInfo[.decodeDiagnostics] = diagnostics
    return decoder
  }

  nonisolated private static func makeBackupTimestampFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter
  }

  #if canImport(OSLog)
    nonisolated private static let logger = Logger(
      subsystem: SumikaTelemetry.subsystem,
      category: "WorkspaceStore"
    )
  #endif

  nonisolated private func logIssue(_ message: String) {
    #if canImport(OSLog)
      Self.logger.error("\(message, privacy: .public)")
    #else
      FileHandle.standardError.write(Data((message + "\n").utf8))
    #endif
  }
}
