import DataModelGeneratorCore
import Foundation

let repositoryRoot = URL(filePath: FileManager.default.currentDirectoryPath)
let modelsDirectory = repositoryRoot.appending(
  path: "Sources/LocalCoderCore/Models",
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
  fputs("data-model generation failed: \(error)\n", stderr)
  exit(1)
}
