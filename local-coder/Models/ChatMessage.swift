import Foundation

struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let role: ChatRole
    let content: String
    let attachments: [ChatAttachment]
    let generationMetrics: ChatGenerationMetrics?
    let toolCall: ToolCallModelMessage?
    let toolResult: ToolResultModelMessage?

    init(
        id: UUID = UUID(),
        role: ChatRole,
        content: String,
        attachments: [ChatAttachment] = [],
        generationMetrics: ChatGenerationMetrics? = nil,
        toolCall: ToolCallModelMessage? = nil,
        toolResult: ToolResultModelMessage? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.attachments = attachments
        self.generationMetrics = generationMetrics
        self.toolCall = toolCall
        self.toolResult = toolResult
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case attachments
        case generationMetrics
        case toolCall
        case toolCallRequest
        case toolResult
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(ChatRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        attachments = try container.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
        generationMetrics = try container.decodeIfPresent(
            ChatGenerationMetrics.self, forKey: .generationMetrics)
        if let toolCall = try container.decodeIfPresent(ToolCallModelMessage.self, forKey: .toolCall) {
            self.toolCall = toolCall
        } else if let legacyRequest = try container.decodeIfPresent(
            ToolCallRequest.self, forKey: .toolCallRequest
        ) {
            self.toolCall = ToolCallModelMessage(request: legacyRequest)
        } else {
            toolCall = nil
        }
        toolResult = try container.decodeIfPresent(ToolResultModelMessage.self, forKey: .toolResult)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(attachments, forKey: .attachments)
        try container.encodeIfPresent(generationMetrics, forKey: .generationMetrics)
        try container.encodeIfPresent(toolCall, forKey: .toolCall)
        try container.encodeIfPresent(toolResult, forKey: .toolResult)
    }
}

struct ChatGenerationMetrics: Codable, Equatable, Sendable {
    let generatedTokenCount: Int
    let tokensPerSecond: Double
}

enum ChatRole: String, Codable, Equatable, Sendable {
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
