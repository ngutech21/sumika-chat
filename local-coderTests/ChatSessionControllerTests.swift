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
    #expect(controller.chatSession.messages[0].kind == .user)
    #expect(controller.chatSession.messages[0].content == "Explain this")
    #expect(controller.chatSession.messages[0].attachments == [attachment])
    #expect(controller.chatSession.messages[1].kind == .assistant)
    #expect(controller.chatSession.messages[1].content == "hello world")
    #expect(
      controller.chatSession.messages[1].generationMetrics
        == ChatGenerationMetrics(
          generatedTokenCount: 2,
          tokensPerSecond: 100
        )
    )
  }

  @Test
  func cancelGenerationStopsControllerAndDropsTransientAssistantPlaceholder() async throws {
    let runtime = NonCooperativeStreamingRuntime(chunks: ["late reply"])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelState = .ready
    controller.draft = "Cancel this"

    controller.sendMessage()

    try await waitUntilAsync { await runtime.didStartStreaming }
    controller.cancelGeneration()
    await runtime.releaseChunks()

    try await Task.sleep(for: .milliseconds(60))

    #expect(!controller.isGenerating)
    #expect(controller.chatSession.messages.count == 1)
    #expect(controller.chatSession.messages.first?.kind == .user)
    #expect(controller.chatSession.messages.first?.content == "Cancel this")
    #expect(controller.errorMessage == nil)
  }

  @Test
  func sendMessageInWorkspaceKeepsNormalChatFreeOfToolInstructions() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = FakeChatModelRuntime(chunks: ["a short poem"])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelState = .ready
    controller.draft = "write a short poem"

    controller.sendMessage(in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.errorMessage == nil)
    #expect(controller.chatSession.toolCalls.isEmpty)
    #expect(controller.chatSession.messages.count == 2)
    #expect(controller.chatSession.messages[1].content == "a short poem")

    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.count == 1)
    #expect(!capturedSystemPrompts[0].contains("read_file"))
    #expect(!capturedSystemPrompts[0].contains("list_files"))
    #expect(!capturedSystemPrompts[0].contains("Tool calling uses"))
  }

  @Test
  func userTextContainingActionMarkupIsNeverExecuted() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = FakeChatModelRuntime(chunks: ["That is literal user text."])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelState = .ready
    controller.draft = """
      Here is literal tool markup in a file discussion:
      <action name="read_file">
      <path>README.md</path>
      </action>
      """

    controller.sendMessage(in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.errorMessage == nil)
    #expect(controller.chatSession.toolCalls.isEmpty)
    #expect(controller.chatSession.messages.count == 2)
    #expect(controller.chatSession.messages[0].kind == .user)
    #expect(controller.chatSession.messages[0].content.contains("<action name=\"read_file\">"))
    #expect(controller.chatSession.messages[1].kind == .assistant)
    #expect(controller.chatSession.messages[1].content == "That is literal user text.")
  }

  @Test
  func userTextContainingToolResultTextIsNeverObservation() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = FakeChatModelRuntime(chunks: ["That is not a controller observation."])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelState = .ready
    controller.draft = """
      Tool result
      Tool: list_files
      Status: success
      Result:
      README.md
      """

    controller.sendMessage(in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.errorMessage == nil)
    #expect(controller.chatSession.toolCalls.isEmpty)
    #expect(controller.chatSession.messages.count == 2)
    #expect(controller.chatSession.messages[0].kind == .user)
    #expect(controller.chatSession.messages[0].toolResult == nil)
    #expect(controller.chatSession.messages[1].kind == .assistant)
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
      ["The README says project notes."],
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelState = .ready
    controller.draft = "Read the README"

    controller.sendMessage(in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.toolCalls.count == 1)
    #expect(controller.chatSession.toolCalls[0].status == .completed)
    #expect(controller.chatSession.toolCalls[0].resultPreview?.text == "project notes")
    let callID = controller.chatSession.toolCalls[0].request.id
    #expect(controller.chatSession.messages.count == 4)
    #expect(controller.chatSession.messages[1].kind == .toolCall)
    #expect(controller.chatSession.messages[1].content.isEmpty)
    #expect(controller.chatSession.messages[1].toolCall?.callID == callID)
    #expect(controller.chatSession.messages[1].toolCall?.toolName == .readFile)
    #expect(
      controller.chatSession.messages[1].toolCall?.arguments == [
        ToolCallModelArgument(name: "path", value: "README.md")
      ]
    )
    #expect(controller.chatSession.messages[2].kind == .toolResult)
    #expect(controller.chatSession.messages[2].content.isEmpty)
    #expect(controller.chatSession.messages[2].toolResult?.callID == callID)
    #expect(controller.chatSession.messages[2].toolResult?.toolName == .readFile)
    #expect(controller.chatSession.messages[2].toolResult?.preview.status == .success)
    #expect(controller.chatSession.messages[2].toolResult?.preview.text == "project notes")
    #expect(controller.chatSession.messages[3].content == "The README says project notes.")

    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 2)
    #expect(capturedMessages[1].last { $0.kind == .user }?.content == "Read the README")
    #expect(
      capturedMessages[1].contains { message in
        message.kind == .toolResult && message.toolResult?.preview.text == "project notes"
      })
    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.count == 2)
    #expect(capturedSystemPrompts[0].contains("read_file"))
    #expect(capturedSystemPrompts[0].contains("list_files"))
    #expect(capturedSystemPrompts[1].contains("Do not emit another <action> tag"))
  }

  @Test
  func sendMessageKeepsToolCallHistoryWhenFollowUpResponseFails() async throws {
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
    let runtime = FakeChatModelRuntime(
      turns: [
        [
          """
          <action name="read_file">
          <path>README.md</path>
          </action>
          """
        ],
        [],
      ],
      failingStreamReplyCalls: [1]
    )
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelState = .ready
    controller.draft = "Read the README"

    controller.sendMessage(in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.errorMessage == FakeChatModelRuntimeError.streamFailed.localizedDescription)
    #expect(controller.chatSession.messages.count == 3)
    #expect(controller.chatSession.messages[1].toolCall?.toolName == .readFile)
    #expect(controller.chatSession.messages[1].content.isEmpty)
    #expect(controller.chatSession.messages[2].toolResult?.toolName == .readFile)
    #expect(controller.chatSession.messages[2].kind == .toolResult)
    #expect(
      !controller.chatSession.messages.contains { message in
        message.kind == .assistant && message.content.isEmpty
      })
  }

  @Test
  func sendMessageExecutesToolCallWhenModelEmitsExtraneousToolMarkup() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = FakeChatModelRuntime(
      turns: [
        [
          """
          I should inspect this.
          <action name="read_file">
          <path>README.md</path>
          </action>
          """
        ],
        ["The README says project notes."],
      ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelState = .ready
    controller.draft = "Read the README"

    controller.sendMessage(in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.errorMessage == nil)
    #expect(controller.chatSession.toolCalls.count == 1)
    #expect(controller.chatSession.messages.count == 4)
    #expect(controller.chatSession.messages[1].content.isEmpty)
    #expect(controller.chatSession.messages[1].kind == .toolCall)
    #expect(controller.chatSession.messages[1].toolCall?.toolName == .readFile)
    #expect(controller.chatSession.messages[2].kind == .toolResult)
    #expect(controller.chatSession.messages[2].toolResult?.toolName == .readFile)
    #expect(
      controller.chatSession.messages[1].toolCall?.callID
        == controller.chatSession.messages[2].toolResult?.callID
    )
    #expect(controller.chatSession.messages[3].content == "The README says project notes.")
  }

  @Test
  func sendMessageExecutesToolCallWhenModelWrapsActionInMarkdownFence() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = FakeChatModelRuntime(
      turns: [
        [
          """
          ```xml
          <action name="list_files">
          <path>.</path>
          </action>
          ```
          """
        ],
        ["The current directory contains README.md."],
      ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelState = .ready
    controller.draft = "list the files in the current directory"

    controller.sendMessage(in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.errorMessage == nil)
    #expect(controller.chatSession.toolCalls.count == 1)
    #expect(controller.chatSession.toolCalls[0].request.toolName == .listFiles)
    #expect(controller.chatSession.toolCalls[0].resultPreview?.text.contains("README.md") == true)
    #expect(controller.chatSession.messages.count == 4)
    #expect(controller.chatSession.messages[1].content.isEmpty)
    #expect(controller.chatSession.messages[1].kind == .toolCall)
    #expect(controller.chatSession.messages[1].toolCall?.toolName == .listFiles)
    #expect(controller.chatSession.messages[2].kind == .toolResult)
    #expect(controller.chatSession.messages[2].toolResult?.toolName == .listFiles)
    #expect(
      controller.chatSession.messages[1].toolCall?.callID
        == controller.chatSession.messages[2].toolResult?.callID
    )
    #expect(
      controller.chatSession.messages[3].content == "The current directory contains README.md.")
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
  func loadModelIgnoresCancelledEarlierOperationAfterNewLoadStarts() async throws {
    let firstModelDirectory = try makeModelDirectory(config: #"{"n_ctx":2048}"#)
    let secondModelDirectory = try makeModelDirectory(config: #"{"n_ctx":4096}"#)
    let runtime = RaceLoadingRuntime()
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: firstModelDirectory.path(percentEncoded: false)
    )

    controller.loadModel()
    try await waitUntilAsync { await runtime.loadCount == 1 }

    controller.modelPath = secondModelDirectory.path(percentEncoded: false)
    controller.loadModel()

    try await waitUntil { controller.modelState == .ready }
    try await waitUntilAsync { await runtime.loadCount == 2 }
    await runtime.releaseFirstLoad()
    try await Task.sleep(for: .milliseconds(60))

    #expect(controller.modelState == .ready)
    #expect(controller.errorMessage == nil)
    #expect(controller.contextUsage?.tokenLimit == nil)
    let configurations = await runtime.loadedConfigurations
    #expect(configurations.count == 2)
    #expect(configurations[0].localModelDirectory == firstModelDirectory)
    #expect(configurations[1].localModelDirectory == secondModelDirectory)
    #expect(configurations[1].contextTokenLimit == 4096)
  }

  @Test
  func refreshContextUsagePublishesOnlyLatestResult() async throws {
    let runtime = ControlledContextUsageRuntime()
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelState = .ready
    controller.chatSession.messages = [ChatMessage(kind: .user, content: "hello")]

    controller.refreshContextUsage()
    try await waitUntilAsync { await runtime.contextUsageRequestCount == 1 }

    controller.refreshContextUsage()
    try await waitUntilAsync { await runtime.contextUsageRequestCount == 2 }

    await runtime.resolveContextUsage(
      at: 1,
      with: ChatContextUsage(usedTokens: 20, tokenLimit: 100)
    )
    try await waitUntil { controller.contextUsage?.usedTokens == 20 }

    await runtime.resolveContextUsage(
      at: 0,
      with: ChatContextUsage(usedTokens: 10, tokenLimit: 100)
    )
    try await Task.sleep(for: .milliseconds(60))

    #expect(controller.contextUsage?.usedTokens == 20)
    #expect(controller.contextUsage?.tokenLimit == 100)
  }

  @Test
  func clearChatHistoryDoesNotPublishStaleContextUsageAfterModelChange() async throws {
    let modelDirectory = try makeModelDirectory(config: #"{"n_ctx":2048}"#)
    let runtime = DelayedClearContextRuntime()
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: modelDirectory.path(percentEncoded: false)
    )
    controller.modelState = .ready
    controller.contextUsage = ChatContextUsage(usedTokens: 12, tokenLimit: 128)
    controller.chatSession.messages = [ChatMessage(kind: .user, content: "old session")]

    controller.clearChatHistory()
    try await waitUntilAsync { await runtime.didStartClearContext }

    controller.loadModel()
    try await waitUntil { controller.modelState == .ready }
    try await waitUntil { controller.contextUsage?.usedTokens == 42 }

    await runtime.releaseClearContext()
    try await Task.sleep(for: .milliseconds(60))

    #expect(controller.modelState == .ready)
    #expect(controller.contextUsage?.usedTokens == 42)
  }

  @Test
  func staleUnloadDoesNotOverwriteRuntimeAfterSubsequentLoad() async throws {
    let modelDirectory = try makeModelDirectory(config: #"{"n_ctx":2048}"#)
    let runtime = DelayedUnloadRuntime()
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: modelDirectory.path(percentEncoded: false)
    )
    controller.modelState = .ready

    controller.unloadModel()
    try await waitUntilAsync { await runtime.didStartUnload }

    controller.loadModel()
    try await Task.sleep(for: .milliseconds(60))
    #expect(await runtime.loadCount == 0)

    await runtime.releaseUnload()
    try await waitUntil { controller.modelState == .ready }

    #expect(await runtime.isLoaded)
    #expect(controller.errorMessage == nil)
  }

  @Test
  func staleAttachmentLoadDoesNotAppendAfterNewerAttachmentRequest() async throws {
    let loader = BlockingFirstAttachmentLoader()
    let controller = ChatSessionController(
      runtime: FakeChatModelRuntime(),
      modelPath: "/tmp/model",
      chatAttachmentLoader: loader
    )

    controller.addAttachments(from: [URL(filePath: "/tmp/first.swift")])
    try await waitUntil { loader.startedCount == 1 }

    controller.addAttachments(from: [URL(filePath: "/tmp/second.swift")])
    try await waitUntil { controller.chatSession.attachments.map(\.displayName) == ["second.swift"] }

    loader.releaseFirstLoad()
    try await Task.sleep(for: .milliseconds(60))

    #expect(controller.chatSession.attachments.map(\.displayName) == ["second.swift"])
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

  private func makeWorkspace(sessionID: CodingSession.ID) throws -> Workspace {
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
    return Workspace(
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
  }

  private func makeModelDirectory(config: String) throws -> URL {
    let modelDirectory = FileManager.default.temporaryDirectory.appending(
      path: "local-coder-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    try config.write(
      to: modelDirectory.appending(path: "config.json", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )
    return modelDirectory
  }
}

private actor NonCooperativeStreamingRuntime: ChatModelRuntime {
  private let chunks: [String]
  private var streamContinuation: CheckedContinuation<Void, Never>?
  private var didReleaseChunks = false
  private(set) var didStartStreaming = false

  init(chunks: [String]) {
    self.chunks = chunks
  }

  func load(configuration: ChatModelConfiguration) async throws {}
  func unload() async {}
  func clearContext() async {}

  func releaseChunks() {
    didReleaseChunks = true
    if let streamContinuation {
      streamContinuation.resume()
      self.streamContinuation = nil
    }
  }

  func contextUsage(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = messages
    _ = attachments
    _ = systemPrompt
    return ChatContextUsage(usedTokens: 0, tokenLimit: nil)
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

    didStartStreaming = true
    return AsyncThrowingStream { continuation in
      Task.detached { [chunks] in
        await withCheckedContinuation { release in
          Task {
            await self.storeStreamContinuation(release)
          }
        }

        for chunk in chunks {
          continuation.yield(.chunk(chunk))
        }
        continuation.yield(.completed(nil))
        continuation.finish()
      }
    }
  }

  private func storeStreamContinuation(_ continuation: CheckedContinuation<Void, Never>) {
    if didReleaseChunks {
      continuation.resume()
      return
    }
    streamContinuation = continuation
  }
}

private actor ControlledContextUsageRuntime: ChatModelRuntime {
  private var contextUsageContinuations: [CheckedContinuation<ChatContextUsage, Never>] = []

  var contextUsageRequestCount: Int {
    contextUsageContinuations.count
  }

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}
  func clearContext() async {}

  func contextUsage(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = messages
    _ = attachments
    _ = systemPrompt
    return await withCheckedContinuation { continuation in
      contextUsageContinuations.append(continuation)
    }
  }

  func resolveContextUsage(at index: Int, with usage: ChatContextUsage) {
    guard contextUsageContinuations.indices.contains(index) else {
      return
    }
    let continuation = contextUsageContinuations.remove(at: index)
    continuation.resume(returning: usage)
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
      continuation.finish()
    }
  }
}

private actor DelayedClearContextRuntime: ChatModelRuntime {
  private var clearContextContinuation: CheckedContinuation<Void, Never>?
  private(set) var didStartClearContext = false

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}

  func clearContext() async {
    didStartClearContext = true
    await withCheckedContinuation { continuation in
      clearContextContinuation = continuation
    }
  }

  func releaseClearContext() {
    clearContextContinuation?.resume()
    clearContextContinuation = nil
  }

  func contextUsage(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = messages
    _ = attachments
    _ = systemPrompt
    return ChatContextUsage(usedTokens: 42, tokenLimit: nil)
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
      continuation.finish()
    }
  }
}

