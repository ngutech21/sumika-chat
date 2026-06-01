import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

enum GemmaMLXRuntimeError: LocalizedError {
    case modelNotLoaded
    case missingUserMessage

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            "Load a local Gemma model before sending a message."
        case .missingUserMessage:
            "Enter a message before generating a reply."
        }
    }
}

final actor GemmaMLXRuntime: ChatModelRuntime {
    private var modelContainer: ModelContainer?
    private var session: ChatSession?
    private var contextTokenLimit: Int?

    func load(configuration: ChatModelConfiguration) async throws {
        configureMLXMemory()

        let modelConfiguration = ModelConfiguration(
            directory: configuration.localModelDirectory,
            extraEOSTokens: ["<end_of_turn>"]
        )

        let container = try await LLMModelFactory.shared.loadContainer(
            from: LocalDownloader(),
            using: LocalTokenizerLoader(),
            configuration: modelConfiguration
        )

        modelContainer = container
        contextTokenLimit = configuration.contextTokenLimit
        session = nil
    }

    func unload() async {
        await session?.clear()
        session = nil
        modelContainer = nil
        contextTokenLimit = nil
        Memory.clearCache()
    }

    func clearContext() async {
        await session?.clear()
        session = nil
        Memory.clearCache()
    }

    func contextUsage(
        for messages: [ChatMessage],
        attachments: [ChatAttachment],
        systemPrompt: String
    ) async throws -> ChatContextUsage {
        guard let modelContainer else {
            throw GemmaMLXRuntimeError.modelNotLoaded
        }

        let rawMessages = Self.contextMessages(
            from: messages,
            attachments: attachments,
            systemPrompt: systemPrompt
        )
        .map { ["role": $0.role.rawValue, "content": $0.content] as [String: any Sendable] }
        let usedTokens = try await modelContainer.perform { context in
            try context.tokenizer.applyChatTemplate(messages: rawMessages).count
        }

        return ChatContextUsage(usedTokens: usedTokens, tokenLimit: contextTokenLimit)
    }

    func streamReply(
        for messages: [ChatMessage],
        attachments: [ChatAttachment],
        systemPrompt: String,
        settings: ChatGenerationSettings
    ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
        guard let modelContainer else {
            throw GemmaMLXRuntimeError.modelNotLoaded
        }

        guard let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) else {
            throw GemmaMLXRuntimeError.missingUserMessage
        }

        let prompt = promptWithAttachments(
            prompt: messages[lastUserIndex].content,
            attachments: messages[lastUserIndex].attachments + attachments
        )
        let instructions = Self.normalizedSystemPrompt(systemPrompt)
        let generateParameters = GenerateParameters(
            maxTokens: settings.maxTokens,
            maxKVSize: contextTokenLimit,
            temperature: Float(settings.temperature),
            topP: Float(settings.topP),
            topK: settings.topK
        )
        let history = messages[..<lastUserIndex].compactMap(Chat.Message.init)
        let session = ChatSession(
            modelContainer,
            instructions: instructions,
            history: history,
            generateParameters: generateParameters
        )
        self.session = session

        let stream = session.streamDetails(to: prompt, images: [], videos: [])
        return Self.modelStream(from: stream)
    }

    private func configureMLXMemory() {
        if Memory.cacheLimit > Self.maxMLXCacheBytes {
            Memory.cacheLimit = Self.maxMLXCacheBytes
        }
    }

    nonisolated private static let maxMLXCacheBytes = 512 * 1024 * 1024

    nonisolated private static func modelStream(
        from stream: AsyncThrowingStream<Generation, Error>
    ) -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                defer {
                    Memory.clearCache()
                }

                do {
                    for try await generation in stream {
                        try Task.checkCancellation()

                        if let chunk = generation.chunk {
                            continuation.yield(.chunk(chunk))
                        }

                        if let info = generation.info {
                            let metrics = ChatGenerationMetrics(
                                generatedTokenCount: info.generationTokenCount,
                                tokensPerSecond: info.tokensPerSecond
                            )
                            continuation.yield(.completed(metrics))
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func contextMessages(
        from messages: [ChatMessage],
        attachments: [ChatAttachment],
        systemPrompt: String
    ) -> [Chat.Message] {
        var contextMessages: [Chat.Message] = []

        if let instructions = normalizedSystemPrompt(systemPrompt) {
            contextMessages.append(.system(instructions))
        }

        if messages.isEmpty, !attachments.isEmpty {
            contextMessages.append(.user(attachmentContextBlock(attachments)))
        } else if let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) {
            contextMessages.append(contentsOf: messages[..<lastUserIndex].compactMap(Chat.Message.init))
            let prompt = promptWithAttachments(
                prompt: messages[lastUserIndex].content,
                attachments: messages[lastUserIndex].attachments + attachments
            )
            contextMessages.append(.user(prompt))
            let remainingMessages = messages[messages.index(after: lastUserIndex)...]
            contextMessages.append(contentsOf: remainingMessages.compactMap(Chat.Message.init))
        } else {
            contextMessages.append(contentsOf: messages.compactMap(Chat.Message.init))
        }

        return contextMessages
    }

    private static func normalizedSystemPrompt(_ systemPrompt: String) -> String? {
        let effectiveSystemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return effectiveSystemPrompt.isEmpty ? nil : effectiveSystemPrompt
    }

}

private extension Chat.Message {
    init?(_ message: ChatMessage) {
        guard !message.content.isEmpty else {
            return nil
        }

        switch message.role {
        case .user:
            self = .user(promptWithAttachments(prompt: message.content, attachments: message.attachments))
        case .assistant:
            self = .assistant(message.content)
        }
    }
}

private func promptWithAttachments(
    prompt: String,
    attachments: [ChatAttachment]
) -> String {
    guard !attachments.isEmpty else {
        return prompt
    }

    return """
    User request:
    \(prompt)

    Attached files for this request:
    \(attachmentContextBlock(attachments))

    Use the attached file contents above when answering this request.
    If the user says "file" or "the file", they mean the attached file.
    """
}

private func attachmentContextBlock(_ attachments: [ChatAttachment]) -> String {
    attachments.enumerated().map { index, attachment in
        """
        File \(index + 1) of \(attachments.count)
        Name: \(attachment.displayName)
        Path: \(attachment.displayPath)
        <context_file path="\(attachment.displayPath)">
        \(attachment.content)
        </context_file>
        """
    }
    .joined(separator: "\n\n")
}

private struct LocalDownloader: MLXLMCommon.Downloader {
    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        throw ModelConfiguration.DirectoryError.unresolvedModelDirectory(id)
    }
}

private struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
        return LocalTokenizer(tokenizer: tokenizer)
    }
}

private struct LocalTokenizer: MLXLMCommon.Tokenizer {
    let tokenizer: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        tokenizer.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenizer.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        tokenizer.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        tokenizer.convertIdToToken(id)
    }

    var bosToken: String? {
        tokenizer.bosToken
    }

    var eosToken: String? {
        tokenizer.eosToken
    }

    var unknownToken: String? {
        tokenizer.unknownToken
    }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try tokenizer.applyChatTemplate(
            messages: messages,
            tools: tools,
            additionalContext: additionalContext
        )
    }
}
