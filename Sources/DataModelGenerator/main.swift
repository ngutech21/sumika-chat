import Foundation

let repositoryRoot = URL(filePath: FileManager.default.currentDirectoryPath)
let modelsDirectories = [
  repositoryRoot.appending(
    path: "Sources/SumikaCore/Models",
    directoryHint: .isDirectory
  ),
  repositoryRoot.appending(
    path: "Sources/SumikaCore/Features/Workspace/Models",
    directoryHint: .isDirectory
  ),
  repositoryRoot.appending(
    path: "Sources/SumikaCore/Features/ModelManagement/Models",
    directoryHint: .isDirectory
  ),
  repositoryRoot.appending(
    path: "Sources/SumikaCore/Features/ToolRuntime/Models",
    directoryHint: .isDirectory
  ),
  repositoryRoot.appending(
    path: "Sources/SumikaCore/Features/Agent/MCP/Models",
    directoryHint: .isDirectory
  ),
]
let modelFiles = [
  repositoryRoot.appending(
    path: "Sources/SumikaCore/Features/Chat/Models/ChatGenerationSettings.swift",
    directoryHint: .notDirectory
  ),
  repositoryRoot.appending(
    path: "Sources/SumikaCore/Features/Chat/Models/PromptContext.swift",
    directoryHint: .notDirectory
  ),
  repositoryRoot.appending(
    path: "Sources/SumikaCore/Observability/TurnTraceEvent.swift",
    directoryHint: .notDirectory
  ),
]
let outputURL = repositoryRoot.appending(
  path: "docs/data-model.md",
  directoryHint: .notDirectory
)

do {
  try DataModelGenerator().generate(
    modelsDirectories: modelsDirectories,
    modelFiles: modelFiles,
    outputURL: outputURL,
    repositoryRoot: repositoryRoot
  )
  print("Generated \(outputURL.path)")
} catch {
  FileHandle.standardError.write(Data("data-model generation failed: \(error)\n".utf8))
  exit(1)
}