private actor DelayedUnloadRuntime: ChatModelRuntime {
  private var unloadContinuation: CheckedContinuation<Void, Never>?
  private(set) var didStartUnload = false
  private(set) var isLoaded = true
  private(set) var loadCount = 0

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
    loadCount += 1
    isLoaded = true
  }

  func unload() async {
    didStartUnload = true
    await withCheckedContinuation { continuation in
      unloadContinuation = continuation
    }
    isLoaded = false
  }

  func releaseUnload() {
    unloadContinuation?.resume()
    unloadContinuation = nil
  }

  func clearContext() async {}

  func contextUsage(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = messages
    _ = attachments
    _ = systemPrompt
    return ChatContextUsage(usedTokens: 0, tokenLimit: nil)
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
      continuation.finish()
    }
  }
}

private final class BlockingFirstAttachmentLoader: ChatAttachmentLoading, @unchecked Sendable {
  private let lock = NSLock()
  private let firstLoadRelease = DispatchSemaphore(value: 0)
  private var _startedCount = 0

  var startedCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _startedCount
  }

  func loadAttachments(
    from urls: [URL],
    existingAttachments: [ChatAttachment]
  ) throws -> [ChatAttachment] {
    _ = existingAttachments
    lock.lock()
    _startedCount += 1
    let callNumber = _startedCount
    lock.unlock()

    if callNumber == 1 {
      firstLoadRelease.wait()
    }

    guard let url = urls.first else {
      return []
    }
    return [
      ChatAttachment(
        url: url,
        displayName: url.lastPathComponent,
        kind: .text,
        content: callNumber == 1 ? "first" : "second"
      )
    ]
  }

  func extractDroppedAttachments(from draft: String) -> DroppedAttachmentExtraction {
    DroppedAttachmentExtraction(cleanedDraft: draft)
  }

  func releaseFirstLoad() {
    firstLoadRelease.signal()
  }
}

