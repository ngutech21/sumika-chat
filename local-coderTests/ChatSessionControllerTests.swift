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
    func sendMessageRunsReadOnlyToolCallAndContinuesWithToolResultContext() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appending(
            path: "local-coder-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "project notes".write(
            to: rootURL.appending(path: "README.md"),
            atomically: true,
            encoding: .utf8
        )
        let sessionID = UUID()
        let workspace = Workspace(
            name: "Project",
            rootURL: URL(filePath: Workspace.normalizedPath(for: rootURL)),
            sessions: [
                CodingSession(
                    id: sessionID,
                    selectedModelID: ManagedModelCatalog.defaultModelID,
                    systemPrompt: ChatPromptDefaults.codingSystemPrompt,
                    generationSettings: .codingDefault
                )
            ]
        )
        let runtime = FakeChatModelRuntime(turns: [
            [
                """
                <action name="read_file">
                <path>README.md</path>
                </action>
                """
            ],
            ["The README says project notes."]
        ])
        let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
        controller.modelState = .ready
        controller.draft = "Read the README"

        controller.sendMessage(in: workspace, sessionID: sessionID)

        try await waitUntil { !controller.isGenerating }

        #expect(controller.chatSession.toolCalls.count == 1)
        #expect(controller.chatSession.toolCalls[0].status == .completed)
        #expect(controller.chatSession.toolCalls[0].resultPreview?.text == "project notes")
        #expect(controller.chatSession.messages.count == 4)
        #expect(controller.chatSession.messages[1].role == .assistant)
        #expect(controller.chatSession.messages[1].toolCallRequest?.toolName == .readFile)
        #expect(controller.chatSession.messages[1].toolCallRequest?.arguments["path"] == .string("README.md"))
        #expect(controller.chatSession.messages[2].role == .user)
        #expect(controller.chatSession.messages[2].toolResult?.toolName == .readFile)
        #expect(controller.chatSession.messages[2].toolResult?.preview.status == .success)
        let toolResultMessage = controller.chatSession.messages[2].content
        #expect(toolResultMessage.contains("<tool_result name=\"read_file\" status=\"success\">"))
        #expect(toolResultMessage.contains("project notes"))
        #expect(controller.chatSession.messages[3].content == "The README says project notes.")

        let capturedMessages = await runtime.capturedMessages
        #expect(capturedMessages.count == 2)
        #expect(capturedMessages[1].contains { message in
            message.role == .user && message.content.contains("project notes")
        })
        let capturedSystemPrompts = await runtime.capturedSystemPrompts
        #expect(capturedSystemPrompts.count == 2)
        #expect(capturedSystemPrompts[0].contains("read_file"))
        #expect(capturedSystemPrompts[0].contains("list_files"))
        #expect(capturedSystemPrompts[1].contains("Do not emit another <action> tag"))
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
    func loadModelCapsContextLimitAtUserRequestedSetting() async throws {
        let modelDirectory = FileManager.default.temporaryDirectory.appending(
            path: "local-coder-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try #"{"max_position_embeddings":131072}"#.write(
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
        #expect(configuration?.contextTokenLimit == 65_536)
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
    private let turns: [[String]]
    private var streamReplyCount = 0
    private(set) var loadedConfiguration: ChatModelConfiguration?
    private(set) var didUnload = false
    private(set) var capturedMessages: [[ChatMessage]] = []
    private(set) var capturedSystemPrompts: [String] = []

    init(chunks: [String] = []) {
        self.turns = [chunks]
    }

    init(turns: [[String]]) {
        self.turns = turns
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
        _ = attachments
        _ = settings

        capturedMessages.append(messages)
        capturedSystemPrompts.append(systemPrompt)
        let chunks = turns[min(streamReplyCount, turns.count - 1)]
        streamReplyCount += 1

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
