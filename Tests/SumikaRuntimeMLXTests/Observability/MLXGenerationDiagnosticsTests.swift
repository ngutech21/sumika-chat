import Foundation
import MLXLMCommon
import Testing

@testable import SumikaCore
@testable import SumikaRuntimeMLX

struct MLXGenerationDiagnosticsTests {
  @Test(arguments: [
    (Optional(10), Optional(7), Optional(0.7)),
    (Optional(10), Optional(0), Optional(0.0)),
    (Optional(0), Optional(0), nil),
    (nil, Optional(0), nil),
    (Optional(10), nil, nil),
    (nil, nil, nil),
  ])
  func completionPreservesCountsAndDerivesAcceptance(
    proposed: Int?, accepted: Int?, rate: Double?
  ) {
    let diagnostics = MLXGenerationDiagnostics(prefillStepSize: 512)
    diagnostics.recordCompletion(
      GenerateCompletionInfo(
        promptTokenCount: 100, generationTokenCount: 20,
        evictedTokenCount: 12, reasoningTokenCount: 8, answerTokenCount: 12,
        promptTime: 0.5, generationTime: 1,
        proposedDraftTokens: proposed, acceptedDraftTokens: accepted))
    let completion = diagnostics.snapshot().completion
    #expect(completion?.evictedTokenCount == 12)
    #expect(completion?.reasoningTokenCount == 8)
    #expect(completion?.answerTokenCount == 12)
    #expect(completion?.proposedDraftTokens == proposed)
    #expect(completion?.acceptedDraftTokens == accepted)
    #expect(completion?.mtpAcceptanceRate == rate)
  }

  @Test
  func missingCompletionAndOptionalCountsStayUnavailable() {
    let diagnostics = MLXGenerationDiagnostics(prefillStepSize: 512)
    #expect(diagnostics.snapshot().completion == nil)
    #expect(diagnostics.snapshot().cacheAllocationBefore == nil)
    #expect(diagnostics.snapshot().cacheAllocationAfter == nil)
    diagnostics.recordCompletion(
      GenerateCompletionInfo(
        promptTokenCount: 100, generationTokenCount: 20, promptTime: 0.5, generationTime: 1))
    let completion = diagnostics.snapshot().completion
    #expect(completion?.evictedTokenCount == 0)
    #expect(completion?.reasoningTokenCount == nil)
    #expect(completion?.answerTokenCount == nil)
    #expect(completion?.mtpAcceptanceRate == nil)
  }

  @Test
  func capturesBalancedChunksAndReservedTailWithoutDoubleCountingCompletion() throws {
    let diagnostics = MLXGenerationDiagnostics(prefillStepSize: 1024)
    let prefill = PrefillParameters(stepSize: 1024, chunking: .balanced) { processed, total in
      diagnostics.recordPrefillProgress(processed: processed, total: total)
    }
    let processed = try prefill.forEachChunk(total: 8200) { _ in }
    #expect(processed == 8199)
    prefill.progress?(8200, 8200)
    prefill.progress?(8200, 8200)
    let snapshot = diagnostics.snapshot()
    #expect(snapshot.prefillChunkSizes == Array(repeating: 911, count: 9) + [1])
    #expect(snapshot.prefillProcessedPositions == 8200)
    #expect(snapshot.prefillTotalPositions == 8200)
    #expect(snapshot.cancellationLatencyMs == nil)
  }

  @Test
  func retainsPartialPrefillAndMeasuresFirstCancellationThroughDrain() {
    let diagnostics = MLXGenerationDiagnostics(prefillStepSize: 2048)
    diagnostics.recordPrefillProgress(processed: 1640, total: 8200)
    let start = ContinuousClock.now
    diagnostics.requestCancellation(at: start)
    diagnostics.requestCancellation(at: start.advanced(by: .milliseconds(50)))
    #expect(diagnostics.snapshot().cancellationLatencyMs == nil)
    diagnostics.didDrain(at: start.advanced(by: .milliseconds(125)))
    diagnostics.didDrain(at: start.advanced(by: .seconds(1)))
    let snapshot = diagnostics.snapshot()
    #expect(snapshot.prefillChunkSizes == [1640])
    #expect(snapshot.prefillProcessedPositions == 1640)
    #expect(snapshot.prefillTotalPositions == 8200)
    #expect(snapshot.cancellationLatencyMs == 125)
  }

  @Test
  func lateCancellationAfterCompletionDoesNotBecomeACancellationMeasurement() {
    let diagnostics = MLXGenerationDiagnostics(prefillStepSize: 512)
    diagnostics.didDrain()
    diagnostics.requestCancellation()
    #expect(diagnostics.snapshot().cancellationLatencyMs == nil)
  }

