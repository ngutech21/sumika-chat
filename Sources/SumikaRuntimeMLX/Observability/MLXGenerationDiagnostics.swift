import Foundation
import Synchronization

struct MLXGenerationDiagnosticsSnapshot: Equatable, Sendable {
  let prefillStepSize: Int
  let prefillChunkSizes: [Int]
  let prefillProcessedPositions: Int
  let prefillTotalPositions: Int?
  let cancellationLatencyMs: Double?
}

/// Collects submission counts without adding GPU fences or per-chunk trace writes.
final class MLXGenerationDiagnostics: Sendable {
  private struct State {
    var chunks: [Int] = []
    var processed = 0
    var total: Int?
    var cancellationRequestedAt: ContinuousClock.Instant?
    var drainedAt: ContinuousClock.Instant?
  }

  private let stepSize: Int
  private let state = Mutex(State())

  init(prefillStepSize: Int) {
    stepSize = prefillStepSize
  }

  func recordPrefillProgress(processed: Int, total: Int) {
    state.withLock { state in
      guard processed >= state.processed, processed <= total,
        state.total == nil || state.total == total
      else { return }
      let chunk = processed - state.processed
      if chunk > 0 { state.chunks.append(chunk) }
      state.processed = processed
      state.total = total
    }
  }

  func requestCancellation(at instant: ContinuousClock.Instant? = nil) {
    state.withLock { state in
      guard state.drainedAt == nil, state.cancellationRequestedAt == nil else { return }
      state.cancellationRequestedAt = instant ?? .now
    }
  }

  func didDrain(at instant: ContinuousClock.Instant? = nil) {
    state.withLock { state in
      if state.drainedAt == nil { state.drainedAt = instant ?? .now }
    }
  }

  func snapshot() -> MLXGenerationDiagnosticsSnapshot {
    state.withLock { state in
      let latency: Double?
      if let requested = state.cancellationRequestedAt, let drained = state.drainedAt {
        let duration = requested.duration(to: drained).components
        latency = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
      } else {
        latency = nil
      }
      return MLXGenerationDiagnosticsSnapshot(
        prefillStepSize: stepSize, prefillChunkSizes: state.chunks,
        prefillProcessedPositions: state.processed, prefillTotalPositions: state.total,
        cancellationLatencyMs: latency)
    }
  }
}
