import Foundation

public enum ModelFacingPromptRenderer {
  public static func userPromptEntry(
    id: UUID = UUID(),
    turnID: ChatTurn.ID? = nil,
    sourceMessageID: UUID? = nil,
    prompt: String,
    attachments: [ChatAttachment] = [],
    systemContext: [String] = [],
    currentPromptContext: CurrentPromptContext? = nil
  ) throws -> ModelContextEntry {
    let content = userContent(prompt, systemContext: systemContext)
    return try ModelContextEntry(
      id: id,
      turnID: turnID,
      sourceMessageID: sourceMessageID,
      body: .userPrompt(
        UserPromptContext(
          prompt: prompt,
          attachmentNames: attachments.map(\.displayName),
          imageSignatures: attachments.filter { $0.kind == .image }.map(\.contentSignature),
          systemContext: normalizedSystemContext(systemContext),
          currentPromptContext: currentPromptContext
        )
      ),
      frozenContent: FrozenModelContent(role: .user, content: content)
    )
  }

  public static func assistantOutputEntry(
    id: UUID = UUID(),
    turnID: ChatTurn.ID? = nil,
    sourceMessageID: UUID? = nil,
    content: String
  ) throws -> ModelContextEntry {
    try ModelContextEntry(
      id: id,
      turnID: turnID,
      sourceMessageID: sourceMessageID,
      body: .assistantOutput(AssistantOutputContext(content: content)),
      frozenContent: FrozenModelContent(role: .assistant, content: content)
    )
  }

  public static func toolResultEntry(
    id: UUID = UUID(),
    turnID: ChatTurn.ID? = nil,
    sourceMessageID: UUID? = nil,
    toolResult: ToolResultModelMessage,
    request: ToolCallRequest,
    originalUserRequest _: String?,
    policy: ToolResultProjectionPolicy = .default,
    modelFollowUpNotice: String? = nil
  ) throws -> ModelContextEntry {
    let projection = ToolResultProjector.project(
      payload: toolResult.payload,
      request: request,
      policy: policy
    )
    let rawContent = ToolModelObservationRenderer.render(
      projection,
      callID: toolResult.callID,
      modelFollowUpNotice: modelFollowUpNotice
    )
    let content = limitedToolObservationContent(rawContent, policy: policy)
    let observationContext = ToolObservationContext(
      callID: toolResult.callID,
      toolName: toolResult.toolName,
      status: projection.observation.status,
      content: content,
      toolReceipt: ToolReceiptFactory.make(
        callID: toolResult.callID,
        toolName: toolResult.toolName,
        preview: toolResult.preview
      ),
      toolCall: ToolCallModelMessage(request: request)
    )
    return try ModelContextEntry(
      id: id,
      turnID: turnID,
      sourceMessageID: sourceMessageID,
      body: .toolObservation(observationContext),
      frozenContent: FrozenModelContent(
        role: .tool,
        content: content
      )
    )
  }

  public static func userContent(
    _ content: String,
    systemContext: [String]
  ) -> String {
    let systemContext = normalizedSystemContext(systemContext).joined(separator: "\n\n")

    guard !systemContext.isEmpty else {
      return content
    }

    return """
      \(systemInstructionContent(systemContext))

      User request:
      \(content)
      """
  }

  public static func systemInstructionContent(_ systemContext: String) -> String {
    """
    System instructions:
    \(systemContext)
    """
  }

  public static func normalizedSystemPrompt(_ systemPrompt: String) -> String? {
    let effectiveSystemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    return effectiveSystemPrompt.isEmpty ? nil : effectiveSystemPrompt
  }

  public static func normalizedSystemContext(_ systemContext: [String]) -> [String] {
    systemContext
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private static func limitedToolObservationContent(
    _ content: String,
    policy: ToolResultProjectionPolicy
  ) -> String {
    ProjectionLimiter.limit(content, limit: policy.modelObservationLimit).text
  }

}

enum ToolReceiptFactory {
  static func make(
    callID: UUID,
    toolName: ToolName,
    preview: ToolResultPreview
  ) -> ToolReceipt? {
    guard let summary = ToolReceiptSummary.checked(text: preview.text) else {
      return nil
    }

    let affectedPaths = preview.affectedPaths.compactMap { path -> WorkspaceRelativePath? in
      let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        return nil
      }
      return WorkspaceRelativePath(rawValue: trimmed)
    }

