@testable import SumikaCore

struct TestFunctionToolSchema: Codable, Equatable, Sendable {
  var type: String
  var name: String
  var description: String
  var parameters: ToolJSONSchemaObject
  var strict: Bool?

  init(
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

extension ToolJSONSchemaObject {
  init(parameters: [ToolParameterDefinition]) {
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

nonisolated extension ToolDefinition {
  var functionSchema: TestFunctionToolSchema {
    TestFunctionToolSchema(
      name: name.rawValue,
      description: description,
      parameters: ToolJSONSchemaObject(parameters: parameters)
    )
  }
}
