import Foundation

package enum FinishTaskStatus: String, Codable, CaseIterable, Equatable, Sendable {
  case done
  case blocked
  case needsUser = "needs_user"
}

package struct FinishTaskInput: Codable, Equatable, Sendable {
  package let status: FinishTaskStatus
  package let summary: String

  private enum CodingKeys: String, CodingKey {
    case status
    case summary
  }

  package init(status: FinishTaskStatus, summary: String) {
    self.status = status
    self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    status = try container.decode(FinishTaskStatus.self, forKey: .status)
    summary = try container.decode(String.self, forKey: .summary)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(status, forKey: .status)
    try container.encode(summary, forKey: .summary)
  }
}

package enum FinishTaskResult: Codable, Equatable, Sendable {
  case success
  case failed(reason: ToolFailureReason)
}

nonisolated extension FinishTaskResult {
  var preview: ToolResultPreview {
    switch self {
    case .success:
      ToolResultPreview(text: "Task completion accepted.")
    case .failed(let reason):
      ToolResultPreview(status: reason.previewStatus, text: reason.message)
    }
  }
}

nonisolated extension ToolDefinition {
  package static let finishTask = ToolDefinition(
    name: .finishTask,
    description:
      "Finish the current task. Call this tool alone. The summary is shown directly to the user as the final response.",
    parameters: [
      ToolParameterDefinition(
        name: "status",
        description:
          "Completion status: done when complete, blocked when recovery is exhausted, or needs_user when a new user turn is required.",
        isRequired: true,
        valueType: .string,
        enumValues: FinishTaskStatus.allCases.map(\.rawValue)
      ),
      ToolParameterDefinition(
        name: "summary",
        description: "Complete, non-empty user-visible final response.",
        isRequired: true,
        valueType: .string
      ),
    ],
    capabilities: [],
    riskLevel: .low
  )
}

private enum FinishTaskToolArguments {
  static func decode(_ arguments: ToolCallArguments) throws -> FinishTaskInput {
    guard let statusArgument = arguments["status"] else {
      throw InvalidToolCallReason.missingRequiredArgument("status")
    }
    guard case .string(let rawStatus) = statusArgument,
      let status = FinishTaskStatus(rawValue: rawStatus)
    else {
      throw InvalidToolCallReason.invalidArgumentType(
        name: "status",
        expected: "done, blocked, or needs_user"
      )
    }

    guard let summaryArgument = arguments["summary"] else {
      throw InvalidToolCallReason.missingRequiredArgument("summary")
    }
    guard case .string(let summary) = summaryArgument else {
      throw InvalidToolCallReason.invalidArgumentType(
        name: "summary",
        expected: "a non-empty string"
      )
    }

    let input = FinishTaskInput(status: status, summary: summary)
    try validate(input)
    return input
  }

  static func validate(_ input: FinishTaskInput) throws {
    try ToolArgumentValidation.requireNonEmptyString(
      input.summary,
      name: "summary",
      expected: "a non-empty string"
    )
  }
}

struct FinishTaskToolExecutor: TypedToolExecutor {
  static let codec = ToolCodec<FinishTaskInput>(
    definition: ToolDefinition.finishTask,
    decodeArguments: FinishTaskToolArguments.decode,
    makePayload: ToolCallPayload.finishTask,
    extractInput: { payload in
      guard case .finishTask(let input) = payload else {
        throw ToolInputDecodingError.payloadMismatch(
          expected: ToolDefinition.finishTask.name.rawValue,
          actual: payload.toolName.rawValue
        )
      }
      return input
    }
  )

  func evaluatePermission(
    _ input: FinishTaskInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    _ = input
    _ = context
    return ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Finishing the current task is allowed.",
      riskLevel: .low
    )
  }

  func run(_ input: FinishTaskInput, context: ToolContext) async -> ToolResultPayload {
    _ = context
    do {
      try FinishTaskToolArguments.validate(input)
      return .finishTask(.success)
    } catch let reason as InvalidToolCallReason {
      return .finishTask(.failed(reason: .invalidArguments(reason)))
    } catch {
      return .finishTask(.failed(reason: .executionError(error.localizedDescription)))
    }
  }
}
