import Foundation

public enum ModelDownloadState: Equatable, Sendable {
  case idle
  case downloading(progress: Double?)
  case downloaded
  case failed(String)

  public var isDownloading: Bool {
    if case .downloading = self {
      return true
    }

    return false
  }

  public var label: String {
    switch self {
    case .idle:
      "Not downloaded"
    case .downloading(let progress):
      if let progress {
        "Downloading \(progress.formatted(.percent.precision(.fractionLength(0))))"
      } else {
        "Downloading"
      }
    case .downloaded:
      "Downloaded"
    case .failed:
      "Download failed"
    }
  }
}

public enum ModelLoadState: Equatable, Sendable {
  case notLoaded
  case loading
  case ready
  case failed(String)

  public var label: String {
    switch self {
    case .notLoaded:
      "No model loaded"
    case .loading:
      "Loading model"
    case .ready:
      "Model ready"
    case .failed:
      "Model failed"
    }
  }

  public var systemImage: String {
    switch self {
    case .notLoaded:
      "circle"
    case .loading:
      "clock"
    case .ready:
      "checkmark.circle.fill"
    case .failed:
      "xmark.octagon.fill"
    }
  }
}
