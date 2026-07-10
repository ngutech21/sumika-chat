/// Normalizes server-provided JSON Schemas into a model-agnostic canonical
/// shape: every property carries a plain string `type`, optionality is
/// expressed as OpenAPI-style `nullable: true`, and composition keywords are
/// gone.
///
/// This is the lowest common denominator across chat-template rendering
/// styles. Templates that structurally dispatch on `value['type']` (Gemma)
/// hard-require a string type per property; templates that dump the schema
/// via `tojson` (Qwen) render any shape but benefit from the simpler,
/// shorter form. Pydantic servers routinely emit optionals as
/// `anyOf: [{type: X}, {type: "null"}]` without a top-level `type`, which
/// the dispatching style cannot render at all. Normalization collapses those
/// constructs while keeping everything else intact:
///
/// - `anyOf`/`oneOf` without a sibling `type` collapses to the first
///   non-null variant's fields plus `nullable: true` when a null variant
///   existed.
/// - A `type` array (`["string", "null"]`) becomes its first non-null
///   element plus `nullable: true`.
/// - A property still missing `type` falls back to `"string"`.
///
/// Applied recursively through `properties` and `items`.
enum MCPToolSchemaNormalizer {
  static func normalized(_ schema: ToolArgumentValue) -> ToolArgumentValue {
    guard case .object(var fields) = schema else {
      return schema
    }
    fields = collapsedVariants(fields)
    fields = normalizedTypeField(fields, fallbackToString: false)
    fields = normalizedChildren(fields)
    return .object(fields)
  }

  private static func normalizedProperty(_ value: ToolArgumentValue) -> ToolArgumentValue {
    guard case .object(var fields) = value else {
      return value
    }
    fields = collapsedVariants(fields)
    fields = normalizedTypeField(fields, fallbackToString: true)
    fields = normalizedChildren(fields)
    return .object(fields)
  }

  private static func normalizedChildren(
    _ fields: [String: ToolArgumentValue]
  ) -> [String: ToolArgumentValue] {
    var fields = fields
    if case .object(let properties)? = fields["properties"] {
      fields["properties"] = .object(properties.mapValues(normalizedProperty))
    }
    if let items = fields["items"] {
      fields["items"] = normalizedProperty(items)
    }
    return fields
  }

  private static func collapsedVariants(
    _ fields: [String: ToolArgumentValue]
  ) -> [String: ToolArgumentValue] {
    guard fields["type"] == nil else {
      return fields
    }
    var fields = fields
    for keyword in ["anyOf", "oneOf"] {
      guard case .array(let variants)? = fields[keyword] else {
        continue
      }
      let nonNullVariants = variants.filter { !isNullTypeVariant($0) }
      if case .object(let variantFields)? = nonNullVariants.first {
        for (key, value) in variantFields where fields[key] == nil {
          fields[key] = value
        }
      }
      if nonNullVariants.count < variants.count {
        fields["nullable"] = .bool(true)
      }
      fields[keyword] = nil
      break
    }
    return fields
  }

  private static func normalizedTypeField(
    _ fields: [String: ToolArgumentValue],
    fallbackToString: Bool
  ) -> [String: ToolArgumentValue] {
    var fields = fields
    if case .array(let types)? = fields["type"] {
      let nonNullTypes = types.filter { $0 != .string("null") }
      if nonNullTypes.count < types.count {
        fields["nullable"] = .bool(true)
      }
      fields["type"] = nonNullTypes.first ?? .string("string")
    }
    if fields["type"] == nil, fallbackToString {
      fields["type"] = .string("string")
    }
    return fields
  }

  private static func isNullTypeVariant(_ variant: ToolArgumentValue) -> Bool {
    guard case .object(let fields) = variant else {
      return false
    }
    return fields["type"] == .string("null")
  }
}
