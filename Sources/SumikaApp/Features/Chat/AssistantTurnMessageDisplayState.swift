import SumikaCore

nonisolated extension AssistantTurnMessage {
  public var shouldShowAssistantPlaceholder: Bool {
    deliveryStatus == .streaming && content.isEmpty
  }

  public var canCopyAssistantContent: Bool {
    deliveryStatus != .streaming && !content.isEmpty
  }

  public var assistantPlaceholderTitle: String {
    "Generating"
  }
}
