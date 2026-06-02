import Foundation
import Testing

@testable import local_coder

@MainActor
struct ChatSessionControllerTests {
  @Test
  func canSendRequiresReadyModelNonEmptyDraftAndIdleGeneration() {
    let controller = ChatSessionController(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model"
    )

    controller.modelRuntime.modelState = .ready
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
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["hello", " world"])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
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
    controller.modelRuntime.modelState = .ready
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
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["a short poem"])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
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
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["That is literal user text."])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
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
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["That is not a controller observation."])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
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
    let runtime = ChatSessionFakeChatModelRuntime(turns: [
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
    controller.modelRuntime.modelState = .ready
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
    let runtime = ChatSessionFakeChatModelRuntime(
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
    controller.modelRuntime.modelState = .ready
    controller.draft = "Read the README"

    controller.sendMessage(in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(
      controller.errorMessage
        == ChatSessionFakeChatModelRuntimeError.streamFailed.localizedDescription)
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
    let runtime = ChatSessionFakeChatModelRuntime(
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
    controller.modelRuntime.modelState = .ready
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
    let runtime = ChatSessionFakeChatModelRuntime(
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
    controller.modelRuntime.modelState = .ready
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
    let runtime = ChatSessionFakeChatModelRuntime()
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: modelDirectory.path(percentEncoded: false)
    )

    controller.prepareForModelRuntimeAction(cancelGeneration: false, invalidateContext: true)
    controller.modelRuntime.loadModel()

    try await waitUntil { controller.modelRuntime.modelState == .ready }

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
    let runtime = ChatSessionFakeChatModelRuntime()
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: modelDirectory.path(percentEncoded: false)
    )

    controller.prepareForModelRuntimeAction(cancelGeneration: false, invalidateContext: true)
    controller.modelRuntime.loadModel()

    try await waitUntil { controller.modelRuntime.modelState == .ready }

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

    controller.prepareForModelRuntimeAction(cancelGeneration: false, invalidateContext: true)
    controller.modelRuntime.loadModel()
    try await waitUntilAsync { await runtime.loadCount == 1 }

    controller.modelRuntime.modelPath = secondModelDirectory.path(percentEncoded: false)
    controller.prepareForModelRuntimeAction(cancelGeneration: false, invalidateContext: true)
    controller.modelRuntime.loadModel()

    try await waitUntil { controller.modelRuntime.modelState == .ready }
    try await waitUntilAsync { await runtime.loadCount == 2 }
    await runtime.releaseFirstLoad()
    try await Task.sleep(for: .milliseconds(60))

    #expect(controller.modelRuntime.modelState == .ready)
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
    controller.modelRuntime.modelState = .ready
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
    controller.modelRuntime.modelState = .ready
    controller.contextUsage = ChatContextUsage(usedTokens: 12, tokenLimit: 128)
    controller.chatSession.messages = [ChatMessage(kind: .user, content: "old session")]

    controller.clearChatHistory()
    try await waitUntilAsync { await runtime.didStartClearContext }

    controller.prepareForModelRuntimeAction(cancelGeneration: false, invalidateContext: true)
    controller.modelRuntime.loadModel()
    try await waitUntil { controller.modelRuntime.modelState == .ready }
    try await waitUntil { controller.contextUsage?.usedTokens == 42 }

    await runtime.releaseClearContext()
    try await Task.sleep(for: .milliseconds(60))

    #expect(controller.modelRuntime.modelState == .ready)
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
    controller.modelRuntime.modelState = .ready

    controller.prepareForModelRuntimeAction(cancelGeneration: true, invalidateContext: true)
    controller.modelRuntime.unloadModel()
    try await waitUntilAsync { await runtime.didStartUnload }

    controller.prepareForModelRuntimeAction(cancelGeneration: false, invalidateContext: true)
    controller.modelRuntime.loadModel()
    try await Task.sleep(for: .milliseconds(60))
    #expect(await runtime.loadCount == 0)

    await runtime.releaseUnload()
    try await waitUntil { controller.modelRuntime.modelState == .ready }

    #expect(await runtime.isLoaded)
    #expect(controller.errorMessage == nil)
  }

  @Test
  func staleAttachmentLoadDoesNotAppendAfterNewerAttachmentRequest() async throws {
    let loader = BlockingFirstAttachmentLoader()
    let controller = ChatSessionController(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model",
      chatAttachmentLoader: loader
    )

    controller.addAttachments(from: [URL(filePath: "/tmp/first.swift")])
    try await waitUntil { loader.startedCount == 1 }

    controller.addAttachments(from: [URL(filePath: "/tmp/second.swift")])
    try await waitUntil {
      controller.chatSession.attachments.map(\.displayName) == ["second.swift"]
    }

    loader.releaseFirstLoad()
    try await Task.sleep(for: .milliseconds(60))

    #expect(controller.chatSession.attachments.map(\.displayName) == ["second.swift"])
  }

  @Test
  func unloadModelReleasesRuntimeAndResetsModelState() async throws {
    let runtime = ChatSessionFakeChatModelRuntime()
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.contextUsage = ChatContextUsage(usedTokens: 12, tokenLimit: 128)
    controller.draft = "hello"

    controller.prepareForModelRuntimeAction(cancelGeneration: true, invalidateContext: true)
    controller.modelRuntime.unloadModel()

    try await waitUntil { controller.modelRuntime.modelState == .notLoaded }
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
