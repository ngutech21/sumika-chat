import Foundation

public struct DataModelGenerator: Sendable {
  private let collector: DataModelCollector
  private let renderer: DataModelMarkdownRenderer

  public init(
    collector: DataModelCollector = DataModelCollector(),
    renderer: DataModelMarkdownRenderer = DataModelMarkdownRenderer()
  ) {
    self.collector = collector
    self.renderer = renderer
  }

  public func generate(
    modelsDirectories: [URL],
    modelFiles: [URL] = [],
    outputURL: URL,
    repositoryRoot: URL
  ) throws {
    let files =
      try modelsDirectories.flatMap { directory in
        try swiftFiles(in: directory)
      } + modelFiles
    let declarations = try files.flatMap { fileURL in
      let source = try String(contentsOf: fileURL, encoding: .utf8)
      let sourcePath = fileURL.pathRelative(to: repositoryRoot)
      return try collector.collect(source: source, sourcePath: sourcePath)
    }

    let document = DataModelDocument(
      models: declarations.sorted { lhs, rhs in
        if lhs.name == rhs.name {
          return lhs.sourcePath < rhs.sourcePath
        }
        return lhs.name < rhs.name
      }
    )
    let markdown = renderer.render(document)
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try markdown.write(to: outputURL, atomically: true, encoding: .utf8)
  }

  private func swiftFiles(in directory: URL) throws -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }

    var files: [URL] = []
    for case let url as URL in enumerator {
      guard url.pathExtension == "swift" else {
        continue
      }

      let values = try url.resourceValues(forKeys: [.isRegularFileKey])
      if values.isRegularFile == true {
        files.append(url)
      }
    }

    return files.sorted { $0.path < $1.path }
  }
}

extension URL {
  fileprivate func pathRelative(to root: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let filePath = standardizedFileURL.path
    guard filePath.hasPrefix(rootPath + "/") else {
      return filePath
    }
    return String(filePath.dropFirst(rootPath.count + 1))
  }
}
