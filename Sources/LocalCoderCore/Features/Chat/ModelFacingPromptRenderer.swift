import Foundation

public enum ModelFacingPromptRenderer {
  public static func userPromptEntry(
    id: UUID = UUID(),
    turnID: ChatTurnRecord.ID? = nil,
    sourceMessageID: ChatMessage.ID? = nil,
    prompt: String,
    attachments: [ChatAttachment] = [],
    systemContext: [String] = []
  ) throws -> ModelContextEntry {
    let renderedPrompt = promptWithAttachments(prompt: prompt, attachments: attachments)
    let content = userContent(renderedPrompt, systemContext: systemContext)
    return try ModelContextEntry(
      id: id,
      turnID: turnID,
      sourceMessageID: sourceMessageID,
      body: .userPrompt(
        UserPromptContext(
          prompt: prompt,
          attachmentNames: attachments.map(\.displayName),
          systemContext: normalizedSystemContext(systemContext)
        )
      ),
      frozenContent: FrozenModelContent(role: .user, content: content)
    )
  }

  public static func assistantOutputEntry(
    id: UUID = UUID(),
    turnID: ChatTurnRecord.ID? = nil,
    sourceMessageID: ChatMessage.ID? = nil,
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
    turnID: ChatTurnRecord.ID? = nil,
    sourceMessageID: ChatMessage.ID? = nil,
    toolResult: ToolResultModelMessage,
    systemContext: [String] = []
  ) throws -> ModelContextEntry {
    let rawContent = toolResult.modelContextContent
    if toolResult.modelContextRole == .assistant {
      return try ModelContextEntry(
        id: id,
        turnID: turnID,
        sourceMessageID: sourceMessageID,
        body: .terminalToolResult(
          TerminalToolResultContext(
            callID: toolResult.callID,
            toolName: toolResult.toolName,
            status: toolResult.preview.status,
            content: rawContent
          )
        ),
        frozenContent: FrozenModelContent(role: .assistant, content: rawContent)
      )
    }

    return try ModelContextEntry(
      id: id,
      turnID: turnID,
      sourceMessageID: sourceMessageID,
      body: .toolObservation(
        ToolObservationContext(
          callID: toolResult.callID,
          toolName: toolResult.toolName,
          status: toolResult.preview.status,
          content: rawContent
        )
      ),
      frozenContent: FrozenModelContent(
        role: .user,
        content: userContent(rawContent, systemContext: systemContext)
      )
    )
  }

  public static func finalToolResultPromptEntry(
    id: UUID = UUID(),
    turnID: ChatTurnRecord.ID? = nil,
    sourceMessageID: ChatMessage.ID? = nil,
    terminalToolResult: TerminalToolResultContext,
    followUpInstruction: String,
    systemContext: [String] = []
  ) throws -> ModelContextEntry {
    let prompt = [
      terminalToolResult.content,
      followUpInstruction,
    ]
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }
    .joined(separator: "\n\n")

    return try ModelContextEntry(
      id: id,
      turnID: turnID,
      sourceMessageID: sourceMessageID,
      body: .toolObservation(
        ToolObservationContext(
          callID: terminalToolResult.callID,
          toolName: terminalToolResult.toolName,
          status: terminalToolResult.status,
          content: prompt
        )
      ),
      frozenContent: FrozenModelContent(
        role: .user,
        content: userContent(prompt, systemContext: systemContext)
      )
    )
  }

  public static func legacyEntry(
    id: UUID = UUID(),
    turnID: ChatTurnRecord.ID? = nil,
    sourceMessageID: ChatMessage.ID? = nil,
    role: ModelContextRole,
    content: String
  ) throws -> ModelContextEntry {
    try ModelContextEntry(
      id: id,
      turnID: turnID,
      sourceMessageID: sourceMessageID,
      body: .legacy(LegacyModelContext(role: role, content: content)),
      frozenContent: FrozenModelContent(role: role, content: content)
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

  public static func promptWithAttachments(
    prompt: String,
    attachments: [ChatAttachment]
  ) -> String {
    guard !attachments.isEmpty else {
      return prompt
    }

    let context =
      attachments
      .map { attachment in
        """
        File: \(attachment.displayName)
        \(attachment.content)
        """
      }
      .joined(separator: "\n\n")

    return """
      User request:
      \(prompt)

      Attached context:
      \(context)
      """
  }

  public static func systemInstructionContent(_ systemContext: String) -> String {
    """
    System instructions:
    \(systemContext)
    """
  }

  public static func normalizedSystemPrompt(_ systemPrompt: String?) -> String? {
    guard let systemPrompt else {
      return nil
    }
    return normalizedSystemPrompt(systemPrompt)
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
}
