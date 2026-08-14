import Foundation
import SumikaCore

struct MLXGenerationProgressTracer: Sendable {
  private let traceID: UUID?
  private let traceMetadata: TurnTraceMetadata?
  private let debugTraceStore: MLXDebugTraceStore?
  private let startedAt: Date?
  private let applicationStateSnapshotProvider: RuntimeApplicationStateSnapshotProvider?
  private let generationActivityRequest: GenerationActivityRequest?
  private let estimateTokenCount: (@Sendable (String) -> Int)?
  private var streamedChunkCount = 0

  static let disabled = Self()

  init(
    traceID: UUID,
    traceMetadata: TurnTraceMetadata?,
    debugTraceStore: MLXDebugTraceStore,
    startedAt: Date,
    applicationStateSnapshotProvider: @escaping RuntimeApplicationStateSnapshotProvider,
    generationActivityRequest: GenerationActivityRequest,
    estimateTokenCount: @escaping @Sendable (String) -> Int
  ) {
    self.traceID = traceID
    self.traceMetadata = traceMetadata
    self.debugTraceStore = debugTraceStore
    self.startedAt = startedAt
    self.applicationStateSnapshotProvider = applicationStateSnapshotProvider
    self.generationActivityRequest = generationActivityRequest
    self.estimateTokenCount = estimateTokenCount
  }

  private init() {
    traceID = nil
    traceMetadata = nil
    debugTraceStore = nil
    startedAt = nil
    applicationStateSnapshotProvider = nil
    generationActivityRequest = nil
    estimateTokenCount = nil
  }

  mutating func record(output: String) async {
    guard traceID != nil else {
      return
    }
    streamedChunkCount += 1
    guard streamedChunkCount == 1 || streamedChunkCount.isMultiple(of: 128),
      let traceID,
      let debugTraceStore,
      let startedAt,
      let applicationStateSnapshotProvider,
      let generationActivityRequest,
      let estimateTokenCount
    else {
      return
    }

    await debugTraceStore.traceGenerationProgress(
      id: traceID,
      traceMetadata: traceMetadata,
      durationMs: Date().timeIntervalSince(startedAt) * 1000,
      output: output,
      applicationState: applicationStateSnapshotProvider(),
      generationActivityRequest: generationActivityRequest,
      estimateTokenCount: estimateTokenCount
    )
  }
}
