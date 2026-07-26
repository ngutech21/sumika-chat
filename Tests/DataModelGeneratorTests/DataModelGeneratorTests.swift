import Foundation
import Testing

@testable import DataModelGenerator

struct DataModelGeneratorTests {
  @Test
  func emptyModelSetFailsWithoutOverwritingExistingDocument() throws {
    let repositoryRoot = FileManager.default.temporaryDirectory.appending(
      path: "sumika-data-model-generator-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let outputURL = repositoryRoot.appending(
      path: "data-model.md",
      directoryHint: .notDirectory
    )
    try FileManager.default.createDirectory(
      at: repositoryRoot,
      withIntermediateDirectories: true
    )
    defer {
      try? FileManager.default.removeItem(at: repositoryRoot)
    }
    try "existing document".write(to: outputURL, atomically: true, encoding: .utf8)

    #expect(throws: DataModelGeneratorError.noModelsFound) {
      try DataModelGenerator().generate(
        modelsDirectories: [],
        outputURL: outputURL,
        repositoryRoot: repositoryRoot
      )
    }
    #expect(try String(contentsOf: outputURL, encoding: .utf8) == "existing document")
  }
}
