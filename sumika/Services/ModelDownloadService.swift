import Foundation
import HuggingFace
import SumikaCore

nonisolated enum ModelDownloadError: LocalizedError {
  case invalidRepositoryID(String)

  var errorDescription: String? {
    switch self {
    case .invalidRepositoryID(let repoID):
      "Invalid Hugging Face model repository: \(repoID)"
    }
  }
}

nonisolated struct HuggingFaceModelDownloader: ModelDownloading, @unchecked Sendable {
  private let hubClient: HubClient
  private let fileManager: FileManager

  init(hubClient: HubClient = .default, fileManager: FileManager = .default) {
    self.hubClient = hubClient
    self.fileManager = fileManager
  }

  func download(
    model: ManagedModel,
    progressHandler: @MainActor @Sendable @escaping (Progress) -> Void
  ) async throws -> URL {
    try await downloadSnapshot(
      repoID: model.huggingFaceRepoID,
      to: model.localDirectoryURL,
      progressHandler: progressHandler
    )
  }

  func download(
    drafter: ManagedDrafterModel,
    progressHandler: @MainActor @Sendable @escaping (Progress) -> Void
  ) async throws -> URL {
    try await downloadSnapshot(
      repoID: drafter.huggingFaceRepoID,
      to: drafter.localDirectoryURL,
      progressHandler: progressHandler
    )
  }

  private func downloadSnapshot(
    repoID rawRepoID: String,
    to localDirectoryURL: URL,
    progressHandler: @MainActor @Sendable @escaping (Progress) -> Void
  ) async throws -> URL {
    guard let repoID = Repo.ID(rawValue: rawRepoID) else {
      throw ModelDownloadError.invalidRepositoryID(rawRepoID)
    }

    try fileManager.createDirectory(
      at: LocalModelDirectory.defaultBaseURL,
      withIntermediateDirectories: true
    )

    return try await hubClient.downloadSnapshot(
      of: repoID,
      to: localDirectoryURL,
      matching: ["*.safetensors", "*.json", "*.jinja"],
      progressHandler: progressHandler
    )
  }
}
