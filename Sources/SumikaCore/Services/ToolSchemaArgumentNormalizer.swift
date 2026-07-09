import Foundation

enum ToolSchemaArgumentNormalizer {
  static func normalized(
    _ arguments: ToolCallArguments,
    using schema: ToolArgumentValue
  ) -> ToolCallArguments {
    guard
      case .object(let fields) = schema,
      case .object(let properties)? = fields["properties"]
    else {
      return arguments
    }

    var normalizedArguments = arguments
    for (name, propertySchema) in properties {
      guard let value = arguments[name] else {
        continue
      }
      normalizedArguments[name] = normalized(value, using: propertySchema)
    }
    return normalizedArguments
  }

  private static func normalized(
    _ value: ToolArgumentValue,
    using schema: ToolArgumentValue
  ) -> ToolArgumentValue {
    guard case .object(let fields) = schema else {
      return value
    }

    if value == .null {
      return value
    }

    switch typeName(in: fields) {
    case "integer":
      return normalizedInteger(value) ?? value
    case "number":
      return normalizedNumber(value) ?? value
    case "boolean":
      return normalizedBoolean(value) ?? value
    case "array":
      return normalizedArray(value, itemSchema: fields["items"])
    case "object":
      return normalizedObject(value, fields: fields)
    default:
      return value
    }
  }

  private static func typeName(in fields: [String: ToolArgumentValue]) -> String? {
    guard case .string(let type)? = fields["type"] else {
      return nil
    }
    return type
  }

  private static func normalizedInteger(_ value: ToolArgumentValue) -> ToolArgumentValue? {
    guard case .string(let string) = value else {
      return nil
    }
    guard let number = finiteNumber(from: string), number.rounded(.towardZero) == number else {
      return nil
    }
    return .number(number)
  }

  private static func normalizedNumber(_ value: ToolArgumentValue) -> ToolArgumentValue? {
    guard case .string(let string) = value, let number = finiteNumber(from: string) else {
      return nil
    }
    return .number(number)
  }

  private static func finiteNumber(from string: String) -> Double? {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let number = Double(trimmed), number.isFinite else {
      return nil
    }
    return number
  }

  private static func normalizedBoolean(_ value: ToolArgumentValue) -> ToolArgumentValue? {
    guard case .string(let string) = value else {
      return nil
    }
    switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "true":
      return .bool(true)
    case "false":
      return .bool(false)
    default:
      return nil
    }
  }

  private static func normalizedArray(
    _ value: ToolArgumentValue,
    itemSchema: ToolArgumentValue?
  ) -> ToolArgumentValue {
    guard case .array(let values) = value, let itemSchema else {
      return value
    }
    return .array(values.map { normalized($0, using: itemSchema) })
  }

  private static func normalizedObject(
    _ value: ToolArgumentValue,
    fields: [String: ToolArgumentValue]
  ) -> ToolArgumentValue {
    guard
      case .object(let object) = value,
      case .object(let properties)? = fields["properties"]
    else {
      return value
    }

    var normalizedObject = object
    for (name, propertySchema) in properties {
      guard let nestedValue = object[name] else {
        continue
      }
      normalizedObject[name] = normalized(nestedValue, using: propertySchema)
    }
    return .object(normalizedObject)
  }
}
