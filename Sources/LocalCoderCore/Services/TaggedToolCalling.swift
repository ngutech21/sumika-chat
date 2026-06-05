import Foundation

public enum ToolCallParseResult: Equatable, Sendable {
  case none
  case toolCall(ToolCallParseOutput)
}

public struct ToolCallParseOutput: Equatable, Sendable {
  public var request: RawToolCallRequest
  public var modelMessage: ToolCallModelMessage
}

public protocol ToolCallParsing: Sendable {
  func parse(
    _ text: String,
    workspaceID: Workspace.ID,
    sessionID: ChatSession.ID,
    createdAt: Date
  ) throws -> ToolCallParseResult
}

public protocol ToolPromptRendering: Sendable {
  func renderToolInstructions(
    registry: ToolRegistry,
    payloadDelimiter: String
  ) -> String
}

public enum TaggedToolCallParseError: Error, Equatable, LocalizedError {
  case multipleActions
  case extraneousContent
  case missingActionName
  case emptyActionName
  case unclosedAction
  case malformedTag
  case duplicateParameter(String)
  case missingDelimiter(String)
  case emptyDelimiter(String)
  case delimiterNotFound(String)

  public var errorDescription: String? {
    switch self {
    case .multipleActions:
      "Only one action block is allowed."
    case .extraneousContent:
      "A tool action must be the only non-whitespace content in the assistant turn."
    case .missingActionName:
      "The action tag requires a name attribute."
    case .emptyActionName:
      "The action name cannot be empty."
    case .unclosedAction:
      "The action block is missing a closing </action> tag."
    case .malformedTag:
      "The tagged tool call contains a malformed tag."
    case .duplicateParameter(let name):
      "The tool call contains a duplicate parameter: \(name)."
    case .missingDelimiter(let name):
      "The payload parameter requires a delimiter attribute: \(name)."
    case .emptyDelimiter(let name):
      "The payload delimiter cannot be empty for parameter: \(name)."
    case .delimiterNotFound(let delimiter):
      "The payload delimiter was not found on its own line: \(delimiter)."
    }
  }
}

public struct TaggedToolPromptRenderer: ToolPromptRendering {
  public init() {}

  public func renderToolInstructions(
    registry: ToolRegistry,
    payloadDelimiter: String
  ) -> String {
    let renderedTools = registry.tools.map(renderedSignature(for:)).joined(separator: "\n")

    return """
      Tool calling:
      - Emit exactly one <action name="tool_name">...</action>, then stop.
      - Do not include text before or after an <action>.
      - Do not wrap actions in Markdown fences.
      - Use workspace-relative paths.
      - For content, old_text, and new_text, use delimiter="\(payloadDelimiter)" with the delimiter on its own line.
      - Payload contents are raw text; do not escape HTML, XML, JSON, or code inside payloads.
      - If a payload would contain the delimiter as its own line, do not call a tool. Ask for a new delimiter.

      Tools:
      \(renderedTools)

      Example:
      <action name="read_file">
      <path>Sources/App.swift</path>
      <offset>1</offset>
      <limit>100</limit>
      </action>

      Multiline payload example:
      <content delimiter="\(payloadDelimiter)">
      raw text
      \(payloadDelimiter)
      </content>
      """
  }

  private func renderedSignature(for definition: ToolDefinition) -> String {
    let parameters = definition.parameters
      .map { parameter in
        parameter.name + (parameter.isRequired ? "" : "?")
      }
      .joined(separator: ", ")
    return
      "- \(definition.name.rawValue)(\(parameters)): \(compactDescription(for: definition.name))"
  }

  private func compactDescription(for name: ToolName) -> String {
    switch name {
    case .readFile:
      "Read workspace file lines into context."
    case .showFile:
      "Display workspace file lines directly to the user."
    case .listFiles:
      "List files in a workspace directory."
    case .globFiles:
      "Find workspace files by glob."
    case .searchFiles:
      "Search workspace text files."
    case .writeFile:
      "Create or fully overwrite a workspace text file."
    case .editFile:
      "Replace one exact old_text span in an existing workspace file."
    case .invalid:
      "Invalid tool-call observation."
    default:
      "Use this workspace tool."
    }
  }
}

public struct TaggedToolCallParser: ToolCallParsing {
  private let payloadParameterNames: Set<String>
  private let closingTagFallbackPayloadNames: Set<String>

