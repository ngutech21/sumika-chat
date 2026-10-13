import Foundation
import MLXLMCommon
import SumikaCore
import SumikaTestSupport
import Synchronization
import Testing

@testable import SumikaRuntimeMLX

@Suite(.serialized, TemporaryDirectoryTrait(named: "sumika-token-progress-tests"))
struct MLXTokenProgressTracerTests {
  @Test
  func rawTokensProgressWithoutAnyParsedOutputAndFlushInOrder() async throws {
    let fileURL = try traceFileURL()
    let store = MLXDebugTraceStore(fileURL: fileURL, isEnabled: { true })
    let id = UUID()
    let metadata = TurnTraceMetadata(
      turnID: UUID(), generationID: id, tracer: store, toolLoopIteration: 5)
    let tracer = MLXTokenProgressTracer(
      traceID: id, metadata: metadata, store: store, tokenProgressAvailable: true,
      decode: { $0.map(String.init).joined(separator: " ") }
    )
    var processor = MLXTokenProgressProcessor(tracer: tracer)
    for token in 1...300 { processor.didEmit(token: token) }
    await tracer.finish()
    await tracer.finish()
    processor.didEmit(token: 301)

    let rows = try traceObjects(at: fileURL)
    #expect(rows.compactMap { $0["observedTokenCount"] as? Int } == [1, 128, 256, 300])
    #expect(rows.allSatisfy { $0["kind"] as? String == "turn_trace" })
    #expect(rows.allSatisfy { $0["phase"] as? String == "runtime_token_progress" })
    #expect(rows.allSatisfy { $0["generationID"] as? String == id.uuidString })
    #expect(rows.allSatisfy { $0["toolLoopIteration"] as? Int == 5 })
    let final = try #require(rows.last)
    #expect(final["final"] as? Bool == true)
    #expect(final["prefixTokenCount"] as? Int == 64)
    #expect(final["suffixTokenCount"] as? Int == 256)
    #expect((final["tokenPrefixPreview"] as? String)?.hasSuffix(" 64") == true)
    #expect((final["tokenSuffixPreview"] as? String)?.hasPrefix("45 ") == true)
    #expect((final["tokenSuffixPreview"] as? String)?.hasSuffix(" 300") == true)
    #expect(final["previewTruncated"] as? Bool == true)
  }

