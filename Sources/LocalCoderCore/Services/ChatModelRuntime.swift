import Foundation

public protocol ChatModelRuntime: Sendable {
  func load(configuration: ChatModelConfiguration) async throws
  func unload() async
  func clearContext() async
  func generatedTokenCount(for text: String) async throws -> Int
  func contextUsage(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage
  func streamReply(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error>
  func streamReply(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings,
    toolContext: ChatRuntimeToolContext?
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error>
}

public enum ChatModelStreamEvent: Sendable {
  case chunk(String)
  case toolCall(ChatRuntimeToolCall)
  case completed(ChatGenerationMetrics?)
}

public struct ChatRuntimeToolContext: Equatable, Sendable {
  public var strategy: ToolCallingStrategy
  public var registry: ToolRegistry

  public init(strategy: ToolCallingStrategy, registry: ToolRegistry) {
    self.strategy = strategy
    self.registry = registry
  }
}

public struct ChatRuntimeToolCall: Equatable, Sendable {
  public var name: String
  public var arguments: ToolCallArguments
  public var rawText: String?

  public init(
    name: String,
    arguments: ToolCallArguments = [:],
    rawText: String? = nil
  ) {
    self.name = name
    self.arguments = arguments
    self.rawText = rawText
  }
}

extension ChatModelRuntime {
  public func streamReply(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings,
    toolContext: ChatRuntimeToolContext?
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = toolContext
    return try await streamReply(
      for: transcript,
      attachments: attachments,
      systemPrompt: systemPrompt,
      settings: settings
    )
  }

  public func generatedTokenCount(for text: String) async throws -> Int {
    text.split(whereSeparator: \.isWhitespace).count
  }
}

public struct MockChatRuntime: ChatModelRuntime {
  public init() {}

  public func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
    try await Task.sleep(for: .milliseconds(350))
  }

  public func unload() async {}

  public func clearContext() async {}

  public func generatedTokenCount(for text: String) async throws -> Int {
    text.split(whereSeparator: \.isWhitespace).count
  }

  public func contextUsage(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = systemPrompt
    let projectedContent =
      (try? transcript.runtimeProjectedEntries(mode: .compactedHistoryForLaterTurns).map(\.content))
      ?? transcript.projectedEntries(mode: .compactedHistoryForLaterTurns).map(\.content)
    let content = (attachments.map(\.content) + projectedContent).joined(separator: "\n")
    let tokenEstimate = content.split(whereSeparator: \.isWhitespace).count
    return ChatContextUsage(usedTokens: tokenEstimate, tokenLimit: nil)
  }

  public func streamReply(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = attachments
    _ = systemPrompt
    _ = settings

    let lastMessage = try transcript.runtimeProjectedEntries(mode: .compactedHistoryForLaterTurns)
      .last(where: { $0.role == .user })
    let attachmentSummary = attachments.map(\.displayName).joined(separator: ", ")
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
          .completed(
            ChatGenerationMetrics(generatedTokenCount: 18, tokensPerSecond: 40, durationMs: 450)
          )
        )
        continuation.finish()
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }
}
