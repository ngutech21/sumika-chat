import MLXLMCommon
import Synchronization

import struct SumikaCore.RuntimeCacheAllocationSnapshot

struct MLXCompletionDiagnostics: Equatable, Sendable {
  let evictedTokenCount: Int
  let reasoningTokenCount: Int?
  let answerTokenCount: Int?
  let proposedDraftTokens: Int?
  let acceptedDraftTokens: Int?

  init(_ info: GenerateCompletionInfo) {
    evictedTokenCount = info.evictedTokenCount
    reasoningTokenCount = info.reasoningTokenCount
    answerTokenCount = info.answerTokenCount
    proposedDraftTokens = info.proposedDraftTokens
    acceptedDraftTokens = info.acceptedDraftTokens
  }

  var mtpAcceptanceRate: Double? {
    guard let proposedDraftTokens, let acceptedDraftTokens, proposedDraftTokens > 0 else {
      return nil
    }
    return Double(acceptedDraftTokens) / Double(proposedDraftTokens)
  }
}

struct MLXGenerationDiagnosticsSnapshot: Equatable, Sendable {
  let prefillStepSize: Int
  let prefillChunkSizes: [Int]
  let prefillProcessedPositions: Int
  let prefillTotalPositions: Int?
  let cancellationLatencyMs: Double?
  let completion: MLXCompletionDiagnostics?
  let cacheAllocationBefore: RuntimeCacheAllocationSnapshot?
  let cacheAllocationAfter: RuntimeCacheAllocationSnapshot?
}

/// Collects generation diagnostics without adding GPU fences or per-chunk trace writes.
final class MLXGenerationDiagnostics: Sendable {
  private struct State {
    var chunks: [Int] = []
    var processed = 0
    var total: Int?
    var cancellationRequestedAt: ContinuousClock.Instant?
    var drainedAt: ContinuousClock.Instant?
    var completion: MLXCompletionDiagnostics?
    var cacheAllocationBefore: RuntimeCacheAllocationSnapshot?
    var cacheAllocationAfter: RuntimeCacheAllocationSnapshot?
  }

  private let stepSize: Int
  private let state = Mutex(State())

  init(prefillStepSize: Int) {
    stepSize = prefillStepSize
  }

  func recordCompletion(_ info: GenerateCompletionInfo) {
    state.withLock { $0.completion = MLXCompletionDiagnostics(info) }
  }

  func recordCacheAllocationBefore(_ snapshot: RuntimeCacheAllocationSnapshot?) {
    state.withLock { $0.cacheAllocationBefore = snapshot }
  }

  func recordCacheAllocationAfter(_ snapshot: RuntimeCacheAllocationSnapshot?) {
    state.withLock { $0.cacheAllocationAfter = snapshot }
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
        cancellationLatencyMs: latency,
        completion: state.completion,
        cacheAllocationBefore: state.cacheAllocationBefore,
        cacheAllocationAfter: state.cacheAllocationAfter)
    }
  }
}
