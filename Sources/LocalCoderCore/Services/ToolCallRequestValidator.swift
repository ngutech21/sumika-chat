import Foundation

public struct ToolCallRequestValidator: Sendable {
  public init() {}

  public func validate(
    _ rawRequest: RawToolCallRequest,
    registry: ToolRegistry
  ) -> ToolCallRequest {
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
    default:
      throw InvalidToolCallReason.unknownToolName(rawRequest.toolName.rawValue)
    }
  }

  private func validateArgumentNames(
    _ arguments: ToolCallArguments,
    definition: ToolDefinition
  ) -> InvalidToolCallReason? {
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
    case .writeFile:
      .writeFile
    case .editFile:
      .editFile
    case .runCommand:
      .runCommand
    default:
      nil
    }
  }
}
