import Foundation

public struct ToolCallRequestValidator: Sendable {
  public init() {}

  public func validate(
    _ rawRequest: RawToolCallRequest,
    registry: ToolRegistry,
    dynamicCodecs: [ToolName: AnyToolCodec] = [:]
  ) -> ToolCallRequest {
    // Built-in codecs resolve first so a built-in tool outside the active
    // registry still reports `unavailable` instead of `unknown`. Dynamic
    // codecs exist only for tools in the active registry.
    let builtInCodec = ToolCodecCatalog.builtInCodec(for: rawRequest.toolName)
    let dynamicCodec = builtInCodec == nil ? dynamicCodecs[rawRequest.toolName] : nil
    guard let codec = builtInCodec ?? dynamicCodec else {
      return invalidRequest(
        rawRequest,
        reason: .unknownToolName(rawRequest.toolName.rawValue)
      )
    }

    let definition = codec.definition
    guard registry.definition(for: rawRequest.toolName) != nil else {
      return invalidRequest(
        rawRequest,
        reason: .unavailableToolName(rawRequest.toolName.rawValue)
      )
    }

    if let argumentError = validateArgumentNames(
      rawRequest.arguments,
      definition: definition,
      isDynamic: dynamicCodec != nil
    ) {
      return invalidRequest(rawRequest, reason: argumentError)
    }

    do {
      let payload = try codec.payload(from: rawRequest.arguments)
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

  private func validateArgumentNames(
    _ arguments: ToolCallArguments,
    definition: ToolDefinition,
    isDynamic: Bool
  ) -> InvalidToolCallReason? {
    if isDynamic {
      // Dynamic tools carry an opaque schema the external server owns and
      // validates itself. Only enforce required parameters the schema states
      // explicitly; unknown-argument rejection needs a full property list the
      // structured definition does not have.
      guard let rawSchema = definition.rawParametersSchema else {
        return nil
      }
      for requiredName in Self.requiredParameterNames(fromRawSchema: rawSchema) {
        guard arguments[requiredName] != nil else {
          return .missingRequiredArgument(requiredName)
        }
      }
      return nil
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

  private static func requiredParameterNames(
    fromRawSchema schema: ToolArgumentValue
  ) -> [String] {
    guard
      case .object(let fields) = schema,
      case .array(let required)? = fields["required"]
    else {
      return []
    }
    return required.compactMap { value in
      if case .string(let name) = value {
        return name
      }
      return nil
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
