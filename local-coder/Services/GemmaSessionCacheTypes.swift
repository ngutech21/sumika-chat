import Foundation
import LocalCoderCore
import MLXLMCommon

nonisolated enum GemmaSessionCacheMode: String, Equatable, Sendable {
  case newSessionHistory = "new_session_history"
  case sessionReused = "session_reused"
  case invalidatedSignatureMismatch = "invalidated_signature_mismatch"
  case invalidatedCancelled = "invalidated_cancelled"
  case invalidatedInterrupted = "invalidated_interrupted"
  case invalidatedDownstreamTerminated = "invalidated_downstream_terminated"
  case invalidatedRuntimeError = "invalidated_runtime_error"
  case invalidatedModelChanged = "invalidated_model_changed"
  case invalidatedNativeToolCallBoundary = "invalidated_native_tool_call_boundary"
}

nonisolated enum GemmaSessionInvalidationReason: Equatable, Sendable {
  case signatureMismatch
  case cancelled
  case interrupted
  case downstreamTerminated
  case runtimeError
  case modelChanged
  case nativeToolCallBoundary

  var cacheMode: GemmaSessionCacheMode {
    switch self {
    case .signatureMismatch:
      .invalidatedSignatureMismatch
    case .cancelled:
      .invalidatedCancelled
    case .interrupted:
      .invalidatedInterrupted
    case .downstreamTerminated:
      .invalidatedDownstreamTerminated
    case .runtimeError:
      .invalidatedRuntimeError
    case .modelChanged:
      .invalidatedModelChanged
    case .nativeToolCallBoundary:
      .invalidatedNativeToolCallBoundary
    }
  }
}

nonisolated enum GemmaSessionCacheReason: String, Equatable, Sendable {
  case sessionReused = "session_reused"
  case newSessionNoCache = "new_session_no_cache"
  case invalidatedGenCancelled = "invalidated_generation_cancelled"
  case invalidatedGenInterrupted = "invalidated_generation_interrupted"
  case invalidatedGenDownstreamTerminated = "invalidated_generation_downstream_terminated"
  case invalidatedGenRuntimeError = "invalidated_generation_runtime_error"
  case invalidatedSettingsChanged = "invalidated_settings_changed"
  case invalidatedRendererVersionChanged = "invalidated_renderer_version_changed"
  case invalidatedRenderedContextChanged = "invalidated_rendered_context_signature_changed"
  case invalidatedSystemPromptChanged = "invalidated_system_prompt_changed"
  case invalidatedHistoryAppended = "invalidated_history_appended"
  case invalidatedHistoryPrefixMismatch = "invalidated_history_prefix_mismatch"
  case invalidatedCurrentPromptContextBoundary = "invalidated_current_prompt_context_boundary"
  case invalidatedToolPromptChanged = "invalidated_tool_prompt_changed"
  case invalidatedModelChanged = "invalidated_model_changed"
  case invalidatedRuntimeContextCleared = "invalidated_runtime_context_cleared"
  case invalidatedNativeToolCallBoundary = "invalidated_native_tool_call_boundary"
  case appendOnlyDeltaReused = "append_only_delta_reused"

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

nonisolated enum GemmaCachedSessionState: Equatable, Sendable {
  case clean
  case cleanNativeToolCallBoundary
  case inFlight(generationID: GemmaGenerationID)
  case dirty(reason: GemmaSessionInvalidationReason)

  var isReusable: Bool {
    switch self {
    case .clean, .cleanNativeToolCallBoundary:
      true
    case .inFlight, .dirty:
      false
    }
  }

  var invalidationReason: GemmaSessionInvalidationReason? {
    switch self {
    case .clean, .cleanNativeToolCallBoundary:
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

  func completingNativeToolCallBoundary(generationID: GemmaGenerationID) -> GemmaCachedSessionState?
  {
    guard self == .inFlight(generationID: generationID) else {
      return nil
    }
    return .cleanNativeToolCallBoundary
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

nonisolated struct GemmaSessionCacheDecision: Equatable, Sendable {
  let reuseStrategy: GemmaSessionReuseStrategy
  let trace: GemmaSessionCacheTrace

  var shouldReuse: Bool {
    reuseStrategy != .none
  }
}

nonisolated enum GemmaSessionReuseStrategy: Equatable, Sendable {
  case none
  case exactPrompt
  case appendHistoryDelta(startIndex: Int)
}

nonisolated struct CachedGemmaSession {
  let session: MLXLMCommon.ChatSession
  let prefix: [GemmaMessageSnapshot]
  let settings: ChatGenerationSettings
  let contextSignature: GemmaRenderedContextSignature
  let state: GemmaCachedSessionState
}

nonisolated struct GemmaSessionCachePlan {
  let session: MLXLMCommon.ChatSession
  let trace: GemmaSessionCacheTrace
  let reuseStrategy: GemmaSessionReuseStrategy
  let streamInput: GemmaSessionStreamInput
}

nonisolated enum GemmaSessionStreamInput {
  case prompt(String, images: [UserInput.Image])
  case messages([Chat.Message])

  var contentByteCount: Int {
    switch self {
    case .prompt(let prompt, let images):
      return prompt.utf8.count + images.count
    case .messages(let messages):
      return messages.reduce(0) { byteCount, message in
        byteCount + message.content.utf8.count + message.images.count
      }
    }
  }
}