  @Test
  func disabledTracingDoesNotCreateDiagnosticsOrWriteRows() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let url = directory.appending(path: "trace.jsonl")
    let store = MLXDebugTraceStore(fileURL: url, isEnabled: { false })
    #expect(await store.makeGenerationDiagnostics(prefillStepSize: 512) == nil)
    await store.recordRuntimeStreamEnd(
      TurnTraceEvent(phase: .runtimeStreamEnd, durationMs: 1), diagnostics: nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test
  func streamEndWritesDiagnosticsInExistingTraceFormat() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "trace.jsonl")
    let store = MLXDebugTraceStore(fileURL: url, isEnabled: { true })
    let diagnostics = try #require(await store.makeGenerationDiagnostics(prefillStepSize: 1024))
    diagnostics.recordPrefillProgress(processed: 300, total: 300)
    diagnostics.recordCacheAllocationBefore(
      RuntimeCacheAllocationSnapshot(phase: .planned, allocatedBytes: 0, layers: []))
    diagnostics.recordCacheAllocationAfter(
      RuntimeCacheAllocationSnapshot(
        phase: .realized, allocatedBytes: 4_096,
        layers: [.init(path: [2, 0], kind: "stateSpace", allocatedBytes: 4_096)]))
    diagnostics.recordCompletion(
      GenerateCompletionInfo(
        promptTokenCount: 300, generationTokenCount: 10, evictedTokenCount: 0,
        reasoningTokenCount: 6, answerTokenCount: 4, promptTime: 0.5, generationTime: 1,
        proposedDraftTokens: 5, acceptedDraftTokens: 3))
    let id = UUID()
    await store.recordRuntimeStreamEnd(
      TurnTraceEvent(generationID: id, phase: .runtimeStreamEnd, durationMs: 1),
      diagnostics: diagnostics.snapshot())
    let row = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    #expect(row["kind"] as? String == "turn_trace")
    #expect(row["generationID"] as? String == id.uuidString)
    #expect(row["prefillStepSize"] as? Int == 1024)
    #expect(row["prefillChunking"] as? String == "balanced")
    #expect(row["prefillChunkSizes"] as? [Int] == [300])
    #expect(row["prefillProcessedPositions"] as? Int == 300)
    #expect(row["prefillTotalPositions"] as? Int == 300)
    #expect(row["cancellationLatencyMs"] == nil)
    #expect(row["evictedTokenCount"] as? Int == 0)
    #expect(row["reasoningTokenCount"] as? Int == 6)
    #expect(row["answerTokenCount"] as? Int == 4)
    #expect(row["proposedDraftTokens"] as? Int == 5)
    #expect(row["acceptedDraftTokens"] as? Int == 3)
    #expect(row["mtpAcceptanceRate"] as? Double == 0.6)
    let before = try #require(row["cacheAllocationBefore"] as? [String: Any])
    let after = try #require(row["cacheAllocationAfter"] as? [String: Any])
    #expect(before["phase"] as? String == "planned")
    #expect(before["allocatedBytes"] as? Int == 0)
    #expect(after["phase"] as? String == "realized")
    #expect(after["allocatedBytes"] as? Int == 4_096)
    let layers = try #require(after["layers"] as? [[String: Any]])
    #expect(layers.first?["path"] as? [Int] == [2, 0])
    #expect(layers.first?["kind"] as? String == "stateSpace")
    #expect(layers.first?["allocatedBytes"] as? Int == 4_096)
  }

  @Test(arguments: [false, true])
  func streamEndOmitsUnavailableDiagnostics(hasCompletion: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "trace.jsonl")
    let store = MLXDebugTraceStore(fileURL: url, isEnabled: { true })
    let diagnostics = MLXGenerationDiagnostics(prefillStepSize: 512)
    if hasCompletion {
      diagnostics.recordCompletion(
        GenerateCompletionInfo(
          promptTokenCount: 1, generationTokenCount: 1, promptTime: 1, generationTime: 1,
          proposedDraftTokens: 0, acceptedDraftTokens: 0))
    }
    await store.recordRuntimeStreamEnd(
      TurnTraceEvent(phase: .runtimeStreamEnd, durationMs: 1), diagnostics: diagnostics.snapshot())
    let row = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    for key in [
      "reasoningTokenCount", "answerTokenCount", "mtpAcceptanceRate",
      "cacheAllocationBefore", "cacheAllocationAfter",
    ] {
      #expect(row[key] == nil)
    }
    #expect(row["evictedTokenCount"] as? Int == (hasCompletion ? 0 : nil))
    #expect(row["proposedDraftTokens"] as? Int == (hasCompletion ? 0 : nil))
    #expect(row["acceptedDraftTokens"] as? Int == (hasCompletion ? 0 : nil))
  }
}
