import Foundation
import MLX
import MLXLMCommon
import SumikaCore
import Synchronization

enum MLXThinkingBudgetPolicy: String, Equatable, Sendable {
  case unmanaged
  case unsupported
  case qwen36ImmediateV2 = "qwen36_immediate_v2"
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

enum MLXThinkingBudgetDiagnostic: Equatable, Sendable {
  case budgetFailure(MLXThinkingBudgetFailure)
  case configurationFailure(ThinkingBudgetError)
  case preflightValidationFailed
}

enum MLXThinkingBudgetOutcome: Equatable, Sendable {
  case notApplied
  case preflightFailed(MLXThinkingBudgetDiagnostic)
  case cancelled
  case failedClosed(MLXThinkingBudgetDiagnostic?)
  case outputLimit
  case interrupted
  case completedAuthoritative
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

}

enum MLXThinkingBudgetValidationStatus: Equatable, Sendable {
  case notApplied
  case pending
  case validated
  case rejected(MLXThinkingBudgetFailure)
  case failed
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
        policy: .qwen36ImmediateV2,
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

  static func diagnostic(for error: Error) -> MLXThinkingBudgetDiagnostic {
    if let failure = error as? MLXThinkingBudgetFailure {
      return .budgetFailure(failure)
    }
    if let failure = error as? ThinkingBudgetError {
      return .configurationFailure(failure)
    }
    return .preflightValidationFailed
  }

  static func makeComponents(
    maximumTokenCount: Int,
    minimumAnswerTokenCount: Int,
    reasoning: ReasoningConfig,
    tokenizer: any Tokenizer,
    generateParameters: GenerateParameters,
    enforcementState: MLXThinkingBudgetEnforcementState
  ) throws -> GenerationComponents {
    let protocolGuard = try MLXQwenReasoningTokenGuard(
      reasoning: reasoning, tokenizer: tokenizer, enforcementState: enforcementState)
    var budgetReasoning = reasoning
    // Track template newlines so prompt spacing is uncharged and a partial close completes once.
    budgetReasoning.startDelimiter = reasoning.startDelimiter + "\n"
    budgetReasoning.endDelimiter = "\n" + reasoning.endDelimiter
    budgetReasoning.implicitEndDelimiters.append(reasoning.endDelimiter)
    let budgetConfiguration = try ThinkingBudgetConfiguration(
      maximumTokenCount: maximumTokenCount,
      minimumAnswerTokenCount: minimumAnswerTokenCount,
      transitionOverride: ReasoningBudgetTransition(afterEndDelimiter: "\n\n")
    )
    let components = try GenerationComponents().applyingThinkingBudget(
      budgetConfiguration,
      reasoning: budgetReasoning,
      tokenizer: tokenizer,
      diagnosticHandler: { diagnostic in
        enforcementState.record(diagnostic)
      }
    ).appendingLogitProcessor { protocolGuard }
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
      case .chat, .agent:
        return Specification(maximumTokenCount: 8_192, minimumAnswerTokenCount: 1_024)
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
      .qwen36ImmediateV2
    }
  }
}

private struct MLXQwenReasoningTokenGuard: LogitProcessor, Sendable {
  private let startToken: Int
  private let endToken: Int
  private let toolToken: Int
  private let enforcementState: MLXThinkingBudgetEnforcementState
  private var isClosed = false

  init(
    reasoning: ReasoningConfig, tokenizer: any Tokenizer,
    enforcementState: MLXThinkingBudgetEnforcementState
  ) throws {
    guard reasoning == QwenReasoningProtocol.tagged,
      let implicitEnd = reasoning.implicitEndDelimiters.first
    else {
      throw MLXThinkingBudgetFailure.incompatibleReasoningProtocol
    }
    startToken = try Self.tokenID(for: reasoning.startDelimiter, tokenizer: tokenizer)
    endToken = try Self.tokenID(for: reasoning.endDelimiter, tokenizer: tokenizer)
    toolToken = try Self.tokenID(for: implicitEnd, tokenizer: tokenizer)
    guard Set([startToken, endToken, toolToken]).count == 3 else {
      throw MLXThinkingBudgetFailure.incompatibleReasoningProtocol
    }
    self.enforcementState = enforcementState
  }

  mutating func prompt(_ prompt: MLXArray) {
    // The enforced Qwen prompt opens reasoning, even when a cached suffix omits its opener.
    isClosed = false
  }

  func process(logits: MLXArray) -> MLXArray { logits }
  mutating func didSample(token: MLXArray) {}

  mutating func didEmit(token: Int) {
    if token == endToken {
      if isClosed { enforcementState.record(.duplicateReasoningClose) }
      isClosed = true
    } else if token == toolToken {
      isClosed = true
    } else if token == startToken, isClosed {
      enforcementState.record(.reopenedReasoning)
    }
  }

  private static func tokenID(for marker: String, tokenizer: any Tokenizer) throws -> Int {
    let tokenID: Int
    if let converted = tokenizer.convertTokenToId(marker) {
      tokenID = converted
    } else {
      let encoded = tokenizer.encode(text: marker, addSpecialTokens: false)
      guard encoded.count == 1, let encodedToken = encoded.first else {
        throw MLXThinkingBudgetFailure.incompatibleReasoningProtocol
      }
      tokenID = encodedToken
    }
    guard tokenID >= 0, tokenID != tokenizer.unknownTokenId,
      tokenizer.decode(tokenIds: [tokenID]) == marker
    else {
      throw MLXThinkingBudgetFailure.incompatibleReasoningProtocol
    }
    return tokenID
  }
}
