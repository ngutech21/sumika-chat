import Foundation

struct ChatSessionState: Equatable, Sendable {
    var messages: [ChatMessage]
    var attachments: [ChatAttachment]
    var systemPrompt: String
    var generationSettings: ChatGenerationSettings

    static let codingDefault = ChatSessionState(
        messages: [],
        attachments: [],
        systemPrompt: ChatPromptDefaults.codingSystemPrompt,
        generationSettings: .codingDefault
    )
}
