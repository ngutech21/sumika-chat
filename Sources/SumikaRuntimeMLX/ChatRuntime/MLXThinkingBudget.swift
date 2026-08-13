import Foundation
import MLXLMCommon
import SumikaCore
import Synchronization

struct MLXThinkingBudgetIdentity: Equatable, Sendable {
  let policy: String
  let maximumTokenCount: Int
  let minimumAnswerTokenCount: Int
  let transitionMode: String

  var signatureComponent: String {
    "\(policy):\(maximumTokenCount):\(minimumAnswerTokenCount):\(transitionMode)"
  }
}

struct MLXThinkingBudgetTrace: Equatable, Sendable {
  let policy: String
  let maximumTokenCount: Int?
  let minimumAnswerTokenCount: Int?
  let transitionMode: String?
  let validationStatus: String
}

enum MLXThinkingBudgetFailure: LocalizedError, Equatable, Sendable {
  case unsupportedModel
  case missingInteractionMode
  case incompatibleReasoningProtocol
  case enforcementDisabled
  case unicodeBoundaryCompletionFailed
  case reopenedReasoning

  var errorDescription: String? {
    switch self {
    case .unsupportedModel:
      "Hard thinking limits are not enabled for this Qwen model. Disable reasoning or select the allowlisted Qwen 3.6 27B OptiQ 4-bit model."
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
    }
  }
}

final class MLXThinkingBudgetEnforcementState: Sendable {
  private let failureStorage = Mutex<MLXThinkingBudgetFailure?>(nil)

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
        policy: "qwen36_immediate_v1",
        maximumTokenCount: maximumTokenCount,
        minimumAnswerTokenCount: minimumAnswerTokenCount,
        transitionMode: "immediate"
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
          validationStatus: "not_applied"
        )
      }
      return MLXThinkingBudgetTrace(
        policy: specification.identity.policy,
        maximumTokenCount: specification.maximumTokenCount,
        minimumAnswerTokenCount: specification.minimumAnswerTokenCount,
        transitionMode: specification.identity.transitionMode,
        validationStatus: "pending"
      )
    } catch let failure as MLXThinkingBudgetFailure {
      return MLXThinkingBudgetTrace(
        policy: policyName(policy),
        maximumTokenCount: nil,
        minimumAnswerTokenCount: nil,
        transitionMode: nil,
        validationStatus: failure.diagnosticCode
      )
    } catch {
      return MLXThinkingBudgetTrace(
        policy: policyName(policy),
        maximumTokenCount: nil,
        minimumAnswerTokenCount: nil,
        transitionMode: nil,
        validationStatus: "failed"
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
          validationStatus: "not_applied"
        ),
        enforcementState: nil
      )
    }

    let modelConfiguration = await modelContainer.configuration
    guard modelConfiguration.reasoningConfig == QwenReasoningProtocol.tagged else {
      throw MLXThinkingBudgetFailure.incompatibleReasoningProtocol
    }
    let tokenizer = await modelContainer.tokenizer
    let enforcementState = MLXThinkingBudgetEnforcementState()
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
        validationStatus: "validated"
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

  private static func policyName(_ policy: ThinkingBudgetPolicy) -> String {
    switch policy {
    case .unmanaged:
      "unmanaged"
    case .unsupported:
      "unsupported"
    case .hardLimitImmediate:
      "qwen36_immediate_v1"
    }
  }
}

struct MLXReasoningReopenGuard: Sendable {
  private static let openMarker = "<think>"
  private static let closeMarkers = ["</think>", "<tool_call>"]
  private static let retainedCharacterCount =
    max(openMarker.count, closeMarkers.map(\.count).max() ?? 0) - 1

  private var pending = ""
  private var reasoningEnded = false

  mutating func observe(_ chunk: String) throws {
    pending += chunk
    if !reasoningEnded {
      let closeRange = Self.closeMarkers
        .compactMap { pending.range(of: $0) }
        .min { $0.lowerBound < $1.lowerBound }
      guard let closeRange else {
        retainBoundarySuffix()
        return
      }
      pending = String(pending[closeRange.upperBound...])
      reasoningEnded = true
    }
    if pending.contains(Self.openMarker) {
      throw MLXThinkingBudgetFailure.reopenedReasoning
    }
    retainBoundarySuffix()
  }

  mutating func observeToolCall() {
    reasoningEnded = true
    pending = ""
  }

  private mutating func retainBoundarySuffix() {
    if pending.count > Self.retainedCharacterCount {
      pending = String(pending.suffix(Self.retainedCharacterCount))
    }
  }
}