private actor RaceLoadingRuntime: ChatModelRuntime {
  private var firstLoadContinuation: CheckedContinuation<Void, Never>?
  private(set) var loadedConfigurations: [ChatModelConfiguration] = []

  var loadCount: Int {
    loadedConfigurations.count
  }

  func load(configuration: ChatModelConfiguration) async throws {
    loadedConfigurations.append(configuration)

    if loadedConfigurations.count == 1 {
      await withCheckedContinuation { continuation in
        firstLoadContinuation = continuation
      }
      try Task.checkCancellation()
    }
  }

  func releaseFirstLoad() {
    firstLoadContinuation?.resume()
    firstLoadContinuation = nil
  }

  func unload() async {}
  func clearContext() async {}

  func contextUsage(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = messages
    _ = attachments
    _ = systemPrompt
    return ChatContextUsage(usedTokens: 0, tokenLimit: nil)
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
      continuation.finish()
    }
  }
}

private actor FakeChatModelRuntime: ChatModelRuntime {
  private let turns: [[String]]
  private let failingStreamReplyCalls: Set<Int>
  private var streamReplyCount = 0
  private(set) var loadedConfiguration: ChatModelConfiguration?
  private(set) var didUnload = false
  private(set) var capturedMessages: [[ChatMessage]] = []
  private(set) var capturedSystemPrompts: [String] = []

  init(chunks: [String] = []) {
    self.turns = [chunks]
    self.failingStreamReplyCalls = []
  }

  init(turns: [[String]], failingStreamReplyCalls: Set<Int> = []) {
    self.turns = turns
    self.failingStreamReplyCalls = failingStreamReplyCalls
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
    let callIndex = streamReplyCount
    let chunks = turns[min(callIndex, turns.count - 1)]
    streamReplyCount += 1

    if failingStreamReplyCalls.contains(callIndex) {
      return AsyncThrowingStream { continuation in
        continuation.finish(throwing: FakeChatModelRuntimeError.streamFailed)
      }
    }

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

private enum FakeChatModelRuntimeError: Error {
  case streamFailed
}
