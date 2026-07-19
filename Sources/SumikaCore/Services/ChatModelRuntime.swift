import Foundation

public protocol ChatModelRuntime: Sendable {
  func load(configuration: ChatModelConfiguration) async throws
  func unload() async
  func clearContext() async
  func runtimeCacheDebugSnapshot() async -> RuntimeCacheDebugSnapshot?
  func generatedTokenCount(for text: String) async throws -> Int
  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error>
}

public enum ChatModelStreamEvent: Sendable {
  case chunk(String)
  case thinkingChunk(String)
  case toolCall(ChatRuntimeToolCall)
  case completed(ChatGenerationMetrics?)
}

public struct ChatRuntimeToolContext: Equatable, Sendable {
  public var registry: ToolRegistry
  public var cacheSystemPrompt: String?

  public init(
    registry: ToolRegistry,
    cacheSystemPrompt: String? = nil
  ) {
    self.registry = registry
    self.cacheSystemPrompt = cacheSystemPrompt
  }
}

public struct ChatRuntimePromptPlan: Equatable, Sendable {
  public let stableInstructions: String
  public let transientInstructions: [String]
  public let toolContext: ChatRuntimeToolContext?
  public let cacheIdentityInstructions: String

  public init(
    stableInstructions: String,
    transientInstructions: [String] = [],
    toolContext: ChatRuntimeToolContext? = nil,
    cacheIdentityInstructions: String? = nil
  ) {
    self.stableInstructions = stableInstructions
    self.transientInstructions =
      transientInstructions
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    self.toolContext = toolContext
    self.cacheIdentityInstructions = cacheIdentityInstructions ?? stableInstructions
  }
}

public struct ChatRuntimeToolCall: Equatable, Sendable {
  public var id: String?
  public var name: String
  public var arguments: ToolCallArguments

  public init(
    id: String? = nil,
    name: String,
    arguments: ToolCallArguments = [:]
  ) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }
}

extension ChatModelRuntime {
  public func runtimeCacheDebugSnapshot() async -> RuntimeCacheDebugSnapshot? {
    nil
  }

  public func generatedTokenCount(for text: String) async throws -> Int {
    text.split(whereSeparator: \.isWhitespace).count
  }
}
