import Foundation
import MLXLMCommon
import SumikaCore

nonisolated enum GemmaNativeToolSchema {
  nonisolated static func toolSpecs(from toolContext: ChatRuntimeToolContext?) -> [ToolSpec]? {
    guard toolContext?.strategy == .nativeGemma4 else {
      return nil
    }
    let tools = toolContext?.registry.tools ?? []
    guard !tools.isEmpty else {
      return nil
    }
    return tools.map(toolSpec(for:))
  }

  nonisolated private static func toolSpec(for definition: ToolDefinition) -> ToolSpec {
    [
      "type": "function",
      "function": [
        "name": definition.name.rawValue,
        "description": definition.description,
        "parameters": jsonSchemaObject(for: definition.parameters),
      ] as [String: any Sendable],
    ] as ToolSpec
  }

  nonisolated private static func jsonSchemaObject(
    for parameters: [ToolParameterDefinition]
  ) -> [String: any Sendable] {
    var properties: [String: any Sendable] = [:]
    var required: [String] = []

    for parameter in parameters {
      properties[parameter.name] = jsonSchemaProperty(for: parameter)
      if parameter.isRequired {
        required.append(parameter.name)
      }
    }

    return [
      "type": "object",
      "properties": properties,
      "required": required,
      "additionalProperties": false,
    ] as [String: any Sendable]
  }

  nonisolated private static func jsonSchemaProperty(
    for parameter: ToolParameterDefinition
  ) -> [String: any Sendable] {
    var schema: [String: any Sendable] = [
      "type": parameter.valueType.rawValue,
      "description": parameter.description,
    ]
    if let enumValues = parameter.enumValues {
      schema["enum"] = enumValues
    }
    if let defaultValue = parameter.defaultValue {
      schema["default"] = sendableValue(from: defaultValue)
    }
    if let minimum = parameter.minimum {
      schema["minimum"] = minimum
    }
    if let maximum = parameter.maximum {
      schema["maximum"] = maximum
    }
    if let arrayItems = parameter.arrayItems {
      schema["items"] = jsonSchemaObjectValue(for: arrayItems)
    }
    return schema
  }

  nonisolated private static func jsonSchemaObjectValue(
    for object: ToolJSONSchemaObject
  ) -> [String: any Sendable] {
    var properties: [String: any Sendable] = [:]
    for (name, property) in object.properties {
      properties[name] = jsonSchemaPropertyValue(for: property)
    }

    return [
      "type": object.type,
      "properties": properties,
      "required": object.required,
      "additionalProperties": object.additionalProperties,
    ] as [String: any Sendable]
  }

  nonisolated private static func jsonSchemaPropertyValue(
    for property: ToolJSONSchemaProperty
  ) -> [String: any Sendable] {
    var schema: [String: any Sendable] = [
      "type": property.type.rawValue,
      "description": property.description,
    ]
    if let enumValues = property.enumValues {
      schema["enum"] = enumValues
    }
    if let defaultValue = property.defaultValue {
      schema["default"] = sendableValue(from: defaultValue)
    }
    if let minimum = property.minimum {
      schema["minimum"] = minimum
    }
    if let maximum = property.maximum {
      schema["maximum"] = maximum
    }
    if let arrayItems = property.arrayItems {
      schema["items"] = jsonSchemaObjectValue(for: arrayItems)
    }
    return schema
  }

  nonisolated private static func sendableValue(
    from value: ToolArgumentValue
  ) -> any Sendable {
    switch value {
    case .string(let string):
      return string
    case .number(let number):
      return number
    case .bool(let bool):
      return bool
    case .array(let array):
      return array.map(sendableValue(from:))
    case .object(let object):
      return object.mapValues(sendableValue(from:))
    case .null:
      return NSNull()
    }
  }

  nonisolated static func chatRuntimeToolCall(from toolCall: MLXLMCommon.ToolCall)
    -> ChatRuntimeToolCall
  {
    var usedIDs = Set<UUID>()
    return chatRuntimeToolCall(from: toolCall, usedIDs: &usedIDs)
  }

  nonisolated static func chatRuntimeToolCall(
    from toolCall: MLXLMCommon.ToolCall,
    usedIDs: inout Set<UUID>
  ) -> ChatRuntimeToolCall {
    ChatRuntimeToolCall(
      id: RuntimeToolCallID.normalizedString(from: toolCall.id, usedIDs: &usedIDs),
      name: toolCall.function.name,
      arguments: toolCall.function.arguments.mapValues(toolArgumentValue(from:))
    )
  }

  nonisolated private static func toolArgumentValue(from value: JSONValue) -> ToolArgumentValue {
    switch value {
    case .null:
      return .null
    case .bool(let bool):
      return .bool(bool)
    case .int(let int):
      return .number(Double(int))
    case .double(let double):
      return .number(double)
    case .string(let string):
      return .string(string)
    case .array(let array):
      return .array(array.map(toolArgumentValue(from:)))
    case .object(let object):
      return .object(object.mapValues(toolArgumentValue(from:)))
    }
  }

}
