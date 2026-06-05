import Foundation

nonisolated extension AssistantTurnMessage {
  public var containsStreamingToolCallMarkup: Bool {
    let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedContent.isEmpty else {
      return false
    }

    return "<action".hasPrefix(trimmedContent) || trimmedContent.hasPrefix("<action")
  }

  public var shouldShowAssistantPlaceholder: Bool {
    deliveryStatus == .streaming
      && (content.isEmpty || containsStreamingToolCallMarkup)
  }

  public var canCopyAssistantContent: Bool {
    deliveryStatus != .streaming
      && !containsStreamingToolCallMarkup
      && !content.isEmpty
  }

  public var assistantPlaceholderTitle: String {
    containsStreamingToolCallMarkup ? "Preparing tool call" : "Generating"
  }

  public var assistantPlaceholderSystemImage: String {
    containsStreamingToolCallMarkup ? "wrench.and.screwdriver" : "sparkles"
  }
}
