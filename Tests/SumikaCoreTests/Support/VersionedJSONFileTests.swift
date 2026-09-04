import Foundation
import SumikaTestSupport
import Testing

@testable import SumikaCore

@Suite(TemporaryDirectoryTrait(named: "sumika-versioned-json-tests"))
struct VersionedJSONFileTests {
  @Test
  func missingFileLoadsAsMissingAndCanBeSavedWithoutPriorLoad() async throws {
    let fileURL = try settingsURL()
    let file = VersionedJSONFile<TestFormat>(fileURL: fileURL)

    #expect(try await file.load() == .missing)

    let saveWithoutLoadURL = fileURL.deletingLastPathComponent().appending(
      path: "save-without-load.json",
      directoryHint: .notDirectory
    )
    let saveWithoutLoadFile = VersionedJSONFile<TestFormat>(fileURL: saveWithoutLoadURL)
    let document = TestDocument(value: "created")
    try await saveWithoutLoadFile.save(document)

    #expect(try await saveWithoutLoadFile.load() == .current(document))
  }

  @Test
  func zeroCurrentVersionIsRejectedBecauseVersionZeroIsReservedForLegacyInput() async throws {
    let file = VersionedJSONFile<ZeroVersionFormat>(fileURL: try settingsURL())

    await #expect(
      throws: VersionedJSONFileError.invalidCurrentVersion(
        fileName: "settings.json",
        currentVersion: 0
      )
    ) {
      try await file.load()
    }
  }

  @Test
  func currentFileLoadsWithoutBeingRewritten() async throws {
    let fileURL = try settingsURL()
    let originalData = Data(#"{"value":"kept","schemaVersion":1}"#.utf8)
    try originalData.write(to: fileURL)
    let file = VersionedJSONFile<TestFormat>(fileURL: fileURL)

    #expect(try await file.load() == .current(TestDocument(value: "kept")))
    #expect(try Data(contentsOf: fileURL) == originalData)
  }

  @Test
  func unversionedFileMigratesToVerifiedCurrentEncoding() async throws {
    let fileURL = try settingsURL()
    try Data(#"{"value":"legacy"}"#.utf8).write(to: fileURL)
    let file = VersionedJSONFile<TestFormat>(fileURL: fileURL)
    let expectedDocument = TestDocument(value: "legacy")

    #expect(
      try await file.load() == .migrated(expectedDocument, fromVersion: 0)
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    #expect(try Data(contentsOf: fileURL) == encoder.encode(expectedDocument))
    #expect(try await file.load() == .current(expectedDocument))
  }

  @Test
  func futureVersionFailsClosedAndBlocksSaves() async throws {
    let fileURL = try settingsURL()
    let originalData = Data(#"{"schemaVersion":2,"value":"future"}"#.utf8)
    try originalData.write(to: fileURL)
    let file = VersionedJSONFile<TestFormat>(fileURL: fileURL)

    await #expect(
      throws: VersionedJSONFileError.unsupportedSchemaVersion(
        fileName: "settings.json",
        found: 2,
        current: 1
      )
    ) {
      try await file.load()
    }
    await #expect(throws: VersionedJSONFileError.saveBlocked(fileName: "settings.json")) {
      try await file.save(TestDocument(value: "replacement"))
    }
    #expect(try Data(contentsOf: fileURL) == originalData)
  }

  @Test
  func futureVersionWrittenAfterSuccessfulLoadBlocksSave() async throws {
    let fileURL = try settingsURL()
    try Data(#"{"schemaVersion":1,"value":"current"}"#.utf8).write(to: fileURL)
    let file = VersionedJSONFile<TestFormat>(fileURL: fileURL)

    #expect(try await file.load() == .current(TestDocument(value: "current")))

    let futureData = Data(#"{"schemaVersion":2,"value":"future"}"#.utf8)
    try futureData.write(to: fileURL, options: .atomic)

    await #expect(
      throws: VersionedJSONFileError.unsupportedSchemaVersion(
        fileName: "settings.json",
        found: 2,
        current: 1
      )
    ) {
      try await file.save(TestDocument(value: "replacement"))
    }
    #expect(try Data(contentsOf: fileURL) == futureData)

    await #expect(throws: VersionedJSONFileError.saveBlocked(fileName: "settings.json")) {
      try await file.save(TestDocument(value: "second replacement"))
    }
  }

  @Test(arguments: [
    Data("not json".utf8),
    Data(#"{"schemaVersion":null,"value":"invalid"}"#.utf8),
    Data(#"{"schemaVersion":"1","value":"invalid"}"#.utf8),
    Data(#"{"schemaVersion":-1,"value":"invalid"}"#.utf8),
  ])
  func malformedOrNegativeVersionFailsWithoutChangingSource(_ originalData: Data) async throws {
    let fileURL = try settingsURL()
    try originalData.write(to: fileURL)
    let file = VersionedJSONFile<TestFormat>(fileURL: fileURL)

    await #expect(
      throws: VersionedJSONFileError.invalidSchemaVersion(fileName: "settings.json")
    ) {
      try await file.load()
    }
    #expect(try Data(contentsOf: fileURL) == originalData)
  }

  @Test
  func saveBeforeLoadValidatesExistingDataAndDoesNotOverwriteInvalidFile() async throws {
    let fileURL = try settingsURL()
    let originalData = Data("invalid existing data".utf8)
    try originalData.write(to: fileURL)
    let file = VersionedJSONFile<TestFormat>(fileURL: fileURL)

    await #expect(
      throws: VersionedJSONFileError.invalidSchemaVersion(fileName: "settings.json")
    ) {
      try await file.save(TestDocument(value: "replacement"))
    }
    await #expect(throws: VersionedJSONFileError.saveBlocked(fileName: "settings.json")) {
      try await file.save(TestDocument(value: "second replacement"))
    }
    #expect(try Data(contentsOf: fileURL) == originalData)
  }

  @Test
  func blockedFileRequiresSuccessfulExplicitReloadBeforeSaving() async throws {
    let fileURL = try settingsURL()
    try Data("invalid".utf8).write(to: fileURL)
    let file = VersionedJSONFile<TestFormat>(fileURL: fileURL)

    await #expect(throws: VersionedJSONFileError.self) {
      try await file.load()
    }

    let recoveredDocument = TestDocument(value: "recovered")
    let encoder = JSONEncoder()
    let recoveredData = try encoder.encode(recoveredDocument)
    try recoveredData.write(to: fileURL, options: .atomic)

    await #expect(throws: VersionedJSONFileError.saveBlocked(fileName: "settings.json")) {
      try await file.save(TestDocument(value: "must wait"))
    }
    #expect(try Data(contentsOf: fileURL) == recoveredData)

    #expect(try await file.load() == .current(recoveredDocument))
    let replacement = TestDocument(value: "replacement")
    try await file.save(replacement)
    #expect(try await file.load() == .current(replacement))
  }

  @Test
  func failedEncodedDocumentVerificationLeavesExistingSourceUnchanged() async throws {
    let fileURL = try settingsURL()
    let originalDocument = VerificationFailureDocument(value: "original")
    let originalData = try JSONEncoder().encode(originalDocument)
    try originalData.write(to: fileURL)
    let file = VersionedJSONFile<VerificationFailureFormat>(fileURL: fileURL)
    #expect(try await file.load() == .current(originalDocument))

    await #expect(
      throws: VersionedJSONFileError.invalidEncodedDocument(fileName: "settings.json")
    ) {
      try await file.save(
        VerificationFailureDocument(value: "replacement", mutateAfterDecoding: true)
      )
    }

    #expect(try Data(contentsOf: fileURL) == originalData)
  }

  @Test
  func failedAtomicWriteLeavesExistingSourceUnchanged() async throws {
    let fileURL = try settingsURL()
    let originalDocument = TestDocument(value: "original")
    let originalData = try JSONEncoder().encode(originalDocument)
    try originalData.write(to: fileURL)
    let file = VersionedJSONFile<TestFormat>(fileURL: fileURL)
    #expect(try await file.load() == .current(originalDocument))

    let parentURL = fileURL.deletingLastPathComponent()
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500],
      ofItemAtPath: parentURL.path(percentEncoded: false)
    )
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: parentURL.path(percentEncoded: false)
      )
    }

    await #expect(throws: VersionedJSONFileError.writeFailed(fileName: "settings.json")) {
      try await file.save(TestDocument(value: "replacement"))
    }
    #expect(try Data(contentsOf: fileURL) == originalData)
  }

  @Test
  func unreadableExistingPathFailsClosedAndBlocksSaves() async throws {
    let fileURL = try settingsURL()
    try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)
    let file = VersionedJSONFile<TestFormat>(fileURL: fileURL)

    await #expect(throws: VersionedJSONFileError.readFailed(fileName: "settings.json")) {
      try await file.load()
    }
    await #expect(throws: VersionedJSONFileError.saveBlocked(fileName: "settings.json")) {
      try await file.save(TestDocument(value: "replacement"))
    }
    var isDirectory: ObjCBool = false
    #expect(
      FileManager.default.fileExists(
        atPath: fileURL.path(percentEncoded: false),
        isDirectory: &isDirectory
      )
    )
    #expect(isDirectory.boolValue)
  }

  @Test
  func concurrentSavesCompleteInSubmissionOrder() async throws {
    let fileURL = try settingsURL()
    let file = VersionedJSONFile<TestFormat>(fileURL: fileURL)
    #expect(try await file.load() == .missing)

    let first = TestDocument(
      value: "first",
      payload: String(repeating: "a", count: 4_000_000),
      signalOnEncode: true
    )
    let second = TestDocument(value: "second")
    let firstTask = Task {
      try await file.save(first)
    }
    await ConcurrentSaveSignal.waitForFirstEncode()
    let secondTask = Task {
      try await file.save(second)
    }

    try await firstTask.value
    try await secondTask.value
    #expect(try await file.load() == .current(second))
  }

  private func settingsURL() throws -> URL {
    try scopedTemporaryDirectory().appending(
      path: "settings.json",
      directoryHint: .notDirectory
    )
  }
}

