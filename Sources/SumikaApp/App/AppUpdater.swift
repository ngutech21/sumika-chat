import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: ObservableObject {
  @Published private(set) var canCheckForUpdates = false

  private let updaterController: SPUStandardUpdaterController
  private let applicationIcon: NSImage?

  init(startingUpdater: Bool) {
    applicationIcon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
      .flatMap { NSImage(contentsOf: $0) }
    if let applicationIcon {
      // Sparkle uses this named image; keep macOS's icon background out of its dialogs.
      NSImage(named: NSImage.applicationIconName)?.setName(nil)
      applicationIcon.setName(NSImage.applicationIconName)
    }

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
