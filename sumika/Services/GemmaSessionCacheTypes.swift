import Foundation
import MLXLMCommon
import SumikaCore

nonisolated enum GemmaSessionCacheMode: String, Equatable, Sendable {
  case newSession = "new_session"
  case reusedSession = "reused_session"
  case appendDelta = "append_delta"
  case dirtyRebuild = "dirty_rebuild"
}

nonisolated enum GemmaSessionInvalidationReason: Equatable, Sendable {
  case signatureMismatch
  case cancelled
  case interrupted
  case downstreamTerminated
  case runtimeError
  case modelChanged
  case nativeToolCallBoundary
}

nonisolated enum GemmaSessionCacheReason: String, Equatable, Sendable {
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
    from reason: GemmaSessionInvalidationReason
  ) -> GemmaSessionCacheReason {
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

nonisolated struct GemmaSessionCacheIdentity: Equatable, Sendable {
  let systemPrompt: String?
  let projectionMode: ModelContextProjectionMode
  let maxKVSize: Int?
  let reasoningEnabled: Bool
}

nonisolated enum GemmaCachedSessionState: Equatable, Sendable {
  case clean
  case inFlight(generationID: GemmaGenerationID)
  case dirty(reason: GemmaSessionInvalidationReason)

  var isReusable: Bool {
    switch self {
    case .clean:
      true
    case .inFlight, .dirty:
      false
    }
  }

  var invalidationReason: GemmaSessionInvalidationReason? {
    switch self {
    case .clean:
      nil
    case .inFlight:
      .interrupted
    case .dirty(let reason):
      reason
    }
  }

  func completing(generationID: GemmaGenerationID) -> GemmaCachedSessionState? {
    guard self == .inFlight(generationID: generationID) else {
      return nil
    }
    return .clean
  }

  func invalidating(
    generationID: GemmaGenerationID,
    reason: GemmaSessionInvalidationReason
  ) -> GemmaCachedSessionState? {
    guard self == .inFlight(generationID: generationID) else {
      return nil
    }
    return .dirty(reason: reason)
  }
}

nonisolated struct GemmaSessionCacheTrace: Equatable, Sendable {
  let cacheMode: GemmaSessionCacheMode
  let cacheReason: GemmaSessionCacheReason
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

nonisolated struct CachedGemmaSession {
  let session: MLXLMCommon.ChatSession
  let prefix: [GemmaMessageSnapshot]
  let identity: GemmaSessionCacheIdentity
  let state: GemmaCachedSessionState
}

nonisolated struct GemmaSessionCachePlan {
  let session: MLXLMCommon.ChatSession
  let trace: GemmaSessionCacheTrace
  let appendDeltaStartIndex: Int?
  let streamMessages: [Chat.Message]
}
