import Foundation
import MLXLMCommon
import SumikaCore
import SumikaTestSupport
import Testing

@testable import SumikaRuntimeMLX

@Suite(.serialized, TemporaryDirectoryTrait(named: "sumika-mlx-trace-tests"))
struct MLXDebugTraceStoreTests {
  @Test
  func turnTraceEventDoesNotWriteWhenDebugTraceIsDisabled() async throws {
    unsetenv("SUMIKA_DEBUG_TRACE")
    let fileURL = try temporaryTraceFileURL()
    let store = MLXDebugTraceStore(fileURL: fileURL)

    await store.recordTurnTraceEvent(
      TurnTraceEvent(phase: .runtimeTTFT, durationMs: 10, ttftMs: 10)
    )

    #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
  }

  @Test
  func turnTraceEventWritesToMLXTraceJSONLWhenDebugTraceIsEnabled() async throws {
    setenv("SUMIKA_DEBUG_TRACE", "1", 1)
    defer {
      unsetenv("SUMIKA_DEBUG_TRACE")
    }
    let turnID = UUID()
    let generationID = UUID()
    let fileURL = try temporaryTraceFileURL()
    let store = MLXDebugTraceStore(fileURL: fileURL)

    await store.recordTurnTraceEvent(
      TurnTraceEvent(
        turnID: turnID,
        generationID: generationID,
        phase: .runtimePrefill,
        durationMs: 123.5,
        promptTokens: 37,
        messageCount: 2,
        cacheMode: "reused_session",
        cacheReason: "reused_session",
        memoryClearReason: "runtime_error",
        contextSignature: "ctx-new",
        previousContextSignature: "ctx-old",
        appendOnly: true,
        reusedMessageCount: 3,
        appendedMessageCount: 1,
        mismatchReason: "history_prefix_mismatch",
        firstMismatchIndex: 2,
        systemPromptChanged: false,
        mlxCacheDecision: "full_prefill",
        mlxCacheMismatchReason: "prefix_or_alignment_mismatch_nontrimmable_cache",
        fullPromptTokens: 140,
        expectedCachedTokens: 120,
        expectedSuffixTokens: 20,
        reusedPromptTokens: 0,
        inputMaskPresent: false,
        preparedMediaPresent: false,
        newMediaPresent: false,
        cacheTrimmable: false,
        cacheTypes: ["MLXLMCommon.MambaCache", "MLXLMCommon.KVCacheSimple"],
        toolCallFormat: "native",
        toolValidationStatus: "invalid",
        toolValidationError: "Unknown argument(s): id, status.",
        toolOriginalName: "todo_write",
        toolArgumentKeys: ["id", "status"],
        toolArguments: [
          ToolArgumentTrace(
            name: "id",
            valueType: "string",
            preview: "setup-project",
            previewTruncated: false
          )
        ],
        generatedTokenCount: 128,
        generatedTokenCountIsEstimate: true
      )
    )

    let data = try Data(contentsOf: fileURL)
    let line = try #require(String(data: data, encoding: .utf8)?.split(separator: "\n").first)
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    )

