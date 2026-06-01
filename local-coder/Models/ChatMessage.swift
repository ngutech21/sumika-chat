import Foundation

struct ChatMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: ChatRole
    let content: String
    let attachments: [ChatAttachment]
    let generationMetrics: ChatGenerationMetrics?

    init(
        id: UUID = UUID(),
        role: ChatRole,
        content: String,
        attachments: [ChatAttachment] = [],
        generationMetrics: ChatGenerationMetrics? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.attachments = attachments
        self.generationMetrics = generationMetrics
    }
}

struct ChatGenerationMetrics: Equatable, Sendable {
    let generatedTokenCount: Int
    let tokensPerSecond: Double
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
