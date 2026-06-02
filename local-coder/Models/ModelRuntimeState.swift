import Foundation

enum ModelDownloadState: Equatable, Sendable {
  case idle
  case downloading(progress: Double?)
  case downloaded
  case failed(String)

  var isDownloading: Bool {
    if case .downloading = self {
      return true
    }

    return false
  }

  var label: String {
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

enum ModelLoadState: Equatable, Sendable {
  case notLoaded
  case loading
  case ready
  case failed(String)

  var label: String {
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

  var systemImage: String {
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
