import Foundation

package struct BrowserInspectInput: Codable, Equatable, Sendable {
  package static let defaultMaxLength = 4000

  package var selector: String?
  package var maxLength: Int?
  package var includeHTML: Bool?

  private enum CodingKeys: String, CodingKey {
    case selector
    case maxLength
    case includeHTML = "includeHtml"
  }

  package init(selector: String? = nil, maxLength: Int? = nil, includeHTML: Bool? = nil) {
    self.selector = selector
    self.maxLength = maxLength
    self.includeHTML = includeHTML
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    selector = try container.decodeIfPresent(String.self, forKey: .selector)
    maxLength = try Self.decodeOptionalInt(from: container, forKey: .maxLength)
    includeHTML = try Self.decodeOptionalBool(from: container, forKey: .includeHTML)

    if let selector,
      selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw BrowserToolInputValidationError.emptySelector
    }
    if let maxLength, maxLength < 1 {
      throw BrowserToolInputValidationError.invalidMaxLength
    }
  }

  package var resolvedMaxLength: Int {
    maxLength ?? Self.defaultMaxLength
  }

  package var resolvedSelector: String? {
    Self.normalizedSelector(selector)
  }

  package var resolvedIncludeHTML: Bool {
    includeHTML ?? false
  }

  package static func normalizedSelector(_ selector: String?) -> String? {
    guard var normalized = selector?.trimmingCharacters(in: .whitespacesAndNewlines),
      !normalized.isEmpty
    else {
      return nil
    }

    while normalized.count >= 2,
      let first = normalized.first,
      let last = normalized.last,
      first == last,
      first == "\"" || first == "'"
    {
      normalized.removeFirst()
      normalized.removeLast()
      normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
      if normalized.isEmpty {
        return nil
      }
    }

    return normalized
  }

  private static func decodeOptionalInt(
    from container: KeyedDecodingContainer<CodingKeys>,
    forKey key: CodingKeys
  ) throws -> Int? {
    guard container.contains(key) else {
      return nil
    }
    if let value = try? container.decode(Int.self, forKey: key) {
      return value
    }
    if let stringValue = try? container.decode(String.self, forKey: key),
      let value = Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      return value
    }
    throw BrowserToolInputValidationError.invalidIntegerArgument(key.stringValue)
  }

  private static func decodeOptionalBool(
    from container: KeyedDecodingContainer<CodingKeys>,
    forKey key: CodingKeys
  ) throws -> Bool? {
    guard container.contains(key) else {
      return nil
    }
    if let value = try? container.decode(Bool.self, forKey: key) {
      return value
    }
    if let rawValue = try? container.decode(String.self, forKey: key) {
      switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "true":
        return true
      case "false":
        return false
      default:
        break
      }
    }
    throw BrowserToolInputValidationError.invalidBooleanArgument(key.stringValue)
  }
}

package enum BrowserInspectResult: Codable, Equatable, Sendable {
  case success(
    path: WorkspaceRelativePath?,
    title: String,
    url: String,
    selector: String?,
    text: ToolTextOutput,
    html: ToolTextOutput?
  )
  case failed(reason: ToolFailureReason)
}

nonisolated extension BrowserInspectResult {
  var preview: ToolResultPreview {
    switch self {
    case .success(let path, let title, let url, let selector, let text, let html):
      var lines: [String] = []
      if let path {
        lines.append("Preview path: \(path.rawValue)")
      }
      lines.append("Title: \(title)")
      lines.append("URL: \(url)")
      lines.append("Scope: \(selector ?? "document.body")")
      lines.append("Text truncated: \(text.truncated)")
      lines.append("")
      lines.append("Text:")
      lines.append(text.text)
      if let html {
        lines.append("")
        lines.append("HTML truncated: \(html.truncated)")
        lines.append("")
        lines.append("HTML:")
        lines.append(html.text)
      }
      return ToolResultPreview(
        text: lines.joined(separator: "\n"),
        truncated: text.truncated || (html?.truncated ?? false),
        redacted: text.redacted || (html?.redacted ?? false),
        affectedPaths: path.map { [$0.rawValue] } ?? []
      )
    case .failed(let reason):
      return ToolResultPreview(status: reason.previewStatus, text: reason.message)
    }
  }
}

nonisolated extension ToolDefinition {
  package static let browserInspect = ToolDefinition(
    name: .browserInspect,
    description: "Inspect text or HTML from the current HTML preview page.",
    parameters: [
      ToolParameterDefinition(
        name: "selector",
        description: "Optional plain CSS selector. Do not wrap the value in extra quotes.",
        isRequired: false,
        valueType: .string
      ),
      ToolParameterDefinition(
        name: "maxLength",
        description: "Maximum characters to return. Defaults to 4000.",
        isRequired: false,
        valueType: .integer,
        defaultValue: .number(4000),
        minimum: 1,
        maximum: 20_000
      ),
      ToolParameterDefinition(
        name: "includeHtml",
        description: "When true, include HTML for the inspected element.",
        isRequired: false,
        valueType: .boolean,
        defaultValue: .bool(false)
      ),
    ],
    capabilities: [],
    riskLevel: .low
  )
}

extension BrowserInspectInput {
  static func decodeToolArguments(_ arguments: ToolCallArguments) throws -> BrowserInspectInput {
    do {
      return try ToolInputDecoder.decode(BrowserInspectInput.self, from: arguments)
    } catch let error as BrowserToolInputValidationError {
      switch error {
      case .invalidBooleanArgument(let name):
        throw InvalidToolCallReason.invalidArgumentType(name: name, expected: "true or false")
      case .invalidIntegerArgument(let name):
        throw InvalidToolCallReason.invalidArgumentType(name: name, expected: "an integer")
      case .invalidMaxLength:
        throw InvalidToolCallReason.invalidPagination("maxLength")
      case .emptySelector:
        throw InvalidToolCallReason.invalidArgumentType(
          name: "selector",
          expected: "omit it or provide a non-empty CSS selector"
        )
      }
    }
  }
}

struct BrowserInspectToolExecutor: TypedToolExecutor {
  static let codec = ToolCodec<BrowserInspectInput>(
    definition: ToolDefinition.browserInspect,
    decodeArguments: BrowserInspectInput.decodeToolArguments,
    makePayload: ToolCallPayload.browserInspect,
    extractInput: { payload in
      guard case .browserInspect(let input) = payload else {
        throw ToolInputDecodingError.payloadMismatch(
          expected: ToolDefinition.browserInspect.name.rawValue,
          actual: payload.toolName.rawValue
        )
      }
      return input
    }
  )

  func evaluatePermission(
    _ input: BrowserInspectInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    _ = input
    _ = context
    return ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Inspecting the active HTML preview is allowed.",
      riskLevel: .low
    )
  }

  func run(_ input: BrowserInspectInput, context: ToolContext) async -> ToolResultPayload {
    .browserInspect(await context.browserToolService.inspect(input))
  }
}
