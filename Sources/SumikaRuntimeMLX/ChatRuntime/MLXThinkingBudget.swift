import Foundation
import MLXLMCommon
import SumikaCore
import Synchronization

enum MLXThinkingBudgetPolicy: String, Equatable, Sendable {
  case unmanaged
  case unsupported
  case qwen36ImmediateV1 = "qwen36_immediate_v1"
}

enum MLXThinkingBudgetTransitionMode: String, Equatable, Sendable {
  case immediate
}

struct MLXThinkingBudgetIdentity: Equatable, Sendable {
  let policy: MLXThinkingBudgetPolicy
  let maximumTokenCount: Int
  let minimumAnswerTokenCount: Int
  let transitionMode: MLXThinkingBudgetTransitionMode

  var signatureComponent: String {
    "\(policy.rawValue):\(maximumTokenCount):\(minimumAnswerTokenCount):\(transitionMode.rawValue)"
  }
}

struct MLXThinkingBudgetTrace: Equatable, Sendable {
  let policy: MLXThinkingBudgetPolicy
  let maximumTokenCount: Int?
  let minimumAnswerTokenCount: Int?
  let transitionMode: MLXThinkingBudgetTransitionMode?
  let validationStatus: MLXThinkingBudgetValidationStatus
}

enum MLXThinkingBudgetFailure: LocalizedError, Equatable, Sendable {
  case unsupportedModel
  case missingInteractionMode
  case incompatibleReasoningProtocol
  case enforcementDisabled
  case unicodeBoundaryCompletionFailed
  case reopenedReasoning
  case duplicateReasoningClose
  case unexpectedChatBoundary
  case truncatedProtocolMarker

  var errorDescription: String? {
    switch self {
    case .unsupportedModel:
      "Hard thinking limits are not enabled for this model. Disable reasoning or select a model that supports hard thinking limits."
    case .missingInteractionMode:
      "A Chat or Agent interaction mode is required before applying the hard thinking limit."
    case .incompatibleReasoningProtocol:
      "The loaded model or tokenizer does not expose the validated Qwen thinking protocol required for hard limit enforcement."
    case .enforcementDisabled:
      "Hard thinking-limit enforcement became non-authoritative during generation, so the response was rejected."
    case .unicodeBoundaryCompletionFailed:
      "Hard thinking-limit enforcement could not complete a Unicode boundary, so the response was rejected."
    case .reopenedReasoning:
      "The model reopened a thinking span after reasoning had already ended, so the response was rejected."
    case .duplicateReasoningClose:
      "The model emitted a duplicate thinking close marker after reasoning had already ended, so the response was rejected."
    case .unexpectedChatBoundary:
      "The model emitted an unexpected chat-template boundary after reasoning had ended, so the response was rejected."
    case .truncatedProtocolMarker:
      "The model stopped after emitting a partial protocol marker, so the response was rejected."
    }
  }

