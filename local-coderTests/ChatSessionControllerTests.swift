import Foundation
import Testing
@testable import local_coder

@MainActor
struct ChatSessionControllerTests {
    @Test
    func canSendRequiresReadyModelNonEmptyDraftAndIdleGeneration() {
        let controller = ChatSessionController(runtime: FakeChatModelRuntime(), modelPath: "/tmp/model")

        controller.modelState = .ready
        controller.draft = "  hello  "

        #expect(controller.canSend)

        controller.draft = "   "
        #expect(!controller.canSend)

        controller.draft = "hello"
        controller.isGenerating = true
        #expect(!controller.canSend)
    }

    @Test
    func sendMessageStreamsAssistantReplyAndClearsDraftAndAttachments() async throws {
        let attachment = ChatAttachment(
            url: URL(filePath: "/tmp/source.swift"),
            displayName: "source.swift",
            kind: .text,
            content: "let value = 1"
        )
        let runtime = FakeChatModelRuntime(chunks: ["hello", " world"])
        let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
        controller.modelState = .ready
        controller.draft = "Explain this"
        controller.chatSession.attachments = [attachment]

        controller.sendMessage()

        try await waitUntil { !controller.isGenerating }

        #expect(controller.draft.isEmpty)
        #expect(controller.chatSession.attachments.isEmpty)
        #expect(controller.chatSession.messages.count == 2)
        #expect(controller.chatSession.messages[0].role == .user)
        #expect(controller.chatSession.messages[0].content == "Explain this")
        #expect(controller.chatSession.messages[0].attachments == [attachment])
        #expect(controller.chatSession.messages[1].role == .assistant)
        #expect(controller.chatSession.messages[1].content == "hello world")
        #expect(
            controller.chatSession.messages[1].generationMetrics == ChatGenerationMetrics(
                generatedTokenCount: 2,
                tokensPerSecond: 100
            )
        )
    }

    @Test
    func loadModelUsesDirectoryConfigurationAndUpdatesReadyState() async throws {
        let modelDirectory = FileManager.default.temporaryDirectory.appending(
            path: "local-coder-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try #"{"n_ctx":2048}"#.write(
            to: modelDirectory.appending(path: "config.json", directoryHint: .notDirectory),
            atomically: true,
            encoding: .utf8
        )
        let runtime = FakeChatModelRuntime()
        let controller = ChatSessionController(
            runtime: runtime,
            modelPath: modelDirectory.path(percentEncoded: false)
        )

        controller.loadModel()

        try await waitUntil { controller.modelState == .ready }

        let configuration = await runtime.loadedConfiguration
        #expect(configuration?.localModelDirectory == modelDirectory)
        #expect(configuration?.contextTokenLimit == 2048)
        #expect(controller.errorMessage == nil)
    }

    @Test
    func unloadModelReleasesRuntimeAndResetsModelState() async throws {
        let runtime = FakeChatModelRuntime()
        let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
        controller.modelState = .ready
        controller.contextUsage = ChatContextUsage(usedTokens: 12, tokenLimit: 128)
        controller.draft = "hello"

        controller.unloadModel()

        try await waitUntil { controller.modelState == .notLoaded }
        try await waitUntilAsync { await runtime.didUnload }

        #expect(await runtime.didUnload)
        #expect(controller.contextUsage == nil)
        #expect(!controller.canSend)
        #expect(controller.errorMessage == nil)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while !condition() {
            if start.duration(to: .now) > timeout {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitUntilAsync(
        timeout: Duration = .seconds(1),
        condition: @escaping () async -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while !(await condition()) {
            if start.duration(to: .now) > timeout {
                Issue.record("Timed out waiting for async condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor FakeChatModelRuntime: ChatModelRuntime {
    private let chunks: [String]
    private(set) var loadedConfiguration: ChatModelConfiguration?
    private(set) var didUnload = false

    init(chunks: [String] = []) {
        self.chunks = chunks
    }

    func load(configuration: ChatModelConfiguration) async throws {
        loadedConfiguration = configuration
    }

    func unload() async {
        didUnload = true
        loadedConfiguration = nil
    }

    func clearContext() async {}

    func contextUsage(
        for messages: [ChatMessage],
        attachments: [ChatAttachment],
        systemPrompt: String
    ) async throws -> ChatContextUsage {
        let usedTokens = ([systemPrompt] + messages.map(\.content) + attachments.map(\.content))
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .count
        return ChatContextUsage(usedTokens: usedTokens, tokenLimit: nil)
    }

    func streamReply(
        for messages: [ChatMessage],
        attachments: [ChatAttachment],
        systemPrompt: String,
        settings: ChatGenerationSettings
    ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
        _ = messages
        _ = attachments
        _ = systemPrompt
        _ = settings

        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(.chunk(chunk))
            }
            continuation.yield(
                .completed(ChatGenerationMetrics(generatedTokenCount: chunks.count, tokensPerSecond: 100))
            )
            continuation.finish()
        }
    }
}
