import Foundation
import MLXLMCommon
import SumikaCore

nonisolated enum GemmaHistoryRenderer {
  /// Full history keeps the rendered transcript append-only so the cached
  /// KV prefix stays a byte-stable prefix of every later generation. Receipt
  /// compaction rewrites past observations and would invalidate the cache
  /// after every tool turn.
  nonisolated static let runtimeProjectionMode = ModelContextProjectionMode.fullHistory

  nonisolated static func chatMessage(
    from entry: ProjectedModelContextEntry,
    images: [UserInput.Image] = []
  ) -> Chat.Message {
    switch entry.role {
    case .user:
      return .user(entry.content, images: images)
    case .assistant:
      return .assistant(entry.content)
    }
  }

  nonisolated static func imageInputs(
    from attachments: [ChatAttachment],
    attachmentStore: ChatAttachmentStore = ChatAttachmentStore()
  ) throws -> [UserInput.Image] {
    try attachments.map { attachment in
      .url(try attachmentStore.validateStoredFile(for: attachment))
    }
  }

  nonisolated static func imageTypes(from attachments: [ChatAttachment]) -> [String]? {
    let types = attachments.compactMap(\.mimeType)
    return types.isEmpty ? nil : types
  }

  nonisolated static func imageByteCount(from attachments: [ChatAttachment]) -> Int? {
    let byteCount = attachments.reduce(0) { total, attachment in
      total + attachment.byteSize
    }
    return byteCount == 0 ? nil : byteCount
  }

  nonisolated static func templateMessages(
    from transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String
  ) throws -> [Chat.Message] {
    _ = attachments
    let history = chatMessages(
      from: normalizedSnapshots(
        from: transcript.projectedEntries(mode: runtimeProjectionMode)[...],
        dropsTrailingUser: false
      )
    )
    return try validatedTemplateMessages(
      runtimeHistoryMessages(systemPrompt: systemPrompt, history: history),
      allowsSystemPrompt: true
    )
  }

  nonisolated static func runtimeHistoryMessages(
    systemPrompt: String,
    history: [Chat.Message]
  ) throws -> [Chat.Message] {
    let normalizedSystemPrompt = normalizedRuntimeSystemPrompt(systemPrompt)
    let messages =
      if let normalizedSystemPrompt {
        [Chat.Message.system(normalizedSystemPrompt)] + history
      } else {
        history
      }
    return try validatedTemplateMessages(messages, allowsSystemPrompt: true)
  }

  nonisolated static func normalizedRuntimeSystemPrompt(_ systemPrompt: String) -> String? {
    ModelFacingPromptRenderer.normalizedSystemPrompt(systemPrompt)
  }

  nonisolated static func validatedTemplateMessages(
    _ messages: [Chat.Message],
    allowsSystemPrompt: Bool = false
  ) throws -> [Chat.Message] {
    let bodyMessages: ArraySlice<Chat.Message>
    if messages.first?.role == .system {
      guard allowsSystemPrompt else {
        throw GemmaMLXRuntimeError.invalidChatTemplateMessageSequence
      }
      bodyMessages = messages.dropFirst()
    } else {
      bodyMessages = messages[...]
    }

    guard bodyMessages.allSatisfy({ $0.role == .user || $0.role == .assistant }) else {
      throw GemmaMLXRuntimeError.invalidChatTemplateMessageSequence
    }

    for index in bodyMessages.indices.dropFirst() {
      let previousIndex = bodyMessages.index(before: index)
      if bodyMessages[previousIndex].role == bodyMessages[index].role {
        throw GemmaMLXRuntimeError.invalidChatTemplateMessageSequence
      }
    }

    return messages
  }

  /// Skips empty entries, merges consecutive same-role entries with a blank
  /// line, and carries image signatures. `dropsTrailingUser` removes trailing
  /// user turns for the generation history (the current prompt is rendered
  /// separately); the token-counting path keeps them. Single source for the
  /// template history, the generation history, and the cache prefix snapshot so
  /// the three can never drift.
  nonisolated private static func normalizedSnapshots(
    from entries: ArraySlice<ProjectedModelContextEntry>,
    dropsTrailingUser: Bool
  ) -> [GemmaMessageSnapshot] {
    var items: [GemmaMessageSnapshot] = []
    for entry in entries {
      guard !entry.content.isEmpty else {
        continue
      }
      let role: Chat.Message.Role = entry.role == .user ? .user : .assistant
      if let last = items.last, last.role == role.rawValue {
        items[items.count - 1] = GemmaMessageSnapshot(
          role: last.role,
          content: [last.content, entry.content].joined(separator: "\n\n"),
          imageSignatures: last.imageSignatures + entry.imageSignatures
        )
      } else {
        items.append(
          GemmaMessageSnapshot(
            role: role.rawValue,
            content: entry.content,
            imageSignatures: entry.imageSignatures
          )
        )
      }
    }

    if dropsTrailingUser {
      while items.last?.role == Chat.Message.Role.user.rawValue {
        items.removeLast()
      }
    }

    return items
  }

  /// Maps normalized snapshots back to `Chat.Message`. Snapshots from
  /// `normalizedSnapshots` only ever carry user/assistant roles.
  nonisolated static func chatMessages(
    from snapshots: [GemmaMessageSnapshot]
  ) -> [Chat.Message] {
    snapshots.map { snapshot in
      Chat.Message(
        role: snapshot.role == Chat.Message.Role.assistant.rawValue ? .assistant : .user,
        content: snapshot.content
      )
    }
  }

  nonisolated static func validatedChatMessages(
    from snapshots: [GemmaMessageSnapshot]
  ) throws -> [Chat.Message] {
    try validatedTemplateMessages(chatMessages(from: snapshots))
  }

  nonisolated static func generationHistoryMessages(
    from entries: ArraySlice<ProjectedModelContextEntry>
  ) throws -> [Chat.Message] {
    try validatedChatMessages(from: generationHistorySnapshot(from: entries))
  }

  nonisolated static func generationHistorySnapshot(
    from entries: ArraySlice<ProjectedModelContextEntry>
  ) -> [GemmaMessageSnapshot] {
    normalizedSnapshots(from: entries, dropsTrailingUser: true)
  }

  nonisolated static func generationHistoryMessages(
    from transcript: ModelContextSnapshot
  ) throws -> [Chat.Message] {
    let entries = transcript.projectedEntries(mode: runtimeProjectionMode)
    guard let lastUserIndex = entries.lastIndex(where: { $0.role == .user }) else {
      return []
    }
    return try generationHistoryMessages(from: entries[..<lastUserIndex])
  }
}
