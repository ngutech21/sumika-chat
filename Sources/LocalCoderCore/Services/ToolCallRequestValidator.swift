import Foundation

public struct ToolCallRequestValidator: Sendable {
  public init() {}

  public func validate(
    _ rawRequest: RawToolCallRequest,
    registry: ToolRegistry
  ) -> ToolCallRequest {
    let rawRequest = normalizedTodoWriteRequest(rawRequest)

    guard let definition = ToolDefinition.builtInDefinition(for: rawRequest.toolName) else {
      return invalidRequest(
        rawRequest,
        reason: .unknownToolName(rawRequest.toolName.rawValue)
      )
    }

    guard registry.definition(for: rawRequest.toolName) != nil else {
      return invalidRequest(
        rawRequest,
        reason: .unavailableToolName(rawRequest.toolName.rawValue)
      )
    }

    if let argumentError = validateArgumentNames(rawRequest.arguments, definition: definition) {
      return invalidRequest(rawRequest, reason: argumentError)
    }

    do {
      let payload = try payload(for: rawRequest)
      return ToolCallRequest.validated(raw: rawRequest, payload: payload)
    } catch let error as InvalidToolCallReason {
      return invalidRequest(rawRequest, reason: error)
    } catch {
      return invalidRequest(
        rawRequest,
        reason: invalidReason(from: error)
      )
    }
  }

