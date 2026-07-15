import Combine
import Sparkle

@MainActor
final class AppUpdater: ObservableObject {
  @Published private(set) var canCheckForUpdates = false

  private let updaterController: SPUStandardUpdaterController

  init(startingUpdater: Bool) {
    updaterController = SPUStandardUpdaterController(
      startingUpdater: startingUpdater,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
    updaterController.updater
      .publisher(for: \.canCheckForUpdates)
      .assign(to: &$canCheckForUpdates)
  }

  func checkForUpdates() {
    updaterController.updater.checkForUpdates()
  }
}
