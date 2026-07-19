import Foundation
import Testing

@testable import SumikaCore

struct ModelRuntimeStateTests {
  @Test
  func downloadStateIdentifiesActiveDownloads() {
    #expect(ModelDownloadState.downloading(progress: nil).isDownloading)
    #expect(ModelDownloadState.downloading(progress: 0.4).isDownloading)
    #expect(!ModelDownloadState.idle.isDownloading)
    #expect(!ModelDownloadState.downloaded.isDownloading)
    #expect(!ModelDownloadState.failed("error").isDownloading)
  }

  @Test
  func downloadStateLabelsMatchExistingCopy() {
    let formattedProgress = 0.42.formatted(.percent.precision(.fractionLength(0)))

    #expect(ModelDownloadState.idle.label == "Not downloaded")
    #expect(ModelDownloadState.downloading(progress: nil).label == "Downloading")
    #expect(
      ModelDownloadState.downloading(progress: 0.42).label == "Downloading \(formattedProgress)")
    #expect(ModelDownloadState.downloaded.label == "Downloaded")
    #expect(ModelDownloadState.failed("network").label == "Download failed")
  }

  @Test
  func loadStateLabelsAndSystemImagesMatchExistingCopy() {
    #expect(ModelLoadState.notLoaded.label == "No model loaded")
    #expect(ModelLoadState.notLoaded.systemImage == "circle")

    #expect(ModelLoadState.loading.label == "Loading model")
    #expect(ModelLoadState.loading.systemImage == "clock")

    #expect(ModelLoadState.ready.label == "Model ready")
    #expect(ModelLoadState.ready.systemImage == "checkmark.circle.fill")

    #expect(ModelLoadState.failed("error").label == "Model failed")
    #expect(ModelLoadState.failed("error").systemImage == "xmark.octagon.fill")
  }
}
