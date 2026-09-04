import Foundation

package protocol VersionedJSONFormat: Sendable {
  associatedtype CurrentDocument: Codable & Equatable & Sendable

  static var currentVersion: Int { get }

  static func decode(
    _ data: Data,
    sourceVersion: Int
  ) throws -> CurrentDocument
}

package enum VersionedJSONLoad<Document: Equatable & Sendable>: Equatable, Sendable {
  case missing
  case current(Document)
  case migrated(Document, fromVersion: Int)
}

package enum VersionedJSONFileError: Error, Equatable, LocalizedError, Sendable {
  case invalidCurrentVersion(fileName: String, currentVersion: Int)
  case readFailed(fileName: String)
  case invalidSchemaVersion(fileName: String)
  case unsupportedSchemaVersion(fileName: String, found: Int, current: Int)
  case decodeFailed(fileName: String, schemaVersion: Int)
  case encodeFailed(fileName: String)
  case invalidEncodedDocument(fileName: String)
  case writeFailed(fileName: String)
  case saveBlocked(fileName: String)

  package var errorDescription: String? {
    switch self {
    case .invalidCurrentVersion(let fileName, let currentVersion):
      "The persistence format for \(fileName) has invalid current schema version \(currentVersion)."
    case .readFailed(let fileName):
      "The saved configuration in \(fileName) could not be read."
    case .invalidSchemaVersion(let fileName):
      "The saved configuration in \(fileName) has an invalid schema version."
    case .unsupportedSchemaVersion(let fileName, let found, let current):
      "The saved configuration in \(fileName) uses schema version \(found), but this version of Sumika supports up to version \(current)."
    case .decodeFailed(let fileName, let schemaVersion):
      "The saved configuration in \(fileName) could not be decoded as schema version \(schemaVersion)."
    case .encodeFailed(let fileName):
      "The configuration for \(fileName) could not be encoded."
    case .invalidEncodedDocument(let fileName):
      "The encoded configuration for \(fileName) failed persistence validation."
    case .writeFailed(let fileName):
      "The configuration in \(fileName) could not be written."
    case .saveBlocked(let fileName):
      "Saving \(fileName) is blocked until the existing configuration loads successfully."
    }
  }
}

