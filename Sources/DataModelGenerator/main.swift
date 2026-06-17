import DataModelGeneratorCore
import Foundation

let repositoryRoot = URL(filePath: FileManager.default.currentDirectoryPath)
let modelsDirectory = repositoryRoot.appending(
  path: "Sources/SumikaCore/Models",
  directoryHint: .isDirectory
)
let outputURL = repositoryRoot.appending(
  path: "docs/data-model.md",
  directoryHint: .notDirectory
)

do {
  try DataModelGenerator().generate(
    modelsDirectory: modelsDirectory,
    outputURL: outputURL,
    repositoryRoot: repositoryRoot
  )
  print("Generated \(outputURL.path)")
} catch {
  FileHandle.standardError.write(Data("data-model generation failed: \(error)\n".utf8))
  exit(1)
}