  private func payload(for rawRequest: RawToolCallRequest) throws -> ToolCallPayload {
    switch rawRequest.toolName {
    case .readFile:
      let input = try decode(ReadFileInput.self, from: rawRequest.arguments)
      try validatePath(input.path)
      return .readFile(input)
    case .showFile:
      let input = try decode(ReadFileInput.self, from: rawRequest.arguments)
      try validatePath(input.path)
      return .showFile(input)
    case .listFiles:
      let input = try decode(ListFilesInput.self, from: rawRequest.arguments)
      try input.path.map(validatePath)
      return .listFiles(input)
    case .globFiles:
      let input = try decode(GlobFilesInput.self, from: rawRequest.arguments)
      try input.path.map(validatePath)
      return .globFiles(input)
    case .searchFiles:
      let input = try decode(SearchFilesInput.self, from: rawRequest.arguments)
      try input.path.map(validatePath)
      return .searchFiles(input)
    case .workspaceDiff:
      let input = try decode(WorkspaceDiffInput.self, from: rawRequest.arguments)
      try input.path.map(validatePath)
      return .workspaceDiff(input)
    case .workspaceDiagnostics:
      let input = try decode(WorkspaceDiagnosticsInput.self, from: rawRequest.arguments)
      guard !input.outputRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw InvalidToolCallReason.invalidArgumentType(
          name: "outputRef",
          expected: "a non-empty command output ref"
        )
      }
      return .workspaceDiagnostics(input)
    case .writeFile:
      let input = try decode(WriteFileInput.self, from: rawRequest.arguments)
      try validatePath(input.path)
      return .writeFile(input)
    case .editFile:
      let input = try decode(EditFileInput.self, from: rawRequest.arguments)
      try validatePath(input.path)
      guard !input.oldText.isEmpty else {
        throw InvalidToolCallReason.emptyOldText
      }
      return .editFile(input)
    case .runCommand:
      let input = try decode(RunCommandInput.self, from: rawRequest.arguments)
      guard !input.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw InvalidToolCallReason.invalidArgumentType(
          name: "command",
          expected: "a non-empty shell command"
        )
      }
      return .runCommand(input)
    case .todoWrite:
      let input = try decode(TodoWriteInput.self, from: rawRequest.arguments)
      do {
        try TodoStateValidator().validate(input.items)
      } catch let validationError as TodoStateValidationError {
        throw InvalidToolCallReason.invalidTodoItems(validationError.localizedDescription)
      }
      return .todoWrite(input)
    case .webSearch:
      let input = try decode(WebSearchInput.self, from: rawRequest.arguments)
      guard !input.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw InvalidToolCallReason.invalidArgumentType(
          name: "query",
          expected: "a non-empty public web search query"
        )
      }
      return .webSearch(input)
    case .webFetch:
      let input = try decode(WebFetchInput.self, from: rawRequest.arguments)
      guard !input.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw InvalidToolCallReason.invalidArgumentType(
          name: "url",
          expected: "a non-empty public http or https URL"
        )
      }
      return .webFetch(input)
    default:
      throw InvalidToolCallReason.unknownToolName(rawRequest.toolName.rawValue)
    }
  }

  private func validateArgumentNames(
    _ arguments: ToolCallArguments,
    definition: ToolDefinition
  ) -> InvalidToolCallReason? {
    if definition.name == .todoWrite {
      return validateTodoWriteArgumentNames(arguments)
    }

    let knownArguments = Set(definition.parameters.map(\.name))
    let unknownArguments = Set(arguments.keys).subtracting(knownArguments)
    guard unknownArguments.isEmpty else {
      return .unknownArguments(unknownArguments.sorted())
    }

    for parameter in definition.parameters where parameter.isRequired {
      guard arguments[parameter.name] != nil else {
        return .missingRequiredArgument(parameter.name)
      }
    }

    return nil
  }

  private func validateTodoWriteArgumentNames(
    _ arguments: ToolCallArguments
  ) -> InvalidToolCallReason? {
    if arguments["items"] != nil {
      let unknownArguments = Set(arguments.keys).subtracting(["items"])
      return unknownArguments.isEmpty ? nil : .unknownArguments(unknownArguments.sorted())
    }

    if todoItemField("content", in: arguments) != nil,
      todoItemField("status", in: arguments) != nil
    {
      return nil
    }

    guard arguments["content"] != nil else {
      return .missingRequiredArgument("items")
    }
    guard arguments["status"] != nil else {
      return .missingRequiredArgument("items")
    }
    return nil
  }

  private func normalizedTodoWriteRequest(
    _ rawRequest: RawToolCallRequest
  ) -> RawToolCallRequest {
    guard rawRequest.toolName == .todoWrite,
      rawRequest.arguments["items"] == nil,
      let content = todoItemField("content", in: rawRequest.arguments),
      let status = todoItemField("status", in: rawRequest.arguments)
    else {
      return rawRequest
    }

    var normalized = rawRequest
    let id = todoItemField("id", in: rawRequest.arguments) ?? "todo-1"
    normalized.arguments = [
      "id": .string(id),
      "content": .string(content),
      "status": .string(status),
    ]
    return normalized
  }

  private func todoItemField(
    _ field: String,
    in arguments: ToolCallArguments
  ) -> String? {
    if let value = arguments[field] {
      guard value != .null else {
        return nil
      }
      return value.displayValue
    }

    let expected = normalizedTodoItemFieldName(field)
    for (name, value) in arguments where normalizedTodoItemFieldName(name) == expected {
      guard value != .null else {
        return nil
      }
      return value.displayValue
    }
    return nil
  }

  private func normalizedTodoItemFieldName(_ name: String) -> String {
    name
      .lowercased()
      .filter { $0.isLetter }
  }

  private func decode<Input: Decodable>(
    _ inputType: Input.Type,
    from arguments: ToolCallArguments
  ) throws -> Input {
    try ToolInputDecoder.decode(inputType, from: arguments)
  }

  private func validatePath(_ path: String) throws {
    guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw InvalidToolCallReason.emptyPath
    }
  }

  private func invalidRequest(
    _ rawRequest: RawToolCallRequest,
    reason: InvalidToolCallReason
  ) -> ToolCallRequest {
    ToolCallRequest.invalid(
      raw: rawRequest,
      input: InvalidToolInput(
        originalName: rawRequest.toolName.rawValue,
        rawArguments: rawRequest.arguments,
        reason: reason
      )
    )
  }

  private func invalidReason(from error: Error) -> InvalidToolCallReason {
    if let reason = error as? InvalidToolCallReason {
      return reason
    }

    if let readFileError = error as? ReadFileInputValidationError {
      switch readFileError {
      case .invalidOffset:
        return .invalidPagination("offset")
      case .invalidLimit:
        return .invalidPagination("limit")
      }
    }

    if let runCommandError = error as? RunCommandInputValidationError {
      switch runCommandError {
      case .invalidTimeout:
        return .invalidTimeout("timeoutSeconds")
      }
    }

    if let decodingError = error as? DecodingError {
      return invalidReason(from: decodingError)
    }

    if let localizedError = error as? LocalizedError,
      let description = localizedError.errorDescription
    {
      return .parserError(description)
    }

    return .parserError(error.localizedDescription)
  }

  private func invalidReason(from error: DecodingError) -> InvalidToolCallReason {
    switch error {
    case .typeMismatch(_, let context):
      return .invalidArgumentType(
        name: context.codingPath.last?.stringValue ?? "argument",
        expected: context.debugDescription
      )
    case .valueNotFound(_, let context):
      return .invalidArgumentType(
        name: context.codingPath.last?.stringValue ?? "argument",
        expected: context.debugDescription
      )
    case .keyNotFound(let key, _):
      return .missingRequiredArgument(key.stringValue)
    case .dataCorrupted(let context):
      return .parserError(context.debugDescription)
    @unknown default:
      return .parserError(error.localizedDescription)
    }
  }
}

nonisolated extension ToolDefinition {
  fileprivate static func builtInDefinition(for toolName: ToolName) -> ToolDefinition? {
    switch toolName {
    case .readFile:
      .readFile
    case .showFile:
      .showFile
    case .listFiles:
      .listFiles
    case .globFiles:
      .globFiles
    case .searchFiles:
      .searchFiles
    case .workspaceDiff:
      .workspaceDiff
    case .workspaceDiagnostics:
      .workspaceDiagnostics
    case .writeFile:
      .writeFile
    case .editFile:
      .editFile
    case .runCommand:
      .runCommand
    case .todoWrite:
      .todoWrite
    case .webSearch:
      .webSearch
    case .webFetch:
      .webFetch
    default:
      nil
    }
  }
}
