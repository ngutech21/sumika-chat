import Testing

@testable import local_coder

@MainActor
struct HTMLPreviewLoadWaiterTests {
  @Test
  func finishesWhenNavigationCompletesBeforeTimeout() async throws {
    let waiter = HTMLPreviewLoadWaiter(timeout: .seconds(1))
    let task = Task { @MainActor in
      await waiter.waitForLoadIfNeeded()
    }

    try await Task.sleep(for: .milliseconds(10))
    waiter.finish(error: nil)

    let outcome = try await withTestTimeout {
      await task.value
    }
    #expect(outcome == .finished)
  }

  @Test
  func failsWhenNavigationFailsBeforeTimeout() async throws {
    let waiter = HTMLPreviewLoadWaiter(timeout: .seconds(1))
    let task = Task { @MainActor in
      await waiter.waitForLoadIfNeeded()
    }

    try await Task.sleep(for: .milliseconds(10))
    waiter.finish(error: "Preview failed to load: test failure")

    let outcome = try await withTestTimeout {
      await task.value
    }
    #expect(outcome == .failed("Preview failed to load: test failure"))
  }

  @Test
  func timesOutWhenNavigationDoesNotComplete() async throws {
    let waiter = HTMLPreviewLoadWaiter(timeout: .milliseconds(10))

    let outcome = try await withTestTimeout {
      await waiter.waitForLoadIfNeeded()
    }

    #expect(outcome == .timedOut(HTMLPreviewLoadWaiter.timeoutMessage))
  }

  @Test
  func resumesMultipleWaitersOnce() async throws {
    let waiter = HTMLPreviewLoadWaiter(timeout: .seconds(1))
    let first = Task { @MainActor in
      await waiter.waitForLoadIfNeeded()
    }
    let second = Task { @MainActor in
      await waiter.waitForLoadIfNeeded()
    }

    try await Task.sleep(for: .milliseconds(10))
    waiter.finish(error: nil)
    waiter.finish(error: "late failure")

    let firstOutcome = try await withTestTimeout {
      await first.value
    }
    let secondOutcome = try await withTestTimeout {
      await second.value
    }

    #expect(firstOutcome == .finished)
    #expect(secondOutcome == .finished)
  }
}