    return ToolReceipt.make(
      callID: callID,
      toolName: toolName,
      status: preview.status,
      affectedPaths: affectedPaths,
      summary: summary,
      outputTruncated: preview.truncated || summary.truncated,
      outputRedacted: preview.redacted
    )
  }
}

public enum ToolReceiptRenderer {
  public static func render(_ receipt: ToolReceipt) -> String {
    var lines = [
      "Tool receipt: \(receipt.toolName.rawValue)",
      "Call ID: \(receipt.callID.uuidString)",
      "Status: \(receipt.status.rawValue)",
    ]

    if receipt.affectedPaths.isEmpty {
      lines.append("Affected paths: none")
    } else {
      lines.append("Affected paths:")
      lines.append(contentsOf: receipt.affectedPaths.map { "- \($0.rawValue)" })
    }

    lines.append("Summary:")
    lines.append(receipt.summary.text)
    if receipt.summary.truncated || receipt.outputTruncated {
      lines.append("Tool output summary was truncated.")
    }
    if receipt.outputRedacted {
      lines.append("Tool output was redacted.")
    }
    lines.append(
      "Receipt is not full file or code context; read_file is required for exact content.")
    return lines.joined(separator: "\n")
  }
}

public enum ToolModelObservationRenderer {
  public static func render(
    _ projection: ToolResultProjection,
    callID _: UUID,
    modelFollowUpNotice: String? = nil
  ) -> String {
    let observation = projection.observation
    let nextStep =
      normalizedModelFollowUpNotice(modelFollowUpNotice)
      ?? projection.metadata.nextStep
    let envelope = ToolResultJSONValue.object(
      envelopeFields(
        for: observation,
        metadata: projection.metadata,
        nextStep: nextStep
      )
    )
    let content = observation.blocks
      .compactMap(renderContentBlock(_:))
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    return """
      TOOL_RESULT_JSON:
      \(envelope.rendered())

      CONTENT:
      \(content.isEmpty ? "(none)" : content)
      """
  }

  private static func envelopeFields(
    for observation: ToolModelObservation,
    metadata: ToolResultModelMetadata,
    nextStep: String?
  ) -> [(String, ToolResultJSONValue)] {
    var fields: [(String, ToolResultJSONValue)] = [
      ("tool", .string(observation.toolName.rawValue)),
      ("status", .string(observation.status.rawValue)),
      ("kind", .string(metadata.kind)),
    ]

    if metadata.duplicate {
      fields.append(("duplicate", .bool(true)))
    }
    if metadata.notReexecuted {
      fields.append(("not_reexecuted", .bool(true)))
    }
    if let replayedResultKind = metadata.replayedResultKind {
      fields.append(("replayed_result_kind", .string(replayedResultKind)))
    }

    if !observation.affectedPaths.isEmpty {
      fields.append(
        (
          "affected_paths",
          .array(observation.affectedPaths.map { .string($0.rawValue) })
        ))
    }

    fields.append(
      contentsOf: metadata.fields.compactMap { field in
        let value = jsonValue(field.value)
        return value.isDefaultOrEmpty ? nil : (field.name, value)
      }
    )
    if !metadata.nextAllowedActions.isEmpty {
      fields.append(
        (
          "next_allowed_actions",
          .array(metadata.nextAllowedActions.map { .string($0) })
        ))
    }
    if metadata.forbiddenRepeat {
      fields.append(("forbidden_repeat", .bool(true)))
    }
    if let nextStep {
      fields.append(("next_step", .string(nextStep)))
    }
    return fields
  }

