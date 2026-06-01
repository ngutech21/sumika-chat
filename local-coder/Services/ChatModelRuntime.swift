import Foundation

protocol ChatModelRuntime: Sendable {
    func load(configuration: ChatModelConfiguration) async throws
    func generateReply(for messages: [ChatMessage]) async throws -> String
}

struct MockChatRuntime: ChatModelRuntime {
    func load(configuration: ChatModelConfiguration) async throws {
        _ = configuration
        try await Task.sleep(for: .milliseconds(350))
    }

    func generateReply(for messages: [ChatMessage]) async throws -> String {
        try await Task.sleep(for: .milliseconds(450))

        let lastPrompt = messages.last(where: { $0.role == .user })?.content ?? ""
        return """
        Mock runtime received:

        \(lastPrompt)

        Next step: replace MockChatRuntime with a Gemma MLX runtime behind the same ChatModelRuntime protocol.
        """
    }
}
