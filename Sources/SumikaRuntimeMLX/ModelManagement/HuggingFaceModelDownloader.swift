import Foundation
import HuggingFace
import SumikaCore

private enum ModelDownloadError: LocalizedError {
  case invalidRepository
  case invalidPath
  case incompleteModel

  var errorDescription: String? {
    switch self {
    case .invalidRepository: "Could not resolve the model repository revision."
    case .invalidPath: "The model contains an unsafe download path."
    case .incompleteModel: "The downloaded model is incomplete. Resume the download to try again."
    }
  }
}

actor HuggingFaceModelDownloader: ModelDownloading {
  private struct DownloadFile: Sendable {
    let request: URLRequest
    let destination: URL
    let size: Int64
    let progress: Progress
  }

  private let hubClient: HubClient
  private let modelDirectoryBaseURL: URL
  private let sessionConfiguration: URLSessionConfiguration

  init(
    hubClient: HubClient = HubClient(cache: nil),
    modelDirectoryBaseURL: URL = LocalModelDirectory.defaultBaseURL,
    sessionConfiguration: URLSessionConfiguration = .default
  ) {
    self.hubClient = hubClient
    self.modelDirectoryBaseURL = modelDirectoryBaseURL
    self.sessionConfiguration = sessionConfiguration
  }

  func download(
    model: ManagedModel,
    progressHandler: @MainActor @Sendable @escaping (Progress) -> Void
  ) async throws -> URL {
    guard let repoID = Repo.ID(rawValue: model.huggingFaceRepoID) else {
      throw ModelDownloadError.invalidRepository
    }
    let workDirectory = try downloadDirectory(for: model)
    let staging = try fileURL("model", in: workDirectory)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let revisionURL = try fileURL("revision", in: workDirectory)
    let revision: String
    if FileManager.default.fileExists(atPath: revisionURL.path) {
      revision = try String(contentsOf: revisionURL, encoding: .utf8)
    } else {
      guard let resolved = try await hubClient.getModel(repoID).sha,
        resolved.count == 40, resolved.allSatisfy(\.isHexDigit)
      else {
        throw ModelDownloadError.invalidRepository
      }
      revision = resolved
      try Task.checkCancellation()
      try revision.write(to: revisionURL, atomically: true, encoding: .utf8)
    }
    guard revision.count == 40, revision.allSatisfy(\.isHexDigit) else {
      throw ModelDownloadError.invalidRepository
    }
    let files = try await hubClient.listFiles(in: repoID, revision: revision, recursive: true)
      .filter {
        $0.type == .file
          && ["safetensors", "json", "jinja"].contains(URL(filePath: $0.path).pathExtension)
      }
    guard !files.isEmpty else { throw ModelDownloadError.incompleteModel }
    let progress = Progress(
      totalUnitCount: files.reduce(0) { $0 + Int64(max($1.effectiveSize ?? 0, 1)) })
    let token = await hubClient.bearerToken
    let downloads = try files.map { file -> DownloadFile in
      let destination = try fileURL(file.path, in: staging)
      let size = Int64(file.effectiveSize ?? -1)
      guard size >= 0 else { throw ModelDownloadError.incompleteModel }
      let child = Progress(
        totalUnitCount: max(size, 1), parent: progress, pendingUnitCount: max(size, 1))
      var request = URLRequest(
        url: hubClient.host.appending(path: model.huggingFaceRepoID)
          .appending(path: "resolve").appending(path: revision).appending(path: file.path))
      if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
      request.setValue(hubClient.userAgent, forHTTPHeaderField: "User-Agent")
      request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
      return DownloadFile(request: request, destination: destination, size: size, progress: child)
    }
    let sampler = Task {
      while !Task.isCancelled {
        await progressHandler(progress)
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        for (index, download) in downloads.enumerated() {
          if index >= 4 { try await group.next() }
          let configuration = sessionConfiguration
          group.addTask {
            try await ModelFileDownload.download(
              request: download.request, to: download.destination, size: download.size,
              progress: download.progress, configuration: configuration
            )
          }
        }
        try await group.waitForAll()
      }
    } catch {
      sampler.cancel()
      await sampler.value
      throw error
    }
    sampler.cancel()
    await sampler.value
    try Task.checkCancellation()
    guard LocalModelDirectory.isComplete(at: staging) else {
      throw ModelDownloadError.incompleteModel
    }
    let destination = modelDirectoryBaseURL.appending(path: model.localDirectoryName)
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
    } else {
      try FileManager.default.moveItem(at: staging, to: destination)
    }
    // Installation has committed; a later cancellation must not undo it.
    try? FileManager.default.removeItem(at: workDirectory)
    await progressHandler(progress)
    return destination
  }

  func discardDownload(model: ManagedModel) async throws {
    let directory = try downloadDirectory(for: model)
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
  }

  private func downloadDirectory(for model: ManagedModel) throws -> URL {
    guard !model.localDirectoryName.contains("/"), !model.localDirectoryName.hasPrefix(".") else {
      throw ModelDownloadError.invalidPath
    }
    _ = try fileURL(model.localDirectoryName, in: modelDirectoryBaseURL)
    return try fileURL(".downloads/\(model.localDirectoryName)", in: modelDirectoryBaseURL)
  }

  private func fileURL(_ path: String, in root: URL) throws -> URL {
    let components = path.components(separatedBy: "/")
    guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
      !path.contains("\\")
    else { throw ModelDownloadError.invalidPath }
    func isSymbolicLink(_ url: URL) -> Bool {
      (try? FileManager.default.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType
        == .typeSymbolicLink
    }
    var url = root.resolvingSymlinksInPath()
    for component in components {
      url.append(path: component)
      guard !isSymbolicLink(url) else { throw ModelDownloadError.invalidPath }
    }
    guard !isSymbolicLink(url.appendingPathExtension("partial")) else {
      throw ModelDownloadError.invalidPath
    }
    return url
  }
}