private enum TestFormat: VersionedJSONFormat {
  static let currentVersion = 1

  static func decode(_ data: Data, sourceVersion: Int) throws -> TestDocument {
    switch sourceVersion {
    case 0:
      let legacy = try JSONDecoder().decode(LegacyTestDocument.self, from: data)
      return TestDocument(value: legacy.value)
    case currentVersion:
      let document = try JSONDecoder().decode(TestDocument.self, from: data)
      guard document.schemaVersion == currentVersion else {
        throw TestFormatError.invalidVersion
      }
      return document
    default:
      throw TestFormatError.invalidVersion
    }
  }
}

private struct LegacyTestDocument: Codable {
  let value: String
}

private struct TestDocument: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let value: String
  let payload: String
  let signalOnEncode: Bool

  init(
    schemaVersion: Int = TestFormat.currentVersion,
    value: String,
    payload: String = "",
    signalOnEncode: Bool = false
  ) {
    self.schemaVersion = schemaVersion
    self.value = value
    self.payload = payload
    self.signalOnEncode = signalOnEncode
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case value
    case payload
    case signalOnEncode
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    value = try container.decode(String.self, forKey: .value)
    payload = try container.decodeIfPresent(String.self, forKey: .payload) ?? ""
    signalOnEncode = try container.decodeIfPresent(Bool.self, forKey: .signalOnEncode) ?? false
  }

  func encode(to encoder: any Encoder) throws {
    if signalOnEncode {
      ConcurrentSaveSignal.firstEncode.signal()
    }
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(value, forKey: .value)
    if !payload.isEmpty {
      try container.encode(payload, forKey: .payload)
    }
    if signalOnEncode {
      try container.encode(signalOnEncode, forKey: .signalOnEncode)
    }
  }
}

