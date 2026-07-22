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

  init(hubClient: HubClient = .default) {
    self.hubClient = hubClient
  }

  func download(
    model: ManagedModel,
    progressHandler: @MainActor @Sendable @escaping (Progress) -> Void
  ) async throws -> URL {
    guard let repoID = Repo.ID(rawValue: model.huggingFaceRepoID) else {
      throw ModelDownloadError.invalidRepositoryID(model.huggingFaceRepoID)
    }

    try FileManager.default.createDirectory(
      at: LocalModelDirectory.defaultBaseURL,
      withIntermediateDirectories: true
    )

    return try await hubClient.downloadSnapshot(
      of: repoID,
      to: model.localDirectoryURL,
      matching: ["*.safetensors", "*.json", "*.jinja"],
      progressHandler: progressHandler
    )
  }
}
