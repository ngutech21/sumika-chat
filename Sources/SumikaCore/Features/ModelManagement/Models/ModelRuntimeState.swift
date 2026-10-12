import Foundation

package enum ModelDownloadState: Equatable, Sendable {
  case idle
  case downloading(progress: Double?)
  case pausing(progress: Double?)
  case paused(progress: Double?)
  case cancelling
  case downloaded
  case failed(String)

  package var isDownloading: Bool {
    if case .downloading = self {
      return true
    }

    return false
  }

  package var isInProgress: Bool {
    switch self {
    case .downloading, .pausing, .paused, .cancelling: true
    case .idle, .downloaded, .failed: false
    }
  }

  package var label: String {
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
    case .pausing:
      "Pausing"
    case .paused:
      "Paused"
    case .cancelling:
      "Cancelling"
    case .failed:
      "Download failed"
    }
  }
}

package enum ModelLoadState: Equatable, Sendable {
  case notLoaded
  case loading
  case ready
  case failed(String)

  package var label: String {
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

  package var systemImage: String {
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
