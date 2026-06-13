import Foundation
import OSLog

public protocol WorkspaceStoring: Sendable {
  func loadLibrary() async -> WorkspaceLibrary
  func saveLibrary(_ library: WorkspaceLibrary) async throws
}

public actor WorkspaceStore: WorkspaceStoring {
  nonisolated private let libraryURL: URL
  nonisolated private let onLoadFailure: (@Sendable (Error) -> Void)?

  public init(
    libraryURL: URL = LocalModelDirectory.defaultBaseURL
      .deletingLastPathComponent()
      .appending(path: "workspaces.json", directoryHint: .notDirectory),
    onLoadFailure: (@Sendable (Error) -> Void)? = nil
  ) {
    self.libraryURL = libraryURL
    self.onLoadFailure = onLoadFailure
  }

  public func loadLibrary() async -> WorkspaceLibrary {
    let data: Data
    do {
      data = try Data(contentsOf: libraryURL)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      // No library on disk yet (first launch) — a clean empty library is the
      // correct result, not a failure.
      return WorkspaceLibrary()
    } catch {
      reportLoadFailure(error)
      return WorkspaceLibrary()
    }

    do {
      return try Self.makeDecoder().decode(WorkspaceLibrary.self, from: data)
    } catch {
      // The file exists but cannot be decoded. Returning an empty library
      // silently discards every workspace, so surface the failure loudly
      // instead of swallowing it. (Prototype: no migration / legacy decode.)
      reportLoadFailure(error)
      return WorkspaceLibrary()
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

  nonisolated private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  nonisolated private static func makeDecoder() -> JSONDecoder {
    JSONDecoder()
  }

  nonisolated private static let logger = Logger(
    subsystem: "local-coder",
    category: "WorkspaceStore"
  )

  /// Routes a load failure to the injected handler (tests) or, by default, logs
  /// it loudly so a corrupt/undecodable library on disk is never discarded in
  /// silence.
  nonisolated private func reportLoadFailure(_ error: Error) {
    if let onLoadFailure {
      onLoadFailure(error)
    } else {
      Self.logger.error(
        "Failed to load workspace library; starting empty. error=\(String(reflecting: error), privacy: .public)"
      )
    }
  }
}
