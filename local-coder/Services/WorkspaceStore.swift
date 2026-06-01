import Foundation

protocol WorkspaceStoring: Sendable {
  func loadLibrary() -> WorkspaceLibrary
  func saveLibrary(_ library: WorkspaceLibrary) throws
}

final class WorkspaceStore: WorkspaceStoring, @unchecked Sendable {
  private let libraryURL: URL
  private let fileManager: FileManager

  init(
    libraryURL: URL = LocalModelDirectory.defaultBaseURL
      .deletingLastPathComponent()
      .appending(path: "workspaces.json", directoryHint: .notDirectory),
    fileManager: FileManager = .default
  ) {
    self.libraryURL = libraryURL
    self.fileManager = fileManager
  }

  func loadLibrary() -> WorkspaceLibrary {
    guard
      let data = try? Data(contentsOf: libraryURL),
      let decoded = try? Self.decoder.decode(WorkspaceLibrary.self, from: data)
    else {
      return WorkspaceLibrary()
    }

    return decoded
  }

  func saveLibrary(_ library: WorkspaceLibrary) throws {
    try fileManager.createDirectory(
      at: libraryURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let data = try Self.encoder.encode(library)
    try data.write(to: libraryURL, options: .atomic)
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    JSONDecoder()
  }()
}
