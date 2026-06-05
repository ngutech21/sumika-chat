import Foundation

public enum WorkspaceInteractionMode: String, Codable, CaseIterable, Equatable, Sendable {
  case chat
  case inspect
  case agent

  public var displayName: String {
    switch self {
    case .chat:
      "Chat"
    case .inspect:
      "Inspect"
    case .agent:
      "Agent"
    }
  }
}
