import Foundation

struct ChatSessionState: Equatable, Sendable {
    var messages: [ChatMessage]
    var systemPrompt: String
    var generationSettings: ChatGenerationSettings

    static let codingDefault = ChatSessionState(
        messages: [],
        systemPrompt: ChatPromptDefaults.codingSystemPrompt,
        generationSettings: .codingDefault
    )
}
