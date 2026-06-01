import Foundation

nonisolated struct ChatGenerationSettings: Codable, Equatable, Sendable {
    var temperature: Double
    var topP: Double
    var topK: Int
    var maxTokens: Int

    static let codingDefault = ChatGenerationSettings(
        temperature: 0,
        topP: 1,
        topK: 0,
        maxTokens: 2048
    )
}
