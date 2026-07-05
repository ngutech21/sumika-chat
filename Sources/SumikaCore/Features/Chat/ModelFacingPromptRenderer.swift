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
    systemContext: [String] = [],
    modelFollowUpNotice: String? = nil
  ) throws -> ModelContextEntry {
    let projection = ToolResultProjector.project(
      payload: toolResult.payload,
      request: request,
      policy: policy
    )
    let rawContent = ToolModelObservationRenderer.render(
      projection.observation,
      callID: toolResult.callID,
      modelFollowUpNotice: modelFollowUpNotice
    )
    let content = limitedToolObservationContent(rawContent, policy: policy)
    let toolReceipt = ToolReceiptFactory.make(
      callID: toolResult.callID,
      toolName: toolResult.toolName,
      preview: toolResult.preview
    )
    if isTerminalWriteResult(
      toolName: toolResult.toolName,
      status: projection.observation.status
    ) {
      return try ModelContextEntry(
        id: id,
        turnID: turnID,
        sourceMessageID: sourceMessageID,
        body: .terminalToolResult(
          TerminalToolResultContext(
            callID: toolResult.callID,
            toolName: toolResult.toolName,
            status: projection.observation.status,
            content: content,
            toolReceipt: toolReceipt,
            toolCall: ToolCallModelMessage(request: request)
          )
        ),
        frozenContent: FrozenModelContent(role: .tool, content: content)
      )
    }

    let observationContext = ToolObservationContext(
      callID: toolResult.callID,
      toolName: toolResult.toolName,
      status: projection.observation.status,
      content: content,
      toolReceipt: toolReceipt,
      toolCall: ToolCallModelMessage(request: request),
      systemContext: normalizedSystemContext(systemContext)
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

  private static func isTerminalWriteResult(
    toolName: ToolName,
    status: ToolResultStatus
  ) -> Bool {
    status == .success && (toolName == .writeFile || toolName == .editFile)
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
    _ observation: ToolModelObservation,
    callID _: UUID,
    modelFollowUpNotice: String? = nil
  ) -> String {
    let resultKind = resultKind(for: observation)
    let duplicate = isDuplicateReplay(observation)
    let nextStep =
      normalizedModelFollowUpNotice(modelFollowUpNotice)
      ?? nextStepSummary(from: observation.blocks)
    let envelope = ToolResultJSONValue.object(
      envelopeFields(
        for: observation,
        resultKind: resultKind,
        duplicate: duplicate,
        nextStep: nextStep
      )
    )
    let content = observation.blocks
      .compactMap { renderContentBlock($0, omitNextStepSummary: nextStep != nil) }
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
    resultKind: String,
    duplicate: Bool,
    nextStep: String?
  ) -> [(String, ToolResultJSONValue)] {
    let primaryBlock = primaryResultBlock(from: observation.blocks)
    let replayedKind = primaryBlock.map(resultKind(for:))
    var fields: [(String, ToolResultJSONValue)] = [
      ("ok", .bool(observation.status == .success)),
      ("tool", .string(observation.toolName.rawValue)),
      ("status", .string(observation.status.rawValue)),
      ("result_kind", .string(resultKind)),
      ("duplicate", .bool(duplicate)),
    ]

    if duplicate {
      fields.append(("not_reexecuted", .bool(true)))
      if let replayedKind {
        fields.append(("replayed_result_kind", .string(replayedKind)))
      }
    }

    fields.append(
      (
        "affected_paths",
        .array(observation.affectedPaths.map { .string($0.rawValue) })
      ))

    if let primaryBlock {
      fields.append(contentsOf: metadataFields(for: primaryBlock))
    }
    if let nextAllowedActions = nextAllowedActions(for: observation.toolName, block: primaryBlock) {
      fields.append(
        (
          "next_allowed_actions",
          .array(nextAllowedActions.map { .string($0) })
        ))
    }
    if let forbiddenRepeat = forbiddenRepeat(for: observation.toolName, duplicate: duplicate) {
      fields.append(("forbidden_repeat", forbiddenRepeat))
    }
    if let nextStep {
      fields.append(("next_step", .string(nextStep)))
    }
    return fields
  }

  private static func metadataFields(for block: ToolObservationBlock)
    -> [(String, ToolResultJSONValue)]
  {
    switch block {
    case .summary:
      return []
    case .fileDisplayedToUser(
      let path,
      let range,
      let lineCount,
      let byteCount,
      let truncated,
      let redacted
    ):
      return [
        ("path", .string(path.rawValue)),
        ("range", range.map(ToolResultJSONValue.string) ?? .null),
        ("line_count", lineCount.map(ToolResultJSONValue.int) ?? .null),
        ("byte_count", byteCount.map(ToolResultJSONValue.int) ?? .null),
        ("truncated", .bool(truncated)),
        ("redacted", .bool(redacted)),
      ]
    case .fileContent(let path, let content):
      return [
        ("path", .string(path.rawValue)),
        ("truncated", .bool(content.truncated)),
        ("redacted", .bool(content.redacted)),
      ]
    case .fileList(let root, let entries, let totalCount, let truncated):
      return [
        ("path", .string(root.rawValue)),
        ("entry_count", .int(totalCount)),
        ("visible_entry_count", .int(entries.count)),
        ("truncated", .bool(truncated)),
      ]
    case .searchSnippets(let root, let pattern, let matches, let totalCount, let truncated):
      return [
        ("path", .string(root.rawValue)),
        ("pattern", .string(pattern)),
        ("match_count", .int(totalCount)),
        ("visible_match_count", .int(matches.count)),
        ("truncated", .bool(truncated)),
      ]
    case .editReceipt(let path, _, let matchStrategy):
      var fields: [(String, ToolResultJSONValue)] = [("path", .string(path.rawValue))]
      if let matchStrategy {
        fields.append(("match_strategy", .string(matchStrategy.rawValue)))
      }
      return fields
    case .commandResult(let result):
      var fields: [(String, ToolResultJSONValue)] = [
        ("command", .string(result.command)),
        ("exit_code", result.exitCode.map { .int(Int($0)) } ?? .null),
        ("timed_out", .bool(result.timedOut)),
        ("cancelled", .bool(result.cancelled)),
        ("stdout_present", .bool(!result.stdout.text.isEmpty)),
        ("stdout_truncated", .bool(result.stdout.truncated)),
        ("stderr_present", .bool(!result.stderr.text.isEmpty)),
        ("stderr_truncated", .bool(result.stderr.truncated)),
      ]
      if let outputRef = result.outputRef {
        fields.append(("output_ref", .string(outputRef)))
      }
      return fields
    case .diagnostics(let result):
      return [
        ("output_ref", .string(result.outputRef)),
        ("diagnostic_count", .int(result.diagnostics.count)),
      ]
    case .webSearch(let query, let provider, let results, let truncated):
      return [
        ("query", .string(query)),
        ("provider", .string(provider.displayName)),
        ("result_count", .int(results.count)),
        ("truncated", .bool(truncated)),
      ]
    case .webFetch(
      let url, let provider, let finalURL, let statusCode, let contentType, let content,
      let byteCount):
      return [
        ("url", .string(url)),
        ("final_url", .string(finalURL)),
        ("provider", .string(provider?.displayName ?? "unknown")),
        ("status_code", .int(statusCode)),
        ("content_type", contentType.map(ToolResultJSONValue.string) ?? .null),
        ("byte_count", .int(byteCount)),
        ("truncated", .bool(content.truncated)),
        ("redacted", .bool(content.redacted)),
      ]
    case .failure:
      return []
    }
  }

  private static func renderContentBlock(
    _ block: ToolObservationBlock,
    omitNextStepSummary: Bool
  ) -> String? {
    switch block {
    case .summary(let text):
      if omitNextStepSummary, isNextStepSummary(text) {
        return nil
      }
      if text == "Plan updated." {
        return text
      }
      return "Summary: \(sanitizedSummary(text))"
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
        "Truncated: \(truncated)",
        "Redacted: \(redacted)",
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
      return """
        Listed files under: \(root.rawValue)
        Total entries: \(totalCount)
        Truncated: \(truncated)
        Entries:
        \(body)
        """
    case .searchSnippets(let root, let pattern, let matches, let totalCount, let truncated):
      let body =
        matches.isEmpty
        ? "(no matches)"
        : matches.map { "\($0.path.rawValue):\($0.line): \($0.snippet)" }
          .joined(separator: "\n")
      return """
        Search root: \(root.rawValue)
        Pattern: \(pattern)
        Total matches: \(totalCount)
        Truncated: \(truncated)
        Matches:
        \(body)
        """
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
        "Timed out: \(result.timedOut)",
        "Cancelled: \(result.cancelled)",
        result.outputRef.map { "Output ref: \($0)" },
        "Stdout truncated: \(result.stdout.truncated)",
        result.stdoutOmittedChars > 0 ? "Stdout omitted chars: \(result.stdoutOmittedChars)" : nil,
        result.stdout.text.isEmpty ? nil : "Stdout preview:\n\(result.stdout.text)",
        "Stderr truncated: \(result.stderr.truncated)",
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
      return """
        Web search provider: \(provider.displayName)
        Query: \(query)
        Truncated: \(truncated)
        Results:
        \(body)
        """
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

  private static func resultKind(for observation: ToolModelObservation) -> String {
    if isDuplicateReplay(observation) {
      return "duplicate_replay"
    }
    if observation.toolName == .todoWrite,
      observation.status == .success,
      observation.blocks == [.summary("Plan updated.")]
    {
      return "plan_update"
    }
    guard let primaryBlock = primaryResultBlock(from: observation.blocks) else {
      return observation.status == .success ? "summary" : "failure"
    }
    return resultKind(for: primaryBlock)
  }

  private static func resultKind(for block: ToolObservationBlock) -> String {
    switch block {
    case .summary:
      return "summary"
    case .fileDisplayedToUser:
      return "file_displayed"
    case .fileContent:
      return "file_content"
    case .fileList:
      return "listing"
    case .searchSnippets:
      return "search_matches"
    case .editReceipt:
      return "edit_receipt"
    case .commandResult:
      return "command_result"
    case .diagnostics:
      return "diagnostics"
    case .webSearch:
      return "web_search"
    case .webFetch:
      return "web_fetch"
    case .failure:
      return "failure"
    }
  }

  private static func primaryResultBlock(from blocks: [ToolObservationBlock])
    -> ToolObservationBlock?
  {
    blocks.first { block in
      if case .summary = block {
        return false
      }
      return true
    }
  }

  private static func isDuplicateReplay(_ observation: ToolModelObservation) -> Bool {
    observation.blocks.contains { block in
      guard case .summary(let text) = block else {
        return false
      }
      return text.hasPrefix("Duplicate of call_")
    }
  }

  private static func nextStepSummary(from blocks: [ToolObservationBlock]) -> String? {
    blocks.compactMap { block -> String? in
      guard case .summary(let text) = block, isNextStepSummary(text) else {
        return nil
      }
      return text
    }.last
  }

  private static func isNextStepSummary(_ text: String) -> Bool {
    text.hasPrefix("Next step:")
  }

  private static func sanitizedSummary(_ text: String) -> String {
    guard text.hasPrefix("Duplicate of call_"),
      let separatorRange = text.range(of: ": ")
    else {
      return text
    }
    return "Duplicate replay: " + text[separatorRange.upperBound...]
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

  private static func nextAllowedActions(
    for toolName: ToolName,
    block: ToolObservationBlock?
  ) -> [String]? {
    switch toolName {
    case .listFiles, .globFiles, .searchFiles:
      return ["read_file", "final_answer"]
    case .readFile:
      return ["edit_file", "final_answer"]
    case .runCommand:
      if case .commandResult(let result) = block, result.outputRef != nil {
        return ["workspace_diagnostics", "final_answer"]
      }
      return ["final_answer"]
    case .webSearch:
      return ["web_fetch", "final_answer"]
    case .workspaceDiagnostics:
      return ["read_file", "edit_file", "final_answer"]
    case .workspaceDiff, .webFetch, .showFile, .editFile, .writeFile, .askUser, .browserRefresh,
      .browserInspect, .todoWrite, .invalid:
      return ["final_answer"]
    default:
      return ["final_answer"]
    }
  }

  private static func forbiddenRepeat(for toolName: ToolName, duplicate: Bool)
    -> ToolResultJSONValue?
  {
    guard duplicate else {
      return nil
    }
    return .object([
      ("tool", .string(toolName.rawValue)),
      ("same_arguments", .bool(true)),
    ])
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

  func rendered(indentation: Int = 0) -> String {
    switch self {
    case .object(let fields):
      guard !fields.isEmpty else {
        return "{}"
      }
      let indent = String(repeating: " ", count: indentation)
      let childIndent = String(repeating: " ", count: indentation + 2)
      let body = fields.map { key, value in
        "\(childIndent)\"\(Self.escaped(key))\": \(value.rendered(indentation: indentation + 2))"
      }.joined(separator: ",\n")
      return "{\n\(body)\n\(indent)}"
    case .array(let values):
      guard !values.isEmpty else {
        return "[]"
      }
      if values.allSatisfy(\.isScalar) {
        return "[" + values.map { $0.rendered(indentation: indentation) }.joined(separator: ", ")
          + "]"
      }
      let indent = String(repeating: " ", count: indentation)
      let childIndent = String(repeating: " ", count: indentation + 2)
      let body = values.map {
        "\(childIndent)\($0.rendered(indentation: indentation + 2))"
      }.joined(separator: ",\n")
      return "[\n\(body)\n\(indent)]"
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

  private var isScalar: Bool {
    switch self {
    case .string, .int, .bool, .null:
      return true
    case .object, .array:
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
