import Foundation

package protocol ModelDownloading: Sendable {
  /// Returns only after installation commits. Cancellation retains resumable files.
  func download(
    model: ManagedModel,
    progressHandler: @MainActor @Sendable @escaping (Progress) -> Void
  ) async throws -> URL

  /// Called after the download task drains; removes only the unfinished installation.
  func discardDownload(model: ManagedModel) async throws
}

package struct UnavailableModelDownloader: ModelDownloading {
  package init() {}

  package func discardDownload(model: ManagedModel) async throws {}

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