  var diagnosticCode: String {
    switch self {
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
}

enum MLXThinkingBudgetValidationStatus: Equatable, Sendable {
  case notApplied
  case pending
  case validated
  case rejected(MLXThinkingBudgetFailure)
  case failed

  var traceValue: String {
    switch self {
    case .notApplied:
      "not_applied"
    case .pending:
      "pending"
    case .validated:
      "validated"
    case .rejected(let failure):
      failure.diagnosticCode
    case .failed:
      "failed"
    }
  }
}

final class MLXThinkingBudgetEnforcementState: Sendable {
  let responseStopStrings: Set<String>

  private let failureStorage = Mutex<MLXThinkingBudgetFailure?>(nil)

  init(responseStopStrings: Set<String> = []) {
    self.responseStopStrings = responseStopStrings
  }

  var failure: MLXThinkingBudgetFailure? {
    failureStorage.withLock { $0 }
  }

  func record(_ diagnostic: ThinkingBudgetDiagnostic) {
    let failure: MLXThinkingBudgetFailure =
      switch diagnostic {
      case .enforcementDisabled:
        .enforcementDisabled
      case .unicodeBoundaryCompletionFailed:
        .unicodeBoundaryCompletionFailed
      }
    record(failure)
  }

  func record(_ failure: MLXThinkingBudgetFailure) {
    failureStorage.withLock { storedFailure in
      if storedFailure == nil {
        storedFailure = failure
      }
    }
  }

  func checkAuthoritative() throws {
    if let failure {
      throw failure
    }
  }
}

struct MLXThinkingBudgetPlan: Sendable {
  let components: GenerationComponents
  let identity: MLXThinkingBudgetIdentity?
  let trace: MLXThinkingBudgetTrace
  let enforcementState: MLXThinkingBudgetEnforcementState?
}

enum MLXThinkingBudgetPlanner {
  private struct Specification: Equatable, Sendable {
    let maximumTokenCount: Int
    let minimumAnswerTokenCount: Int

    var identity: MLXThinkingBudgetIdentity {
      MLXThinkingBudgetIdentity(
        policy: .qwen36ImmediateV1,
        maximumTokenCount: maximumTokenCount,
        minimumAnswerTokenCount: minimumAnswerTokenCount,
        transitionMode: .immediate
      )
    }
  }

  static func trace(
    policy: ThinkingBudgetPolicy,
    reasoningEnabled: Bool,
    interactionMode: WorkspaceInteractionMode?
  ) -> MLXThinkingBudgetTrace {
    do {
      guard
        let specification = try specification(
          policy: policy,
          reasoningEnabled: reasoningEnabled,
          interactionMode: interactionMode
        )
      else {
        return MLXThinkingBudgetTrace(
          policy: policyName(policy),
          maximumTokenCount: nil,
          minimumAnswerTokenCount: nil,
          transitionMode: nil,
          validationStatus: .notApplied
        )
      }
      return MLXThinkingBudgetTrace(
        policy: specification.identity.policy,
        maximumTokenCount: specification.maximumTokenCount,
        minimumAnswerTokenCount: specification.minimumAnswerTokenCount,
        transitionMode: specification.identity.transitionMode,
        validationStatus: .pending
      )
    } catch let failure as MLXThinkingBudgetFailure {
      return MLXThinkingBudgetTrace(
        policy: policyName(policy),
        maximumTokenCount: nil,
        minimumAnswerTokenCount: nil,
        transitionMode: nil,
        validationStatus: .rejected(failure)
      )
    } catch {
      return MLXThinkingBudgetTrace(
        policy: policyName(policy),
        maximumTokenCount: nil,
        minimumAnswerTokenCount: nil,
        transitionMode: nil,
        validationStatus: .failed
      )
    }
  }

  static func makePlan(
    policy: ThinkingBudgetPolicy,
    reasoningEnabled: Bool,
    interactionMode: WorkspaceInteractionMode?,
    modelContainer: ModelContainer,
    generateParameters: GenerateParameters
  ) async throws -> MLXThinkingBudgetPlan {
    guard
      let specification = try specification(
        policy: policy,
        reasoningEnabled: reasoningEnabled,
        interactionMode: interactionMode
      )
    else {
      return MLXThinkingBudgetPlan(
        components: .init(),
        identity: nil,
        trace: MLXThinkingBudgetTrace(
          policy: policyName(policy),
          maximumTokenCount: nil,
          minimumAnswerTokenCount: nil,
          transitionMode: nil,
          validationStatus: .notApplied
        ),
        enforcementState: nil
      )
    }

    let modelConfiguration = await modelContainer.configuration
    guard modelConfiguration.reasoningConfig == QwenReasoningProtocol.tagged else {
      throw MLXThinkingBudgetFailure.incompatibleReasoningProtocol
    }
    let tokenizer = await modelContainer.tokenizer
    let enforcementState = MLXThinkingBudgetEnforcementState(
      responseStopStrings: modelConfiguration.effectiveStopStrings
    )
    let components = try makeComponents(
      maximumTokenCount: specification.maximumTokenCount,
      minimumAnswerTokenCount: specification.minimumAnswerTokenCount,
      reasoning: QwenReasoningProtocol.tagged,
      tokenizer: tokenizer,
      generateParameters: generateParameters,
      enforcementState: enforcementState
    )

    return MLXThinkingBudgetPlan(
      components: components,
      identity: specification.identity,
      trace: MLXThinkingBudgetTrace(
        policy: specification.identity.policy,
        maximumTokenCount: specification.maximumTokenCount,
        minimumAnswerTokenCount: specification.minimumAnswerTokenCount,
        transitionMode: specification.identity.transitionMode,
        validationStatus: .validated
      ),
      enforcementState: enforcementState
    )
  }

  static func diagnosticCode(for error: Error) -> String {
    if let failure = error as? MLXThinkingBudgetFailure {
      return failure.diagnosticCode
    }
    if let failure = error as? ThinkingBudgetError {
      switch failure {
      case .invalidMaximumTokenCount:
        return "invalid_maximum_token_count"
      case .invalidMinimumAnswerTokenCount:
        return "invalid_minimum_answer_token_count"
      case .unsupportedReasoningProtocol:
        return "unsupported_reasoning_protocol"
      case .unencodableBoundary:
        return "unencodable_boundary"
      case .unencodableTransition:
        return "unencodable_transition"
      case .invalidTokenID:
        return "invalid_token_id"
      case .insufficientGenerationTokenLimit:
        return "insufficient_generation_token_limit"
      case .generationTokenRequirementOverflow:
        return "generation_token_requirement_overflow"
      }
    }
    return "preflight_validation_failed"
  }

  static func makeComponents(
    maximumTokenCount: Int,
    minimumAnswerTokenCount: Int,
    reasoning: ReasoningConfig,
    tokenizer: any Tokenizer,
    generateParameters: GenerateParameters,
    enforcementState: MLXThinkingBudgetEnforcementState
  ) throws -> GenerationComponents {
    let budgetConfiguration = try ThinkingBudgetConfiguration(
      maximumTokenCount: maximumTokenCount,
      minimumAnswerTokenCount: minimumAnswerTokenCount,
      transitionOverride: .immediate
    )
    let components = try GenerationComponents().applyingThinkingBudget(
      budgetConfiguration,
      reasoning: reasoning,
      tokenizer: tokenizer,
      diagnosticHandler: { diagnostic in
        enforcementState.record(diagnostic)
      }
    )
    try components.validate(parameters: generateParameters)
    return components
  }

  private static func specification(
    policy: ThinkingBudgetPolicy,
    reasoningEnabled: Bool,
    interactionMode: WorkspaceInteractionMode?
  ) throws -> Specification? {
    guard reasoningEnabled else {
      return nil
    }
    switch policy {
    case .unmanaged:
      return nil
    case .unsupported:
      throw MLXThinkingBudgetFailure.unsupportedModel
    case .hardLimitImmediate:
      guard let interactionMode else {
        throw MLXThinkingBudgetFailure.missingInteractionMode
      }
      switch interactionMode {
      case .chat:
        return Specification(maximumTokenCount: 1_024, minimumAnswerTokenCount: 512)
      case .agent:
        return Specification(maximumTokenCount: 2_048, minimumAnswerTokenCount: 1_024)
      }
    }
  }

  private static func policyName(_ policy: ThinkingBudgetPolicy) -> MLXThinkingBudgetPolicy {
    switch policy {
    case .unmanaged:
      .unmanaged
    case .unsupported:
      .unsupported
    case .hardLimitImmediate:
      .qwen36ImmediateV1
    }
  }
}

struct MLXQwenThinkingBudgetGuard: Sendable {
  private enum State {
    case reasoning
    case response
  }

  private struct ForbiddenMarker: Sendable {
    let value: String
    let failure: MLXThinkingBudgetFailure
  }

  private static let reasoningEndMarkers = ["</think>", "<tool_call>"]
  private static let protocolResponseMarkers = [
    ForbiddenMarker(value: "<think>", failure: .reopenedReasoning),
    ForbiddenMarker(value: "</think>", failure: .duplicateReasoningClose),
    ForbiddenMarker(value: "<|im_start|>", failure: .unexpectedChatBoundary),
  ]

  private let forbiddenResponseMarkers: [ForbiddenMarker]
  private var state = State.reasoning
  private var pending = ""

  init(responseStopStrings: Set<String> = []) {
    forbiddenResponseMarkers =
      Self.protocolResponseMarkers
      + responseStopStrings.filter { !$0.isEmpty }.map {
        ForbiddenMarker(value: $0, failure: .unexpectedChatBoundary)
      }
  }

  mutating func consume(_ chunk: String) throws -> String {
    pending += chunk

    switch state {
    case .reasoning:
      guard
        let closeRange = Self.firstMarkerRange(
          in: pending,
          markers: Self.reasoningEndMarkers
        )
      else {
        return releaseSafePrefix(watching: Self.reasoningEndMarkers)
      }

      let reasoning = String(pending[..<closeRange.upperBound])
      pending = String(pending[closeRange.upperBound...])
      state = .response
      return reasoning + (try consumeResponse())
    case .response:
      return try consumeResponse()
    }
  }

  mutating func finish() throws -> String {
    defer { pending = "" }
    guard state == .response, !pending.isEmpty else {
      return pending
    }
    if forbiddenResponseMarkers.contains(where: { marker in
      marker.value.hasPrefix(pending)
    }) {
      throw MLXThinkingBudgetFailure.truncatedProtocolMarker
    }
    return pending
  }

  mutating func observeToolCall() {
    state = .response
    pending = ""
  }

  private mutating func consumeResponse() throws -> String {
    if let failure = firstForbiddenMarker(in: pending)?.failure {
      throw failure
    }
    return releaseSafePrefix(
      watching: forbiddenResponseMarkers.map(\.value)
    )
  }

  private mutating func releaseSafePrefix(watching markers: [String]) -> String {
    let retainedCount = markers.reduce(0) { count, marker in
      max(count, Self.matchingSuffixLength(in: pending, marker: marker))
    }
    let releaseEnd = pending.index(pending.endIndex, offsetBy: -retainedCount)
    let released = String(pending[..<releaseEnd])
    pending = String(pending[releaseEnd...])
    return released
  }

  private func firstForbiddenMarker(
    in value: String
  ) -> (range: Range<String.Index>, failure: MLXThinkingBudgetFailure)? {
    forbiddenResponseMarkers.compactMap { marker in
      value.range(of: marker.value).map { ($0, marker.failure) }
    }.min { lhs, rhs in
      lhs.0.lowerBound < rhs.0.lowerBound
    }
  }

  private static func firstMarkerRange(
    in value: String,
    markers: [String]
  ) -> Range<String.Index>? {
    markers.compactMap { value.range(of: $0) }.min { lhs, rhs in
      lhs.lowerBound < rhs.lowerBound
    }
  }

  private static func matchingSuffixLength(in value: String, marker: String) -> Int {
    var length = min(value.count, marker.count - 1)
    while length > 0 {
      if value.suffix(length) == marker.prefix(length) {
        return length
      }
      length -= 1
    }
    return 0
  }
}
