import Foundation

nonisolated enum ToolCallParseResult: Equatable, Sendable {
  case none
  case toolCall(ToolCallParseOutput)
}

nonisolated struct ToolCallParseOutput: Equatable, Sendable {
  var request: ToolCallRequest
  var modelMessage: ToolCallModelMessage
}

nonisolated protocol ToolCallParsing: Sendable {
  func parse(
    _ text: String,
    workspaceID: Workspace.ID,
    sessionID: CodingSession.ID,
    createdAt: Date
  ) throws -> ToolCallParseResult
}

nonisolated protocol ToolPromptRendering: Sendable {
  func renderToolInstructions(
    registry: ToolRegistry,
    payloadDelimiter: String
  ) -> String
}

nonisolated enum TaggedToolCallParseError: Error, Equatable, LocalizedError {
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

  var errorDescription: String? {
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

nonisolated struct TaggedToolPromptRenderer: ToolPromptRendering {
  func renderToolInstructions(
    registry: ToolRegistry,
    payloadDelimiter: String
  ) -> String {
    let renderedTools = registry.tools.map { definition in
      let parameters = definition.parameters.map { parameter in
        let required = parameter.isRequired ? "required" : "optional"
        let payload = parameter.supportsHeredocPayload ? " heredoc payload" : ""
        return "- <\(parameter.name)> (\(required)\(payload)): \(parameter.description)"
      }
      .joined(separator: "\n")

      return """
        Tool: \(definition.name.rawValue)
        Description: \(definition.description)
        Parameters:
        \(parameters)
        Example:
        \(definition.taggedExample)
        """
    }
    .joined(separator: "\n\n")

    return """
      Tool calling uses a tagged action format. It is XML-inspired, but it is not XML.
      Emit one complete <action> block and then stop. Do not include explanatory text before or after the action.
      For small parameters, use paired tags like <path>Sources/App.swift</path>.
      For raw multiline payloads, use this exact app-provided delimiter on its own line with no spaces:
      \(payloadDelimiter)
      End every raw multiline payload with the delimiter line, then the closing parameter tag.
      Payload contents are raw text; do not escape HTML, XML, JSON, or code inside payloads.
      If a payload would contain the delimiter as its own line, do not call a tool. Ask for a new delimiter.

      Available tools:

      \(renderedTools)
      """
  }
}

nonisolated struct TaggedToolCallParser: ToolCallParsing {
  private let payloadParameterNames: Set<String>
  private let closingTagFallbackPayloadNames: Set<String>

  init(
    payloadParameterNames: Set<String> = ["content", "patch"],
    closingTagFallbackPayloadNames: Set<String> = ["content"]
  ) {
    self.payloadParameterNames = payloadParameterNames
    self.closingTagFallbackPayloadNames = closingTagFallbackPayloadNames
  }

  func parse(
    _ text: String,
    workspaceID: Workspace.ID,
    sessionID: CodingSession.ID,
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

      if text[cursor...].hasPrefix("</action>") {
        cursor = text.index(cursor, offsetBy: "</action>".count)
        didCloseAction = true
        break
      }

      guard text[cursor] == "<" else {
        throw TaggedToolCallParseError.malformedTag
      }

      let parameterOpenEnd = try openingTagEnd(in: text, from: cursor)
      let parameterTag = try parseOpeningTag(text[text.index(after: cursor)..<parameterOpenEnd])
      let parameterName = parameterTag.name
      guard !parameterName.isEmpty else {
        throw TaggedToolCallParseError.malformedTag
      }
      guard arguments[parameterName] == nil else {
        throw TaggedToolCallParseError.duplicateParameter(parameterName)
      }

      cursor = text.index(after: parameterOpenEnd)

      if parameterTag.attributes.keys.contains("delimiter") {
        guard let delimiter = parameterTag.attributes["delimiter"] else {
          throw TaggedToolCallParseError.missingDelimiter(parameterName)
        }
        guard !delimiter.isEmpty else {
          throw TaggedToolCallParseError.emptyDelimiter(parameterName)
        }

        let payload = try readHeredocPayload(
          in: text,
          from: cursor,
          parameterName: parameterName,
          delimiter: delimiter,
          allowsClosingTagFallback: closingTagFallbackPayloadNames.contains(parameterName)
        )
        arguments[parameterName] = .string(payload.content)
        cursor = payload.endIndex
      } else {
        guard !payloadParameterNames.contains(parameterName) else {
          throw TaggedToolCallParseError.missingDelimiter(parameterName)
        }
        guard parameterTag.attributes.isEmpty else {
          throw TaggedToolCallParseError.malformedTag
        }

        let closingTag = "</\(parameterName)>"
        guard let closingRange = text[cursor...].range(of: closingTag) else {
          throw TaggedToolCallParseError.malformedTag
        }

        let value = text[cursor..<closingRange.lowerBound]
          .trimmingCharacters(in: .whitespacesAndNewlines)
        arguments[parameterName] = .string(String(value))
        cursor = closingRange.upperBound
      }
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

    let request = ToolCallRequest(
      workspaceID: workspaceID,
      sessionID: sessionID,
      toolName: ToolName(canonicalizing: trimmedActionName),
      arguments: arguments,
      createdAt: createdAt
    )
    return .toolCall(
      ToolCallParseOutput(request: request, modelMessage: ToolCallModelMessage(request: request)))
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
        guard text[line.nextStart...].hasPrefix(closingTag) else {
          throw TaggedToolCallParseError.malformedTag
        }
        let endIndex = text.index(line.nextStart, offsetBy: closingTag.count)
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
  var name: String
  var attributes: [String: String]
}
