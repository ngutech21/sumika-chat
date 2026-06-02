import Foundation

nonisolated protocol WorkspaceStoring: Sendable {
  func loadLibrary() async -> WorkspaceLibrary
  func saveLibrary(_ library: WorkspaceLibrary) async throws
}

actor WorkspaceStore: WorkspaceStoring {
  nonisolated private let libraryURL: URL

  init(
    libraryURL: URL = LocalModelDirectory.defaultBaseURL
      .deletingLastPathComponent()
      .appending(path: "workspaces.json", directoryHint: .notDirectory)
  ) {
    self.libraryURL = libraryURL
  }

  func loadLibrary() async -> WorkspaceLibrary {
    guard
      let data = try? Data(contentsOf: libraryURL),
      let decoded = try? Self.makeDecoder().decode(WorkspaceLibrary.self, from: data)
    else {
      return WorkspaceLibrary()
    }

    return decoded
  }

  func saveLibrary(_ library: WorkspaceLibrary) async throws {
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
}
