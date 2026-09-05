import AppKit
import Testing

@testable import SumikaApp

@Suite
@MainActor
struct SumikaAppDelegateTests {
  @Test(arguments: [true, false])
  func terminationRepliesWhenCleanupFinishesOrTimesOut(timeoutFirst: Bool) async {
    let cleanup = TerminationTestBarrier()
    let timeout = TerminationTestBarrier()
    defer {
      Task {
        await cleanup.release()
        await timeout.release()
      }
    }
    let (replies, continuation) = AsyncStream<Void>.makeStream()
    var replyCount = 0
    let delegate = SumikaAppDelegate(
      waitForTimeout: { await timeout.wait() },
      terminationReply: { _ in
        replyCount += 1
        continuation.yield(())
      }
    )
    delegate.prepareForTermination = { await cleanup.wait() }
    #expect(delegate.applicationShouldTerminate(.shared) == .terminateLater)
    await cleanup.waitUntilStarted()
    await timeout.waitUntilStarted()
    #expect(replyCount == 0)
    if timeoutFirst { await timeout.release() } else { await cleanup.release() }
    var iterator = replies.makeAsyncIterator()
    _ = await iterator.next()
    #expect(replyCount == 1)
    continuation.finish()
  }
}

private actor TerminationTestBarrier {
  private var continuation: CheckedContinuation<Void, Never>?
  private var startWaiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      for waiter in startWaiters { waiter.resume() }
      startWaiters.removeAll()
    }
  }

  func waitUntilStarted() async {
    if continuation == nil { await withCheckedContinuation { startWaiters.append($0) } }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}
