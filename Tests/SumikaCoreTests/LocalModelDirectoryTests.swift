import Foundation
import Testing

@testable import SumikaCore

struct LocalModelDirectoryTests {
  @Test
  func readContextTokenLimitReadsKnownTopLevelKeys() throws {
    let modelDirectory = try makeTemporaryModelDirectory(
      configJSON: #"{"max_position_embeddings":4096}"#)

    #expect(LocalModelDirectory.readContextTokenLimit(from: modelDirectory) == 4096)
  }

  @Test
  func readContextTokenLimitReadsNestedKnownKeys() throws {
    let modelDirectory = try makeTemporaryModelDirectory(
      configJSON: #"{"text_config":{"max_seq_len":8192}}"#)

    #expect(LocalModelDirectory.readContextTokenLimit(from: modelDirectory) == 8192)
  }

  @Test
  func readContextTokenLimitReturnsNilForMissingConfig() throws {
    let modelDirectory = FileManager.default.temporaryDirectory.appending(
      path: "sumika-chat-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

    #expect(LocalModelDirectory.readContextTokenLimit(from: modelDirectory) == nil)
  }

  private func makeTemporaryModelDirectory(configJSON: String) throws -> URL {
    let modelDirectory = FileManager.default.temporaryDirectory.appending(
      path: "sumika-chat-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    let configURL = modelDirectory.appending(path: "config.json", directoryHint: .notDirectory)
    try configJSON.write(to: configURL, atomically: true, encoding: .utf8)
    return modelDirectory
  }
}