  private struct ParsedParameter {
    var name: String
    var value: String
    var endIndex: String.Index
  }

  public init(
    payloadParameterNames: Set<String> = ["content", "old_text", "new_text"],
    closingTagFallbackPayloadNames: Set<String> = ["content", "old_text", "new_text"]
  ) {
    self.payloadParameterNames = payloadParameterNames
    self.closingTagFallbackPayloadNames = closingTagFallbackPayloadNames
  }

  public func parse(
    _ text: String,
    workspaceID: Workspace.ID,
    sessionID: ChatSession.ID,
    createdAt: Date = Date()
  ) throws -> ToolCallParseResult {
    guard let actionStart = text.range(of: "<action")?.lowerBound else {
      return .none
    }

    guard text[..<actionStart].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TaggedToolCallParseError.extraneousContent
    }

    let actionOpenEnd = try openingTagEnd(in: text, from: actionStart)
    let actionTag = try parseOpeningTag(text[text.index(after: actionStart)..<actionOpenEnd])

    guard actionTag.name == "action" else {
      throw TaggedToolCallParseError.malformedTag
    }

    guard let rawActionName = actionTag.attributes["name"] else {
      throw TaggedToolCallParseError.missingActionName
    }

    let trimmedActionName = rawActionName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedActionName.isEmpty else {
      throw TaggedToolCallParseError.emptyActionName
    }

    var arguments: ToolCallArguments = [:]
    var cursor = text.index(after: actionOpenEnd)
    var didCloseAction = false

    while cursor < text.endIndex {
      cursor = skipWhitespace(in: text, from: cursor)
      guard cursor < text.endIndex else {
        break
      }

      if text[cursor...].hasPrefix("</action>") {
        cursor = text.index(cursor, offsetBy: "</action>".count)
        didCloseAction = true
        break
      }

      let parameter = try parseParameter(in: text, from: cursor)
      guard arguments[parameter.name] == nil else {
        throw TaggedToolCallParseError.duplicateParameter(parameter.name)
      }
      arguments[parameter.name] = .string(parameter.value)
      cursor = parameter.endIndex
    }

    guard didCloseAction else {
      throw TaggedToolCallParseError.unclosedAction
    }

