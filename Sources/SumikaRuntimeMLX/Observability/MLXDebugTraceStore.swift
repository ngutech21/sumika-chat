import Foundation
import MLXLMCommon
import SumikaCore

struct MLXRuntimePrefillTrace: Equatable, Sendable {
  let event: TurnTraceEvent
  let cacheDiagnostics: MLXRuntimeCacheDiagnosticResult?
}

struct MLXMTPDecodeTrace: Equatable, Sendable {
  let proposedDraftTokens: Int?
  let acceptedDraftTokens: Int?
  let acceptanceRate: Double?
  let roundCount: Int?
  let targetModelCallCount: Int?
  let draftModelCallCount: Int?
  let targetVerifiedTokenCount: Int?
  let emittedTokenCount: Int?
  let passthroughReason: String?
}

struct MLXRuntimeDecodeTrace: Equatable, Sendable {
  let event: TurnTraceEvent
  let mtp: MLXMTPDecodeTrace?
}

protocol MLXRuntimeTracing: TurnTracing {
  func recordRuntimePrefillTrace(_ trace: MLXRuntimePrefillTrace) async
  func recordRuntimeDecodeTrace(_ trace: MLXRuntimeDecodeTrace) async
}

actor MLXDebugTraceStore: MLXRuntimeTracing {
  static var isEnabled: Bool {
    let value = ProcessInfo.processInfo.environment["SUMIKA_DEBUG_TRACE"] ?? ""
    return ["1", "true", "yes", "on"].contains(value.lowercased())
  }

  private let fileURL: URL
  private let memorySnapshotSource: MLXMemorySnapshotSource
  private let isEnabledProvider: @Sendable () -> Bool
  private let maxFieldCharacters = 80_000

  init(
    memorySnapshotSource: MLXMemorySnapshotSource = .live,
    isEnabled: @escaping @Sendable () -> Bool = { MLXDebugTraceStore.isEnabled }
  ) {
    self.fileURL = Self.defaultFileURL()
    self.memorySnapshotSource = memorySnapshotSource
    self.isEnabledProvider = isEnabled
  }

  init(
    fileURL: URL,
    memorySnapshotSource: MLXMemorySnapshotSource = .live,
    isEnabled: @escaping @Sendable () -> Bool = { MLXDebugTraceStore.isEnabled }
  ) {
    self.fileURL = fileURL
    self.memorySnapshotSource = memorySnapshotSource
    self.isEnabledProvider = isEnabled
  }

  func traceRequest(
    id: UUID,
    history: [(role: String, content: String)],
    prompt: String,
    settings: ChatGenerationSettings,
    effectiveReasoningSelection: ReasoningSelection? = nil,
    contextTokenLimit: Int?,
    imageAttachments: [ChatAttachment] = [],
    thinkingBudget: MLXThinkingBudgetTrace? = nil,
    mtpDrafterLoaded: Bool = false,
    speculativeDecodingMode: String = "none",
    interactionMode: WorkspaceInteractionMode? = nil
  ) async {
    guard tracingIsEnabled else {
      return
    }

    let truncatedPrompt = truncated(prompt)
    let resolvedReasoningSelection = effectiveReasoningSelection ?? settings.reasoningSelection
    var settingsTrace: [String: Any] = [
      "maxTokens": settings.maxTokens,
      "temperature": settings.temperature,
      "topP": settings.topP,
      "topK": settings.topK,
      "repetitionPenalty": settings.repetitionPenalty,
      "repetitionContextSize": settings.repetitionContextSize,
      "presencePenalty": settings.presencePenalty,
      "reasoningEnabled": settings.reasoningEnabled,
      "reasoningSelection": settings.reasoningSelection.persistenceValue,
      "effectiveReasoningSelection": resolvedReasoningSelection.persistenceValue,
    ]
    if let reasoningEffort = resolvedReasoningSelection.effort {
      settingsTrace["reasoningEffort"] = reasoningEffort.rawValue
    }
    var request: [String: Any] = [
      "id": id.uuidString,
      "timestamp": timestamp(),
      "kind": "mlx_request",
      "settings": settingsTrace,
      "history": history.map(traceMessage(from:)),
      "prompt": truncatedPrompt.value,
      "promptTruncated": truncatedPrompt.truncated,
      "mtpDrafterLoaded": mtpDrafterLoaded,
      "speculativeDecodingMode": speculativeDecodingMode,
    ]
    if let contextTokenLimit {
      request["contextTokenLimit"] = contextTokenLimit
    }
    if let interactionMode {
      request["interactionMode"] = interactionMode.rawValue
    }
    if let thinkingBudget {
      request["thinkingBudget"] = thinkingBudgetObject(from: thinkingBudget)
    }
    let imageMetadata = traceImageAttachments(from: imageAttachments)
    if !imageMetadata.isEmpty {
      request["imageInputs"] = imageMetadata
      request["imageCount"] = imageMetadata.count
      request["imageByteCount"] = MLXHistoryRenderer.imageByteCount(from: imageAttachments)
    }
    append(request)
  }

  func traceResponse(
    id: UUID,
    output: String,
    metrics: ChatGenerationMetrics?,
    error: String? = nil,
    thinkingBudget: MLXThinkingBudgetTrace? = nil,
    thinkingBudgetOutcome: MLXThinkingBudgetOutcome
  ) async {
    guard tracingIsEnabled else {
      return
    }

    let truncatedOutput = truncated(output)
    var response: [String: Any] = [
      "id": id.uuidString,
      "timestamp": timestamp(),
      "kind": "mlx_response",
      "output": truncatedOutput.value,
      "outputTruncated": truncatedOutput.truncated,
    ]
    if let metrics {
      response["metrics"] = [
        "generatedTokenCount": metrics.generatedTokenCount,
        "tokensPerSecond": metrics.tokensPerSecond,
      ]
    }
    if let error {
      response["error"] = error
    }
    if let thinkingBudget {
      response["thinkingBudget"] = thinkingBudgetObject(from: thinkingBudget)
    }
    response["thinkingBudgetOutcome"] = thinkingBudgetOutcomeValue(thinkingBudgetOutcome)
    if let diagnostic = thinkingBudgetDiagnostic(from: thinkingBudgetOutcome) {
      response["thinkingBudgetDiagnostic"] = thinkingBudgetDiagnosticValue(diagnostic)
    }
    append(response)
  }

  func traceGenerationProgress(
    id: UUID,
    traceMetadata: TurnTraceMetadata?,
    durationMs: Double,
    output: String,
    applicationState: RuntimeApplicationStateSnapshot,
    generationActivityRequest: GenerationActivityRequest,
    estimateTokenCount: @Sendable (String) -> Int
  ) async {
    guard tracingIsEnabled else {
      return
    }

    await recordTurnTraceEvent(
      TurnTraceEvent(
        turnID: traceMetadata?.turnID,
        generationID: id,
        phase: .runtimePartialDecode,
        durationMs: durationMs,
        toolLoopIteration: traceMetadata?.toolLoopIteration,
        interactionMode: traceMetadata?.interactionMode,
        generatedTokenCount: estimateTokenCount(output),
        generatedTokenCountIsEstimate: true,
        applicationActivation: applicationState.applicationActivation,
        applicationVisibility: applicationState.applicationVisibility,
        applicationOcclusion: applicationState.applicationOcclusion,
        mainWindowVisibility: applicationState.mainWindowVisibility,
        generationActivityRequest: generationActivityRequest
      )
    )
  }

  func recordTurnTraceEvent(_ event: TurnTraceEvent) async {
    guard tracingIsEnabled else {
      return
    }

    append(turnTraceObject(from: event))
  }

  func recordRuntimePrefillTrace(_ runtimeTrace: MLXRuntimePrefillTrace) async {
    guard tracingIsEnabled else {
      return
    }

    var trace = turnTraceObject(from: runtimeTrace.event)
    if let diagnostics = runtimeTrace.cacheDiagnostics {
      trace["mlxCacheDecision"] = diagnostics.decision.rawValue
      if let mismatchReason = diagnostics.mismatchReason {
        trace["mlxCacheMismatchReason"] = mismatchReason.rawValue
      }
      trace["fullPromptTokens"] = diagnostics.fullPromptTokens
      if let expectedCachedTokens = diagnostics.expectedCachedTokens {
        trace["expectedCachedTokens"] = expectedCachedTokens
      }
      if let expectedSuffixTokens = diagnostics.expectedSuffixTokens {
        trace["expectedSuffixTokens"] = expectedSuffixTokens
      }
      trace["reusedPromptTokens"] = diagnostics.reusedPromptTokens
      trace["cacheEfficiency"] = diagnostics.cacheEfficiency
      trace["inputMaskPresent"] = diagnostics.inputMaskPresent
      trace["preparedMediaPresent"] = diagnostics.preparedMediaPresent
      trace["newMediaPresent"] = diagnostics.newMediaPresent
      trace["cacheTrimmable"] = diagnostics.cacheTrimmable
      trace["cacheTypes"] = diagnostics.cacheTypes
    }
    append(trace)
  }

  func beginMemoryScope(
    phase: MLXMemoryTracePhase,
    generationID: UUID? = nil,
    traceMetadata: TurnTraceMetadata? = nil,
    memoryClearReason: MLXMemoryClearReason? = nil
  ) -> MLXMemoryTraceScope? {
    guard tracingIsEnabled else {
      return nil
    }

    let snapshot = memorySnapshotSource.capture()
    let scope = MLXMemoryTraceScope(
      id: UUID(),
      baselinePhase: phase,
      baselineSnapshot: snapshot,
      startedAt: Date(),
      turnID: traceMetadata?.turnID,
      generationID: generationID ?? traceMetadata?.generationID,
      toolLoopIteration: traceMetadata?.toolLoopIteration,
      interactionMode: traceMetadata?.interactionMode,
      memoryClearReason: memoryClearReason?.rawValue
    )
    append(
      memoryTraceObject(
        phase: phase,
        scope: scope,
        snapshot: snapshot,
        delta: nil,
        durationMs: 0
      )
    )
    return scope
  }

  func recordMemorySnapshot(
    phase: MLXMemoryTracePhase,
    scope: MLXMemoryTraceScope?,
    durationMs: Double? = nil,
    modelLoadOutcome: MLXModelLoadOutcome? = nil,
    runtimeStreamOutcome: RuntimeStreamOutcome? = nil
  ) {
    guard tracingIsEnabled, let scope else {
      return
    }
    if phase == .generationTerminal,
      !scope.claimTerminalSnapshot()
    {
      return
    }

    let snapshot = memorySnapshotSource.capture()
    let delta = scope.baselineSnapshot.delta(to: snapshot)
    append(
      memoryTraceObject(
        phase: phase,
        scope: scope,
        snapshot: snapshot,
        delta: delta,
        durationMs: durationMs ?? Date().timeIntervalSince(scope.startedAt) * 1000,
        modelLoadOutcome: modelLoadOutcome,
        runtimeStreamOutcome: runtimeStreamOutcome
      )
    )
  }

  private var tracingIsEnabled: Bool {
    isEnabledProvider()
  }

  private func memoryTraceObject(
    phase: MLXMemoryTracePhase,
    scope: MLXMemoryTraceScope,
    snapshot: MLXMemorySnapshot,
    delta: MLXMemorySnapshotDelta?,
    durationMs: Double,
    modelLoadOutcome: MLXModelLoadOutcome? = nil,
    runtimeStreamOutcome: RuntimeStreamOutcome? = nil
  ) -> [String: Any] {
    var trace = turnTraceObject(
      from: TurnTraceEvent(
        turnID: scope.turnID,
        generationID: scope.generationID,
        phase: .runtimeMemory,
        durationMs: durationMs,
        toolLoopIteration: scope.toolLoopIteration,
        memoryClearReason: scope.memoryClearReason,
        interactionMode: scope.interactionMode,
        runtimeStreamOutcome: runtimeStreamOutcome
      )
    )
    trace["memoryScopeID"] = scope.id.uuidString
    trace["memoryPhase"] = phase.rawValue
    trace["activeMemoryBytes"] = snapshot.activeMemoryBytes
    trace["cacheMemoryBytes"] = snapshot.cacheMemoryBytes
    trace["peakMemoryBytes"] = snapshot.peakMemoryBytes
    if let delta {
      trace["baselineMemoryPhase"] = scope.baselinePhase.rawValue
      trace["activeMemoryDeltaBytes"] = delta.activeMemoryBytes
      trace["cacheMemoryDeltaBytes"] = delta.cacheMemoryBytes
      trace["peakMemoryDeltaBytes"] = delta.peakMemoryBytes
    }
    if let modelLoadOutcome {
      trace["modelLoadOutcome"] = modelLoadOutcome.rawValue
    }
    return trace
  }

  func recordRuntimeDecodeTrace(_ runtimeTrace: MLXRuntimeDecodeTrace) async {
    guard tracingIsEnabled else {
      return
    }

    var trace = turnTraceObject(from: runtimeTrace.event)
    if let mtp = runtimeTrace.mtp {
      let optionalFields: [(String, Any?)] = [
        ("mtpProposedDraftTokens", mtp.proposedDraftTokens),
        ("mtpAcceptedDraftTokens", mtp.acceptedDraftTokens),
        ("mtpAcceptanceRate", mtp.acceptanceRate),
        ("mtpRoundCount", mtp.roundCount),
        ("mtpTargetModelCallCount", mtp.targetModelCallCount),
        ("mtpDraftModelCallCount", mtp.draftModelCallCount),
        ("mtpTargetVerifiedTokenCount", mtp.targetVerifiedTokenCount),
        ("mtpEmittedTokenCount", mtp.emittedTokenCount),
        ("mtpPassthroughReason", mtp.passthroughReason),
      ]
      for (key, value) in optionalFields {
        if let value {
          trace[key] = value
        }
      }
    }
    append(trace)
  }

  private func turnTraceObject(from event: TurnTraceEvent) -> [String: Any] {
    var trace: [String: Any] = [
      "timestamp": timestamp(),
      "kind": "turn_trace",
      "phase": event.phase.rawValue,
      "durationMs": event.durationMs,
    ]
    let optionalFields: [(String, Any?)] = [
      ("turnID", event.turnID?.uuidString),
      ("generationID", event.generationID?.uuidString),
      ("promptBytes", event.promptBytes),
      ("promptTokens", event.promptTokens),
      ("messageCount", event.messageCount),
      ("toolLoopIteration", event.toolLoopIteration),
      ("toolName", event.toolName),
      ("ttftMs", event.ttftMs),
      ("tokensPerSecond", event.tokensPerSecond),
      ("cacheMode", event.cacheMode),
      ("cacheReason", event.cacheReason),
      ("memoryClearReason", event.memoryClearReason),
      ("interactionMode", event.interactionMode?.rawValue),
      ("selectedMCPServerIDs", event.selectedMCPServerIDs?.map(\.uuidString)),
      ("activeMCPToolCount", event.activeMCPToolCount),
      ("activatedSkillIDs", event.activatedSkillIDs),
      ("activatedSkillContentHashes", event.activatedSkillContentHashes),
      ("activatedSkillCharacterCount", event.activatedSkillCharacterCount),
      ("contextSignature", event.contextSignature),
      ("previousContextSignature", event.previousContextSignature),
      ("appendOnly", event.appendOnly),
      ("reusedMessageCount", event.reusedMessageCount),
      ("appendedMessageCount", event.appendedMessageCount),
      ("mismatchReason", event.mismatchReason),
      ("firstMismatchIndex", event.firstMismatchIndex),
      ("systemPromptChanged", event.systemPromptChanged),
      ("toolCallFormat", event.toolCallFormat),
      ("toolValidationStatus", event.toolValidationStatus),
      ("toolValidationError", event.toolValidationError),
      ("toolOriginalName", event.toolOriginalName),
      ("toolArgumentKeys", event.toolArgumentKeys),
      ("toolArguments", event.toolArguments?.map(traceToolArgument(from:))),
      ("imageCount", event.imageCount),
      ("imageTypes", event.imageTypes),
      ("imageByteCount", event.imageByteCount),
      ("generatedTokenCount", event.generatedTokenCount),
      ("generatedTokenCountIsEstimate", event.generatedTokenCountIsEstimate),
      ("applicationActivation", event.applicationActivation?.rawValue),
      ("applicationVisibility", event.applicationVisibility?.rawValue),
      ("applicationOcclusion", event.applicationOcclusion?.rawValue),
      ("mainWindowVisibility", event.mainWindowVisibility?.rawValue),
      ("generationActivityRequest", event.generationActivityRequest?.rawValue),
      ("runtimeStreamOutcome", event.runtimeStreamOutcome?.rawValue),
    ]
    for (key, value) in optionalFields {
      if let value {
        trace[key] = value
      }
    }
    return trace
  }

  private func traceMessage(from message: (role: String, content: String)) -> [String: Any] {
    let truncatedContent = truncated(message.content)
    return [
      "role": message.role,
      "content": truncatedContent.value,
      "truncated": truncatedContent.truncated,
    ]
  }

  private func thinkingBudgetObject(
    from trace: MLXThinkingBudgetTrace
  ) -> [String: Any] {
    var object: [String: Any] = [
      "policy": trace.policy.rawValue,
      "validationStatus": thinkingBudgetValidationStatusValue(trace.validationStatus),
    ]
    if let maximumTokenCount = trace.maximumTokenCount {
      object["maximumTokenCount"] = maximumTokenCount
    }
    if let minimumAnswerTokenCount = trace.minimumAnswerTokenCount {
      object["minimumAnswerTokenCount"] = minimumAnswerTokenCount
    }
    if let transitionMode = trace.transitionMode {
      object["transitionMode"] = transitionMode.rawValue
    }
    return object
  }

  private func thinkingBudgetOutcomeValue(_ outcome: MLXThinkingBudgetOutcome) -> String {
    switch outcome {
    case .notApplied:
      "not_applied"
    case .preflightFailed:
      "preflight_failed"
    case .cancelled:
      "cancelled"
    case .failedClosed:
      "failed_closed"
    case .outputLimit:
      "output_limit"
    case .interrupted:
      "interrupted"
    case .completedAuthoritative:
      "completed_authoritative"
    }
  }

  private func thinkingBudgetDiagnostic(
    from outcome: MLXThinkingBudgetOutcome
  ) -> MLXThinkingBudgetDiagnostic? {
    switch outcome {
    case .preflightFailed(let diagnostic):
      diagnostic
    case .failedClosed(let diagnostic):
      diagnostic
    case .notApplied, .cancelled, .outputLimit, .interrupted, .completedAuthoritative:
      nil
    }
  }

  private func thinkingBudgetDiagnosticValue(
    _ diagnostic: MLXThinkingBudgetDiagnostic
  ) -> String {
    switch diagnostic {
    case .budgetFailure(let failure):
      thinkingBudgetFailureValue(failure)
    case .configurationFailure(let failure):
      thinkingBudgetConfigurationFailureValue(failure)
    case .preflightValidationFailed:
      "preflight_validation_failed"
    }
  }

  private func thinkingBudgetValidationStatusValue(
    _ status: MLXThinkingBudgetValidationStatus
  ) -> String {
    switch status {
    case .notApplied:
      "not_applied"
    case .pending:
      "pending"
    case .validated:
      "validated"
    case .rejected(let failure):
      thinkingBudgetFailureValue(failure)
    case .failed:
      "failed"
    }
  }

  private func thinkingBudgetFailureValue(_ failure: MLXThinkingBudgetFailure) -> String {
    switch failure {
    case .unsupportedModel:
      "unsupported_model"
    case .missingInteractionMode:
      "missing_interaction_mode"
    case .incompatibleReasoningProtocol:
      "incompatible_reasoning_protocol"
    case .enforcementDisabled:
      "enforcement_disabled"
    case .unicodeBoundaryCompletionFailed:
      "unicode_boundary_completion_failed"
    case .reopenedReasoning:
      "reopened_reasoning"
    case .duplicateReasoningClose:
      "duplicate_reasoning_close"
    case .unexpectedChatBoundary:
      "unexpected_chat_boundary"
    case .truncatedProtocolMarker:
      "truncated_protocol_marker"
    }
  }

  private func thinkingBudgetConfigurationFailureValue(
    _ failure: ThinkingBudgetError
  ) -> String {
    switch failure {
    case .invalidMaximumTokenCount:
      "invalid_maximum_token_count"
    case .invalidMinimumAnswerTokenCount:
      "invalid_minimum_answer_token_count"
    case .unsupportedReasoningProtocol:
      "unsupported_reasoning_protocol"
    case .unencodableBoundary:
      "unencodable_boundary"
    case .unencodableTransition:
      "unencodable_transition"
    case .invalidTokenID:
      "invalid_token_id"
    case .insufficientGenerationTokenLimit:
      "insufficient_generation_token_limit"
    case .generationTokenRequirementOverflow:
      "generation_token_requirement_overflow"
    }
  }

  private func traceToolArgument(from argument: ToolArgumentTrace) -> [String: Any] {
    [
      "name": argument.name,
      "valueType": argument.valueType,
      "preview": argument.preview,
      "previewTruncated": argument.previewTruncated,
    ]
  }

  private func traceImageAttachments(from attachments: [ChatAttachment]) -> [[String: Any]] {
    attachments.filter { $0.kind == .image }.map { attachment in
      var trace: [String: Any] = [
        "attachmentID": attachment.id.uuidString,
        "name": attachment.displayName,
        "byteCount": attachment.byteSize,
        "sha256": attachment.contentSHA256,
      ]
      if let mimeType = attachment.mimeType {
        trace["mimeType"] = mimeType
      }
      return trace
    }
  }

  private func truncated(_ value: String) -> (value: String, truncated: Bool) {
    guard value.count > maxFieldCharacters else {
      return (value, false)
    }

    return (String(value.prefix(maxFieldCharacters)), true)
  }

  private func timestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
  }

  private func append(_ value: [String: Any]) {
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )

      var data = try JSONSerialization.data(
        withJSONObject: value,
        options: [.sortedKeys, .withoutEscapingSlashes]
      )
      data.append(0x0A)

      if FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
      } else {
        try data.write(to: fileURL, options: .atomic)
      }
    } catch {
      // Debug tracing must never affect model generation.
    }
  }

  private static func defaultFileURL() -> URL {
    if let traceFile = ProcessInfo.processInfo.environment["SUMIKA_DEBUG_TRACE_FILE"],
      !traceFile.isEmpty
    {
      return URL(filePath: traceFile, directoryHint: .notDirectory)
    }
    if let traceBasename = ProcessInfo.processInfo.environment["SUMIKA_DEBUG_TRACE_BASENAME"],
      !traceBasename.isEmpty,
      !traceBasename.contains("/")
    {
      return debugDirectory()
        .appending(path: "traces", directoryHint: .isDirectory)
        .appending(path: traceBasename, directoryHint: .notDirectory)
    }

    return debugDirectory()
      .appending(path: "mlx-trace.jsonl", directoryHint: .notDirectory)
  }

  private static func debugDirectory() -> URL {
    URL.applicationSupportDirectory
      .appending(path: "Sumika", directoryHint: .isDirectory)
      .appending(path: "debug", directoryHint: .isDirectory)
  }
}
