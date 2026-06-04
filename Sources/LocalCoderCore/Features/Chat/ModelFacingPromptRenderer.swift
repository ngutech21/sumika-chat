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

  public static func renderedEntries(
    from messages: [ChatModelContextMessage],
    fallbackSystemPrompt: String
  ) throws -> [ModelContextEntry] {
    var pendingSystemContext: [String] = []
    var entries: [ModelContextEntry] = []
    let lastUserIndex = messages.lastIndex(where: { $0.role == .user })

    for index in messages.indices {
      let message = messages[index]
      guard !message.content.isEmpty else {
        continue
      }

      switch message.role {
      case .system:
        if let systemMessage = normalizedSystemPrompt(message.content) {
          pendingSystemContext.append(systemMessage)
        }
      case .assistant:
        if entries.isEmpty, !pendingSystemContext.isEmpty {
          let systemContent = systemInstructionContent(
            pendingSystemContext.joined(separator: "\n\n")
          )
          entries.append(
            try legacyEntry(
              id: message.id,
              turnID: message.turnID,
              role: .user,
              content: systemContent
            )
          )
        }
        pendingSystemContext.removeAll()
        entries.append(
          try assistantOutputEntry(
            id: message.id,
            turnID: message.turnID,
            sourceMessageID: message.sourceMessageID,
            content: message.content
          )
        )
      case .user:
        var systemContext: [String] = []
        if let snapshot = normalizedSystemPrompt(message.systemPromptSnapshot) {
          systemContext.append(snapshot)
        } else if index == lastUserIndex,
          let fallback = normalizedSystemPrompt(fallbackSystemPrompt)
        {
          systemContext.append(fallback)
        }
        systemContext.append(contentsOf: pendingSystemContext)
        pendingSystemContext.removeAll()
        entries.append(
          try userPromptEntry(
            id: message.id,
            turnID: message.turnID,
            sourceMessageID: message.sourceMessageID,
            prompt: message.content,
            attachments: message.attachments,
            systemContext: systemContext
          )
        )
      }
    }

    if entries.isEmpty, !pendingSystemContext.isEmpty {
      return [
        try legacyEntry(
          role: .user,
          content: systemInstructionContent(pendingSystemContext.joined(separator: "\n\n"))
        )
      ]
    }

    return try normalizedEntries(entries)
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

  private static func normalizedEntries(_ entries: [ModelContextEntry]) throws
    -> [ModelContextEntry]
  {
    try entries.reduce(into: []) { normalizedEntries, entry in
      guard !entry.frozenContent.content.isEmpty else {
        return
      }

      guard let lastEntry = normalizedEntries.last,
        lastEntry.frozenContent.role == entry.frozenContent.role
      else {
        normalizedEntries.append(entry)
        return
      }

      let mergedContent = [
        lastEntry.frozenContent.content,
        entry.frozenContent.content,
      ].joined(separator: "\n\n")
      let mergedEntry = try legacyEntry(
        id: lastEntry.id,
        turnID: lastEntry.turnID,
        sourceMessageID: lastEntry.sourceMessageID,
        role: lastEntry.frozenContent.role,
        content: mergedContent
      )
      normalizedEntries[normalizedEntries.index(before: normalizedEntries.endIndex)] = mergedEntry
    }
  }
}

public enum ModelFacingTranscriptBackfill {
  public static func transcript(
    from modelContextMessages: [ChatModelContextMessage],
    fallbackSystemPrompt: String
  ) -> ModelFacingTranscript {
    let entries =
      (try? ModelFacingPromptRenderer.renderedEntries(
        from: modelContextMessages,
        fallbackSystemPrompt: fallbackSystemPrompt
      )) ?? []
    return ModelFacingTranscript(entries: entries)
  }

  public static func transcript(
    from transcriptMessages: [ChatMessage],
    fallbackSystemPrompt: String
  ) -> ModelFacingTranscript {
    let modelContextMessages = ChatModelContextBackfill.messages(from: transcriptMessages)
    return transcript(from: modelContextMessages, fallbackSystemPrompt: fallbackSystemPrompt)
  }
}