private enum TestFormatError: Error {
  case invalidVersion
}

private enum VerificationFailureFormat: VersionedJSONFormat {
  static let currentVersion = 1

  static func decode(_ data: Data, sourceVersion: Int) throws -> VerificationFailureDocument {
    guard sourceVersion == currentVersion else {
      throw TestFormatError.invalidVersion
    }
    let document = try JSONDecoder().decode(VerificationFailureDocument.self, from: data)
    guard document.mutateAfterDecoding else {
      return document
    }
    return VerificationFailureDocument(
      value: document.value + "-decoded",
      mutateAfterDecoding: true
    )
  }
}

private enum ZeroVersionFormat: VersionedJSONFormat {
  static let currentVersion = 0

  static func decode(_ data: Data, sourceVersion _: Int) throws -> ZeroVersionDocument {
    try JSONDecoder().decode(ZeroVersionDocument.self, from: data)
  }
}

private struct ZeroVersionDocument: Codable, Equatable, Sendable {
  let schemaVersion: Int
}

private struct VerificationFailureDocument: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let value: String
  let mutateAfterDecoding: Bool

  init(
    value: String,
    mutateAfterDecoding: Bool = false
  ) {
    schemaVersion = VerificationFailureFormat.currentVersion
    self.value = value
    self.mutateAfterDecoding = mutateAfterDecoding
  }
}

private enum ConcurrentSaveSignal {
  static let firstEncode = DispatchSemaphore(value: 0)

  static func waitForFirstEncode() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        firstEncode.wait()
        continuation.resume()
      }
    }
  }
}
