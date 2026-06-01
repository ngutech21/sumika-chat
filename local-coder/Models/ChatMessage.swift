import Foundation

struct ChatMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: ChatRole
    let content: String

    init(id: UUID = UUID(), role: ChatRole, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

enum ChatRole: String, Equatable, Sendable {
    case user
    case assistant

    var title: String {
        switch self {
        case .user:
            "You"
        case .assistant:
            "Local Coder"
        }
    }

    var systemImage: String {
        switch self {
        case .user:
            "person.crop.circle"
        case .assistant:
            "cpu"
        }
    }
}
