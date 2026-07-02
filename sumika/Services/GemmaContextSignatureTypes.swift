import Foundation
import MLXLMCommon
import SumikaCore

nonisolated struct GemmaToolCallSnapshot: Equatable, Sendable {
  let id: String?
  let name: String
  let arguments: ToolCallArguments
}

nonisolated struct GemmaMessageSnapshot: Equatable, Sendable {
  let role: String
  let content: String
  let toolCalls: [GemmaToolCallSnapshot]
  let toolCallID: String?
  /// Identities of images prefilled with this message. Part of the prefix
  /// comparison so identical text with different images never reuses a
  /// cached session.
  let imageSignatures: [String]

  var hasToolMetadata: Bool {
    !toolCalls.isEmpty || toolCallID != nil
  }

  init(
    role: String,
    content: String,
    toolCalls: [GemmaToolCallSnapshot] = [],
    toolCallID: String? = nil,
    imageSignatures: [String] = []
  ) {
    self.role = role
    self.content = content
    self.toolCalls = toolCalls
    self.toolCallID = toolCallID
    self.imageSignatures = imageSignatures
  }
}
