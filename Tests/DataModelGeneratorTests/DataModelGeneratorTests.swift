import Foundation
import SumikaTestSupport
import Testing

@testable import DataModelGenerator

@Suite(TemporaryDirectoryTrait(named: "sumika-data-model-generator-tests"))
struct DataModelGeneratorTests {
  @Test
  func emptyModelSetFailsWithoutOverwritingExistingDocument() throws {
    let repositoryRoot = try scopedTemporaryDirectory().appending(
      path: "repository",
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
