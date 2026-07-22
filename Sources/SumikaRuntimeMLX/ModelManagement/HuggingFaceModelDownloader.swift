import Foundation
import HuggingFace
import SumikaCore

package enum ModelDownloadError: LocalizedError {
  case invalidRepositoryID(String)

  package var errorDescription: String? {
    switch self {
    case .invalidRepositoryID(let repoID):
      "Invalid Hugging Face model repository: \(repoID)"
    }
  }
}

package struct HuggingFaceModelDownloader: ModelDownloading, @unchecked Sendable {
  private let hubClient: HubClient
  private let fileManager: FileManager

  package init(hubClient: HubClient = .default, fileManager: FileManager = .default) {
    self.hubClient = hubClient
    self.fileManager = fileManager
  }

  package func download(
    model: ManagedModel,
    progressHandler: @MainActor @Sendable @escaping (Progress) -> Void
  ) async throws -> URL {
    guard let repoID = Repo.ID(rawValue: model.huggingFaceRepoID) else {
      throw ModelDownloadError.invalidRepositoryID(model.huggingFaceRepoID)
    }

    try fileManager.createDirectory(
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