    let trailing = text[cursor...]
    guard trailing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      if trailing.contains("<action") {
        throw TaggedToolCallParseError.multipleActions
      }
      throw TaggedToolCallParseError.extraneousContent
    }

    let request = RawToolCallRequest(
      workspaceID: workspaceID,
      sessionID: sessionID,
      toolName: ToolName(canonicalizing: trimmedActionName),
      arguments: arguments,
      rawText: String(text[actionStart..<cursor]),
      createdAt: createdAt
    )
    return .toolCall(
      ToolCallParseOutput(
        request: request,
        modelMessage: ToolCallModelMessage(rawRequest: request)
      ))
  }

  private func parseParameter(in text: String, from cursor: String.Index) throws -> ParsedParameter
  {
    guard text[cursor] == "<" else {
      throw TaggedToolCallParseError.malformedTag
    }

    let parameterOpenEnd = try openingTagEnd(in: text, from: cursor)
    let parameterTag = try parseOpeningTag(text[text.index(after: cursor)..<parameterOpenEnd])
    let parameterName = parameterTag.name
    guard !parameterName.isEmpty else {
      throw TaggedToolCallParseError.malformedTag
    }

    let contentStart = text.index(after: parameterOpenEnd)
    let payload = try readParameterPayload(
      in: text,
      from: contentStart,
      parameterName: parameterName,
      attributes: parameterTag.attributes
    )
    return ParsedParameter(name: parameterName, value: payload.content, endIndex: payload.endIndex)
  }

  private func readParameterPayload(
    in text: String,
    from contentStart: String.Index,
    parameterName: String,
    attributes: [String: String]
  ) throws -> (content: String, endIndex: String.Index) {
    if attributes.keys.contains("delimiter") {
      return try readDelimitedParameterPayload(
        in: text,
        from: contentStart,
        parameterName: parameterName,
        attributes: attributes
      )
    }

    if payloadParameterNames.contains(parameterName),
      closingTagFallbackPayloadNames.contains(parameterName)
    {
      guard attributes.isEmpty else {
        throw TaggedToolCallParseError.malformedTag
      }
      return try readClosingTagTerminatedPayload(
        in: text,
        from: contentStart,
        parameterName: parameterName
      )
    }

    guard !payloadParameterNames.contains(parameterName) else {
      throw TaggedToolCallParseError.missingDelimiter(parameterName)
    }
    guard attributes.isEmpty else {
      throw TaggedToolCallParseError.malformedTag
    }
    return try readPlainParameterPayload(in: text, from: contentStart, parameterName: parameterName)
  }

  private func readDelimitedParameterPayload(
    in text: String,
    from contentStart: String.Index,
    parameterName: String,
    attributes: [String: String]
  ) throws -> (content: String, endIndex: String.Index) {
    guard let delimiter = attributes["delimiter"] else {
      throw TaggedToolCallParseError.missingDelimiter(parameterName)
    }
    guard !delimiter.isEmpty else {
      throw TaggedToolCallParseError.emptyDelimiter(parameterName)
    }

    return try readHeredocPayload(
      in: text,
      from: contentStart,
      parameterName: parameterName,
      delimiter: delimiter,
      allowsClosingTagFallback: closingTagFallbackPayloadNames.contains(parameterName)
    )
  }

  private func readPlainParameterPayload(
    in text: String,
    from contentStart: String.Index,
    parameterName: String
  ) throws -> (content: String, endIndex: String.Index) {
    let closingTag = "</\(parameterName)>"
    guard let closingRange = text[contentStart...].range(of: closingTag) else {
      throw TaggedToolCallParseError.malformedTag
    }

    let value = text[contentStart..<closingRange.lowerBound]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (String(value), closingRange.upperBound)
  }

  private func openingTagEnd(in text: String, from start: String.Index) throws -> String.Index {
    guard text[start] == "<", let end = text[start...].firstIndex(of: ">") else {
      throw TaggedToolCallParseError.malformedTag
    }
    return end
  }

  private func parseOpeningTag(_ rawTag: Substring) throws -> OpeningTag {
    let tag = String(rawTag)
    var cursor = tag.startIndex
    cursor = skipWhitespace(in: tag, from: cursor)

    let nameStart = cursor
    while cursor < tag.endIndex, isTagNameCharacter(tag[cursor]) {
      cursor = tag.index(after: cursor)
    }

    guard nameStart < cursor else {
      throw TaggedToolCallParseError.malformedTag
    }

    let name = String(tag[nameStart..<cursor])
    var attributes: [String: String] = [:]

    while cursor < tag.endIndex {
      cursor = skipWhitespace(in: tag, from: cursor)
      guard cursor < tag.endIndex else {
        break
      }

      let attributeNameStart = cursor
      while cursor < tag.endIndex, isTagNameCharacter(tag[cursor]) {
        cursor = tag.index(after: cursor)
      }
      guard attributeNameStart < cursor else {
        throw TaggedToolCallParseError.malformedTag
      }

      let attributeName = String(tag[attributeNameStart..<cursor])
      cursor = skipWhitespace(in: tag, from: cursor)
      guard cursor < tag.endIndex, tag[cursor] == "=" else {
        throw TaggedToolCallParseError.malformedTag
      }

      cursor = tag.index(after: cursor)
      cursor = skipWhitespace(in: tag, from: cursor)
      guard cursor < tag.endIndex, tag[cursor] == "\"" || tag[cursor] == "'" else {
        throw TaggedToolCallParseError.malformedTag
      }

      let quote = tag[cursor]
      cursor = tag.index(after: cursor)
      let valueStart = cursor
      while cursor < tag.endIndex, tag[cursor] != quote {
        cursor = tag.index(after: cursor)
      }
      guard cursor < tag.endIndex else {
        throw TaggedToolCallParseError.malformedTag
      }

      guard attributes[attributeName] == nil else {
        throw TaggedToolCallParseError.malformedTag
      }
      attributes[attributeName] = String(tag[valueStart..<cursor])
      cursor = tag.index(after: cursor)
    }

    return OpeningTag(name: name, attributes: attributes)
  }

  private func readHeredocPayload(
    in text: String,
    from start: String.Index,
    parameterName: String,
    delimiter: String,
    allowsClosingTagFallback: Bool
  ) throws -> (content: String, endIndex: String.Index) {
    var contentStart = start
    if let crlfRange = text[contentStart...].range(of: "\r\n"),
      crlfRange.lowerBound == contentStart
    {
      contentStart = crlfRange.upperBound
    } else if let lfRange = text[contentStart...].range(of: "\n"),
      lfRange.lowerBound == contentStart
    {
      contentStart = lfRange.upperBound
    }

    var lineStart = contentStart
    while lineStart <= text.endIndex {
      let line = lineBounds(in: text, from: lineStart)
      if String(text[line.contentStart..<line.contentEnd]) == delimiter {
        let contentEnd = trimmedContentEndBeforeDelimiter(in: text, lineStart: lineStart)
        let closingTag = "</\(parameterName)>"
        let closingTagStart = skipWhitespace(in: text, from: line.nextStart)
        guard text[closingTagStart...].hasPrefix(closingTag) else {
          throw TaggedToolCallParseError.malformedTag
        }
        let endIndex = text.index(closingTagStart, offsetBy: closingTag.count)
        return (String(text[contentStart..<contentEnd]), endIndex)
      }

      guard line.nextStart > lineStart else {
        break
      }
      lineStart = line.nextStart
    }

    if allowsClosingTagFallback {
      return try readClosingTagTerminatedPayload(
        in: text,
        from: contentStart,
        parameterName: parameterName
      )
    }

    throw TaggedToolCallParseError.delimiterNotFound(delimiter)
  }

  private func readClosingTagTerminatedPayload(
    in text: String,
    from contentStart: String.Index,
    parameterName: String
  ) throws -> (content: String, endIndex: String.Index) {
    var contentStart = contentStart
    if let crlfRange = text[contentStart...].range(of: "\r\n"),
      crlfRange.lowerBound == contentStart
    {
      contentStart = crlfRange.upperBound
    } else if let lfRange = text[contentStart...].range(of: "\n"),
      lfRange.lowerBound == contentStart
    {
      contentStart = lfRange.upperBound
    }

    let closingTag = "</\(parameterName)>"
    guard let closingRange = text[contentStart...].range(of: closingTag) else {
      throw TaggedToolCallParseError.malformedTag
    }

    let contentEnd = trimmedContentEndBeforeClosingTag(
      in: text, closingStart: closingRange.lowerBound)
    return (String(text[contentStart..<contentEnd]), closingRange.upperBound)
  }

  private func lineBounds(
    in text: String,
    from start: String.Index
  ) -> (contentStart: String.Index, contentEnd: String.Index, nextStart: String.Index) {
    let remainder = text[start...]
    let crlfRange = remainder.range(of: "\r\n")
    let lfRange = remainder.range(of: "\n")

    switch earliestLineEnding(crlfRange: crlfRange, lfRange: lfRange) {
    case .some(let range):
      return (start, range.lowerBound, range.upperBound)
    case .none:
      return (start, text.endIndex, text.endIndex)
    }
  }

  private func earliestLineEnding(
    crlfRange: Range<String.Index>?,
    lfRange: Range<String.Index>?
  ) -> Range<String.Index>? {
    switch (crlfRange, lfRange) {
    case (.some(let crlfRange), .some(let lfRange)):
      return crlfRange.lowerBound <= lfRange.lowerBound ? crlfRange : lfRange
    case (.some(let crlfRange), .none):
      return crlfRange
    case (.none, .some(let lfRange)):
      return lfRange
    case (.none, .none):
      return nil
    }
  }

  private func trimmedContentEndBeforeDelimiter(
    in text: String,
    lineStart: String.Index
  ) -> String.Index {
    trimmedContentEndBeforeClosingTag(in: text, closingStart: lineStart)
  }

  private func trimmedContentEndBeforeClosingTag(
    in text: String,
    closingStart: String.Index
  ) -> String.Index {
    let prefix = text[..<closingStart]
    if let crlfRange = prefix.range(of: "\r\n", options: .backwards),
      crlfRange.upperBound == closingStart
    {
      return crlfRange.lowerBound
    }
    if let lfRange = prefix.range(of: "\n", options: .backwards),
      lfRange.upperBound == closingStart
    {
      return lfRange.lowerBound
    }

    return closingStart
  }

  private func skipWhitespace(in text: String, from start: String.Index) -> String.Index {
    var cursor = start
    while cursor < text.endIndex, text[cursor].isWhitespace {
      cursor = text.index(after: cursor)
    }
    return cursor
  }

  private func isTagNameCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_" || character == "-"
  }
}

private struct OpeningTag {
  public var name: String
  public var attributes: [String: String]
}
