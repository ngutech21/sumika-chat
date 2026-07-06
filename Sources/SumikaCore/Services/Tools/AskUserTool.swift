import Foundation

public struct AskUserInput: Codable, Equatable, Sendable {
  public let question: String
  public let options: [String]

  public init(question: String, options: [String]) {
    self.question = question
    self.options = options
  }
}

public struct AskUserResult: Codable, Equatable, Sendable {
  public let answer: String

  public init(answer: String) {
    self.answer = answer
  }
}

nonisolated extension AskUserResult {
  var preview: ToolResultPreview {
    ToolResultPreview(text: "User answered: \(answer)")
  }
}

nonisolated extension ToolDefinition {
  public static let askUser = ToolDefinition(
    name: .askUser,
    description:
      "Ask the user one blocking clarification question with predefined answer options. Use only when workspace inspection cannot resolve the ambiguity and choosing a default would risk wrong changes.",
    parameters: [
      ToolParameterDefinition(
        name: "question",
        description: "One concise question for the user. Do not include the answer choices here.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "option1",
        description: "First answer option. Plain short string; no numbering or markdown.",
        isRequired: true,
        valueType: .string
      ),
      ToolParameterDefinition(
        name: "option2",
        description: "Second answer option. Plain short string; no numbering or markdown.",
        isRequired: true,
        valueType: .string
      ),
      ToolParameterDefinition(
        name: "option3",
        description: "Optional third answer option. Plain short string.",
        isRequired: false,
        valueType: .string
      ),
      ToolParameterDefinition(
        name: "option4",
        description: "Optional fourth answer option. Plain short string.",
        isRequired: false,
        valueType: .string
      ),
    ],
    capabilities: [],
    riskLevel: .low
  )
}

private enum AskUserToolArguments {
  static func decode(_ arguments: ToolCallArguments) throws -> AskUserInput {
    let question = try stringArgument("question", from: arguments)
    let options = try optionFields(from: arguments)
      .compactMap(\.1)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    let input = AskUserInput(question: question, options: options)
    try validate(input, optionFields: optionFields(from: arguments))
    return input
  }

  private static func validate(
    _ input: AskUserInput,
    optionFields: [(String, String?)]
  ) throws {
    try ToolArgumentValidation.requireNonEmptyString(
      input.question,
      name: "question",
      expected: "a non-empty blocking question"
    )

    let missingRequiredOption = optionFields.prefix(2).first {
      ($0.1 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if let missingRequiredOption {
      throw InvalidToolCallReason.invalidArgumentType(
        name: missingRequiredOption.0,
        expected: "a non-empty answer option string"
      )
    }

    let optionalOptionIsEmpty = optionFields.dropFirst(2).first {
      guard let value = $0.1 else {
        return false
      }
      return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if let optionalOptionIsEmpty {
      throw InvalidToolCallReason.invalidArgumentType(
        name: optionalOptionIsEmpty.0,
        expected: "omit it or provide a non-empty answer option string"
      )
    }

    var uniqueOptions = Set<String>()
    let duplicateOption = input.options.first { option in
      let normalizedOption = option.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      return !uniqueOptions.insert(normalizedOption).inserted
    }
    if duplicateOption != nil {
      throw InvalidToolCallReason.invalidArgumentType(
        name: "options",
        expected: "unique answer option strings"
      )
    }
  }

  private static func optionFields(
    from arguments: ToolCallArguments
  ) throws -> [(String, String?)] {
    [
      ("option1", try stringArgumentIfPresent("option1", from: arguments)),
      ("option2", try stringArgumentIfPresent("option2", from: arguments)),
      ("option3", try stringArgumentIfPresent("option3", from: arguments)),
      ("option4", try stringArgumentIfPresent("option4", from: arguments)),
    ]
  }

  private static func stringArgument(
    _ name: String,
    from arguments: ToolCallArguments
  ) throws -> String {
    guard let value = try stringArgumentIfPresent(name, from: arguments) else {
      throw InvalidToolCallReason.invalidArgumentType(
        name: name,
        expected: "a string"
      )
    }
    return value
  }

  private static func stringArgumentIfPresent(
    _ name: String,
    from arguments: ToolCallArguments
  ) throws -> String? {
    guard let argument = arguments[name] else {
      return nil
    }
    guard case .string(let value) = argument else {
      throw InvalidToolCallReason.invalidArgumentType(
        name: name,
        expected: "a string"
      )
    }
    return value
  }
}

public struct AskUserToolExecutor: TypedToolExecutor {
  public static let codec = ToolCodec<AskUserInput>(
    definition: ToolDefinition.askUser,
    decodeArguments: AskUserToolArguments.decode,
    makePayload: ToolCallPayload.askUser,
    extractInput: { payload in
      guard case .askUser(let input) = payload else {
        throw ToolInputDecodingError.payloadMismatch(
          expected: ToolDefinition.askUser.name.rawValue,
          actual: payload.toolName.rawValue
        )
      }
      return input
    }
  )

  public init() {}

  public func evaluatePermission(
    _ input: AskUserInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    _ = input
    _ = context
    return ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Asking the user a blocking clarification is allowed.",
      riskLevel: .low
    )
  }

  public func run(_ input: AskUserInput, context: ToolContext) async -> ToolResultPayload {
    _ = input
    _ = context
    return .failure(
      ToolFailure(
        toolName: .askUser,
        path: nil,
        reason: .executionError("ask_user must be answered by the user before it completes.")
      )
    )
  }
}