  private static func jsonValue(_ value: ToolResultModelMetadataValue) -> ToolResultJSONValue {
    switch value {
    case .array(let values):
      return .array(values.map { jsonValue($0) })
    case .string(let value):
      return .string(value)
    case .int(let value):
      return .int(value)
    case .bool(let value):
      return .bool(value)
    case .null:
      return .null
    }
  }

  private static func renderContentBlock(_ block: ToolObservationBlock) -> String? {
    switch block {
    case .summary(let text):
      if text == "Plan updated." {
        return text
      }
      return "Summary: \(text)"
    case .fileDisplayedToUser(
      let path,
      let range,
      let lineCount,
      let byteCount,
      let truncated,
      let redacted
    ):
      return [
        "Displayed file to user: \(path.rawValue)",
        range.map { "Range: \($0)" },
        lineCount.map { "Displayed lines: \($0)" },
        byteCount.map { "Displayed bytes: \($0)" },
        truncated ? "Truncated: true" : nil,
        redacted ? "Redacted: true" : nil,
        "Content: omitted from model history.",
      ].compactMap(\.self).joined(separator: "\n")
    case .fileContent(let path, let content):
      let flags = [
        content.truncated ? "truncated" : nil,
        content.redacted ? "redacted" : nil,
      ].compactMap(\.self).joined(separator: ", ")
      let suffix = flags.isEmpty ? "" : "\nFlags: \(flags)"
      return """
        File: \(path.rawValue)\(suffix)
        \(content.text)
        """
    case .fileList(let root, let entries, let totalCount, let truncated):
      let body =
        entries.isEmpty
        ? "(empty)"
        : entries.map { entry in
          entry.kind == .directory ? entry.path.rawValue + "/" : entry.path.rawValue
        }.joined(separator: "\n")
      let lines: [String?] = [
        "Listed files under: \(root.rawValue)",
        "Total entries: \(totalCount)",
        truncated ? "Truncated: true" : nil,
        "Entries:",
        body,
      ]
      return lines.compactMap(\.self).joined(separator: "\n")
    case .searchSnippets(let root, let pattern, let matches, let totalCount, let truncated):
      let body =
        matches.isEmpty
        ? "(no matches)"
        : matches.map { "\($0.path.rawValue):\($0.line): \($0.snippet)" }
          .joined(separator: "\n")
      let lines: [String?] = [
        "Search root: \(root.rawValue)",
        "Pattern: \(pattern)",
        "Total matches: \(totalCount)",
        truncated ? "Truncated: true" : nil,
        "Matches:",
        body,
      ]
      return lines.compactMap(\.self).joined(separator: "\n")
    case .editReceipt(let path, let diffSummary, let matchStrategy):
      return [
        "Edited file: \(path.rawValue)",
        matchStrategy.map { "Match strategy: \($0.rawValue)" },
        diffSummary.map { "Diff summary:\n\($0)" },
      ].compactMap(\.self).joined(separator: "\n")
    case .commandResult(let result):
      var lines = [
        "Command: \(result.command)",
        "Exit code: \(result.exitCode.map(String.init) ?? "none")",
        "Duration ms: \(result.durationMs)",
        result.timedOut ? "Timed out: true" : nil,
        result.cancelled ? "Cancelled: true" : nil,
        result.outputRef.map { "Output ref: \($0)" },
        result.stdout.truncated ? "Stdout truncated: true" : nil,
        result.stdoutOmittedChars > 0 ? "Stdout omitted chars: \(result.stdoutOmittedChars)" : nil,
        result.stdout.text.isEmpty ? nil : "Stdout preview:\n\(result.stdout.text)",
        result.stderr.truncated ? "Stderr truncated: true" : nil,
        result.stderrOmittedChars > 0 ? "Stderr omitted chars: \(result.stderrOmittedChars)" : nil,
        result.stderr.text.isEmpty ? nil : "Stderr preview:\n\(result.stderr.text)",
      ].compactMap(\.self)
      if let outputRef = result.outputRef {
        lines.append(
          "Hint: Run workspace_diagnostics(outputRef: \(outputRef)) for structured errors.")
      }
      return lines.joined(separator: "\n")
    case .diagnostics(let result):
      guard !result.diagnostics.isEmpty else {
        return "No diagnostics found for \(result.outputRef)."
      }
      return result.diagnostics.map { diagnostic in
        let column = diagnostic.column.map { ":\($0)" } ?? ""
        return
          "\(diagnostic.path.rawValue):\(diagnostic.line)\(column): \(diagnostic.severity.rawValue): \(diagnostic.message)"
      }.joined(separator: "\n")
    case .webSearch(let query, let provider, let results, let truncated):
      let body =
        results.isEmpty
        ? "(no results)"
        : results.enumerated().map { index, result in
          [
            "\(index + 1). \(result.title)",
            result.url,
            result.snippet,
          ].compactMap(\.self).joined(separator: "\n")
        }.joined(separator: "\n\n")
      let lines: [String?] = [
        "Web search provider: \(provider.displayName)",
        "Query: \(query)",
        truncated ? "Truncated: true" : nil,
        "Results:",
        body,
      ]
      return lines.compactMap(\.self).joined(separator: "\n")
    case .webFetch(
      let url, let provider, let finalURL, let statusCode, let contentType, let content,
      let byteCount):
      let flags = [
        content.truncated ? "truncated" : nil,
        content.redacted ? "redacted" : nil,
      ].compactMap(\.self).joined(separator: ", ")
      let suffix = flags.isEmpty ? "" : "\nFlags: \(flags)"
      let redirect = url == finalURL ? "" : "\nFinal URL: \(finalURL)"
      return """
        Web fetch URL: \(url)\(redirect)
        Web fetch provider: \(provider?.displayName ?? "Unknown")
        Status: \(statusCode)
        Content-Type: \(contentType ?? "unknown")
        Bytes: \(byteCount)\(suffix)
        Content:
        \(content.text)
        """
    case .failure(let text):
      return "Failure: \(text)"
    }
  }

