import AppKit
import SumikaCore
import SwiftUI
import Synchronization

@MainActor
final class RuntimeApplicationStateMonitor: NSObject {
  nonisolated private let snapshotStorage = Mutex(RuntimeApplicationStateSnapshot.unavailable)
  private weak var mainWindow: NSWindow?

  override init() {
    super.init()
    let center = NotificationCenter.default
    for name in Self.applicationNotifications + Self.windowNotifications {
      center.addObserver(
        self,
        selector: #selector(refreshFromNotification),
        name: name,
        object: nil
      )
    }
    refresh()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  nonisolated func snapshot() -> RuntimeApplicationStateSnapshot {
    snapshotStorage.withLock { $0 }
  }

  func updateMainWindow(previous: NSWindow?, current: NSWindow?) {
    if let current {
      mainWindow = current
    } else if mainWindow === previous {
      mainWindow = nil
    }
    refresh()
  }

  static func mainWindowVisibility(
    isMiniaturized: Bool,
    isVisible: Bool,
    isOccluded: Bool
  ) -> MainWindowVisibilityState {
    if isMiniaturized {
      return .minimized
    }
    if !isVisible {
      return .notVisible
    }
    return isOccluded ? .occluded : .visible
  }

  @objc private func refreshFromNotification(_: Notification) {
    refresh()
  }

  private func refresh() {
    let application = NSApplication.shared
    let mainWindowVisibility =
      if let mainWindow {
        Self.mainWindowVisibility(
          isMiniaturized: mainWindow.isMiniaturized,
          isVisible: mainWindow.isVisible,
          isOccluded: !mainWindow.occlusionState.contains(.visible)
        )
      } else {
        MainWindowVisibilityState.unavailable
      }
    let snapshot = RuntimeApplicationStateSnapshot(
      applicationActivation: application.isActive ? .active : .inactive,
      applicationVisibility: application.isHidden ? .hidden : .shown,
      applicationOcclusion: application.occlusionState.contains(.visible) ? .visible : .occluded,
      mainWindowVisibility: mainWindowVisibility
    )
    snapshotStorage.withLock { $0 = snapshot }
  }

  private static let applicationNotifications: [Notification.Name] = [
    NSApplication.didBecomeActiveNotification,
    NSApplication.didResignActiveNotification,
    NSApplication.didHideNotification,
    NSApplication.didUnhideNotification,
    NSApplication.didChangeOcclusionStateNotification,
  ]

  private static let windowNotifications: [Notification.Name] = [
    NSWindow.didBecomeKeyNotification,
    NSWindow.didResignKeyNotification,
    NSWindow.didMiniaturizeNotification,
    NSWindow.didDeminiaturizeNotification,
    NSWindow.didChangeOcclusionStateNotification,
    NSWindow.willCloseNotification,
  ]
}

struct RuntimeMainWindowObserver: NSViewRepresentable {
  let onWindowChange: @MainActor (NSWindow?, NSWindow?) -> Void

  func makeNSView(context _: Context) -> RuntimeMainWindowObservationView {
    RuntimeMainWindowObservationView(onWindowChange: onWindowChange)
  }

  func updateNSView(
    _ view: RuntimeMainWindowObservationView,
    context _: Context
  ) {
    view.onWindowChange = onWindowChange
  }
}

final class RuntimeMainWindowObservationView: NSView {
  var onWindowChange: @MainActor (NSWindow?, NSWindow?) -> Void
  private weak var observedWindow: NSWindow?

  init(onWindowChange: @escaping @MainActor (NSWindow?, NSWindow?) -> Void) {
    self.onWindowChange = onWindowChange
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard observedWindow !== window else {
      return
    }
    let previous = observedWindow
    observedWindow = window
    onWindowChange(previous, window)
  }
}
