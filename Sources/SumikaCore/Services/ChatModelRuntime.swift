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
  case outputLimitReached(ChatGenerationOutputLimit)
}

package struct ChatGenerationOutputLimit: Equatable, Sendable {
  package let discardedToolProtocolTail: Bool

  package init(discardedToolProtocolTail: Bool) {
    self.discardedToolProtocolTail = discardedToolProtocolTail
  }
}

package struct ChatRuntimeToolContext: Equatable, Sendable {
  package var registry: ToolRegistry

  package init(registry: ToolRegistry) {
    self.registry = registry
  }
}

package struct ChatRuntimePromptPlan: Equatable, Sendable {
  package let stableInstructions: String
  package let transientInstructions: [String]
  package let toolContext: ChatRuntimeToolContext?

  package init(
    stableInstructions: String,
    transientInstructions: [String] = [],
    toolContext: ChatRuntimeToolContext? = nil
  ) {
    self.stableInstructions = stableInstructions
    self.transientInstructions =
      transientInstructions
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    self.toolContext = toolContext
  }

  func appendingTransientInstruction(_ instruction: String) -> Self {
    Self(
      stableInstructions: stableInstructions,
      transientInstructions: transientInstructions + [instruction],
      toolContext: toolContext
    )
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
