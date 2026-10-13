import Foundation
import MLX
import MLXLMCommon
import SumikaCore
import Synchronization

/// Observes raw emitted tokens before the provider tool parser can buffer them.
final class MLXTokenProgressTracer: Sendable {
  private struct State {
    var tokenCount = 0
    var prefix: [Int] = []
    var suffix: [Int] = []
    var writeTask: Task<Void, Never>?
    var finished = false
  }

  private let state = Mutex(State())
  private let traceID: UUID
  private let metadata: TurnTraceMetadata?
  private let store: MLXDebugTraceStore
  private let decode: @Sendable ([Int]) -> String
  private let startedAt = Date()
  let tokenProgressAvailable: Bool

  init(
    traceID: UUID, metadata: TurnTraceMetadata?, store: MLXDebugTraceStore,
    tokenProgressAvailable: Bool, decode: @escaping @Sendable ([Int]) -> String
  ) {
    self.traceID = traceID
    self.metadata = metadata
    self.store = store
    self.tokenProgressAvailable = tokenProgressAvailable
    self.decode = decode
  }

  func record(token: Int) {
    state.withLock { state in
      guard !state.finished else { return }
      state.tokenCount += 1
      if state.prefix.count < 64 { state.prefix.append(token) }
      state.suffix.append(token)
      if state.suffix.count > 256 { state.suffix.removeFirst() }
      if state.tokenCount == 1 || state.tokenCount.isMultiple(of: 128) {
        enqueueProgress(state: &state, final: false)
      }
    }
  }

  func recordParserEvent(_ event: Generation) async {
    await store.traceToolParserEvent(
      event, id: traceID, metadata: metadata,
      durationMs: Date().timeIntervalSince(startedAt) * 1000
    )
  }

  func finish() async {
    let task = state.withLock { state in
      if !state.finished {
        state.finished = true
        enqueueProgress(state: &state, final: true)
      }
      return state.writeTask
    }
    await task?.value
  }

  private func enqueueProgress(state: inout State, final: Bool) {
    let count = state.tokenCount
    let prefix = state.prefix
    let suffix = state.suffix
    let previous = state.writeTask
    let durationMs = Date().timeIntervalSince(startedAt) * 1000
    state.writeTask = Task { [self] in
      await previous?.value
      await store.traceTokenProgress(
        id: traceID, metadata: metadata, durationMs: durationMs,
        tokenCount: count, prefix: prefix, suffix: suffix, decode: decode,
        available: tokenProgressAvailable, final: final
      )
    }
  }
}

struct MLXTokenProgressProcessor: LogitProcessor {
  let tracer: MLXTokenProgressTracer

  mutating func prompt(_ prompt: MLXArray) {}
  func process(logits: MLXArray) -> MLXArray { logits }
  mutating func didSample(token: MLXArray) {}

  // shortcut: upstream calls didEmit only with reasoning-token tracking; extend
  // the upstream hook when exact progress for other generation modes is needed.
  mutating func didEmit(token: Int) {
    tracer.record(token: token)
  }
}
