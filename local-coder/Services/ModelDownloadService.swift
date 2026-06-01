import Foundation
import HuggingFace

protocol ModelDownloading: Sendable {
    func download(
        model: ManagedModel,
        progressHandler: @MainActor @Sendable @escaping (Progress) -> Void
    ) async throws -> URL
}

enum ModelDownloadError: LocalizedError {
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
    private let fileManager: FileManager

    init(hubClient: HubClient = .default, fileManager: FileManager = .default) {
        self.hubClient = hubClient
        self.fileManager = fileManager
    }

    func download(
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
