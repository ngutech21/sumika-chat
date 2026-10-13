import Foundation
import Testing

@testable import SumikaEval

struct EvaluationMetadataTests {
  @Test
  func fingerprintsModelBytesWithStableRelativePaths() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let nested = directory.appending(path: "nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data("abc".utf8).write(to: nested.appending(path: "model.safetensors"))
    try Data("{}".utf8).write(to: directory.appending(path: "config.json"))
    try Data("cache".utf8).write(to: directory.appending(path: ".DS_Store"))

    let files = try await EvaluationMetadata.modelFiles(in: directory)
    #expect(files.map(\.path) == ["config.json", "nested/model.safetensors"])
    #expect(files.last?.byteCount == 3)
    #expect(
      files.last?.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
    try Data("changed".utf8).write(to: nested.appending(path: "model.safetensors"))
    let changed = try await EvaluationMetadata.modelFiles(in: directory)
    #expect(changed.last?.sha256 != files.last?.sha256)
    let encoded =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(files)) as? [[String: Any]]
    #expect(encoded?.last?["path"] as? String == "nested/model.safetensors")
  }

  @Test
  func rejectsMissingAndEmptyModelDirectories() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    await #expect(throws: (any Error).self) {
      try await EvaluationMetadata.modelFiles(in: directory)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    await #expect(throws: EvaluationError.self) {
      try await EvaluationMetadata.modelFiles(in: directory)
    }
  }
}
