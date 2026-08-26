import Foundation
import MLXLMCommon
import SumikaCore
import SumikaTestSupport
import Synchronization
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
  func disabledMemoryTracingDoesNotCreateScopeOrInvokeSnapshotSource() async throws {
    let fileURL = try temporaryTraceFileURL()
    let probe = MLXMemorySnapshotProbe(
      snapshots: [
        MLXMemorySnapshot(activeMemoryBytes: 1, cacheMemoryBytes: 2, peakMemoryBytes: 3)
      ]
    )
    let store = MLXDebugTraceStore(
      fileURL: fileURL,
      memorySnapshotSource: MLXMemorySnapshotSource(probe.capture),
      isEnabled: { false }
    )

    let scope = await store.beginMemoryScope(phase: .modelLoadBefore)
    await store.recordMemorySnapshot(
      phase: .modelLoadAfter,
      scope: scope,
      modelLoadOutcome: .loaded
    )

    #expect(scope == nil)
    #expect(probe.invocationCount == 0)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
  }

  @Test
  func disablingMemoryTracingDuringScopeSkipsFollowUpCaptureAndDelta() async throws {
    let fileURL = try temporaryTraceFileURL()
    let probe = MLXMemorySnapshotProbe(
      snapshots: [
        MLXMemorySnapshot(activeMemoryBytes: 1, cacheMemoryBytes: 2, peakMemoryBytes: 3),
        MLXMemorySnapshot(activeMemoryBytes: 4, cacheMemoryBytes: 5, peakMemoryBytes: 6),
      ]
    )
    let enablement = MLXTraceEnablementProbe(isEnabled: true)
    let store = MLXDebugTraceStore(
      fileURL: fileURL,
      memorySnapshotSource: MLXMemorySnapshotSource(probe.capture),
      isEnabled: { enablement.isEnabled }
    )

    let scope = try #require(await store.beginMemoryScope(phase: .generationStart))
    enablement.setEnabled(false)
    await store.recordMemorySnapshot(
      phase: .generationTerminal,
      scope: scope,
      runtimeStreamOutcome: .completed
    )

    let objects = try traceObjects(at: fileURL)
    #expect(probe.invocationCount == 1)
    #expect(objects.count == 1)
    #expect(objects.first?["memoryPhase"] as? String == "generation_start")
    #expect(objects.first?["baselineMemoryPhase"] == nil)
    #expect(objects.first?["activeMemoryDeltaBytes"] == nil)
  }

  @Test
  func memoryTraceRecordsStableFieldsAndSignedDeltas() async throws {
    let fileURL = try temporaryTraceFileURL()
    let probe = MLXMemorySnapshotProbe(
      snapshots: [
        MLXMemorySnapshot(
          activeMemoryBytes: 100,
          cacheMemoryBytes: 40,
          peakMemoryBytes: 150
        ),
        MLXMemorySnapshot(
          activeMemoryBytes: 130,
          cacheMemoryBytes: 10,
          peakMemoryBytes: 180
        ),
      ]
    )
    let store = MLXDebugTraceStore(
      fileURL: fileURL,
      memorySnapshotSource: MLXMemorySnapshotSource(probe.capture),
      isEnabled: { true }
    )
    let turnID = UUID()
    let generationID = UUID()
    let metadata = TurnTraceMetadata(
      turnID: turnID,
      generationID: generationID,
      tracer: store,
      toolLoopIteration: 2,
      interactionMode: .agent
    )

    let scope = try #require(
      await store.beginMemoryScope(
        phase: .modelLoadBefore,
        generationID: generationID,
        traceMetadata: metadata
      )
    )
    await store.recordMemorySnapshot(
      phase: .modelLoadAfter,
      scope: scope,
      durationMs: 25,
      modelLoadOutcome: .loaded
    )

    let objects = try traceObjects(at: fileURL)
    #expect(objects.count == 2)
    let start = try #require(objects.first)
    let end = try #require(objects.last)

    #expect(start["kind"] as? String == "turn_trace")
    #expect(start["phase"] as? String == "runtime_memory")
    #expect(start["memoryPhase"] as? String == "model_load_before")
    #expect(start["memoryScopeID"] as? String == scope.id.uuidString)
    #expect(start["turnID"] as? String == turnID.uuidString)
    #expect(start["generationID"] as? String == generationID.uuidString)
    #expect(start["toolLoopIteration"] as? Int == 2)
    #expect(start["interactionMode"] as? String == "agent")
    #expect(start["activeMemoryBytes"] as? Int == 100)
    #expect(start["cacheMemoryBytes"] as? Int == 40)
    #expect(start["peakMemoryBytes"] as? Int == 150)
    #expect(start["baselineMemoryPhase"] == nil)
    #expect(start["activeMemoryDeltaBytes"] == nil)

    #expect(end["phase"] as? String == "runtime_memory")
    #expect(end["memoryPhase"] as? String == "model_load_after")
    #expect(end["memoryScopeID"] as? String == scope.id.uuidString)
    #expect(end["baselineMemoryPhase"] as? String == "model_load_before")
    #expect(end["activeMemoryBytes"] as? Int == 130)
    #expect(end["cacheMemoryBytes"] as? Int == 10)
    #expect(end["peakMemoryBytes"] as? Int == 180)
    #expect(end["activeMemoryDeltaBytes"] as? Int == 30)
    #expect(end["cacheMemoryDeltaBytes"] as? Int == -30)
    #expect(end["peakMemoryDeltaBytes"] as? Int == 30)
    #expect(end["modelLoadOutcome"] as? String == "loaded")
    #expect(end["durationMs"] as? Double == 25)
    #expect(probe.invocationCount == 2)
  }

  @Test
  func memoryTraceRecordsFailedModelLoadOutcome() async throws {
    let fileURL = try temporaryTraceFileURL()
    let probe = MLXMemorySnapshotProbe(
      snapshots: [
        MLXMemorySnapshot(activeMemoryBytes: 10, cacheMemoryBytes: 20, peakMemoryBytes: 30),
        MLXMemorySnapshot(activeMemoryBytes: 11, cacheMemoryBytes: 19, peakMemoryBytes: 31),
      ]
    )
    let store = MLXDebugTraceStore(
      fileURL: fileURL,
      memorySnapshotSource: MLXMemorySnapshotSource(probe.capture),
      isEnabled: { true }
    )

    let scope = try #require(await store.beginMemoryScope(phase: .modelLoadBefore))
    await store.recordMemorySnapshot(
      phase: .modelLoadAfter,
      scope: scope,
      modelLoadOutcome: .failed
    )

    let end = try #require(traceObjects(at: fileURL).last)
    #expect(end["memoryPhase"] as? String == "model_load_after")
    #expect(end["modelLoadOutcome"] as? String == "failed")
  }

  @Test
  func memoryTracePhaseRawValuesStayStable() {
    #expect(MLXMemoryTracePhase.modelLoadBefore.rawValue == "model_load_before")
    #expect(MLXMemoryTracePhase.modelLoadAfter.rawValue == "model_load_after")
    #expect(MLXMemoryTracePhase.generationStart.rawValue == "generation_start")
    #expect(
      MLXMemoryTracePhase.generationFirstOutput.rawValue == "generation_first_output"
    )
    #expect(MLXMemoryTracePhase.generationTerminal.rawValue == "generation_terminal")
    #expect(MLXMemoryTracePhase.cacheClearBefore.rawValue == "cache_clear_before")
    #expect(MLXMemoryTracePhase.cacheClearAfter.rawValue == "cache_clear_after")
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

    await store.recordRuntimePrefillTrace(
      MLXRuntimePrefillTrace(
        event: TurnTraceEvent(
          turnID: turnID,
          generationID: generationID,
          phase: .runtimePrefill,
          durationMs: 123.5,
          promptTokens: 37,
          messageCount: 2,
          cacheMode: "reused_session",
          cacheReason: "reused_session",
          memoryClearReason: "runtime_error",
          activatedSkillIDs: ["project:review"],
          activatedSkillContentHashes: ["skill-hash"],
          activatedSkillCharacterCount: 812,
          contextSignature: "ctx-new",
          previousContextSignature: "ctx-old",
          appendOnly: true,
          reusedMessageCount: 3,
          appendedMessageCount: 1,
          mismatchReason: "history_prefix_mismatch",
          firstMismatchIndex: 2,
          systemPromptChanged: false,
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
          generatedTokenCountIsEstimate: true,
          applicationActivation: .inactive,
          applicationVisibility: .shown,
          applicationOcclusion: .occluded,
          mainWindowVisibility: .notVisible,
          generationActivityRequest: .userInitiatedAllowingIdleSystemSleep,
          runtimeStreamOutcome: .completed
        ),
        cacheDiagnostics: MLXRuntimeCacheDiagnosticResult(
          decision: .fullPrefill,
          mismatchReason: .nontrimmablePrefixOrAlignmentMismatch,
          fullPromptTokens: 140,
          expectedCachedTokens: 120,
          expectedSuffixTokens: 20,
          reusedPromptTokens: 0,
          cacheEfficiency: 0,
          inputMaskPresent: false,
          preparedMediaPresent: false,
          newMediaPresent: false,
          cacheTrimmable: false,
          cacheTypes: ["MLXLMCommon.MambaCache", "MLXLMCommon.KVCacheSimple"]
        )
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
    #expect(object["activatedSkillIDs"] as? [String] == ["project:review"])
    #expect(object["activatedSkillContentHashes"] as? [String] == ["skill-hash"])
    #expect(object["activatedSkillCharacterCount"] as? Int == 812)
    #expect(object["activatedSkillContents"] == nil)
    #expect(object["activatedSkillPaths"] == nil)
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
    #expect(object["cacheEfficiency"] as? Double == 0)
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
    #expect(object["applicationActivation"] as? String == "inactive")
    #expect(object["applicationVisibility"] as? String == "shown")
    #expect(object["applicationOcclusion"] as? String == "occluded")
    #expect(object["mainWindowVisibility"] as? String == "not_visible")
    #expect(
      object["generationActivityRequest"] as? String
        == "user_initiated_allowing_idle_system_sleep"
    )
    #expect(object["runtimeStreamOutcome"] as? String == "completed")

    let toolArguments = try #require(object["toolArguments"] as? [[String: Any]])
    #expect(toolArguments.count == 1)
    #expect(toolArguments.first?["name"] as? String == "id")
    #expect(toolArguments.first?["valueType"] as? String == "string")
    #expect(toolArguments.first?["preview"] as? String == "setup-project")
    #expect(toolArguments.first?["previewTruncated"] as? Bool == false)
  }

  @Test
  func runtimeDecodeTracePreservesZeroMTPValuesAndPassthroughReason() async throws {
    setenv("SUMIKA_DEBUG_TRACE", "1", 1)
    defer { unsetenv("SUMIKA_DEBUG_TRACE") }
    let fileURL = try temporaryTraceFileURL()
    let store = MLXDebugTraceStore(fileURL: fileURL)

    await store.recordRuntimeDecodeTrace(
      MLXRuntimeDecodeTrace(
        event: TurnTraceEvent(
          generationID: UUID(),
          phase: .runtimeDecode,
          durationMs: 250,
          tokensPerSecond: 20,
          generatedTokenCount: 5,
          generatedTokenCountIsEstimate: false
        ),
        mtp: MLXMTPDecodeTrace(
          proposedDraftTokens: 0,
          acceptedDraftTokens: 0,
          acceptanceRate: 0,
          roundCount: 0,
          targetModelCallCount: 0,
          draftModelCallCount: 0,
          targetVerifiedTokenCount: 0,
          emittedTokenCount: 0,
          passthroughReason: "main model did not emit drafter state"
        )
      )
    )

    let data = try Data(contentsOf: fileURL)
    let line = try #require(String(data: data, encoding: .utf8)?.split(separator: "\n").first)
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    )

    #expect(object["phase"] as? String == "runtime_decode")
    #expect(object["mtpProposedDraftTokens"] as? Int == 0)
    #expect(object["mtpAcceptedDraftTokens"] as? Int == 0)
    #expect(object["mtpAcceptanceRate"] as? Double == 0)
    #expect(object["mtpRoundCount"] as? Int == 0)
    #expect(object["mtpTargetModelCallCount"] as? Int == 0)
    #expect(object["mtpDraftModelCallCount"] as? Int == 0)
    #expect(object["mtpTargetVerifiedTokenCount"] as? Int == 0)
    #expect(object["mtpEmittedTokenCount"] as? Int == 0)
    #expect(
      object["mtpPassthroughReason"] as? String
        == "main model did not emit drafter state"
    )
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
      reasoningSelection: .on,
      isMTPEnabled: true
    )

    await store.traceRequest(
      id: UUID(),
      history: [],
      prompt: "Prompt",
      settings: settings,
      effectiveReasoningSelection: .effort(.medium),
      contextTokenLimit: nil,
      thinkingBudget: MLXThinkingBudgetTrace(
        policy: .qwen36ImmediateV1,
        maximumTokenCount: 1_024,
        minimumAnswerTokenCount: 512,
        transitionMode: .immediate,
        validationStatus: .validated
      ),
      mtpDrafterLoaded: true,
      speculativeDecodingMode: "mtp",
      interactionMode: .chat
    )

    let data = try Data(contentsOf: fileURL)
    let line = try #require(String(data: data, encoding: .utf8)?.split(separator: "\n").first)
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    )
    let tracedSettings = try #require(object["settings"] as? [String: Any])

    #expect(tracedSettings["presencePenalty"] as? Double == 0.35)
    #expect(tracedSettings["reasoningEnabled"] as? Bool == true)
    #expect(tracedSettings["reasoningSelection"] as? String == "on")
    #expect(tracedSettings["effectiveReasoningSelection"] as? String == "medium")
    #expect(tracedSettings["reasoningEffort"] as? String == "medium")
    #expect(tracedSettings["repetitionContextSize"] as? Int == 512)
    #expect(tracedSettings["mtpEnabled"] as? Bool == true)
    #expect(tracedSettings["temperature"] as? Double == 0)
    #expect(object["interactionMode"] as? String == "chat")
    #expect(object["mtpDrafterLoaded"] as? Bool == true)
    #expect(object["speculativeDecodingMode"] as? String == "mtp")
    let budget = try #require(object["thinkingBudget"] as? [String: Any])
    #expect(budget["policy"] as? String == "qwen36_immediate_v1")
    #expect(budget["maximumTokenCount"] as? Int == 1_024)
    #expect(budget["minimumAnswerTokenCount"] as? Int == 512)
    #expect(budget["transitionMode"] as? String == "immediate")
    #expect(budget["validationStatus"] as? String == "validated")
  }

  @Test
  func responseTraceRecordsFailClosedThinkingBudgetOutcome() async throws {
    setenv("SUMIKA_DEBUG_TRACE", "1", 1)
    defer { unsetenv("SUMIKA_DEBUG_TRACE") }
    let fileURL = try temporaryTraceFileURL()
    let store = MLXDebugTraceStore(fileURL: fileURL)

    await store.traceResponse(
      id: UUID(),
      output: "partial",
      metrics: nil,
      error: "rejected",
      thinkingBudget: MLXThinkingBudgetTrace(
        policy: .qwen36ImmediateV1,
        maximumTokenCount: 2_048,
        minimumAnswerTokenCount: 1_024,
        transitionMode: .immediate,
        validationStatus: .validated
      ),
      thinkingBudgetOutcome: .failedClosed(.budgetFailure(.enforcementDisabled))
    )

    let data = try Data(contentsOf: fileURL)
    let line = try #require(String(data: data, encoding: .utf8)?.split(separator: "\n").first)
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    )
    #expect(object["kind"] as? String == "mlx_response")
    #expect(object["thinkingBudgetOutcome"] as? String == "failed_closed")
    #expect(object["thinkingBudgetDiagnostic"] as? String == "enforcement_disabled")
  }

  @Test
  func responseTraceRecordsPreflightThinkingBudgetDiagnostic() async throws {
    setenv("SUMIKA_DEBUG_TRACE", "1", 1)
    defer { unsetenv("SUMIKA_DEBUG_TRACE") }
    let fileURL = try temporaryTraceFileURL()
    let store = MLXDebugTraceStore(fileURL: fileURL)

    await store.traceResponse(
      id: UUID(),
      output: "",
      metrics: nil,
      error: "rejected",
      thinkingBudgetOutcome: .preflightFailed(
        .configurationFailure(
          .insufficientGenerationTokenLimit(required: 1_540, actual: 1_000)
        )
      )
    )

    let data = try Data(contentsOf: fileURL)
    let line = try #require(String(data: data, encoding: .utf8)?.split(separator: "\n").first)
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    )
    #expect(object["thinkingBudgetOutcome"] as? String == "preflight_failed")
    #expect(
      object["thinkingBudgetDiagnostic"] as? String
        == "insufficient_generation_token_limit"
    )
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
      applicationStateSnapshotProvider: {
        RuntimeApplicationStateSnapshot(
          applicationActivation: .inactive,
          applicationVisibility: .shown,
          applicationOcclusion: .occluded,
          mainWindowVisibility: .notVisible
        )
      },
      generationActivityRequest: .userInitiatedAllowingIdleSystemSleep,
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
    #expect(objects.allSatisfy { $0["applicationActivation"] as? String == "inactive" })
    #expect(objects.allSatisfy { $0["mainWindowVisibility"] as? String == "not_visible" })
    #expect(
      objects.allSatisfy {
        $0["generationActivityRequest"] as? String
          == "user_initiated_allowing_idle_system_sleep"
      })
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
    let plan = MLXModelStreamProcessor.modelStreamPlan(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: cacheTrace,
      debugTraceStore: store,
      generationProgressTracer: .disabled,
      markCompleted: { _ in },
      markCancelled: { _ in },
      memoryCacheClearer: MLXMemoryCacheClearer { _ in }
    )

    for try await _ in plan.stream {}
    await plan.task.value

    let data = try Data(contentsOf: fileURL)
    let lines = try #require(String(data: data, encoding: .utf8)?.split(separator: "\n"))
    let objects = try lines.map {
      try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }

    #expect(objects.count == 2)
    #expect(objects.first?["kind"] as? String == "mlx_response")
    #expect(objects.last?["phase"] as? String == "runtime_stream_end")
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
      applicationState: RuntimeApplicationStateSnapshot(
        applicationActivation: .active,
        applicationVisibility: .shown,
        applicationOcclusion: .visible,
        mainWindowVisibility: .visible
      ),
      generationActivityRequest: .userInitiatedAllowingIdleSystemSleep,
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
    #expect(object["applicationActivation"] as? String == "active")
    #expect(object["applicationVisibility"] as? String == "shown")
    #expect(object["applicationOcclusion"] as? String == "visible")
    #expect(object["mainWindowVisibility"] as? String == "visible")
    #expect(
      object["generationActivityRequest"] as? String
        == "user_initiated_allowing_idle_system_sleep"
    )
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
      ]
    )
    let finalPrompt = MLXHistoryRenderer.chatMessages(
      from: promptWithTransientInstructions,
      supportsHistoricalReasoningPreservation: false
    ).map(\.content)
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

  private func traceObjects(at fileURL: URL) throws -> [[String: Any]] {
    let data = try Data(contentsOf: fileURL)
    let lines = try #require(String(data: data, encoding: .utf8)?.split(separator: "\n"))
    return try lines.map { line in
      try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
  }

  private final class MLXMemorySnapshotProbe: Sendable {
    private let state: Mutex<(snapshots: [MLXMemorySnapshot], invocationCount: Int)>

    init(snapshots: [MLXMemorySnapshot]) {
      self.state = Mutex((snapshots: snapshots, invocationCount: 0))
    }

    var invocationCount: Int {
      state.withLock { $0.invocationCount }
    }

    nonisolated func capture() -> MLXMemorySnapshot {
      state.withLock { state in
        let snapshot = state.snapshots[min(state.invocationCount, state.snapshots.count - 1)]
        state.invocationCount += 1
        return snapshot
      }
    }
  }

  private final class MLXTraceEnablementProbe: Sendable {
    private let state: Mutex<Bool>

    init(isEnabled: Bool) {
      self.state = Mutex(isEnabled)
    }

    nonisolated var isEnabled: Bool {
      state.withLock { $0 }
    }

    nonisolated func setEnabled(_ isEnabled: Bool) {
      state.withLock { $0 = isEnabled }
    }
  }
}
