import Foundation

package protocol ModelDownloading: Sendable {
  func download(
    model: ManagedModel,
    progressHandler: @MainActor @Sendable @escaping (Progress) -> Void
  ) async throws -> URL
}

package struct UnavailableModelDownloader: ModelDownloading {
  package init() {}

  package func download(
    model: ManagedModel,
    progressHandler: @MainActor @Sendable (Progress) -> Void
  ) async throws -> URL {
    _ = model
    _ = progressHandler
    throw UnavailableModelDownloadError()
  }
}

package struct UnavailableModelDownloadError: LocalizedError, Sendable {
  package var errorDescription: String? {
    "No model downloader is configured."
  }
}
