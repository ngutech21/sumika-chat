public enum ToolParameterValueType: String, Codable, Equatable, Sendable {
  case string
  case integer
  case number
  case boolean
  case array
  case object
}

public struct ToolParameterDefinition: Codable, Equatable, Sendable {
  public var name: String
  public var description: String
  public var isRequired: Bool
  public var valueType: ToolParameterValueType
  public var enumValues: [String]?
  public var defaultValue: ToolArgumentValue?
  public var minimum: Double?
  public var maximum: Double?
  public var arrayItems: ToolJSONSchemaObject?
  public var supportsHeredocPayload: Bool

  public init(
    name: String,
    description: String,
    isRequired: Bool,
    valueType: ToolParameterValueType = .string,
    enumValues: [String]? = nil,
    defaultValue: ToolArgumentValue? = nil,
    minimum: Double? = nil,
    maximum: Double? = nil,
    arrayItems: ToolJSONSchemaObject? = nil,
    supportsHeredocPayload: Bool = false
  ) {
    self.name = name
    self.description = description
    self.isRequired = isRequired
    self.valueType = valueType
    self.enumValues = enumValues
    self.defaultValue = defaultValue
    self.minimum = minimum
    self.maximum = maximum
    self.arrayItems = arrayItems
    self.supportsHeredocPayload = supportsHeredocPayload
  }
}

public enum ToolCapability: String, Codable, Equatable, Hashable, Sendable {
  case readWorkspace
  case writeWorkspace
  case runCommand
  case accessWeb
  case externalService
}

public struct ToolDefinition: Codable, Identifiable, Equatable, Sendable {
  public var id: ToolName { name }

  public var name: ToolName
  public var description: String
  public var parameters: [ToolParameterDefinition]
  /// Verbatim JSON Schema for dynamic (MCP) tools whose parameter shapes the
  /// structured `parameters` list cannot express. When set, provider adapters
  /// must pass this schema through instead of deriving one from `parameters`,
  /// and argument-name validation is skipped because the schema owner (the
  /// external server) validates calls itself.
  public var rawParametersSchema: ToolArgumentValue?
  public var capabilities: Set<ToolCapability>
  public var riskLevel: ToolRiskLevel

  public init(
    name: ToolName,
    description: String,
    parameters: [ToolParameterDefinition],
    rawParametersSchema: ToolArgumentValue? = nil,
    capabilities: Set<ToolCapability> = [],
    riskLevel: ToolRiskLevel = .low
  ) {
    precondition(
      Set(parameters.map(\.name)).count == parameters.count,
      "ToolDefinition parameter names must be unique."
    )
    self.name = name
    self.description = description
    self.parameters = parameters
    self.rawParametersSchema = rawParametersSchema
    self.capabilities = capabilities
    self.riskLevel = riskLevel
  }
}

public struct FunctionToolSchema: Codable, Equatable, Sendable {
  public var type: String
  public var name: String
  public var description: String
  public var parameters: ToolJSONSchemaObject
  public var strict: Bool?

  public init(
    type: String = "function",
    name: String,
    description: String,
    parameters: ToolJSONSchemaObject,
    strict: Bool? = nil
  ) {
    self.type = type
    self.name = name
    self.description = description
    self.parameters = parameters
    self.strict = strict
  }
}

public struct ToolJSONSchemaObject: Codable, Equatable, Sendable {
  public var type: String
  public var properties: [String: ToolJSONSchemaProperty]
  public var required: [String]
  public var additionalProperties: Bool

  public init(
    type: String = "object",
    properties: [String: ToolJSONSchemaProperty],
    required: [String],
    additionalProperties: Bool = false
  ) {
    self.type = type
    self.properties = properties
    self.required = required
    self.additionalProperties = additionalProperties
  }

  public init(parameters: [ToolParameterDefinition]) {
    var properties: [String: ToolJSONSchemaProperty] = [:]
    var required: [String] = []

    for parameter in parameters {
      guard properties[parameter.name] == nil else {
        continue
      }

      properties[parameter.name] = ToolJSONSchemaProperty(
        type: parameter.valueType,
        description: parameter.description,
        enumValues: parameter.enumValues,
        defaultValue: parameter.defaultValue,
        minimum: parameter.minimum,
        maximum: parameter.maximum,
        arrayItems: parameter.arrayItems
      )

      if parameter.isRequired {
        required.append(parameter.name)
      }
    }

    self.init(properties: properties, required: required)
  }
}

public struct ToolJSONSchemaProperty: Codable, Equatable, Sendable {
  public var type: ToolParameterValueType
  public var description: String
  public var enumValues: [String]?
  public var defaultValue: ToolArgumentValue?
  public var minimum: Double?
  public var maximum: Double?
  public var arrayItems: ToolJSONSchemaObject?

  private enum CodingKeys: String, CodingKey {
    case type
    case description
    case enumValues = "enum"
    case defaultValue = "default"
    case minimum
    case maximum
    case arrayItems = "items"
  }

  public init(
    type: ToolParameterValueType,
    description: String,
    enumValues: [String]? = nil,
    defaultValue: ToolArgumentValue? = nil,
    minimum: Double? = nil,
    maximum: Double? = nil,
    arrayItems: ToolJSONSchemaObject? = nil
  ) {
    self.type = type
    self.description = description
    self.enumValues = enumValues
    self.defaultValue = defaultValue
    self.minimum = minimum
    self.maximum = maximum
    self.arrayItems = arrayItems
  }
}

public struct ToolRegistry: Equatable, Sendable {
  public var tools: [ToolDefinition]

  public init(tools: [ToolDefinition]) {
    self.tools = tools
  }

  public func definition(for name: ToolName) -> ToolDefinition? {
    tools.first { $0.name == name }
  }
}

nonisolated extension ToolDefinition {
  public var functionSchema: FunctionToolSchema {
    FunctionToolSchema(
      name: name.rawValue,
      description: description,
      parameters: ToolJSONSchemaObject(parameters: parameters)
    )
  }
}
