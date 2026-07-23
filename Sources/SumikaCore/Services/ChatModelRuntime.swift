import Foundation

package protocol ChatModelRuntime: Sendable {
  func load(configuration: ChatModelConfiguration) async throws
  func unload() async
  func clearContext() async
  func runtimeCacheDebugSnapshot() async -> RuntimeCacheDebugSnapshot?
  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error>
}

package enum ChatModelStreamEvent: Sendable {
  case chunk(String)
  case thinkingChunk(String)
  case toolCall(ChatRuntimeToolCall)
  case completed(ChatGenerationMetrics?)
}

package struct ChatRuntimeToolContext: Equatable, Sendable {
  package var registry: ToolRegistry
  package var cacheSystemPrompt: String?

  package init(
    registry: ToolRegistry,
    cacheSystemPrompt: String? = nil
  ) {
    self.registry = registry
    self.cacheSystemPrompt = cacheSystemPrompt
  }
}

package struct ChatRuntimePromptPlan: Equatable, Sendable {
  package let stableInstructions: String
  package let transientInstructions: [String]
  package let toolContext: ChatRuntimeToolContext?
  package let cacheIdentityInstructions: String

  package init(
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

package struct ChatRuntimeToolCall: Equatable, Sendable {
  package var id: String?
  package var name: String
  package var arguments: ToolCallArguments

  package init(
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
  package func runtimeCacheDebugSnapshot() async -> RuntimeCacheDebugSnapshot? {
    nil
  }
}
