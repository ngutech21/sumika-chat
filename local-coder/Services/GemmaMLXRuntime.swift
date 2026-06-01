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

        session = ChatSession(container)
    }

    func generateReply(for messages: [ChatMessage]) async throws -> String {
        guard let session else {
            throw GemmaMLXRuntimeError.modelNotLoaded
        }

        guard let prompt = messages.last(where: { $0.role == .user })?.content else {
            throw GemmaMLXRuntimeError.missingUserMessage
        }

        return try await session.respond(to: prompt)
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
