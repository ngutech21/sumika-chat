import Foundation
import MLX
import SumikaCore
import Synchronization

enum MLXMemoryTracePhase: String, Equatable, Sendable {
  case modelLoadBefore = "model_load_before"
  case modelLoadAfter = "model_load_after"
  case generationStart = "generation_start"
  case generationFirstOutput = "generation_first_output"
  case generationTerminal = "generation_terminal"
  case cacheClearBefore = "cache_clear_before"
  case cacheClearAfter = "cache_clear_after"
}

enum MLXModelLoadOutcome: String, Equatable, Sendable {
  case loaded
  case failed
}

struct MLXMemorySnapshot: Equatable, Sendable {
  let activeMemoryBytes: Int
  let cacheMemoryBytes: Int
  let peakMemoryBytes: Int

  func delta(to snapshot: Self) -> MLXMemorySnapshotDelta {
    MLXMemorySnapshotDelta(
      activeMemoryBytes: snapshot.activeMemoryBytes - activeMemoryBytes,
      cacheMemoryBytes: snapshot.cacheMemoryBytes - cacheMemoryBytes,
      peakMemoryBytes: snapshot.peakMemoryBytes - peakMemoryBytes
    )
  }
}

struct MLXMemorySnapshotDelta: Equatable, Sendable {
  let activeMemoryBytes: Int
  let cacheMemoryBytes: Int
  /// Change in MLX's process-global high-water mark, not a phase-local peak.
  let peakMemoryBytes: Int
}

struct MLXMemorySnapshotSource: Sendable {
  static let live = Self {
    let snapshot = Memory.snapshot()
    return MLXMemorySnapshot(
      activeMemoryBytes: snapshot.activeMemory,
      cacheMemoryBytes: snapshot.cacheMemory,
      peakMemoryBytes: snapshot.peakMemory
    )
  }

  private let captureOperation: @Sendable () -> MLXMemorySnapshot

  init(_ capture: @escaping @Sendable () -> MLXMemorySnapshot) {
    self.captureOperation = capture
  }

  func capture() -> MLXMemorySnapshot {
    captureOperation()
  }
}

final class MLXMemoryTraceScope: Sendable {
  let id: UUID
  let baselinePhase: MLXMemoryTracePhase
  let baselineSnapshot: MLXMemorySnapshot
  let startedAt: Date
  let turnID: UUID?
  let generationID: UUID?
  let toolLoopIteration: Int?
  let interactionMode: WorkspaceInteractionMode?
  let memoryClearReason: String?
  private let didRecordTerminalSnapshot = Mutex(false)

  init(
    id: UUID,
    baselinePhase: MLXMemoryTracePhase,
    baselineSnapshot: MLXMemorySnapshot,
    startedAt: Date,
    turnID: UUID?,
    generationID: UUID?,
    toolLoopIteration: Int?,
    interactionMode: WorkspaceInteractionMode?,
    memoryClearReason: String?
  ) {
    self.id = id
    self.baselinePhase = baselinePhase
    self.baselineSnapshot = baselineSnapshot
    self.startedAt = startedAt
    self.turnID = turnID
    self.generationID = generationID
    self.toolLoopIteration = toolLoopIteration
    self.interactionMode = interactionMode
    self.memoryClearReason = memoryClearReason
  }

  func claimTerminalSnapshot() -> Bool {
    didRecordTerminalSnapshot.withLock { didRecord in
      guard !didRecord else {
        return false
      }
      didRecord = true
      return true
    }
  }
}
