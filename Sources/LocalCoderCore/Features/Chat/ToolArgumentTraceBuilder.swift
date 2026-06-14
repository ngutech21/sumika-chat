enum ToolArgumentTraceBuilder {
  static func traces(
    from arguments: ToolCallArguments,
    toolName: ToolName
  ) -> [ToolArgumentTrace] {
    arguments.keys.sorted().map { name in
      let value = arguments[name] ?? .null
      let preview =
        shouldRedactToolArgument(name, toolName: toolName)
        ? (value: "[redacted]", truncated: false)
        : truncatedToolArgumentPreview(value.displayValue)
      return ToolArgumentTrace(
        name: name,
        valueType: toolArgumentTypeName(value),
        preview: preview.value,
        previewTruncated: preview.truncated
      )
    }
  }

  private static func shouldRedactToolArgument(_ name: String, toolName: ToolName) -> Bool {
    switch toolName {
    case .writeFile:
      name == "content"
    case .editFile:
      name == "old_text" || name == "new_text"
    default:
      false
    }
  }

  private static func toolArgumentTypeName(_ value: ToolArgumentValue) -> String {
    switch value {
    case .string:
      return "string"
    case .number:
      return "number"
    case .bool:
      return "bool"
    case .array:
      return "array"
    case .object:
      return "object"
    case .null:
      return "null"
    }
  }

  private static func truncatedToolArgumentPreview(
    _ value: String
  ) -> (value: String, truncated: Bool) {
    let limit = 500
    guard value.count > limit else {
      return (value, false)
    }
    return (String(value.prefix(limit)), true)
  }
}
