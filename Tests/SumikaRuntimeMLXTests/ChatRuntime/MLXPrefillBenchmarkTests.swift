import Foundation
import MLX
import MLXLMCommon
import XCTest

@testable import SumikaCore
@testable import SumikaRuntimeMLX

/// Opt-in, local-only measurements. Each invocation runs one independently seeded case.
nonisolated final class MLXPrefillBenchmarkTests: XCTestCase {
  private static let instructions = "Follow the requested output format."

  func testInstalledModelPrefill() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let modelID = environment["SUMIKA_PREFILL_BENCHMARK_MODEL_ID"] else {
      throw XCTSkip("Run script/benchmark_prefill.py to opt into installed-model measurements.")
    }
    let model = try XCTUnwrap(ManagedModelCatalog.model(id: modelID))
    let step = try XCTUnwrap(Int(environment["SUMIKA_PREFILL_BENCHMARK_STEP"] ?? ""))
    let tokens = try XCTUnwrap(Int(environment["SUMIKA_PREFILL_BENCHMARK_TOKENS"] ?? ""))
    let mode = try XCTUnwrap(environment["SUMIKA_PREFILL_BENCHMARK_MODE"])
    XCTAssertTrue([512, 1024, 2048].contains(step))
    XCTAssertTrue(["cold", "warm", "cancel-cold", "cancel-warm"].contains(mode))
    let path = try XCTUnwrap(environment["SUMIKA_PREFILL_BENCHMARK_TRACE"])
    let traceURL = URL(filePath: path)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: path), "Use a fresh trace for every case.")
    let directory =
      environment["SUMIKA_PREFILL_BENCHMARK_MODELS_PATH"]
      .map { URL(filePath: $0) } ?? LocalModelDirectory.defaultBaseURL
    let modelDirectory = directory.appending(path: model.localDirectoryName)
    guard FileManager.default.fileExists(atPath: modelDirectory.appending(path: "config.json").path)
    else { throw XCTSkip("Benchmark model is not installed: \(modelDirectory.path)") }
    let library = Bundle(for: Self.self).resourceURL?
      .appending(path: "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
    guard let library, FileManager.default.fileExists(atPath: library.path) else {
      throw XCTSkip("MLX default.metallib is unavailable in the test bundle.")
    }
    guard MLXDebugTraceStore.isEnabled else {
      XCTFail("SUMIKA_DEBUG_TRACE=1 is required for cache and prefill diagnostics.")
      return
    }
    let tokenizer = try await makeHuggingFaceTokenizerLoader().load(from: modelDirectory)
    let tracer = MLXDebugTraceStore(fileURL: traceURL)
    let runtime = MLXChatRuntime(debugTraceStore: tracer, prefillStepSize: step)
    do {
      try await runtime.load(
        configuration: ChatModelConfiguration(
          localModelDirectory: modelDirectory, contextTokenLimit: 65_536,
          supportsImageInput: model.supportsImageInput,
          reasoningTraceFormat: model.reasoningTraceFormat,
          supportsHistoricalReasoningPreservation: model.supportsHistoricalReasoningPreservation,
          reasoningCapability: model.reasoningCapability,
          thinkingBudgetPolicy: model.thinkingBudgetPolicy))
      try await Self.measure(
        runtime: runtime, tracer: tracer, traceURL: traceURL, tokenizer: tokenizer,
        model: model, tokens: tokens, mode: mode)
      await runtime.unload()
    } catch {
      await runtime.unload()
      throw error
    }
  }

  private static func measure(
    runtime: MLXChatRuntime, tracer: MLXDebugTraceStore, traceURL: URL,
    tokenizer: any Tokenizer, model: ManagedModel, tokens: Int, mode: String
  ) async throws {
    // Warm kernels before measuring; a cold case means an empty conversation cache.
    let warmup = try prompt(tokens: 512, prefix: [], tokenizer: tokenizer, model: model, seed: true)
    _ = try await reply(runtime: runtime, tracer: tracer, entries: [warmup], seed: true)
    await runtime.clearContext()
    var prefix: [ModelContextEntry] = []
    var cachedTokens = 0
    if mode.hasSuffix("warm") {
      let seed = try prompt(
        tokens: 2048, prefix: [], tokenizer: tokenizer, model: model, seed: true)
      let answer = try await reply(runtime: runtime, tracer: tracer, entries: [seed], seed: true)
      XCTAssertFalse(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      prefix = [seed, try ModelFacingPromptRenderer.assistantOutputEntry(content: answer)]
      let rows = try records(traceURL)
      let seedEnd = try XCTUnwrap(rows.last { $0["phase"] as? String == "runtime_stream_end" })
      XCTAssertEqual(seedEnd["runtimeStreamOutcome"] as? String, "completed")
      let prefill = try XCTUnwrap(rows.last { $0["phase"] as? String == "runtime_prefill" })
      let decode = try XCTUnwrap(rows.last { $0["phase"] as? String == "runtime_decode" })
      cachedTokens =
        try XCTUnwrap(prefill["promptTokens"] as? Int)
        + XCTUnwrap(decode["generatedTokenCount"] as? Int) + 1
    }
    let entry = try prompt(
      tokens: tokens + cachedTokens, prefix: prefix, tokenizer: tokenizer, model: model, seed: false
    )
    let entries = prefix + [entry]
    let generationID = UUID()
    StreamOrDevice.default.stream.synchronize()
    // Only this isolated benchmark resets the global counter, after seeding and draining.
    Memory.peakMemory = 0
    if mode.hasPrefix("cancel-") {
      let (started, signal) = AsyncStream<Void>.makeStream()
      let task = Task {
        defer { signal.finish() }
        return try await Self.reply(
          runtime: runtime, tracer: tracer, entries: entries, seed: false,
          generationID: generationID, onStreamStarted: { signal.yield(()) })
      }
      defer { task.cancel() }
      for await _ in started { break }
      try await Task.sleep(for: .milliseconds(250))
      task.cancel()
      do {
        _ = try await task.value
        XCTFail("Cancellation case finished before cancellation was observed.")
      } catch is CancellationError {
        // clearContext below waits for the producer and native work to drain.
      }
    } else {
      let output = try await reply(
        runtime: runtime, tracer: tracer, entries: entries, seed: false,
        generationID: generationID)
      XCTAssertFalse(output.isEmpty)
    }
    await runtime.clearContext()
    let rows = try records(traceURL).filter {
      $0["generationID"] as? String == generationID.uuidString
    }
    let end = try XCTUnwrap(rows.last { $0["phase"] as? String == "runtime_stream_end" })
    XCTAssertNotNil(end["prefillChunkSizes"])
    if mode.hasPrefix("cancel-") {
      XCTAssertNotNil(end["cancellationLatencyMs"], "Cancellation must include producer/GPU drain.")
    } else {
      let prefill = try XCTUnwrap(rows.last { $0["phase"] as? String == "runtime_prefill" })
      let actual = try XCTUnwrap(prefill["promptTokens"] as? Int)
      // EOS cache ownership may differ by one position on a warm continuation.
      XCTAssertLessThanOrEqual(abs(actual - tokens), prefix.isEmpty ? 0 : 1)
      if prefix.isEmpty {
        XCTAssertEqual(prefill["mlxCacheDecision"] as? String, "cold_prefill")
      } else {
        let previousPosition = try XCTUnwrap(prefill["expectedCachedTokens"] as? Int)
        let reusedTokens = try XCTUnwrap(prefill["reusedPromptTokens"] as? Int)
        // Rewinding one terminal EOS is common-prefix reuse under exact cache diagnostics.
        XCTAssertTrue((0...1).contains(previousPosition - reusedTokens))
        XCTAssertEqual(
          prefill["mlxCacheDecision"] as? String,
          previousPosition == reusedTokens ? "exact_suffix_reuse" : "common_prefix_reuse")
      }
      XCTAssertEqual(end["prefillProcessedPositions"] as? Int, actual)
      XCTAssertEqual(end["prefillTotalPositions"] as? Int, actual)
    }
    print(
      "PREFILL BENCHMARK: generation=\(generationID), mode=\(mode), requestedPositions=\(tokens), trace=\(traceURL.path)"
    )
  }

  private static func prompt(
    tokens: Int, prefix: [ModelContextEntry], tokenizer: any Tokenizer,
    model: ManagedModel, seed: Bool
  ) throws -> ModelContextEntry {
    let instruction = seed ? "Reply only READY." : "List the integers from 1 to 1000 in order."
    var padding = max(0, tokens - 100)
    for _ in 0..<8 {
      let entry = try ModelFacingPromptRenderer.userPromptEntry(
        prompt: "Reference data:\n" + String(repeating: " oak", count: padding) + "\n" + instruction
      )
      let input = try MLXHistoryRenderer.generationInput(
        from: ModelPromptProjection(entries: prefix + [entry]), reasoningSelection: .off,
        supportsHistoricalReasoningPreservation: model.supportsHistoricalReasoningPreservation)
      let messages = try MLXHistoryRenderer.runtimeHistoryMessages(
        systemPrompt: Self.instructions,
        history: input.history
          + MLXHistoryRenderer.chatMessages(
            from: input.promptSnapshot,
            supportsHistoricalReasoningPreservation: model.supportsHistoricalReasoningPreservation))
      let count = try tokenizer.applyChatTemplate(
        messages: messages.map { ["role": $0.role.rawValue, "content": $0.content] },
        tools: nil, additionalContext: input.additionalContext
      ).count
      if count == tokens { return entry }
      padding = max(0, padding + tokens - count)
    }
    throw NSError(
      domain: "PrefillBenchmark", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Could not construct a \(tokens)-position prompt."])
  }

  private static func reply(
    runtime: MLXChatRuntime, tracer: MLXDebugTraceStore, entries: [ModelContextEntry],
    seed: Bool, generationID: UUID = UUID(), onStreamStarted: (@Sendable () -> Void)? = nil
  ) async throws -> String {
    let metadata = TurnTraceMetadata(
      turnID: UUID(), generationID: generationID, tracer: tracer, interactionMode: .chat)
    let settings = ChatGenerationSettings(
      temperature: 0, topP: 1, topK: 0, maxTokens: seed ? 32 : 128, reasoningSelection: .off)
    let stream = try await TurnTraceContext.$current.withValue(metadata) {
      try await runtime.streamReply(
        for: ModelPromptProjection(entries: entries), attachments: [],
        promptPlan: .init(stableInstructions: Self.instructions), settings: settings,
        interactionMode: .chat)
    }
    onStreamStarted?()
    var output = ""
    for try await event in stream {
      try Task.checkCancellation()
      if case .chunk(let text) = event { output += text }
    }
    try Task.checkCancellation()
    return output
  }

  private static func records(_ url: URL) throws -> [[String: Any]] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap {
      try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
  }
}
