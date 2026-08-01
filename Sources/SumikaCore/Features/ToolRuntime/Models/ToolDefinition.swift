package enum ToolParameterValueType: String, Codable, Equatable, Sendable {
  case string
  case integer
  case number
  case boolean
  case array
  case object
}

package struct ToolParameterDefinition: Codable, Equatable, Sendable {
  package var name: String
  package var description: String
  package var isRequired: Bool
  package var valueType: ToolParameterValueType
  package var enumValues: [String]?
  package var defaultValue: ToolArgumentValue?
  package var minimum: Double?
  package var maximum: Double?
  package var arrayItems: ToolJSONSchemaObject?
  package var supportsHeredocPayload: Bool

  package init(
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

package enum ToolCapability: String, Codable, Equatable, Hashable, Sendable {
  case readWorkspace
  case writeWorkspace
  case runCommand
  case accessWeb
  case externalService
}

package struct ToolDefinition: Codable, Identifiable, Equatable, Sendable {
  package var id: ToolName { name }

  package var name: ToolName
  package var description: String
  package var parameters: [ToolParameterDefinition]
  /// Verbatim JSON Schema for dynamic (MCP) tools whose parameter shapes the
  /// structured `parameters` list cannot express. When set, provider adapters
  /// must pass this schema through instead of deriving one from `parameters`,
  /// and argument-name validation is skipped because the schema owner (the
  /// external server) validates calls itself.
  package var rawParametersSchema: ToolArgumentValue?
  package var capabilities: Set<ToolCapability>
  package var riskLevel: ToolRiskLevel

  package init(
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

package struct ToolJSONSchemaObject: Codable, Equatable, Sendable {
  package var type: String
  package var properties: [String: ToolJSONSchemaProperty]
  package var required: [String]
  package var additionalProperties: Bool

  package init(
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
}

package struct ToolJSONSchemaProperty: Codable, Equatable, Sendable {
  package var type: ToolParameterValueType
  package var description: String
  package var enumValues: [String]?
  package var defaultValue: ToolArgumentValue?
  package var minimum: Double?
  package var maximum: Double?
  package var arrayItems: ToolJSONSchemaObject?

  private enum CodingKeys: String, CodingKey {
    case type
    case description
    case enumValues = "enum"
    case defaultValue = "default"
    case minimum
    case maximum
    case arrayItems = "items"
  }

  package init(
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

package struct ToolRegistry: Equatable, Sendable {
  package var tools: [ToolDefinition]

  package init(tools: [ToolDefinition]) {
    self.tools = tools
  }

  package func definition(for name: ToolName) -> ToolDefinition? {
    tools.first { $0.name == name }
  }
}
