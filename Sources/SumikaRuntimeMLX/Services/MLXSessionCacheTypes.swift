import MLXLMCommon
import SumikaCore

nonisolated enum MLXSessionCacheMode: String, Equatable, Sendable {
  case newSession = "new_session"
  case reusedSession = "reused_session"
  case appendDelta = "append_delta"
  case dirtyRebuild = "dirty_rebuild"
}

nonisolated enum MLXSessionInvalidationReason: Equatable, Sendable {
  case signatureMismatch
  case cancelled
  case interrupted
  case downstreamTerminated
  case runtimeError
  case modelChanged
  case nativeToolCallBoundary
}

nonisolated enum MLXSessionCacheReason: String, Equatable, Sendable {
  case newSessionNoCache = "no_cached_session"
  case reusedSession = "reused_session"
  case appendOnlyDelta = "append_only_delta"
  case identityChanged = "identity_changed"
  case historyChanged = "history_changed"
  case toolFollowUpRebuild = "tool_follow_up_rebuild"
  case maxKVSizeChanged = "max_kv_size_changed"
  case reasoningChanged = "reasoning_changed"
  case invalidatedGenCancelled = "invalidated_generation_cancelled"
  case invalidatedGenInterrupted = "invalidated_generation_interrupted"
  case invalidatedGenDownstreamTerminated = "invalidated_generation_downstream_terminated"
  case invalidatedGenRuntimeError = "invalidated_generation_runtime_error"
  case invalidatedModelChanged = "invalidated_model_changed"
  case invalidatedRuntimeContextCleared = "invalidated_runtime_context_cleared"
  case invalidatedNativeToolCallBoundary = "invalidated_native_tool_call_boundary"

  static func generationInvalidationReason(
    from reason: MLXSessionInvalidationReason
  ) -> MLXSessionCacheReason {
    switch reason {
    case .signatureMismatch:
      .invalidatedRuntimeContextCleared
    case .cancelled:
      .invalidatedGenCancelled
    case .interrupted:
      .invalidatedGenInterrupted
    case .downstreamTerminated:
      .invalidatedGenDownstreamTerminated
    case .runtimeError:
      .invalidatedGenRuntimeError
    case .modelChanged:
      .invalidatedModelChanged
    case .nativeToolCallBoundary:
      .invalidatedNativeToolCallBoundary
    }
  }
}

nonisolated struct MLXSessionCacheIdentity: Equatable, Sendable {
  let systemPrompt: String?
  let projectionMode: ModelContextProjectionMode
  let maxKVSize: Int?
  let reasoningEnabled: Bool
}

nonisolated enum MLXCachedSessionState: Equatable, Sendable {
  case clean
  case inFlight(generationID: MLXGenerationID)
  case dirty(reason: MLXSessionInvalidationReason)

  var isReusable: Bool {
    switch self {
    case .clean:
      true
    case .inFlight, .dirty:
      false
    }
  }

  var invalidationReason: MLXSessionInvalidationReason? {
    switch self {
    case .clean:
      nil
    case .inFlight:
      .interrupted
    case .dirty(let reason):
      reason
    }
  }

  func completing(generationID: MLXGenerationID) -> MLXCachedSessionState? {
    guard self == .inFlight(generationID: generationID) else {
      return nil
    }
    return .clean
  }

  func invalidating(
    generationID: MLXGenerationID,
    reason: MLXSessionInvalidationReason
  ) -> MLXCachedSessionState? {
    guard self == .inFlight(generationID: generationID) else {
      return nil
    }
    return .dirty(reason: reason)
  }
}

nonisolated struct MLXSessionCacheTrace: Equatable, Sendable {
  let cacheMode: MLXSessionCacheMode
  let cacheReason: MLXSessionCacheReason
  let contextSignature: String
  let previousContextSignature: String?
  let appendOnly: Bool
  let reusedMessageCount: Int
  let appendedMessageCount: Int
  let mismatchReason: String?
  let firstMismatchIndex: Int?
  let systemPromptChanged: Bool?
  let currentPromptContextChanged: Bool?
}

nonisolated struct CachedMLXSession {
  let session: MLXLMCommon.ChatSession
  let prefix: [ProviderPromptMessage]
  let identity: MLXSessionCacheIdentity
  let state: MLXCachedSessionState
}

nonisolated struct MLXSessionCachePlan {
  let session: MLXLMCommon.ChatSession
  let trace: MLXSessionCacheTrace
  let appendDeltaStartIndex: Int?
  let streamMessages: [Chat.Message]
}