package actor VersionedJSONFile<Format: VersionedJSONFormat> {
  private enum AccessState {
    case unchecked
    case writable
    case blocked
  }

  private enum ReadResult: Sendable {
    case missing
    case data(Data)
  }

  private let fileURL: URL
  private var accessState = AccessState.unchecked
  private var operationTail: Task<Void, Never>?

  package init(fileURL: URL) {
    self.fileURL = fileURL
  }

  package func load() async throws -> VersionedJSONLoad<Format.CurrentDocument> {
    try await enqueue { [self] in
      try await loadSerialized()
    }
  }

  package func save(_ document: Format.CurrentDocument) async throws {
    try await enqueue { [self] in
      try await saveSerialized(document)
    }
  }

  private func enqueue<Result: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Result
  ) async throws -> Result {
    let previousTask = operationTail
    let operationTask = Task<Result, Error> {
      await previousTask?.value
      return try await operation()
    }
    operationTail = Task {
      _ = try? await operationTask.value
    }
    return try await operationTask.value
  }

  private func loadSerialized() async throws -> VersionedJSONLoad<Format.CurrentDocument> {
    do {
      let result = try await loadFromDisk()
      accessState = .writable
      return result
    } catch {
      accessState = .blocked
      throw error
    }
  }

  private func loadFromDisk() async throws -> VersionedJSONLoad<Format.CurrentDocument> {
    try validateCurrentVersion()

    switch try await read() {
    case .missing:
      return .missing
    case .data(let data):
      let sourceVersion = try probeVersion(in: data)
      guard sourceVersion >= 0 else {
        throw VersionedJSONFileError.invalidSchemaVersion(fileName: fileName)
      }
      guard sourceVersion <= Format.currentVersion else {
        throw VersionedJSONFileError.unsupportedSchemaVersion(
          fileName: fileName,
          found: sourceVersion,
          current: Format.currentVersion
        )
      }

      let document: Format.CurrentDocument
      do {
        document = try Format.decode(data, sourceVersion: sourceVersion)
      } catch {
        throw VersionedJSONFileError.decodeFailed(
          fileName: fileName,
          schemaVersion: sourceVersion
        )
      }

      guard sourceVersion < Format.currentVersion else {
        return .current(document)
      }

      let migratedData = try encodeAndValidate(document)
      try await write(migratedData)
      return .migrated(document, fromVersion: sourceVersion)
    }
  }

  private func saveSerialized(_ document: Format.CurrentDocument) async throws {
    switch accessState {
    case .unchecked, .writable:
      _ = try await loadSerialized()
    case .blocked:
      throw VersionedJSONFileError.saveBlocked(fileName: fileName)
    }

    let data = try encodeAndValidate(document)
    try await write(data)
  }

  private func validateCurrentVersion() throws {
    guard Format.currentVersion > 0 else {
      throw VersionedJSONFileError.invalidCurrentVersion(
        fileName: fileName,
        currentVersion: Format.currentVersion
      )
    }
  }

  private func probeVersion(in data: Data) throws -> Int {
    do {
      return try JSONDecoder().decode(SchemaVersionProbe.self, from: data).schemaVersion
    } catch {
      throw VersionedJSONFileError.invalidSchemaVersion(fileName: fileName)
    }
  }

  private func encodeAndValidate(_ document: Format.CurrentDocument) throws -> Data {
    try validateCurrentVersion()

    let data: Data
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      data = try encoder.encode(document)
    } catch {
      throw VersionedJSONFileError.encodeFailed(fileName: fileName)
    }

    let encodedVersion: Int
    do {
      encodedVersion = try probeVersion(in: data)
    } catch {
      throw VersionedJSONFileError.invalidEncodedDocument(fileName: fileName)
    }
    guard encodedVersion == Format.currentVersion else {
      throw VersionedJSONFileError.invalidEncodedDocument(fileName: fileName)
    }

    let decodedDocument: Format.CurrentDocument
    do {
      decodedDocument = try Format.decode(data, sourceVersion: encodedVersion)
    } catch {
      throw VersionedJSONFileError.invalidEncodedDocument(fileName: fileName)
    }
    guard decodedDocument == document else {
      throw VersionedJSONFileError.invalidEncodedDocument(fileName: fileName)
    }
    return data
  }

  private func read() async throws -> ReadResult {
    let fileURL = fileURL
    do {
      return try await Task.detached(priority: .utility) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
          return ReadResult.missing
        }
        do {
          return .data(try Data(contentsOf: fileURL))
        } catch {
          guard fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return .missing
          }
          throw error
        }
      }.value
    } catch {
      throw VersionedJSONFileError.readFailed(fileName: fileName)
    }
  }

  private func write(_ data: Data) async throws {
    let fileURL = fileURL
    do {
      try await Task.detached(priority: .utility) {
        try FileManager.default.createDirectory(
          at: fileURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
      }.value
    } catch {
      throw VersionedJSONFileError.writeFailed(fileName: fileName)
    }
  }

  private var fileName: String {
    fileURL.lastPathComponent
  }
}

private struct SchemaVersionProbe: Decodable {
  let schemaVersion: Int

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard container.contains(.schemaVersion) else {
      schemaVersion = 0
      return
    }
    guard try !container.decodeNil(forKey: .schemaVersion) else {
      throw DecodingError.valueNotFound(
        Int.self,
        DecodingError.Context(
          codingPath: container.codingPath + [CodingKeys.schemaVersion],
          debugDescription: "schemaVersion must be an integer."
        )
      )
    }
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
  }
}