    #expect(object["kind"] as? String == "turn_trace")
    #expect(object["turnID"] as? String == turnID.uuidString)
    #expect(object["generationID"] as? String == generationID.uuidString)
    #expect(object["phase"] as? String == "runtime_prefill")
    #expect(object["durationMs"] as? Double == 123.5)
    #expect(object["promptTokens"] as? Int == 37)
    #expect(object["messageCount"] as? Int == 2)
    #expect(object["cacheMode"] as? String == "reused_session")
    #expect(object["cacheReason"] as? String == "reused_session")
    #expect(object["memoryClearReason"] as? String == "runtime_error")
    #expect(object["contextSignature"] as? String == "ctx-new")
    #expect(object["previousContextSignature"] as? String == "ctx-old")
    #expect(object["appendOnly"] as? Bool == true)
    #expect(object["reusedMessageCount"] as? Int == 3)
    #expect(object["appendedMessageCount"] as? Int == 1)
    #expect(object["mismatchReason"] as? String == "history_prefix_mismatch")
    #expect(object["firstMismatchIndex"] as? Int == 2)
    #expect(object["systemPromptChanged"] as? Bool == false)
    #expect(object["mlxCacheDecision"] as? String == "full_prefill")
    #expect(
      object["mlxCacheMismatchReason"] as? String
        == "prefix_or_alignment_mismatch_nontrimmable_cache"
    )
    #expect(object["fullPromptTokens"] as? Int == 140)
    #expect(object["expectedCachedTokens"] as? Int == 120)
    #expect(object["expectedSuffixTokens"] as? Int == 20)
    #expect(object["reusedPromptTokens"] as? Int == 0)
    #expect(object["inputMaskPresent"] as? Bool == false)
    #expect(object["preparedMediaPresent"] as? Bool == false)
    #expect(object["newMediaPresent"] as? Bool == false)
    #expect(object["cacheTrimmable"] as? Bool == false)
    #expect(
      object["cacheTypes"] as? [String]
        == ["MLXLMCommon.MambaCache", "MLXLMCommon.KVCacheSimple"]
    )
    #expect(object["toolCallFormat"] as? String == "native")
    #expect(object["toolValidationStatus"] as? String == "invalid")
    #expect(object["toolValidationError"] as? String == "Unknown argument(s): id, status.")
    #expect(object["toolOriginalName"] as? String == "todo_write")
    #expect(object["toolArgumentKeys"] as? [String] == ["id", "status"])
    #expect(object["generatedTokenCount"] as? Int == 128)
    #expect(object["generatedTokenCountIsEstimate"] as? Bool == true)

    let toolArguments = try #require(object["toolArguments"] as? [[String: Any]])
    #expect(toolArguments.count == 1)
    #expect(toolArguments.first?["name"] as? String == "id")
    #expect(toolArguments.first?["valueType"] as? String == "string")
    #expect(toolArguments.first?["preview"] as? String == "setup-project")
    #expect(toolArguments.first?["previewTruncated"] as? Bool == false)
  }

  @Test
  func requestTraceRecordsAllGenerationSettings() async throws {
    setenv("SUMIKA_DEBUG_TRACE", "1", 1)
    defer {
      unsetenv("SUMIKA_DEBUG_TRACE")
    }
    let fileURL = try temporaryTraceFileURL()
    let store = MLXDebugTraceStore(fileURL: fileURL)
    let settings = ChatGenerationSettings(
      temperature: 0.4,
      topP: 0.8,
      topK: 32,
      maxTokens: 4_096,
      repetitionPenalty: 1.05,
      repetitionContextSize: 512,
      presencePenalty: 0.35,
      reasoningEnabled: false
    )

    await store.traceRequest(
      id: UUID(),
      history: [],
      prompt: "Prompt",
      settings: settings,
      contextTokenLimit: nil
    )

    let data = try Data(contentsOf: fileURL)
    let line = try #require(String(data: data, encoding: .utf8)?.split(separator: "\n").first)
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    )
    let tracedSettings = try #require(object["settings"] as? [String: Any])

    #expect(tracedSettings["presencePenalty"] as? Double == 0.35)
    #expect(tracedSettings["reasoningEnabled"] as? Bool == false)
    #expect(tracedSettings["repetitionContextSize"] as? Int == 512)
  }

  @Test
  func generationProgressTracerRecordsFirstAndPeriodicSnapshots() async throws {
    setenv("SUMIKA_DEBUG_TRACE", "1", 1)
    defer {
      unsetenv("SUMIKA_DEBUG_TRACE")
    }
    let fileURL = try temporaryTraceFileURL()
    let store = MLXDebugTraceStore(fileURL: fileURL)
    let generationID = UUID()
    var tracer = MLXGenerationProgressTracer(
      traceID: generationID,
      traceMetadata: nil,
      debugTraceStore: store,
      startedAt: Date(),
      estimateTokenCount: { $0.split(separator: " ").count }
    )

    for tokenCount in 1...128 {
      await tracer.record(
        output: Array(repeating: "token", count: tokenCount).joined(separator: " ")
      )
    }

    let data = try Data(contentsOf: fileURL)
    let lines = try #require(String(data: data, encoding: .utf8)?.split(separator: "\n"))
    let objects = try lines.map {
      try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }

    #expect(objects.count == 2)
    #expect(
      objects.map { $0["phase"] as? String } == [
        "runtime_partial_decode",
        "runtime_partial_decode",
      ])
    #expect(objects.map { $0["generatedTokenCount"] as? Int } == [1, 128])
    #expect(objects.allSatisfy { $0["generatedTokenCountIsEstimate"] as? Bool == true })
  }

  @Test
  func disabledGenerationProgressTracerDoesNotRecordSnapshots() async throws {
    setenv("SUMIKA_DEBUG_TRACE", "1", 1)
    defer {
      unsetenv("SUMIKA_DEBUG_TRACE")
    }
    let fileURL = try temporaryTraceFileURL()
    let store = MLXDebugTraceStore(fileURL: fileURL)
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      for _ in 1...129 {
        continuation.yield(.chunk("token"))
      }
      continuation.yield(
        .info(
          GenerateCompletionInfo(
            promptTokenCount: 8,
            generationTokenCount: 129,
            promptTime: 0.1,
            generationTime: 1
          )
        ))
      continuation.finish()
    }
    let cacheTrace = MLXSessionCacheTrace(
      cacheMode: .newSession,
      cacheReason: .newSessionNoCache,
      contextSignature: "context",
      previousContextSignature: nil,
      appendOnly: false,
      reusedMessageCount: 0,
      appendedMessageCount: 0,
      mismatchReason: nil,
      firstMismatchIndex: nil,
      systemPromptChanged: nil
    )
    let stream = MLXModelStreamProcessor.modelStreamPlan(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: cacheTrace,
      debugTraceStore: store,
      generationProgressTracer: .disabled,
      markCompleted: { _ in },
      markCancelled: { _ in },
      memoryCacheClearer: MLXMemoryCacheClearer { _ in }
    ).stream

    for try await _ in stream {}

    let data = try Data(contentsOf: fileURL)
    let lines = try #require(String(data: data, encoding: .utf8)?.split(separator: "\n"))
    let objects = try lines.map {
      try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }

    #expect(objects.count == 1)
    #expect(objects.first?["kind"] as? String == "mlx_response")
    #expect(objects.allSatisfy { $0["phase"] as? String != "runtime_partial_decode" })
  }

  @Test
  func generationProgressTraceRecordsEstimatedRunningTokenCount() async throws {
    setenv("SUMIKA_DEBUG_TRACE", "1", 1)
    defer {
      unsetenv("SUMIKA_DEBUG_TRACE")
    }
    let fileURL = try temporaryTraceFileURL()
    let store = MLXDebugTraceStore(fileURL: fileURL)
    let turnID = UUID()
    let generationID = UUID()
    let metadata = TurnTraceMetadata(
      turnID: turnID,
      generationID: generationID,
      tracer: store,
      toolLoopIteration: 3,
      interactionMode: .agent
    )

    await store.traceGenerationProgress(
      id: generationID,
      traceMetadata: metadata,
      durationMs: 1_250,
      output: "one two three",
      estimateTokenCount: { $0.split(separator: " ").count }
    )

    let data = try Data(contentsOf: fileURL)
    let line = try #require(String(data: data, encoding: .utf8)?.split(separator: "\n").first)
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    )

    #expect(object["kind"] as? String == "turn_trace")
    #expect(object["phase"] as? String == "runtime_partial_decode")
    #expect(object["turnID"] as? String == turnID.uuidString)
    #expect(object["generationID"] as? String == generationID.uuidString)
    #expect(object["toolLoopIteration"] as? Int == 3)
    #expect(object["interactionMode"] as? String == "agent")
    #expect(object["durationMs"] as? Double == 1_250)
    #expect(object["generatedTokenCount"] as? Int == 3)
    #expect(object["generatedTokenCountIsEstimate"] as? Bool == true)
  }

  @Test
  func requestTraceRecordsFinalPromptWithTransientInstructions() async throws {
    setenv("SUMIKA_DEBUG_TRACE", "1", 1)
    defer {
      unsetenv("SUMIKA_DEBUG_TRACE")
    }
    let fileURL = try temporaryTraceFileURL()
    let store = MLXDebugTraceStore(fileURL: fileURL)
    let toolObservation = """
      <observation call_id="call_1" tool="read_file" status="success">
      README contents
      </observation>
      """
    let runtimeContext = """
      [Runtime Context]
      Active todo plan:
      - Inspect README.md
      """
    let promptWithTransientInstructions = MLXChatRuntime.appendTransientInstructions(
      [runtimeContext],
      toPromptSnapshot: [
        ProviderPromptMessage(
          role: Chat.Message.Role.tool.rawValue,
          content: toolObservation,
          toolCallID: "call_1"
        )
      ],
      promptMessages: [.tool(toolObservation, id: "call_1")]
    )
    let finalPrompt = promptWithTransientInstructions.promptMessages.map(\.content)
      .joined(separator: "\n\n")

    await store.traceRequest(
      id: UUID(),
      history: [(role: "tool", content: toolObservation)],
      prompt: finalPrompt,
      settings: .agentDefault,
      contextTokenLimit: nil
    )

    let data = try Data(contentsOf: fileURL)
    let line = try #require(String(data: data, encoding: .utf8)?.split(separator: "\n").first)
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    )
    let history = try #require(object["history"] as? [[String: Any]])
    let prompt = try #require(object["prompt"] as? String)

    #expect(object["kind"] as? String == "mlx_request")
    #expect(prompt.contains(runtimeContext))
    #expect(prompt.contains(toolObservation))
    #expect((history.first?["content"] as? String)?.contains(runtimeContext) == false)
    #expect((history.first?["content"] as? String)?.contains(toolObservation) == true)
  }

  @Test
  func defaultTraceFileUsesEnvironmentOverrideWhenPresent() async throws {
    setenv("SUMIKA_DEBUG_TRACE", "1", 1)
    let fileURL = try temporaryTraceFileURL()
    setenv("SUMIKA_DEBUG_TRACE_FILE", fileURL.path(percentEncoded: false), 1)
    defer {
      unsetenv("SUMIKA_DEBUG_TRACE")
      unsetenv("SUMIKA_DEBUG_TRACE_FILE")
    }

    let store = MLXDebugTraceStore()

    await store.recordTurnTraceEvent(
      TurnTraceEvent(phase: .runtimeTTFT, durationMs: 10, ttftMs: 10)
    )

    #expect(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
  }

  @Test
  func defaultTraceFileUsesBasenameEnvironmentOverrideWhenPresent() async throws {
    setenv("SUMIKA_DEBUG_TRACE", "1", 1)
    let basename = "\(UUID().uuidString)-mlx-trace.jsonl"
    setenv("SUMIKA_DEBUG_TRACE_BASENAME", basename, 1)
    defer {
      unsetenv("SUMIKA_DEBUG_TRACE")
      unsetenv("SUMIKA_DEBUG_TRACE_BASENAME")
    }

    let store = MLXDebugTraceStore()

    await store.recordTurnTraceEvent(
      TurnTraceEvent(phase: .runtimeTTFT, durationMs: 10, ttftMs: 10)
    )

    let traceURL = URL.applicationSupportDirectory
      .appending(path: "Sumika", directoryHint: .isDirectory)
      .appending(path: "debug", directoryHint: .isDirectory)
      .appending(path: "traces", directoryHint: .isDirectory)
      .appending(path: basename, directoryHint: .notDirectory)
    defer { removeTemporaryItemIfPresent(traceURL) }
    #expect(FileManager.default.fileExists(atPath: traceURL.path(percentEncoded: false)))
  }

  private func temporaryTraceFileURL() throws -> URL {
    try scopedTemporaryDirectory()
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
      .appending(path: "mlx-trace.jsonl", directoryHint: .notDirectory)
  }
}