  @Test
  func previewsRespectUTF8LimitsAndParserEventsKeepTheirOutcome() async throws {
    let fileURL = try traceFileURL()
    let store = MLXDebugTraceStore(fileURL: fileURL, isEnabled: { true })
    let id = UUID()
    let payload = "BEGIN" + String(repeating: "💡", count: 2000) + "END"
    await store.traceTokenProgress(
      id: id, metadata: nil, durationMs: 1, tokenCount: 1, prefix: [1], suffix: [1],
      decode: { _ in payload }, available: true, final: false
    )
    await store.traceToolParserEvent(
      .toolCall(
        ToolCall(function: .init(name: "write_file", arguments: ["content": .string(payload)]))),
      id: id, metadata: nil, durationMs: 2
    )
    let rejection = RejectedToolCall(
      reason: .incompleteOutput, format: .json, toolName: "write_file", rawText: payload,
      previewByteLimit: 100
    )
    await store.traceToolParserEvent(
      .rejectedToolCall(rejection), id: id, metadata: nil, durationMs: 3
    )
    await store.traceToolParserEvent(.chunk("ignored"), id: id, metadata: nil, durationMs: 4)

    let rows = try traceObjects(at: fileURL)
    #expect(rows.count == 3)
    for row in rows {
      for field in ["tokenPrefixPreview", "payloadPrefixPreview"] {
        if let text = row[field] as? String { #expect(text.utf8.count <= 512) }
      }
      for field in ["tokenSuffixPreview", "payloadSuffixPreview"] {
        if let text = row[field] as? String { #expect(text.utf8.count <= 1536) }
      }
      #expect(row["previewTruncated"] as? Bool == true)
    }
    #expect((rows[0]["tokenPrefixPreview"] as? String)?.hasPrefix("BEGIN") == true)
    #expect((rows[0]["tokenSuffixPreview"] as? String)?.hasSuffix("END") == true)
    #expect(rows[1]["parserOutcome"] as? String == "accepted")
    #expect((rows[1]["payloadByteCount"] as? Int ?? 0) > payload.utf8.count)
    #expect(rows[2]["parserOutcome"] as? String == "rejected")
    #expect(rows[2]["rejectionReason"] as? String == "incomplete_output")
    #expect(rows[2]["payloadByteCount"] as? Int == payload.utf8.count)
    #expect(rows[2]["parserPreviewTruncated"] as? Bool == true)
  }

  @Test
  func disabledTracingDoesNotDecodeOrWrite() async throws {
    let fileURL = try traceFileURL()
    let decoded = Mutex(false)
    let store = MLXDebugTraceStore(fileURL: fileURL, isEnabled: { false })
    let tracer = MLXTokenProgressTracer(
      traceID: UUID(), metadata: nil, store: store, tokenProgressAvailable: true,
      decode: { _ in
        decoded.withLock { $0 = true }
        return "unused"
      }
    )
    tracer.record(token: 1)
    await tracer.finish()
    await tracer.recordParserEvent(
      .rejectedToolCall(.init(reason: .incompleteOutput, format: .json, rawText: "unused")))
    #expect(!decoded.withLock { $0 })
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
  }

  @Test
  func parserDiagnosticsPrecedeBufferedToolDeliveryAndFinalProgressDrains() async throws {
    let fileURL = try traceFileURL()
    let store = MLXDebugTraceStore(fileURL: fileURL, isEnabled: { true })
    let tracer = MLXTokenProgressTracer(
      traceID: UUID(), metadata: nil, store: store, tokenProgressAvailable: false,
      decode: { _ in "" }
    )
    let (upstream, continuation) = AsyncThrowingStream<Generation, Error>.makeStream()
    let generation = MLXGuardedGeneration(
      makeStream: { upstream }, synchronize: {}, tokenProgressTracer: tracer)
    let received = Mutex(0)
    let consumer = Task {
      for try await _ in generation.stream { received.withLock { $0 += 1 } }
    }
    continuation.yield(
      .toolCall(ToolCall(function: .init(name: "read_files", arguments: [String: JSONValue]()))))
    for _ in 0..<100 {
      if FileManager.default.fileExists(atPath: fileURL.path) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let beforeEnd = try traceObjects(at: fileURL)
    #expect(beforeEnd.first?["parserOutcome"] as? String == "accepted")
    #expect(received.withLock { $0 } == 0)
    continuation.finish()
    await generation.drain()
    try await consumer.value
    #expect(received.withLock { $0 } == 1)
    let final = try #require(try traceObjects(at: fileURL).last)
    #expect(final["final"] as? Bool == true)
    #expect(final["tokenProgressAvailable"] as? Bool == false)
    #expect(final["observedTokenCount"] == nil)
  }

  @Test
  func cancellationFlushesTokensWithoutWaitingForParserOutput() async throws {
    let fileURL = try traceFileURL()
    let store = MLXDebugTraceStore(fileURL: fileURL, isEnabled: { true })
    let tracer = MLXTokenProgressTracer(
      traceID: UUID(), metadata: nil, store: store, tokenProgressAvailable: true,
      decode: { $0.map(String.init).joined(separator: " ") }
    )
    let (upstream, _) = AsyncThrowingStream<Generation, Error>.makeStream()
    let generation = MLXGuardedGeneration(
      makeStream: { upstream }, synchronize: {}, tokenProgressTracer: tracer)
    for token in 1...10 { tracer.record(token: token) }
    await generation.cancelAndDrain()
    let final = try #require(try traceObjects(at: fileURL).last)
    #expect(final["observedTokenCount"] as? Int == 10)
    #expect(final["final"] as? Bool == true)
  }

  private func traceFileURL() throws -> URL {
    try scopedTemporaryDirectory().appending(path: "mlx-trace.jsonl")
  }

  private func traceObjects(at fileURL: URL) throws -> [[String: Any]] {
    let data = try Data(contentsOf: fileURL)
    return try data.split(separator: 0x0A).map {
      try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
    }
  }
}
