import Foundation

package struct TodoWriteInput: Codable, Equatable, Sendable {
  package let items: [TodoItem]

  private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
      self.stringValue = stringValue
      intValue = nil
    }

    init?(intValue: Int) {
      stringValue = String(intValue)
      self.intValue = intValue
    }
  }

  package init(items: [TodoItem]) {
    self.items = items
  }

  package init(from decoder: Decoder) throws {
    guard let numberedItems = try Self.decodeNumberedItems(from: decoder) else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "todo_write must use item1/item2 numbered fields."
        ))
    }
    items = numberedItems
  }

  package func encode(to encoder: Encoder) throws {
    try Self.validateItems(items)

    var container = encoder.container(keyedBy: DynamicCodingKey.self)
    for (offset, item) in items.enumerated() {
      let index = offset + 1
      try container.encode(item.content, forKey: Self.key("item\(index)"))
      try container.encode(Self.doneValue(for: item), forKey: Self.key("done\(index)"))
    }
  }

  package static func validateItems(_ items: [TodoItem]) throws {
    try TodoStateValidator().validate(items)

    for item in items {
      switch item.status {
      case .pending, .completed:
        continue
      case .inProgress, .blocked:
        throw TodoStateValidationError.unsupportedTodoWriteStatus(
          id: item.id,
          status: item.status
        )
      }
    }
  }

  private static func doneValue(for item: TodoItem) throws -> Bool {
    switch item.status {
    case .pending:
      false
    case .completed:
      true
    case .inProgress, .blocked:
      throw TodoStateValidationError.unsupportedTodoWriteStatus(
        id: item.id,
        status: item.status
      )
    }
  }

  private static func decodeNumberedItems(from decoder: Decoder) throws -> [TodoItem]? {
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    let hasNumberedItem = (1...6).contains { index in
      container.contains(key("item\(index)"))
    }
    guard hasNumberedItem else {
      return nil
    }

    var decodedItems: [TodoItem] = []
    for index in 1...6 {
      let itemKey = key("item\(index)")
      guard container.contains(itemKey) else {
        continue
      }

      let content = try container.decode(String.self, forKey: itemKey)
      let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmedContent.isEmpty && index > 2 {
        continue
      }

      let done = try decodeDoneValue(from: container, index: index)
      decodedItems.append(
        TodoItem(
          id: String(index),
          content: trimmedContent,
          status: done ? .completed : .pending
        ))
    }
    return decodedItems
  }

  private static func decodeDoneValue(
    from container: KeyedDecodingContainer<DynamicCodingKey>,
    index: Int
  ) throws -> Bool {
    let doneKey = key("done\(index)")
    guard container.contains(doneKey) else {
      return false
    }

    if let value = try? container.decode(Bool.self, forKey: doneKey) {
      return value
    }
    if let rawValue = try? container.decode(String.self, forKey: doneKey) {
      switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "true":
        return true
      case "false":
        return false
      default:
        break
      }
    }

    throw DecodingError.dataCorruptedError(
      forKey: doneKey,
      in: container,
      debugDescription: "done\(index) must be true or false."
    )
  }

  private static func key(_ name: String) -> DynamicCodingKey {
    guard let key = DynamicCodingKey(stringValue: name) else {
      preconditionFailure("Invalid todo_write key: \(name)")
    }
    return key
  }
}

package enum TodoWriteResult: Codable, Equatable, Sendable {
  case success
  case failed(reason: ToolFailureReason)
}

nonisolated extension TodoWriteResult {
  var preview: ToolResultPreview {
    switch self {
    case .success:
      ToolResultPreview(text: "Plan updated.")
    case .failed(let reason):
      ToolResultPreview(status: reason.previewStatus, text: reason.message)
    }
  }
}

nonisolated extension ToolDefinition {
  package static let todoWrite = ToolDefinition(
    name: .todoWrite,
    description:
      "Create or update the Agent's compact todo plan for multi-step work. Send the full current plan in one call, not one call per item.",
    parameters: (1...6).map { index in
      ToolParameterDefinition(
        name: "item\(index)",
        description:
          index <= 2
          ? "Todo item \(index) content. Required; 120 characters or fewer."
          : "Optional todo item \(index) content. Omit when unused; 120 characters or fewer.",
        isRequired: index <= 2
      )
    }
      + (1...6).map { index in
        ToolParameterDefinition(
          name: "done\(index)",
          description: "Whether item\(index) is already done. Defaults to false.",
          isRequired: false,
          valueType: .boolean,
          defaultValue: .bool(false)
        )
      },
    capabilities: [],
    riskLevel: .low
  )
}

extension TodoWriteInput {
  static func decodeToolArguments(_ arguments: ToolCallArguments) throws -> TodoWriteInput {
    let input = try ToolInputDecoder.decode(TodoWriteInput.self, from: arguments)
    do {
      try validateItems(input.items)
      return input
    } catch let validationError as TodoStateValidationError {
      throw InvalidToolCallReason.invalidTodoItems(validationError.localizedDescription)
    }
  }
}

struct TodoWriteToolExecutor: TypedToolExecutor {
  static let codec = ToolCodec<TodoWriteInput>(
    definition: ToolDefinition.todoWrite,
    decodeArguments: TodoWriteInput.decodeToolArguments,
    makePayload: ToolCallPayload.todoWrite,
    extractInput: { payload in
      guard case .todoWrite(let input) = payload else {
        throw ToolInputDecodingError.payloadMismatch(
          expected: ToolDefinition.todoWrite.name.rawValue,
          actual: payload.toolName.rawValue
        )
      }
      return input
    }
  )

  func evaluatePermission(
    _ input: TodoWriteInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    _ = input
    _ = context
    return ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Updating Agent todo state is allowed.",
      riskLevel: .low
    )
  }

  func run(_ input: TodoWriteInput, context: ToolContext) async -> ToolResultPayload {
    _ = context
    do {
      try TodoWriteInput.validateItems(input.items)
      return .todoWrite(.success)
    } catch {
      let reason =
        if let validationError = error as? TodoStateValidationError {
          ToolFailureReason.invalidArguments(
            .invalidTodoItems(validationError.localizedDescription))
        } else {
          ToolFailureReason.executionError(error.localizedDescription)
        }
      return .todoWrite(.failed(reason: reason))
    }
  }
}
