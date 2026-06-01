import Foundation

nonisolated protocol ChatModelRuntime: Sendable {
  func load(configuration: ChatModelConfiguration) async throws
  func unload() async
  func clearContext() async
  func contextUsage(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage
  func streamReply(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error>
}

nonisolated enum ChatModelStreamEvent: Sendable {
  case chunk(String)
  case completed(ChatGenerationMetrics?)
}

nonisolated struct MockChatRuntime: ChatModelRuntime {
  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
    try await Task.sleep(for: .milliseconds(350))
  }

  func unload() async {}

  func clearContext() async {}

  func contextUsage(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    let messageAttachments = messages.flatMap(\.attachments).map(\.content)
    let content =
      ([systemPrompt] + attachments.map(\.content) + messageAttachments + messages.map(\.content))
      .joined(separator: "\n")
    let tokenEstimate = content.split(whereSeparator: \.isWhitespace).count
    return ChatContextUsage(usedTokens: tokenEstimate, tokenLimit: nil)
  }

  func streamReply(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = attachments
    _ = systemPrompt
    _ = settings

    let lastMessage = messages.last(where: { $0.kind == .user })
    let attachmentSummary =
      lastMessage?.attachments.map(\.displayName).joined(separator: ", ") ?? ""
    let lastPrompt = lastMessage?.content ?? ""
    let chunks = [
      "Mock runtime received:\n\n",
      lastPrompt,
      attachmentSummary.isEmpty ? "" : "\n\nAttached files: \(attachmentSummary)",
      "\n\n",
      "Next step: replace MockChatRuntime with a Gemma MLX runtime behind the same ChatModelRuntime protocol.",
    ]

    return AsyncThrowingStream { continuation in
      let task = Task {
        for chunk in chunks {
          try? await Task.sleep(for: .milliseconds(120))
          guard !Task.isCancelled else { break }
          continuation.yield(.chunk(chunk))
        }

        continuation.yield(
          .completed(ChatGenerationMetrics(generatedTokenCount: 18, tokensPerSecond: 40))
        )
        continuation.finish()
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }
}
