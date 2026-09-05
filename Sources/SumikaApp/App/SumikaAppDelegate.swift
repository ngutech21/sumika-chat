import AppKit

/// Delays termination until the active session is snapshotted and all queued
/// library writes have reached disk — the unstructured save tasks would
/// otherwise be killed mid-write on quit. A timeout backstop keeps a hanging
/// write from blocking termination indefinitely.
final class SumikaAppDelegate: NSObject, NSApplicationDelegate {
  private let waitForTimeout: @MainActor () async -> Void
  private let terminationReply: @MainActor (NSApplication) -> Void

  var prepareForTermination: (@MainActor () async -> Void)?
  private var hasRepliedToTermination = false

  override convenience init() {
    self.init(
      waitForTimeout: { try? await Task.sleep(for: .seconds(3)) },
      terminationReply: { $0.reply(toApplicationShouldTerminate: true) }
    )
  }

  init(
    waitForTimeout: @escaping @MainActor () async -> Void,
    terminationReply: @escaping @MainActor (NSApplication) -> Void
  ) {
    self.waitForTimeout = waitForTimeout
    self.terminationReply = terminationReply
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let prepareForTermination else {
      return .terminateNow
    }

    hasRepliedToTermination = false
    Task { [weak self] in
      await prepareForTermination()
      self?.replyToTermination(sender)
    }
    Task { [weak self, waitForTimeout] in
      await waitForTimeout()
      self?.replyToTermination(sender)
    }
    return .terminateLater
  }

  private func replyToTermination(_ sender: NSApplication) {
    guard !hasRepliedToTermination else {
      return
    }
    hasRepliedToTermination = true
    terminationReply(sender)
  }
}
