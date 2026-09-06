import MLX
import MLXLMCommon
import Synchronization

/// Owns producer cancellation and draining before terminal events can escape.
final class MLXGuardedGeneration: Sendable {
  let stream: AsyncThrowingStream<Generation, Error>
  private let failure = FailureState()
  private let task: Task<Void, Never>

  convenience init(session: MLXLMCommon.ChatSession, messages: consuming [Chat.Message]) {
    let stream = StreamOrDevice.default.stream
    // Runtime setup is serialized; upstream protects its cache with an async lock.
    // Only the drain operation crosses tasks while generation is in flight.
    nonisolated(unsafe) let drainingSession = session
    self.init(
      makeStream: { [messages] in session.streamDetails(to: messages) },
      synchronize: {
        await drainingSession.synchronize()
        stream.synchronize()
      }
    )
  }

  init(
    makeStream: () -> AsyncThrowingStream<Generation, Error>,
    synchronize: @escaping @Sendable () async -> Void
  ) {
    let failure = self.failure
    // The upstream producer and decode tasks inherit this task-local handler.
    let upstream = MLX.withErrorHandler(failure.capture) { makeStream() }
    let (stream, continuation) = AsyncThrowingStream<Generation, Error>.makeStream()
    self.stream = stream
    task = Task {
      defer { failure.finish() }
      var terminalEvents: [Generation] = []
      var streamError: Error?
      var iterator = upstream.makeAsyncIterator()
      do {
        while let event = try await iterator.next() {
          try failure.check()
          try Task.checkCancellation()
          if event.info != nil || event.toolCall != nil || !terminalEvents.isEmpty {
            terminalEvents.append(event)
          } else if case .terminated = continuation.yield(event) {
            throw CancellationError()
          }
        }
      } catch {
        streamError = error
        if let caught = error as? MLXError { failure.record(caught) }
        withUnsafeCurrentTask { $0?.cancel() }
        // Enter the iterator's cancellation handler even if failure was detected
        // between calls to next(), while upstream still holds the stream alive.
        _ = try? await iterator.next()
      }

      // Cancellation of iteration only requests upstream cancellation. Its cache
      // lock must be released, and native work settled, before releasing arrays.
      await MLX.withErrorHandler(failure.capture) { await synchronize() }
      do {
        try failure.check()
        if let streamError { throw streamError }
        try Task.checkCancellation()
        for event in terminalEvents {
          continuation.yield(event)
        }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    failure.install(task)
    continuation.onTermination = { [task] termination in
      if case .cancelled = termination { task.cancel() }
    }
  }

  func checkFailure() throws {
    try failure.check()
  }

  func drain() async {
    await task.value
  }

  func cancelAndDrain() async {
    task.cancel()
    await task.value
  }

  var capturedError: MLXError? { failure.error }

  private struct FailureStorage {
    var error: MLXError?
    var task: Task<Void, Never>?
    var finished = false
  }

  private final class FailureState: Sendable {
    private let state = Mutex(FailureStorage())

    var error: MLXError? { state.withLock { $0.error } }

    func capture(_ message: String) {
      record(.caught(message))
    }

    func record(_ error: MLXError) {
      let task = state.withLock { state in
        if state.error == nil { state.error = error }
        return state.task
      }
      withUnsafeCurrentTask { $0?.cancel() }
      task?.cancel()
    }

    func install(_ task: Task<Void, Never>) {
      let shouldCancel = state.withLock { state in
        if !state.finished { state.task = task }
        return state.error != nil
      }
      if shouldCancel { task.cancel() }
    }

    func finish() {
      state.withLock {
        $0.finished = true
        $0.task = nil
      }
    }

    func check() throws {
      if let error { throw error }
    }
  }
}
