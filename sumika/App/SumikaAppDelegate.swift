import AppKit

/// Delays termination until the active session is snapshotted and all queued
/// library writes have reached disk — the unstructured save tasks would
/// otherwise be killed mid-write on quit. A timeout backstop keeps a hanging
/// write from blocking termination indefinitely.
final class SumikaAppDelegate: NSObject, NSApplicationDelegate {
  private static let terminationFlushTimeout: Duration = .seconds(3)

  var prepareForTermination: (@MainActor () async -> Void)?
  private var hasRepliedToTermination = false

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let prepareForTermination else {
      return .terminateNow
    }

    hasRepliedToTermination = false
    Task { [weak self] in
      await prepareForTermination()
      self?.replyToTermination(sender)
    }
    Task { [weak self] in
      try? await Task.sleep(for: Self.terminationFlushTimeout)
      self?.replyToTermination(sender)
    }
    return .terminateLater
  }

  private func replyToTermination(_ sender: NSApplication) {
    guard !hasRepliedToTermination else {
      return
    }
    hasRepliedToTermination = true
    sender.reply(toApplicationShouldTerminate: true)
  }
}