  private static func normalizedModelFollowUpNotice(_ notice: String?) -> String? {
    let normalized = notice?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    guard let normalized, !normalized.isEmpty else {
      return nil
    }
    guard normalized.count > modelFollowUpNoticeLimit else {
      return normalized
    }
    return String(normalized.prefix(modelFollowUpNoticeLimit)) + "\n[follow-up truncated]"
  }

  private static let modelFollowUpNoticeLimit = 1_200
}

private indirect enum ToolResultJSONValue {
  case object([(String, ToolResultJSONValue)])
  case array([ToolResultJSONValue])
  case string(String)
  case int(Int)
  case bool(Bool)
  case null

  func rendered() -> String {
    switch self {
    case .object(let fields):
      let body = fields.map { key, value in
        "\"\(Self.escaped(key))\":\(value.rendered())"
      }.joined(separator: ",")
      return "{\(body)}"
    case .array(let values):
      return "[" + values.map { $0.rendered() }.joined(separator: ",") + "]"
    case .string(let value):
      return "\"\(Self.escaped(value))\""
    case .int(let value):
      return String(value)
    case .bool(let value):
      return value ? "true" : "false"
    case .null:
      return "null"
    }
  }

  fileprivate var isDefaultOrEmpty: Bool {
    switch self {
    case .string(let value):
      return value.isEmpty
    case .bool(let value):
      return !value
    case .null:
      return true
    case .array(let values):
      return values.isEmpty
    case .object(let fields):
      return fields.isEmpty
    case .int:
      return false
    }
  }

  private static func escaped(_ value: String) -> String {
    var result = ""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"":
        result += "\\\""
      case "\\":
        result += "\\\\"
      case "\n":
        result += "\\n"
      case "\r":
        result += "\\r"
      case "\t":
        result += "\\t"
      default:
        if scalar.value < 0x20 {
          result += String(format: "\\u%04X", scalar.value)
        } else {
          result.unicodeScalars.append(scalar)
        }
      }
    }
    return result
  }
}
