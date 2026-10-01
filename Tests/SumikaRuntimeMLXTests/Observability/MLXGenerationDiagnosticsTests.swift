import Foundation
import MLXLMCommon
import Testing

@testable import SumikaCore
@testable import SumikaRuntimeMLX

struct MLXGenerationDiagnosticsTests {
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
  }
}
