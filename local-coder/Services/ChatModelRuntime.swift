import Foundation

protocol ChatModelRuntime: Sendable {
    func load(configuration: ChatModelConfiguration) async throws
    func streamReply(
        for messages: [ChatMessage],
        systemPrompt: String,
        settings: ChatGenerationSettings
    ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error>
}

enum ChatModelStreamEvent: Sendable {
    case chunk(String)
    case completed(ChatGenerationMetrics?)
}

struct MockChatRuntime: ChatModelRuntime {
    func load(configuration: ChatModelConfiguration) async throws {
        _ = configuration
        try await Task.sleep(for: .milliseconds(350))
    }

    func streamReply(
        for messages: [ChatMessage],
        systemPrompt: String,
        settings: ChatGenerationSettings
    ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
        _ = systemPrompt
        _ = settings

        let lastPrompt = messages.last(where: { $0.role == .user })?.content ?? ""
        let chunks = [
            "Mock runtime received:\n\n",
            lastPrompt,
            "\n\n",
            "Next step: replace MockChatRuntime with a Gemma MLX runtime behind the same ChatModelRuntime protocol."
        ]

        return AsyncThrowingStream { continuation in
            let task = Task {
                for chunk in chunks {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { break }
                    continuation.yield(.chunk(chunk))
                }

                continuation.yield(
                    .completed(ChatGenerationMetrics(generatedTokenCount: 18, tokensPerSecond: 40))
                )
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
