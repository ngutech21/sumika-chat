import Foundation
import HuggingFace
import SumikaCore

private enum ModelDownloadError: LocalizedError {
  case invalidRepositoryID(String)

  var errorDescription: String? {
    switch self {
    case .invalidRepositoryID(let repoID):
      "Invalid Hugging Face model repository: \(repoID)"
    }
  }
}

struct HuggingFaceModelDownloader: ModelDownloading {
  private let hubClient: HubClient
  private let modelDirectoryBaseURL: URL

  init(
    hubClient: HubClient = HubClient(cache: nil),
    modelDirectoryBaseURL: URL = LocalModelDirectory.defaultBaseURL
  ) {
    self.hubClient = hubClient
    self.modelDirectoryBaseURL = modelDirectoryBaseURL
  }

  func download(
    model: ManagedModel,
    progressHandler: @MainActor @Sendable @escaping (Progress) -> Void
  ) async throws -> URL {
    guard let repoID = Repo.ID(rawValue: model.huggingFaceRepoID) else {
      throw ModelDownloadError.invalidRepositoryID(model.huggingFaceRepoID)
    }

    try FileManager.default.createDirectory(
      at: modelDirectoryBaseURL,
      withIntermediateDirectories: true
    )

    let destination = modelDirectoryBaseURL.appending(
      path: model.localDirectoryName, directoryHint: .isDirectory)
    do {
      return try await hubClient.downloadSnapshot(
        of: repoID,
        to: destination,
        matching: ["*.safetensors", "*.json", "*.jinja"],
        progressHandler: progressHandler
      )
    } catch HubCacheError.snapshotRequiresCacheOrDestination where hubClient.cache == nil {
      // shortcut: swift-huggingface 0.13 throws after downloading; remove when cache-free returns are fixed.
      return destination
    }
  }
}
