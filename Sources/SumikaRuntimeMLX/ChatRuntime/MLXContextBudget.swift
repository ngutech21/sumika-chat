import Foundation
import MLXLMCommon
import SumikaCore
import Synchronization

struct MLXContextBudgetTrace: Equatable, Sendable {
  let capacity: Int
  let configuredResponseMaximum: Int
  var promptTokens: Int?
  var effectiveResponseMaximum: Int?
  var preparationAttempts = 0
  var rejected = false

  var outputLimitReason: ChatGenerationOutputLimit.Reason {
    guard let promptTokens else { return .configuredMaximum }
    let available = capacity - promptTokens - MLXContextBudget.protocolHeadroom
    // Increasing Max Tokens cannot help when both limits are equal either.
    return configuredResponseMaximum >= available ? .contextCapacity : .configuredMaximum
  }
}

enum MLXContextBudgetError: LocalizedError, Equatable {
  case insufficientSpace(promptTokens: Int, capacity: Int, minimumReply: Int)
  case incompatibleThinkingBudget
  case changedDuringPreparation
  case missingBudget

  var errorDescription: String? {
    switch self {
    case .insufficientSpace(let promptTokens, let capacity, let minimumReply):
      "This conversation uses \(promptTokens.formatted()) of \(capacity.formatted()) context tokens and needs room for at least \(minimumReply.formatted()) reply tokens. Start a new chat, reduce the supplied content, or increase Context Length in model settings."
    case .incompatibleThinkingBudget:
      "The remaining context cannot fit the model's thinking and answer budgets. Start a new chat, reduce the supplied content, or increase Context Length in model settings."
    case .changedDuringPreparation:
      "The prepared conversation changed while fitting the reply into context. Start a new chat or reduce the supplied content."
    case .missingBudget:
      "The model input could not be checked against its context limit. Reload the model and try again."
    }
  }
}

/// One request's measured budget, shared by preparation and terminal diagnostics.
final class MLXContextBudget: Sendable {
  fileprivate static let protocolHeadroom = 64

  private struct Preparation: Sendable {
    let budget: MLXContextBudget
    let responseMaximum: Int
  }

  private struct Adjustment: Error {
    let responseMaximum: Int
  }

  @TaskLocal private static var preparation: Preparation?

  private let storage: Mutex<MLXContextBudgetTrace>

  init(capacity: Int, configuredMaximum: Int) {
    storage = Mutex(
      MLXContextBudgetTrace(
        capacity: capacity, configuredResponseMaximum: configuredMaximum
      ))
  }

  var trace: MLXContextBudgetTrace { storage.withLock { $0 } }

  func measure(promptTokens: Int) throws -> Int {
    try storage.withLock { state in
      state.promptTokens = promptTokens
      state.preparationAttempts += 1
      let available = state.capacity - promptTokens - Self.protocolHeadroom
      let minimumReply = min(
        state.configuredResponseMaximum,
        min(4_096, max(1, state.capacity / 4))
      )
      let effectiveMaximum = min(state.configuredResponseMaximum, max(0, available))
      state.effectiveResponseMaximum = effectiveMaximum
      guard available >= minimumReply else {
        state.rejected = true
        throw MLXContextBudgetError.insufficientSpace(
          promptTokens: promptTokens, capacity: state.capacity, minimumReply: minimumReply
        )
      }
      return effectiveMaximum
    }
  }

  static func install(on container: ModelContainer) async {
    await container.update { context in
      context.processor = BudgetedInputProcessor(base: context.processor)
    }
  }

  /// The owning runtime serializes session access. Keep the stream task on that
  /// actor too: ChatSession and its media messages are not Sendable.
  func streamDetails(
    session: MLXLMCommon.ChatSession,
    messages: [Chat.Message],
    isolation: isolated (any Actor)? = #isolation
  ) -> AsyncThrowingStream<Generation, Error> {
    let (stream, continuation) = AsyncThrowingStream<Generation, Error>.makeStream()
    let originalParameters = session.generateParameters
    let task = Task {
      _ = isolation
      do {
        for attempt in 0...1 {
          try Task.checkCancellation()
          let preparation = Preparation(
            budget: self,
            responseMaximum: session.generateParameters.maxTokens ?? trace.configuredResponseMaximum
          )
          do {
            // ChatSession's preparation task inherits this request-local policy.
            let inputStream = Self.$preparation.withValue(preparation) {
              session.streamDetails(to: messages)
            }
            for try await generation in inputStream {
              try Task.checkCancellation()
              continuation.yield(generation)
            }
            try Task.checkCancellation()
            break
          } catch let adjustment as Adjustment {
            guard attempt == 0 else {
              storage.withLock { $0.rejected = true }
              throw MLXContextBudgetError.changedDuringPreparation
            }
            var parameters = originalParameters
            parameters.maxTokens = adjustment.responseMaximum
            do {
              try session.components.validate(parameters: parameters)
            } catch {
              storage.withLock { $0.rejected = true }
              throw MLXContextBudgetError.incompatibleThinkingBudget
            }
            session.generateParameters = parameters
          }
        }
        session.generateParameters = originalParameters
        continuation.finish()
      } catch {
        session.generateParameters = originalParameters
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
  }

  private struct BudgetedInputProcessor: UserInputProcessor {
    let base: any UserInputProcessor

    func prepare(input: UserInput) async throws -> LMInput {
      try Task.checkCancellation()
      guard let preparation = MLXContextBudget.preparation else {
        throw MLXContextBudgetError.missingBudget
      }
      let prepared = try await base.prepare(input: input)
      try Task.checkCancellation()
      let maximum = try preparation.budget.measure(promptTokens: prepared.text.tokens.size)
      guard maximum == preparation.responseMaximum else {
        // Throw before ChatSession reconciles/trims the cache or runs prefill.
        // Its pending messages are a local copy and have not been committed yet.
        throw Adjustment(responseMaximum: maximum)
      }
      return prepared
    }
  }
}
