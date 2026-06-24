import Foundation

public protocol ModelDownloading: Sendable {
  func download(
    model: ManagedModel,
    progressHandler: @MainActor @Sendable @escaping (Progress) -> Void
  ) async throws -> URL

  func download(
    drafter: ManagedDrafterModel,
    progressHandler: @MainActor @Sendable @escaping (Progress) -> Void
  ) async throws -> URL
}

public struct UnavailableModelDownloader: ModelDownloading {
  public init() {}

  public func download(
    model: ManagedModel,
    progressHandler: @MainActor @Sendable (Progress) -> Void
  ) async throws -> URL {
    _ = model
    _ = progressHandler
    throw UnavailableModelDownloadError()
  }

  public func download(
    drafter: ManagedDrafterModel,
    progressHandler: @MainActor @Sendable (Progress) -> Void
  ) async throws -> URL {
    _ = drafter
    _ = progressHandler
    throw UnavailableModelDownloadError()
  }
}

public struct UnavailableModelDownloadError: LocalizedError, Sendable {
  public var errorDescription: String? {
    "No model downloader is configured."
  }
}
