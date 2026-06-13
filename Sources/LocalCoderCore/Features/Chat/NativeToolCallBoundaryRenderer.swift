import Foundation

public enum NativeToolCallBoundaryRenderer {
  public static func renderGemma4(_ toolCall: ChatRuntimeToolCall) -> String {
    renderGemma4(
      toolName: toolCall.name,
      arguments: toolCall.arguments
    )
  }

  public static func renderGemma4(_ toolCalls: [ChatRuntimeToolCall]) -> String {
    toolCalls.map(renderGemma4(_:)).joined(separator: "\n")
  }

  public static func renderModelContextGemma4(
    _ toolCalls: [ToolCallModelMessage]
  ) -> String {
    toolCalls.map(\.modelContextContent).joined(separator: "\n")
  }

  public static func renderModelContextGemma4(
    _ toolCalls: [ChatRuntimeToolCall],
    registry: ToolRegistry? = nil
  ) -> String {
    toolCalls.map { toolCall in
      modelContextMessage(for: toolCall, registry: registry).modelContextContent
    }
    .joined(separator: "\n")
  }

  public static func renderGemma4(
    toolName: String,
    arguments: ToolCallArguments
  ) -> String {
    let renderedArguments = arguments.keys.sorted().map { key in
      "\(key):\(renderGemma4Argument(arguments[key] ?? .null))"
    }
    .joined(separator: ",")

    return "<|tool_call>call:\(toolName){\(renderedArguments)}<tool_call|>"
  }

  private static func modelContextMessage(
    for toolCall: ChatRuntimeToolCall,
    registry: ToolRegistry?
  ) -> ToolCallModelMessage {
    let toolName = modelContextToolName(for: toolCall.name, registry: registry)
    let rawText = renderGemma4(toolName: toolName.rawValue, arguments: toolCall.arguments)
    return ToolCallModelMessage(
      callID: UUID(),
      toolName: toolName,
      arguments: toolCall.arguments.keys.sorted().map { key in
        ToolCallModelArgument(name: key, value: toolCall.arguments[key]?.displayValue ?? "")
      },
      rawText: rawText
    )
  }

  private static func modelContextToolName(
    for rawName: String,
    registry: ToolRegistry?
  ) -> ToolName {
    guard let registry else {
      return ToolName(rawValue: rawName.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    let resolution = ToolNameResolver().resolve(rawName, registry: registry)
    return resolution.canonicalToolName
      ?? ToolName(rawValue: rawName.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static func renderGemma4Argument(_ value: ToolArgumentValue) -> String {
    switch value {
    case .string(let string):
      return escapedGemma4String(string)
    case .number(let number):
      return canonicalNumber(number)
    case .bool(let bool):
      return bool ? "true" : "false"
    case .array, .object, .null:
      return escapedGemma4String(canonicalJSONValue(value))
    }
  }

  private static func escapedGemma4String(_ value: String) -> String {
    let marker = "<|\"|>"
    return "\(marker)\(jsonEscapedContent(value))\(marker)"
  }

  private static func canonicalNumber(_ number: Double) -> String {
    guard number.isFinite else {
      return "null"
    }
    if number.rounded() == number,
      number >= Double(Int64.min),
      number <= Double(Int64.max)
    {
      return String(Int64(number))
    }
    return String(number)
  }

  private static func canonicalJSONValue(_ value: ToolArgumentValue) -> String {
    switch value {
    case .string(let string):
      return jsonQuoted(string)
    case .number(let number):
      return canonicalNumber(number)
    case .bool(let bool):
      return bool ? "true" : "false"
    case .array(let values):
      return "[\(values.map(canonicalJSONValue(_:)).joined(separator: ","))]"
    case .object(let object):
      let entries = object.keys.sorted().map { key in
        "\(jsonQuoted(key)):\(canonicalJSONValue(object[key] ?? .null))"
      }
      return "{\(entries.joined(separator: ","))}"
    case .null:
      return "null"
    }
  }

  private static func jsonQuoted(_ value: String) -> String {
    "\"\(jsonEscapedContent(value))\""
  }

  private static func jsonEscapedContent(_ value: String) -> String {
    var encoded = ""
    for scalar in value.unicodeScalars {
      switch scalar.value {
      case 0x08:
        encoded += "\\b"
      case 0x09:
        encoded += "\\t"
      case 0x0A:
        encoded += "\\n"
      case 0x0C:
        encoded += "\\f"
      case 0x0D:
        encoded += "\\r"
      case 0x22:
        encoded += "\\\""
      case 0x5C:
        encoded += "\\\\"
      case 0x00...0x1F:
        encoded += String(format: "\\u%04X", scalar.value)
      default:
        encoded.unicodeScalars.append(scalar)
      }
    }
    return encoded
  }
}
