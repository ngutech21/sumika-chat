import Foundation

struct ToolCallRequestValidator: Sendable {
  func validate(
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

    let knownArgumentNames = knownArgumentNames(
      definition: definition,
      isDynamic: dynamicCodec != nil
    )
    var normalizedRequest = rawRequest
    normalizedRequest.arguments = normalizedArgumentNames(
      rawRequest.arguments,
      knownArgumentNames: knownArgumentNames
    )

    if let argumentError = validateArgumentNames(
      normalizedRequest.arguments,
      definition: definition,
      isDynamic: dynamicCodec != nil,
      knownArgumentNames: knownArgumentNames
    ) {
      return invalidRequest(rawRequest, reason: argumentError)
    }

    normalizedRequest = normalizedDynamicRequest(
      normalizedRequest,
      definition: definition,
      isDynamic: dynamicCodec != nil
    )

    do {
      let payload = try codec.payload(from: normalizedRequest.arguments)
      return ToolCallRequest.validated(raw: normalizedRequest, payload: payload)
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
    isDynamic: Bool,
    knownArgumentNames: Set<String>?
  ) -> InvalidToolCallReason? {
    if let knownArgumentNames {
      let unknownArguments = Set(arguments.keys).subtracting(knownArgumentNames)
      guard unknownArguments.isEmpty else {
        return .unknownArguments(unknownArguments.sorted())
      }
    }

    if isDynamic {
      // Dynamic tools carry an opaque schema the external server owns and
      // validates itself. Enforce required parameters the schema states
      // explicitly. Name repair and unknown-argument rejection apply only when
      // the schema explicitly closes the finite top-level property list.
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

    for parameter in definition.parameters where parameter.isRequired {
      guard arguments[parameter.name] != nil else {
        return .missingRequiredArgument(parameter.name)
      }
    }

    return nil
  }

  private func knownArgumentNames(
    definition: ToolDefinition,
    isDynamic: Bool
  ) -> Set<String>? {
    guard isDynamic else {
      return Set(definition.parameters.map(\.name))
    }
    guard
      let rawSchema = definition.rawParametersSchema,
      case .object(let fields) = rawSchema,
      fields["additionalProperties"] == .bool(false),
      case .object(let properties)? = fields["properties"],
      fields["patternProperties"] == nil,
      fields["$ref"] == nil,
      fields["allOf"] == nil,
      fields["anyOf"] == nil,
      fields["oneOf"] == nil
    else {
      return nil
    }
    return Set(properties.keys)
  }

  private func normalizedArgumentNames(
    _ arguments: ToolCallArguments,
    knownArgumentNames: Set<String>?
  ) -> ToolCallArguments {
    guard let knownArgumentNames else {
      return arguments
    }

    let resolver = ToolIdentifierResolver()
    let resolvedNames = arguments.keys.reduce(into: [String: String]()) { result, originalName in
      let resolution = resolver.resolve(originalName, candidates: knownArgumentNames)
      if let canonicalName = resolution.canonicalName {
        result[originalName] = canonicalName
      }
    }
    let originalNamesByCanonical = Dictionary(grouping: resolvedNames.keys) { originalName in
      resolvedNames[originalName] ?? originalName
    }

    var normalizedArguments = arguments
    for originalName in arguments.keys.sorted() {
      guard
        let canonicalName = resolvedNames[originalName],
        canonicalName != originalName,
        originalNamesByCanonical[canonicalName]?.count == 1,
        let value = normalizedArguments.removeValue(forKey: originalName)
      else {
        continue
      }
      normalizedArguments[canonicalName] = value
    }
    return normalizedArguments
  }

  private func normalizedDynamicRequest(
    _ rawRequest: RawToolCallRequest,
    definition: ToolDefinition,
    isDynamic: Bool
  ) -> RawToolCallRequest {
    guard isDynamic, let rawSchema = definition.rawParametersSchema else {
      return rawRequest
    }
    var request = rawRequest
    request.arguments = ToolSchemaArgumentNormalizer.normalized(
      rawRequest.arguments,
      using: rawSchema
    )
    return request
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
