import Foundation
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

    func load(configuration: ChatModelConfiguration) async throws {
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
        session = nil
    }

    func clearContext() async {
        await session?.clear()
        session = nil
    }

    func streamReply(
        for messages: [ChatMessage],
        systemPrompt: String,
        settings: ChatGenerationSettings
    ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
        guard let modelContainer else {
            throw GemmaMLXRuntimeError.modelNotLoaded
        }

        guard let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) else {
            throw GemmaMLXRuntimeError.missingUserMessage
        }

        let prompt = messages[lastUserIndex].content
        let effectiveSystemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = effectiveSystemPrompt.isEmpty ? nil : effectiveSystemPrompt
        let generateParameters = GenerateParameters(
            maxTokens: settings.maxTokens,
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
        return AsyncThrowingStream { continuation in
            let task = Task {
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
}

private extension Chat.Message {
    init?(_ message: ChatMessage) {
        guard !message.content.isEmpty else {
            return nil
        }

        switch message.role {
        case .user:
            self = .user(message.content)
        case .assistant:
            self = .assistant(message.content)
        }
    }
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
