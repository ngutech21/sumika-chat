import Foundation

struct TestWaitTimeoutError: Error {}

func withTestTimeout<T: Sendable>(
  _ timeout: Duration = .seconds(2),
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  let race = TestTimeoutRace<T>()
  let operationTask = Task {
    do {
      race.succeed(try await operation())
    } catch {
      race.fail(error)
    }
  }
  let timeoutTask = Task {
    do {
      try await Task.sleep(for: timeout)
      race.fail(TestWaitTimeoutError())
    } catch {
      // The sleep task is cancelled when the operation wins the race.
    }
  }

  do {
    let value = try await withTaskCancellationHandler {
      try await race.wait()
    } onCancel: {
      operationTask.cancel()
      timeoutTask.cancel()
      race.fail(CancellationError())
    }
    operationTask.cancel()
    timeoutTask.cancel()
    return value
  } catch {
    operationTask.cancel()
    timeoutTask.cancel()
    throw error
  }
}

private final class TestTimeoutRace<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  nonisolated(unsafe) private var continuation: CheckedContinuation<T, any Error>?
  nonisolated(unsafe) private var outcome: TestTimeoutOutcome<T>?

  nonisolated func wait() async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if let outcome {
        lock.unlock()
        outcome.resume(continuation)
      } else {
        self.continuation = continuation
        lock.unlock()
      }
    }
  }

  nonisolated func succeed(_ value: T) {
    complete(.success(value))
  }

  nonisolated func fail(_ error: any Error) {
    complete(.failure(error))
  }

  private nonisolated func complete(_ outcome: TestTimeoutOutcome<T>) {
    lock.lock()
    guard self.outcome == nil else {
      lock.unlock()
      return
    }
    self.outcome = outcome
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation.map { outcome.resume($0) }
  }
}

private enum TestTimeoutOutcome<T: Sendable> {
  case success(T)
  case failure(any Error)

  nonisolated func resume(_ continuation: CheckedContinuation<T, any Error>) {
    switch self {
    case .success(let value):
      continuation.resume(returning: value)
    case .failure(let error):
      continuation.resume(throwing: error)
    }
  }
}
