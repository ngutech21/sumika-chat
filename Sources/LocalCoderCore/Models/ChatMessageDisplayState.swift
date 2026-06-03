extension ChatMessage {
  public var shouldShowAssistantPlaceholder: Bool {
    kind == .assistant
      && deliveryStatus == .streaming
      && (content.isEmpty || containsStreamingToolCallMarkup)
  }

  public var canCopyAssistantContent: Bool {
    kind == .assistant
      && deliveryStatus != .streaming
      && !containsStreamingToolCallMarkup
      && !content.isEmpty
  }

  public var assistantPlaceholderTitle: String {
    containsStreamingToolCallMarkup ? "Preparing tool call" : "Generating"
  }

  public var assistantPlaceholderSystemImage: String {
    containsStreamingToolCallMarkup ? "wrench.and.screwdriver" : "sparkles"
  }

  public var isDisplayedAsUser: Bool {
    kind == .user
  }

  public var displayTitle: String {
    kind.title
  }

  public var displaySystemImage: String {
    kind.systemImage
  }
}
