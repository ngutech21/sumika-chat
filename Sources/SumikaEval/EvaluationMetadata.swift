import CryptoKit
import Foundation
import SumikaCore

struct EvaluationMetadata: Encodable, Sendable {
  struct ModelFile: Encodable, Sendable {
    let path: String
    let byteCount: Int
    let sha256: String
  }

  // Serialized by the synthesized Encodable conformance.
  // swiftlint:disable:next unused_declaration
  let schemaVersion = 1
  let modelID: String
  let huggingFaceRepoID: String
  let modelDirectory: String
  let modelFiles: [ModelFile]
  let buildConfiguration: String
  let settings: StoredModelSettings
  let workspaceRoot: String
  let timeoutSeconds: Double?
  let maxToolLoopIterations: Int
  let networkPolicy: EvaluationNetworkPolicy
  let webAccessSettings: WebAccessSettings
  // Serialized by the synthesized Encodable conformance.
  // swiftlint:disable unused_declaration
  let interactionMode = WorkspaceInteractionMode.agent
  let toolApprovalPolicy = ToolApprovalPolicy.automatic
  let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
  let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
  // swiftlint:enable unused_declaration

  static func capture(
    model: ManagedModel, settings: StoredModelSettings, options: EvaluationOptions
  ) async throws -> Self {
    let files = try await modelFiles(in: model.localDirectoryURL)
    #if DEBUG
      let buildConfiguration = "debug"
    #else
      let buildConfiguration = "release"
    #endif
    return Self(
      modelID: model.id, huggingFaceRepoID: model.huggingFaceRepoID,
      modelDirectory: model.localDirectoryURL.path(percentEncoded: false), modelFiles: files,
      buildConfiguration: buildConfiguration,
      settings: settings, workspaceRoot: options.workspaceRoot.path(percentEncoded: false),
      timeoutSeconds: options.timeoutSeconds, maxToolLoopIterations: model.maxToolLoopIterations,
      networkPolicy: options.networkPolicy,
      webAccessSettings: WebAccessSettings(policy: options.networkPolicy.webEnabled ? .allow : .off)
    )
  }

  static func modelFiles(in directory: URL) async throws -> [ModelFile] {
    let capture = Task.detached {
      let root = directory.resolvingSymlinksInPath()
      let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
      ]
      var files: [ModelFile] = []
      var enumerationError: Error?
      guard
        let enumerator = FileManager.default.enumerator(
          at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles],
          errorHandler: { _, error in
            enumerationError = error
            return false
          }
        )
      else { throw EvaluationError("Cannot enumerate model files") }
      while let url = enumerator.nextObject() as? URL {
        try Task.checkCancellation()
        let before = try url.resourceValues(forKeys: keys)
        guard before.isRegularFile == true else { continue }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var byteCount = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
          try Task.checkCancellation()
          hash.update(data: data)
          byteCount += data.count
        }
        let after = try URL(filePath: url.path).resourceValues(forKeys: keys)
        guard before.fileSize == byteCount, after.fileSize == before.fileSize,
          after.contentModificationDate == before.contentModificationDate
        else {
          throw EvaluationError("Model file changed during capture: \(url.lastPathComponent)")
        }
        files.append(
          ModelFile(
            path: String(
              url.deletingLastPathComponent().resolvingSymlinksInPath()
                .appending(path: url.lastPathComponent).path.dropFirst(root.path.count + 1)
            ), byteCount: byteCount,
            sha256: hash.finalize().map { String(format: "%02x", $0) }.joined()
          )
        )
      }
      if let enumerationError { throw enumerationError }
      guard !files.isEmpty else { throw EvaluationError("The model directory is empty") }
      return files.sorted { $0.path < $1.path }
    }
    return try await withTaskCancellationHandler {
      try await capture.value
    } onCancel: {
      capture.cancel()
    }
  }
}
