import Foundation
import MLXLMCommon
import Testing

@testable import SumikaCore
@testable import SumikaRuntimeMLX

#if canImport(SumikaTestSupport)
  import SumikaTestSupport
#endif

@Suite()
struct MLXChatRuntimeTemplateTests {
  @Test
  func neutralRepetitionPenaltyDoesNotEnableMLXProcessor() {
    #expect(MLXChatRuntime.mlxRepetitionPenalty(from: .agentDefault) == nil)

    var settings = ChatGenerationSettings.agentDefault
    settings.repetitionPenalty = 1.15

    #expect(MLXChatRuntime.mlxRepetitionPenalty(from: settings) == 1.15)
  }

  @Test
  func presencePenaltyMappingMapsZeroToNilAndForwardsNonZero() {
    // Chat mode leaves presence penalty off; agent mode enables it.
    #expect(MLXChatRuntime.mlxPresencePenalty(from: .chatDefault) == nil)
    #expect(MLXChatRuntime.mlxPresencePenalty(from: .agentDefault) == 0.5)

    var settings = ChatGenerationSettings.chatDefault
    settings.presencePenalty = 0.8
    #expect(MLXChatRuntime.mlxPresencePenalty(from: settings) == 0.8)
  }

  @Test
  func chatSessionMediaProcessingDelegatesSizingToModelProcessor() {
    let processing = MLXChatRuntime.modelNativeMediaProcessing

    #expect(processing.resize == nil)
    #expect(processing.minPixels == nil)
    #expect(processing.maxPixels == nil)
  }

  @Test
  func gemma4GenerationConfigFixtureCarriesEOTTokenID() throws {
    let data = Data(
      """
      {
        "eos_token_id": [1, 106, 50]
      }
      """.utf8)

    let generationConfig = try JSONDecoder().decode(GenerationConfigFile.self, from: data)
    var modelConfiguration = ModelConfiguration(directory: URL(filePath: "/tmp/gemma-4-fixture"))
    modelConfiguration.eosTokenIds = Set(generationConfig.eosTokenIds?.values ?? [])

    #expect(modelConfiguration.extraEOSTokens.isEmpty)
    #expect(modelConfiguration.eosTokenIds.contains(106))
  }

  @Test
  func mlxToolCallFormatInferenceDocumentsGemmaAndQwenCoverage() {
    #expect(ToolCallFormat.infer(from: "gemma4_unified") == .gemma4)
    #expect(ToolCallFormat.infer(from: "qwen3_5") == .xmlFunction)
    #expect(ToolCallFormat.infer(from: "qwen3_5_moe") == .xmlFunction)
    #expect(ToolCallFormat.infer(from: "qwen3_next") == .xmlFunction)
    #expect(ToolCallFormat.infer(from: "qwen3") == nil)
    #expect(ToolCallFormat.infer(from: "qwen2") == nil)
  }

  @Test
  func productSourceDoesNotHardCodeModelStopTokens() throws {
    let repositoryURL = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let searchedDirectories = [
      repositoryURL.appending(path: "Sources", directoryHint: .isDirectory),
      repositoryURL.appending(path: "sumika", directoryHint: .isDirectory),
    ]
    let forbiddenTokens = [
      "<end" + "_of_turn>",
      "<turn" + "|>",
      "<|" + "im_end" + "|>",
    ]
    let allowedFiles = Set([
      repositoryURL
        .appending(
          path: "Sources/SumikaRuntimeMLX/Services/MLXDebugTraceStore.swift",
          directoryHint: .notDirectory
        )
        .standardizedFileURL.path(percentEncoded: false)
    ])

    var matches: [String] = []
    for directoryURL in searchedDirectories {
      guard
        let enumerator = FileManager.default.enumerator(
          at: directoryURL,
          includingPropertiesForKeys: [.isRegularFileKey],
          options: [.skipsHiddenFiles]
        )
      else {
        continue
      }
      for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
        let path = fileURL.standardizedFileURL.path(percentEncoded: false)
        guard !allowedFiles.contains(path) else {
          continue
        }
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        for token in forbiddenTokens where contents.contains(token) {
          matches.append("\(path): \(token)")
        }
      }
    }

    #expect(matches.isEmpty, "Model stop tokens must come from MLX/model config: \(matches)")
  }

  @Test
  func imageInputsUseAttachmentFileURLs() throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appending(
        path: "sumika-runtime-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let url = directoryURL.appending(path: "screenshot.png", directoryHint: .notDirectory)
    let data = Data([0x89, 0x50, 0x4e, 0x47])
    try data.write(to: url)
    let store = ChatAttachmentStore(baseURL: directoryURL.appending(path: "attachments"))
    let id = AttachmentID()
    let storedURL = try store.storeFile(from: url, id: id, displayName: "screenshot.png")
    let attachment = ChatAttachment(
      id: id,
      displayName: "screenshot.png",
      payload: .image(
        ImageAttachmentPayload(
          mimeType: "image/png",
          byteSize: data.count,
          contentSHA256: ChatAttachmentStore.contentSHA256(for: data)
        )
      )
    )

    let images = try MLXHistoryRenderer.imageInputs(from: [attachment], attachmentStore: store)

    #expect(images.count == 1)
    guard case .url(let imageURL) = try #require(images.first) else {
      Issue.record("Expected URL-backed image input.")
      return
    }
    #expect(imageURL.lastPathComponent == storedURL.lastPathComponent)
    #expect(try Data(contentsOf: imageURL) == data)
  }

  @Test
  func generationHistorySnapshotCarriesImageSignaturesFromUserPromptEntry() throws {
    let imageAttachment = ChatAttachment(
      displayName: "car.jpg",
      payload: .image(
        ImageAttachmentPayload(mimeType: "image/jpeg", byteSize: 1024, contentSHA256: "abc123")
      )
    )
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        prompt: "what is in the picture",
        attachments: [imageAttachment]
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(content: "A blue Mini Cooper."),
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "what color are the wheels?"),
    ]

    let snapshot = MLXHistoryRenderer.generationHistorySnapshot(
      from: projectedEntries(from: entries)[..<2]
    )

    #expect(snapshot.count == 2)
    #expect(snapshot[0].imageSignatures == ["sha256:abc123"])
    #expect(snapshot[1].imageSignatures == [])
    #expect(snapshot[0].content.contains("abc123") == false)
  }

  @Test
  func mlxGenerationInputConsumesCoreProviderProjectionWithoutDrift() throws {
    let callID = try #require(
      UUID(uuidString: "00000000-0000-0000-0000-000000000041")
    )
    let arguments: ToolCallArguments = ["path": .string("README.md")]
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "read README.md"),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        content: toolCallContent(
          callID: callID,
          toolName: .readFile,
          arguments: arguments
        )
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        toolResult: ToolResultModelMessage(
          callID: callID,
          toolName: .readFile,
          payload: .readFile(
            .success(
              path: WorkspaceRelativePath(rawValue: "README.md"),
              content: ToolTextOutput(text: "Project overview")
            )
          )
        ),
        request: toolRequest(
          callID: callID,
          toolName: .readFile,
          arguments: arguments
        ),
        originalUserRequest: nil
      ),
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "summarize it"),
    ]
    let transcript = ModelPromptProjection(entries: entries)
    let coreSegments = try #require(
      ProviderPromptProjection.generationSegments(from: transcript)
    )

    let input = try MLXHistoryRenderer.generationInput(from: transcript)

    #expect(input.historySnapshot == coreSegments.history.messages)
    #expect(input.promptSnapshot == coreSegments.prompt.messages)
    #expect(input.history.map(\.role) == [.user, .assistant])
    #expect(input.promptMessages.map(\.role) == [.tool, .user])
    let rawMessages = DefaultMessageGenerator().generate(
      messages: input.history + input.promptMessages
    )
    let rawToolCalls = try #require(
      rawMessages[1]["tool_calls"] as? [[String: any Sendable]]
    )
    let rawFunction = try #require(
      rawToolCalls.first?["function"] as? [String: any Sendable]
    )
    #expect(rawFunction["name"] as? String == ToolName.readFile.rawValue)
    #expect(
      rawMessages[2]["tool_call_id"] as? String == RuntimeToolCallID.string(for: callID)
    )
  }

  @Test
  func focusedFileReuseRemainsAppendOnlyForMLXCachePolicy() {
    let path = WorkspaceRelativePath(rawValue: "Sources/App.swift")
    let focusedFileState = FocusedFileState(
      activePath: path,
      recentPaths: [
        FocusedPath(path: path, source: .readFile, confidence: .active)
      ],
      snapshots: [
        path: FocusedFileSnapshot(
          contentHash: "stable-complete-read",
          excerpt: "struct App { let value = 1 }",
          fullContentAvailable: true
        )
      ]
    )
    let promptContext = CurrentPromptContextSelector().selectContext(
      userInput: "Continue",
      mode: .agent,
      focusedFileState: focusedFileState,
      budget: .focusedFileDefault
    )
    let firstTurn = ChatTurn(
      status: .completed,
      items: [
        .userMessage(UserTurnMessage(content: "First", promptContext: promptContext)),
        .assistantMessage(AssistantTurnMessage(content: "First complete")),
      ]
    )
    let secondTurn = ChatTurn(
      status: .completed,
      items: [
        .userMessage(UserTurnMessage(content: "Second", promptContext: promptContext)),
        .assistantMessage(AssistantTurnMessage(content: "Second complete")),
      ]
    )
    let cachedPrefix = ProviderPromptProjection.normalized(
      from: ChatModelContextBuilder().transcript(from: ChatSession(turns: [firstTurn]))
    ).messages
    let appendedHistory = ProviderPromptProjection.normalized(
      from: ChatModelContextBuilder().transcript(
        from: ChatSession(turns: [firstTurn, secondTurn])
      )
    ).messages
    let identity = MLXSessionCachePolicy.cacheIdentity(
      systemPrompt: "Stable",
      settings: .agentDefault,
      projectionMode: .fullHistory
    )
    let appendOnly = MLXSessionCachePolicy.isPrefix(cachedPrefix, of: appendedHistory)
    let trace = MLXSessionCachePolicy.trace(
      mode: .appendDelta,
      reason: .appendOnlyDelta,
      currentHistory: appendedHistory,
      currentIdentity: identity,
      cachedPrefix: cachedPrefix,
      cachedIdentity: identity,
      appendOnly: appendOnly,
      mismatchReason: nil,
      firstMismatchIndex: nil
    )

    #expect(appendedHistory[2].content.contains("content is not repeated"))
    #expect(appendOnly)
    #expect(trace.cacheMode == .appendDelta)
    #expect(trace.appendOnly)
    #expect(trace.reusedMessageCount == cachedPrefix.count)
    #expect(trace.appendedMessageCount == 2)
  }

  @Test
  func workspaceInstructionChangeForcesOneHistoryRebuildThenReturnsAppendOnly() {
    let firstTurn = workspaceInstructionsTurn(
      prompt: "First",
      response: "First complete",
      state: .makeSnapshot(
        path: WorkspaceRelativePath(rawValue: "AGENTS.md"),
        contentHash: String(repeating: "a", count: 64),
        content: "Rule A"
      )
    )
    let changedTurn = workspaceInstructionsTurn(
      prompt: "Second",
      response: "Second complete",
      state: .makeSnapshot(
        path: WorkspaceRelativePath(rawValue: "AGENTS.md"),
        contentHash: String(repeating: "b", count: 64),
        content: "Rule B"
      )
    )
    let unchangedTurn = workspaceInstructionsTurn(
      prompt: "Third",
      response: "Third complete"
    )
    let firstHistory = workspaceInstructionsProviderMessages(turns: [firstTurn])
    let changedHistory = workspaceInstructionsProviderMessages(turns: [firstTurn, changedTurn])
    let unchangedHistory = workspaceInstructionsProviderMessages(
      turns: [firstTurn, changedTurn, unchangedTurn]
    )
    let identity = MLXSessionCachePolicy.cacheIdentity(
      systemPrompt: "Stable",
      settings: .agentDefault,
      projectionMode: .fullHistory
    )
    let changedTrace = MLXSessionCachePolicy.trace(
      mode: .dirtyRebuild,
      reason: .historyChanged,
      currentHistory: changedHistory,
      currentIdentity: identity,
      cachedPrefix: firstHistory,
      cachedIdentity: identity,
      appendOnly: MLXSessionCachePolicy.isPrefix(firstHistory, of: changedHistory),
      mismatchReason: "history_changed",
      firstMismatchIndex: MLXSessionCachePolicy.firstMismatchIndex(
        cachedPrefix: firstHistory,
        currentHistory: changedHistory
      )
    )
    let stableTrace = MLXSessionCachePolicy.trace(
      mode: .appendDelta,
      reason: .appendOnlyDelta,
      currentHistory: unchangedHistory,
      currentIdentity: identity,
      cachedPrefix: changedHistory,
      cachedIdentity: identity,
      appendOnly: MLXSessionCachePolicy.isPrefix(changedHistory, of: unchangedHistory),
      mismatchReason: nil,
      firstMismatchIndex: nil
    )

    #expect(!changedTrace.appendOnly)
    #expect(changedTrace.cacheMode == .dirtyRebuild)
    #expect(changedTrace.cacheReason == .historyChanged)
    #expect(changedTrace.mismatchReason == "history_changed")
    #expect(changedHistory.map(\.content).joined().contains("Rule A") == false)
    #expect(stableTrace.appendOnly)
    #expect(stableTrace.cacheMode == .appendDelta)
    #expect(stableTrace.reusedMessageCount == changedHistory.count)
  }

  @Test
  func workspaceInstructionRemovalForcesOneHistoryRebuildThenReturnsAppendOnly() {
    let firstTurn = workspaceInstructionsTurn(
      prompt: "First",
      response: "First complete",
      state: .makeSnapshot(
        path: WorkspaceRelativePath(rawValue: "AGENTS.md"),
        contentHash: String(repeating: "a", count: 64),
        content: "Rule A"
      )
    )
    let removalTurn = workspaceInstructionsTurn(
      prompt: "Second",
      response: "Second complete",
      state: .makeRemoval(path: WorkspaceRelativePath(rawValue: "AGENTS.md"))
    )
    let unchangedTurn = workspaceInstructionsTurn(
      prompt: "Third",
      response: "Third complete"
    )
    let firstHistory = workspaceInstructionsProviderMessages(turns: [firstTurn])
    let removedHistory = workspaceInstructionsProviderMessages(turns: [firstTurn, removalTurn])
    let unchangedHistory = workspaceInstructionsProviderMessages(
      turns: [firstTurn, removalTurn, unchangedTurn]
    )

    #expect(!MLXSessionCachePolicy.isPrefix(firstHistory, of: removedHistory))
    #expect(removedHistory.map(\.content).joined().contains("Workspace instructions:") == false)
    #expect(MLXSessionCachePolicy.isPrefix(removedHistory, of: unchangedHistory))
  }

  @Test
  func cachePrefixComparisonIncludesImageSignatures() {
    let cachedPrefix = [
      ProviderPromptMessage(
        role: "user",
        content: "what is in the picture",
        imageSignatures: ["sha256:abc"]
      ),
      ProviderPromptMessage(role: "assistant", content: "A blue Mini Cooper."),
    ]
    let currentHistory = [
      ProviderPromptMessage(
        role: "user",
        content: "what is in the picture",
        imageSignatures: ["sha256:other"]
      ),
      ProviderPromptMessage(role: "assistant", content: "A blue Mini Cooper."),
    ]

    #expect(MLXSessionCachePolicy.isPrefix(cachedPrefix, of: cachedPrefix))
    #expect(!MLXSessionCachePolicy.isPrefix(cachedPrefix, of: currentHistory))
    #expect(
      MLXSessionCachePolicy.firstMismatchIndex(
        cachedPrefix: cachedPrefix,
        currentHistory: currentHistory
      ) == 0)
    #expect(
      MLXSessionCachePolicy.contextSignature(for: cachedPrefix)
        != MLXSessionCachePolicy.contextSignature(for: currentHistory))
  }

  @Test
  func templateMessagesUseFrozenTranscriptContent() throws {
    let callID = UUID()
    let transcript = ModelPromptProjection(
      entries: [
        try ModelFacingPromptRenderer.userPromptEntry(prompt: "create index.htm"),
        try ModelFacingPromptRenderer.assistantOutputEntry(
          content: writeFileToolCall(
            callID: callID,
            arguments: [
              "path": .string("index.htm"),
              "content": .string("<html></html>"),
            ]
          ).modelContextContent
        ),
        try ModelFacingPromptRenderer.toolResultEntry(
          toolResult: ToolResultModelMessage(
            callID: callID,
            toolName: .writeFile,
            payload: .writeFile(
              .success(path: WorkspaceRelativePath(rawValue: "index.htm"), bytesWritten: 13))
          ),
          request: toolRequest(
            callID: callID,
            toolName: .writeFile,
            arguments: [
              "path": .string("index.htm"),
              "content": .string("<html></html>"),
            ]
          ),
          originalUserRequest: nil
        ),
        try ModelFacingPromptRenderer.userPromptEntry(
          prompt: "change the background color to green",
          systemContext: ["Use concise coding steps."]
        ),
      ]
    )

    let rendered = try MLXHistoryRenderer.templateMessages(
      from: transcript,
      attachments: [],
      systemPrompt: "This runtime argument must not rewrite frozen content."
    )
    let rawMessages = DefaultMessageGenerator().generate(messages: rendered)
    let rawAssistantToolCalls = try #require(
      rawMessages[2]["tool_calls"] as? [[String: any Sendable]]
    )
    let rawAssistantToolCall = try #require(rawAssistantToolCalls.first)
    let rawAssistantFunction = try #require(
      rawAssistantToolCall["function"] as? [String: any Sendable]
    )

    #expect(rendered[0].role == .system)
    #expect(rendered.map(\.role) == [.system, .user, .assistant, .tool, .user])
    #expect(!rendered[1].content.contains("System instructions:"))
    #expect(rendered[0].content.contains("This runtime argument must not rewrite"))
    #expect(rendered[4].content.contains("System instructions:"))
    #expect(rendered[4].content.contains("Use concise coding steps."))
    #expect(!rendered[4].content.contains("This runtime argument must not rewrite"))
    #expect(rendered[2].content.isEmpty)
    #expect(rawAssistantFunction["name"] as? String == ToolName.writeFile.rawValue)
    #expect(rendered[3].content.contains("TOOL_RESULT_JSON:"))
    #expect(rendered[3].content.contains("\"tool\":\"write_file\""))
    #expect(rendered[3].content.contains("Summary:"))
    #expect(rendered[3].content.contains("Wrote 13 bytes to index.htm."))
    #expect(rendered[3].content.contains("Tool receipt:") == false)
  }

  @Test
  func runtimeHistoryPrependsSystemPromptWithoutEmbeddingItInUserHistory() throws {
    let callID = UUID()
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        prompt: "create index.htm"
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        content: writeFileToolCall(
          callID: callID,
          arguments: ["path": .string("index.htm")]
        ).modelContextContent
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        toolResult: ToolResultModelMessage(
          callID: callID,
          toolName: .writeFile,
          payload: .writeFile(
            .success(path: WorkspaceRelativePath(rawValue: "index.htm"), bytesWritten: 13))
        ),
        request: toolRequest(
          callID: callID,
          toolName: .writeFile,
          arguments: [
            "path": .string("index.htm"),
            "content": .string("<html></html>"),
          ]
        ),
        originalUserRequest: nil
      ),
    ]

    let projectedHistory = try MLXHistoryRenderer.generationHistoryMessages(
      from: projectedEntries(from: entries)[...]
    )
    let history = try MLXHistoryRenderer.runtimeHistoryMessages(
      systemPrompt: "Use concise coding steps.",
      history: projectedHistory
    )

    #expect(history.map(\.role) == [.system, .user, .assistant, .tool])
    #expect(history[0].content.contains("Use concise coding steps."))
    #expect(!history[1].content.contains("System instructions:"))
    #expect(!history[1].content.contains("Use concise coding steps."))
    #expect(!history[3].content.contains("Use concise coding steps."))
  }

  @Test
  func renderedHistoryDoesNotRewriteFirstUserWhenToolPromptModeChanges() throws {
    let initialUser = try ModelFacingPromptRenderer.userPromptEntry(
      prompt: "create index.htm",
      systemContext: ["When tools are available, use them."]
    )
    let initialRendered = try MLXHistoryRenderer.templateMessages(
      from: ModelPromptProjection(entries: [initialUser]),
      attachments: [],
      systemPrompt: "When tools are available, use them."
    )
    let entries = [
      initialUser,
      try ModelFacingPromptRenderer.assistantOutputEntry(
        content: "Tool call write_file requested."),
      try ModelFacingPromptRenderer.userPromptEntry(
        prompt: "Tool write_file completed with status success.",
        systemContext: ["No more tools may run in this response."]
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(content: "Done."),
    ]

    let history = try MLXHistoryRenderer.generationHistoryMessages(
      from: projectedEntries(from: entries)[...]
    )

    #expect(history.map(\.role) == [.user, .assistant, .user, .assistant])
    #expect(history[0].content == initialRendered[1].content)
    #expect(history[2].content.contains("No more tools may run in this response."))
    #expect(!history[0].content.contains("No more tools may run in this response."))
  }

  @Test
  func templateMessagesPreserveFocusedFileSystemContextInsideUserMessage() throws {
    let transcript = ModelPromptProjection(
      entries: [
        try ModelFacingPromptRenderer.userPromptEntry(
          prompt: "change the background color to green",
          systemContext: [
            """
            Current focused file: index.htm
            Source: previous write_file
            Known content excerpt:
            <html><body><table><tr><td>Movie</td></tr></table></body></html>
            Explicit file paths in the user request or tool call take precedence.
            """
          ]
        )
      ]
    )

    let rendered = try MLXHistoryRenderer.templateMessages(
      from: transcript,
      attachments: [],
      systemPrompt: "A later runtime argument must not rewrite frozen content."
    )

    #expect(rendered.map(\.role) == [.system, .user])
    #expect(rendered[0].content.contains("A later runtime argument must not rewrite"))
    #expect(rendered[1].content.contains("Current focused file: index.htm"))
    #expect(rendered[1].content.contains("<html><body><table>"))
    #expect(rendered[1].content.contains("User request:"))
    #expect(rendered[1].content.contains("change the background color to green"))
  }

  @Test
  func generationPromptPreservesFocusedFileSystemContextOnFirstTurn() throws {
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        prompt: "explain this",
        systemContext: [
          """
          Current focused file: index.htm
          Source: previous read_file
          Known content excerpt:
          <h1>Dashboard</h1>
          Explicit file paths in the user request or tool call take precedence.
          """
        ]
      )
    ]
    let (history, prompt) = try generationHistoryAndPrompt(from: entries)

    #expect(history.isEmpty)
    #expect(!prompt.content.contains("Use concise coding steps."))
    #expect(prompt.content.contains("Current focused file: index.htm"))
    #expect(prompt.content.contains("<h1>Dashboard</h1>"))
    #expect(prompt.content.contains("User request:"))
    #expect(prompt.content.contains("explain this"))
  }

  @Test
  func currentPromptContextDoesNotRewriteHistoricalUserMessage() throws {
    let initialUser = try ModelFacingPromptRenderer.userPromptEntry(
      prompt: "summarize the current page",
      systemContext: []
    )
    let initialRendered = try MLXHistoryRenderer.templateMessages(
      from: ModelPromptProjection(entries: [initialUser]),
      attachments: [],
      systemPrompt: "Use concise coding steps."
    )
    let entries = [
      initialUser,
      try ModelFacingPromptRenderer.assistantOutputEntry(content: "The page has a small table."),
      try ModelFacingPromptRenderer.userPromptEntry(
        prompt: "change the heading",
        systemContext: [
          """
          Current focused file: robots.html
          Source: previous read_file
          Known content excerpt:
          <table><tr><td>Robot</td></tr></table>
          Explicit file paths in the user request or tool call take precedence.
          """
        ]
      ),
    ]
    let (history, prompt) = try generationHistoryAndPrompt(from: entries)

    #expect(history.map(\.role) == [.user, .assistant])
    #expect(history[0].content == initialRendered[1].content)
    #expect(!history[0].content.contains("Current focused file: robots.html"))
    #expect(!history[0].content.contains("No more tools may run in this response."))
    #expect(!prompt.content.contains("No more tools may run in this response."))
    #expect(prompt.content.contains("Current focused file: robots.html"))
    #expect(prompt.content.contains("<table><tr><td>Robot</td></tr></table>"))
    #expect(prompt.content.contains("change the heading"))
  }

  @Test
  func templateMessagesDoNotTeachModelInternalInvalidToolActions() throws {
    let callID = UUID()
    let turnID = UUID()
    let transcript = ModelPromptProjection(
      entries: [
        try ModelFacingPromptRenderer.userPromptEntry(
          turnID: turnID,
          prompt: "change the table heading"
        ),
        try ModelFacingPromptRenderer.toolResultEntry(
          turnID: turnID,
          toolResult: ToolResultModelMessage(
            callID: callID,
            toolName: .invalid,
            payload: .invalidTool(
              InvalidToolResult(
                originalName: "edit_file",
                reason: .parserError("Assistant described a tool call without an action block.")
              ))
          ),
          request: ToolCallRequest.invalid(
            raw: RawToolCallRequest(
              id: callID,
              workspaceID: UUID(),
              sessionID: UUID(),
              toolName: .invalid
            ),
            input: InvalidToolInput(
              originalName: "edit_file",
              rawArguments: [:],
              reason: .parserError("Assistant described a tool call without an action block.")
            )
          ),
          originalUserRequest: "change the table heading"
        ),
      ]
    )

    let rendered = try MLXHistoryRenderer.templateMessages(
      from: transcript,
      attachments: [],
      systemPrompt: "Use concise coding steps."
    )

    #expect(rendered.map(\.role) == [.system, .user])
    #expect(!rendered.contains { $0.content.contains("<|tool_call>call:invalid") })
    #expect(rendered[1].content.contains("The tool call was invalid"))
  }

  @Test
  func cacheIdentityIgnoresDecodeOnlySettings() {
    var changedSettings = ChatGenerationSettings.agentDefault
    changedSettings.maxTokens = 128
    changedSettings.temperature = 0.9
    changedSettings.topP = 0.5
    changedSettings.topK = 40
    changedSettings.repetitionPenalty = 1.15

    let first = MLXSessionCachePolicy.cacheIdentity(
      systemPrompt: "Use concise coding steps.",
      settings: .agentDefault,
      projectionMode: .fullHistory
    )
    let second = MLXSessionCachePolicy.cacheIdentity(
      systemPrompt: "Use concise coding steps.",
      settings: changedSettings,
      projectionMode: .fullHistory
    )

    #expect(first == second)
  }

  @Test
  func cacheIdentityChangesForPrefillSettings() {
    var changedMaxKV = ChatGenerationSettings.agentDefault
    changedMaxKV.maxKVSize = 16_384
    var changedReasoning = ChatGenerationSettings.agentDefault
    changedReasoning.reasoningEnabled = false
    let base = MLXSessionCachePolicy.cacheIdentity(
      systemPrompt: "Use concise coding steps.",
      settings: .agentDefault,
      projectionMode: .fullHistory
    )

    #expect(
      MLXSessionCachePolicy.identityMismatchReason(
        cached: base,
        current: MLXSessionCachePolicy.cacheIdentity(
          systemPrompt: "Use concise coding steps.",
          settings: changedMaxKV,
          projectionMode: .fullHistory
        )
      ) == .maxKVSizeChanged)
    #expect(
      MLXSessionCachePolicy.identityMismatchReason(
        cached: base,
        current: MLXSessionCachePolicy.cacheIdentity(
          systemPrompt: "Use concise coding steps.",
          settings: changedReasoning,
          projectionMode: .fullHistory
        )
      ) == .reasoningChanged)
    #expect(
      MLXSessionCachePolicy.identityMismatchReason(
        cached: base,
        current: MLXSessionCachePolicy.cacheIdentity(
          systemPrompt: "Use detailed coding steps.",
          settings: .agentDefault,
          projectionMode: .fullHistory
        )
      ) == .identityChanged)
  }

  @Test
  func streamMessagesUsesOnlyAppendDeltaAndPrompt() {
    let history: [Chat.Message] = [
      .user("hello"),
      .assistant("hi"),
      .tool("result", id: "call_1"),
    ]
    let promptMessages: [Chat.Message] = [.user("continue")]

    let firstPrompt = MLXSessionCachePolicy.streamMessages(
      history: history,
      promptMessages: promptMessages,
      appendDeltaStartIndex: nil
    )
    let appendDelta = MLXSessionCachePolicy.streamMessages(
      history: history,
      promptMessages: promptMessages,
      appendDeltaStartIndex: 2
    )

    #expect(firstPrompt.map(\.role) == [.user])
    #expect(appendDelta.map(\.role) == [.tool, .user])
  }

  @Test
  func chatSessionInstructionsAreOnlyAppliedWhenBuildingCache() {
    let systemPrompt = "Use concise coding steps."

    #expect(
      MLXSessionCachePolicy.chatSessionInstructions(
        for: .newSession,
        systemPrompt: systemPrompt
      ) == systemPrompt)
    #expect(
      MLXSessionCachePolicy.chatSessionInstructions(
        for: .dirtyRebuild,
        systemPrompt: systemPrompt
      ) == systemPrompt)
    #expect(
      MLXSessionCachePolicy.chatSessionInstructions(
        for: .reusedSession,
        systemPrompt: systemPrompt
      ) == nil)
    #expect(
      MLXSessionCachePolicy.chatSessionInstructions(
        for: .appendDelta,
        systemPrompt: systemPrompt
      ) == nil)
  }

  @Test
  func runtimeCacheDebugSnapshotMapsCoarseTrace() {
    let generationID = UUID()
    let recordedAt = Date(timeIntervalSince1970: 42)
    let trace = MLXSessionCacheTrace(
      cacheMode: .appendDelta,
      cacheReason: .appendOnlyDelta,
      contextSignature: "ctx-new",
      previousContextSignature: "ctx-old",
      appendOnly: true,
      reusedMessageCount: 3,
      appendedMessageCount: 1,
      mismatchReason: nil,
      firstMismatchIndex: nil,
      systemPromptChanged: nil,
      currentPromptContextChanged: nil
    )

    let snapshot = MLXSessionCachePolicy.runtimeCacheDebugSnapshot(
      from: trace,
      appendDeltaStartIndex: 3,
      generationID: generationID,
      recordedAt: recordedAt
    )

    #expect(snapshot.generationID == generationID)
    #expect(snapshot.recordedAt == recordedAt)
    #expect(snapshot.cacheMode == "append_delta")
    #expect(snapshot.cacheReason == "append_only_delta")
    #expect(snapshot.reuseStrategy == "append_delta")
    #expect(snapshot.appendDeltaStartIndex == 3)
    #expect(snapshot.contextSignature == "ctx-new")
    #expect(snapshot.previousContextSignature == "ctx-old")
    #expect(snapshot.appendOnly)
    #expect(snapshot.reusedMessageCount == 3)
    #expect(snapshot.appendedMessageCount == 1)
  }

  @Test
  func generationOwnershipBeginsMonotonicGenerations() {
    var ownership = MLXGenerationOwnership()

    let first = ownership.beginGeneration()
    let second = ownership.beginGeneration()

    #expect(first.rawValue == 1)
    #expect(second.rawValue == 2)
    #expect(ownership.activeGenerationID == second)
  }

  @Test
  func generationOwnershipCompletesOnlyCurrentGeneration() {
    var ownership = MLXGenerationOwnership()
    let first = ownership.beginGeneration()
    let second = ownership.beginGeneration()

    let staleCompletionAccepted = ownership.completeIfCurrent(first)
    #expect(ownership.activeGenerationID == second)
    let currentCompletionAccepted = ownership.completeIfCurrent(second)
    #expect(ownership.activeGenerationID == nil)
    let repeatedCompletionAccepted = ownership.completeIfCurrent(second)

    #expect(!staleCompletionAccepted)
    #expect(currentCompletionAccepted)
    #expect(!repeatedCompletionAccepted)
  }

  @Test
  func generationOwnershipInvalidatesOnlyCurrentGeneration() {
    var ownership = MLXGenerationOwnership()
    let first = ownership.beginGeneration()
    let second = ownership.beginGeneration()

    let staleInvalidationAccepted = ownership.invalidateIfCurrent(first)
    #expect(ownership.activeGenerationID == second)
    let currentInvalidationAccepted = ownership.invalidateIfCurrent(second)
    #expect(ownership.activeGenerationID == nil)
    let repeatedInvalidationAccepted = ownership.invalidateIfCurrent(second)

    #expect(!staleInvalidationAccepted)
    #expect(currentInvalidationAccepted)
    #expect(!repeatedInvalidationAccepted)
  }

  @Test
  func generationOwnershipInvalidatesActiveGeneration() {
    var ownership = MLXGenerationOwnership()
    let generationID = ownership.beginGeneration()

    ownership.invalidateActiveGeneration()

    #expect(ownership.activeGenerationID == nil)
    let completionAccepted = ownership.completeIfCurrent(generationID)
    let invalidationAccepted = ownership.invalidateIfCurrent(generationID)

    #expect(!completionAccepted)
    #expect(!invalidationAccepted)
  }

  @Test
  func activeGenerationRegistrySupersedesAndCancelsPreviousTask() async throws {
    var registry = MLXActiveGenerationRegistry()
    let generationID = MLXGenerationID(rawValue: 1)
    let task = Task<Void, Never> {
      do {
        try await Task.sleep(for: .seconds(5))
      } catch {}
    }

    registry.register(id: generationID, task: task)

    let supersededGeneration = registry.supersedeActiveGeneration()
    let superseded = try #require(supersededGeneration)
    #expect(superseded.id == generationID)
    #expect(superseded.task.isCancelled)
    #expect(registry.activeGenerationID == nil)

    try await withTestTimeout(.seconds(5)) {
      await superseded.task.value
    }
  }

  @Test
  func activeGenerationRegistryClearsOnlyCurrentGeneration() {
    var registry = MLXActiveGenerationRegistry()
    let first = MLXGenerationID(rawValue: 1)
    let second = MLXGenerationID(rawValue: 2)
    let task = Task<Void, Never> {}

    registry.register(id: first, task: task)

    let staleClearAccepted = registry.clearIfCurrent(second)
    #expect(!staleClearAccepted)
    #expect(registry.activeGenerationID == first)
    let currentClearAccepted = registry.clearIfCurrent(first)
    #expect(currentClearAccepted)
    #expect(registry.activeGenerationID == nil)
  }

  @Test
  func cachedSessionStateIsReusableOnlyWhenClean() {
    let generationID = MLXGenerationID(rawValue: 1)

    #expect(MLXCachedSessionState.clean.isReusable)
    #expect(!MLXCachedSessionState.inFlight(generationID: generationID).isReusable)
    #expect(!MLXCachedSessionState.dirty(reason: .cancelled).isReusable)
    #expect(MLXCachedSessionState.clean.invalidationReason == nil)
    #expect(
      MLXCachedSessionState.inFlight(generationID: generationID).invalidationReason
        == .interrupted)
    #expect(
      MLXCachedSessionState.dirty(reason: .runtimeError).invalidationReason == .runtimeError)
  }

  @Test
  func cachedSessionStateTransitionsOnlyForOwningGeneration() {
    let first = MLXGenerationID(rawValue: 1)
    let second = MLXGenerationID(rawValue: 2)
    let inFlight = MLXCachedSessionState.inFlight(generationID: second)

    #expect(inFlight.completing(generationID: first) == nil)
    #expect(inFlight.invalidating(generationID: first, reason: .cancelled) == nil)
    #expect(inFlight.completing(generationID: second) == .clean)
    #expect(
      inFlight.invalidating(generationID: second, reason: .downstreamTerminated)
        == .dirty(reason: .downstreamTerminated))
  }

  @Test
  func toolObservationFollowUpUsesStructuredToolResultPromptBatch() throws {
    let callID = UUID()
    let turnID = UUID()
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        turnID: turnID,
        prompt: "read README.md"
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: toolCallContent(
          callID: callID,
          toolName: .readFile,
          arguments: ["path": .string("README.md")]
        )
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: callID,
          toolName: .readFile,
          payload: .readFile(
            .success(
              path: WorkspaceRelativePath(rawValue: "README.md"),
              content: ToolTextOutput(text: "Project overview")
            ))
        ),
        request: toolRequest(
          callID: callID,
          toolName: .readFile,
          arguments: ["path": .string("README.md")]
        ),
        originalUserRequest: "read README.md"
      ),
    ]
    let input = try generationInput(from: entries)

    #expect(input.history.map(\.role) == [.user, .assistant])
    #expect(input.promptMessages.map(\.role) == [.tool])
    let rawMessages = DefaultMessageGenerator().generate(
      messages: input.history + input.promptMessages
    )
    let rawAssistantToolCalls = try #require(
      rawMessages[1]["tool_calls"] as? [[String: any Sendable]]
    )
    let rawAssistantToolCall = try #require(rawAssistantToolCalls.first)
    let rawAssistantFunction = try #require(
      rawAssistantToolCall["function"] as? [String: any Sendable]
    )
    let runtimeCallID = RuntimeToolCallID.string(for: callID)
    #expect(rawAssistantToolCall["id"] as? String == runtimeCallID)
    #expect(rawAssistantFunction["name"] as? String == ToolName.readFile.rawValue)
    #expect(rawMessages[2]["tool_call_id"] as? String == runtimeCallID)
    #expect(input.promptMessages[0].content.contains("TOOL_RESULT_JSON:"))
    #expect(input.promptMessages[0].content.contains("\"tool\":\"read_file\""))
    #expect(input.promptMessages[0].content.contains("Project overview"))
    #expect(input.promptMessages[0].content.contains(runtimeCallID) == false)
    #expect(input.promptMessages[0].content.contains(callID.uuidString) == false)
    #expect(input.promptSnapshot.map(\.role) == ["tool"])
    #expect(input.promptSnapshot[0].toolCallID == runtimeCallID)
  }

  @Test
  func toolObservationFollowUpNoticeRendersOnlyInToolContent() throws {
    let callID = UUID()
    let turnID = UUID()
    let notice = "Continue from the observation without repeating the same read_file call."
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        turnID: turnID,
        prompt: "read README.md"
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: toolCallContent(
          callID: callID,
          toolName: .readFile,
          arguments: ["path": .string("README.md")]
        )
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: callID,
          toolName: .readFile,
          payload: .readFile(
            .success(
              path: WorkspaceRelativePath(rawValue: "README.md"),
              content: ToolTextOutput(text: "Project overview")
            ))
        ),
        request: toolRequest(
          callID: callID,
          toolName: .readFile,
          arguments: ["path": .string("README.md")]
        ),
        originalUserRequest: "read README.md",
        modelFollowUpNotice: notice
      ),
    ]

    let input = try generationInput(from: entries)
    let rawMessages = DefaultMessageGenerator().generate(
      messages: input.history + input.promptMessages
    )
    let rawAssistantToolCalls = try #require(
      rawMessages[1]["tool_calls"] as? [[String: any Sendable]]
    )
    let rawAssistantToolCall = try #require(rawAssistantToolCalls.first)
    let rawAssistantFunction = try #require(
      rawAssistantToolCall["function"] as? [String: any Sendable]
    )

    #expect(input.history.map(\.role) == [.user, .assistant])
    #expect(input.promptMessages.map(\.role) == [.tool])
    #expect(rawAssistantToolCall["id"] as? String == RuntimeToolCallID.string(for: callID))
    #expect(rawAssistantFunction["name"] as? String == ToolName.readFile.rawValue)
    #expect(rawMessages[2]["tool_call_id"] as? String == RuntimeToolCallID.string(for: callID))
    #expect(input.history[0].content.contains("[Follow-up]") == false)
    #expect(input.history[1].content.contains("[Follow-up]") == false)
    #expect(input.promptMessages[0].content.contains("TOOL_RESULT_JSON:"))
    #expect(input.promptMessages[0].content.contains("Project overview"))
    #expect(input.promptMessages[0].content.contains("\"next_step\":\"\(notice)\""))
    #expect(input.promptMessages[0].content.contains("Original user request:") == false)
    #expect(input.promptSnapshot[0].content == input.promptMessages[0].content)
  }

  @Test
  func multipleToolObservationFollowUpUsesStructuredToolResultPromptBatch() throws {
    let readCallID = UUID()
    let listCallID = UUID()
    let turnID = UUID()
    let readArguments: ToolCallArguments = ["path": .string("README.md")]
    let listArguments: ToolCallArguments = ["path": .string(".")]
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        turnID: turnID,
        prompt: "read README.md and list files"
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: [
          toolCallContent(callID: readCallID, toolName: .readFile, arguments: readArguments),
          toolCallContent(callID: listCallID, toolName: .listFiles, arguments: listArguments),
        ].joined(separator: "\n")
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: readCallID,
          toolName: .readFile,
          payload: .readFile(
            .success(
              path: WorkspaceRelativePath(rawValue: "README.md"),
              content: ToolTextOutput(text: "Project overview")
            ))
        ),
        request: toolRequest(
          callID: readCallID,
          toolName: .readFile,
          arguments: readArguments
        ),
        originalUserRequest: "read README.md and list files"
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: listCallID,
          toolName: .listFiles,
          payload: .listFiles(
            ListFilesResult(
              root: WorkspaceRelativePath(rawValue: "."),
              entries: [
                WorkspaceFileEntry(
                  path: WorkspaceRelativePath(rawValue: "README.md"),
                  kind: .file,
                )
              ]
            ))
        ),
        request: toolRequest(
          callID: listCallID,
          toolName: .listFiles,
          arguments: listArguments
        ),
        originalUserRequest: "read README.md and list files"
      ),
    ]

    let input = try generationInput(from: entries)

    #expect(input.history.map(\.role) == [.user, .assistant])
    let rawMessages = DefaultMessageGenerator().generate(
      messages: input.history + input.promptMessages
    )
    let rawAssistantToolCalls = try #require(
      rawMessages[1]["tool_calls"] as? [[String: any Sendable]]
    )
    #expect(rawAssistantToolCalls.count == 2)
    let firstToolCall = try #require(rawAssistantToolCalls.first)
    let secondToolCall = try #require(rawAssistantToolCalls.dropFirst().first)
    let firstFunction = try #require(firstToolCall["function"] as? [String: any Sendable])
    let secondFunction = try #require(secondToolCall["function"] as? [String: any Sendable])
    #expect(firstToolCall["id"] as? String == RuntimeToolCallID.string(for: readCallID))
    #expect(firstFunction["name"] as? String == ToolName.readFile.rawValue)
    #expect(secondToolCall["id"] as? String == RuntimeToolCallID.string(for: listCallID))
    #expect(secondFunction["name"] as? String == ToolName.listFiles.rawValue)
    #expect(input.promptMessages.map(\.role) == [.tool, .tool])
    #expect(rawMessages[2]["tool_call_id"] as? String == RuntimeToolCallID.string(for: readCallID))
    #expect(rawMessages[3]["tool_call_id"] as? String == RuntimeToolCallID.string(for: listCallID))
  }

  @Test
  func toolCallAfterAssistantPreambleReplaysAsSingleStructuredAssistantMessage() throws {
    let callID = UUID()
    let turnID = UUID()
    let arguments: ToolCallArguments = ["path": .string("README.md")]
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(turnID: turnID, prompt: "read README.md"),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: "I'll inspect that."
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: callID,
          toolName: .readFile,
          payload: .readFile(
            .success(
              path: WorkspaceRelativePath(rawValue: "README.md"),
              content: ToolTextOutput(text: "Project overview")
            ))
        ),
        request: toolRequest(callID: callID, toolName: .readFile, arguments: arguments),
        originalUserRequest: "read README.md"
      ),
    ]

    let input = try generationInput(from: entries)

    #expect(input.history.map(\.role) == [.user, .assistant])
    #expect(input.historySnapshot[1].content == "I'll inspect that.")
    #expect(input.historySnapshot[1].toolCalls.count == 1)
    #expect(input.promptMessages.map(\.role) == [.tool])
  }

  @Test
  func redactedWriteFileBoundaryReplaysAsStructuredToolCall() throws {
    let callID = UUID()
    let turnID = UUID()
    let arguments: ToolCallArguments = [
      "path": .string("movies.html"),
      "content": .string("<html></html>"),
    ]
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(turnID: turnID, prompt: "create movies.html"),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: writeFileToolCall(callID: callID, arguments: arguments).modelContextContent
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: callID,
          toolName: .writeFile,
          payload: .writeFile(
            .success(path: WorkspaceRelativePath(rawValue: "movies.html"), bytesWritten: 13))
        ),
        request: toolRequest(callID: callID, toolName: .writeFile, arguments: arguments),
        originalUserRequest: "create movies.html"
      ),
    ]

    let input = try generationInput(from: entries)
    let rawMessages = DefaultMessageGenerator().generate(
      messages: input.history + input.promptMessages
    )
    let rawAssistantToolCalls = try #require(
      rawMessages[1]["tool_calls"] as? [[String: any Sendable]]
    )
    let rawAssistantToolCall = try #require(rawAssistantToolCalls.first)
    let rawAssistantFunction = try #require(
      rawAssistantToolCall["function"] as? [String: any Sendable]
    )
    let rawArguments = try #require(rawAssistantFunction["arguments"] as? [String: any Sendable])

    #expect(input.history.map(\.role) == [.user, .assistant])
    #expect(input.historySnapshot[1].content.isEmpty)
    #expect(rawAssistantToolCall["id"] as? String == RuntimeToolCallID.string(for: callID))
    #expect(rawAssistantFunction["name"] as? String == ToolName.writeFile.rawValue)
    #expect(rawArguments["content"] as? String == "<html></html>")
    #expect(input.promptMessages.map(\.role) == [.tool])
    #expect(rawMessages[2]["tool_call_id"] as? String == RuntimeToolCallID.string(for: callID))
  }

  @Test
  func writeResultFollowUpIncludesEntireStructuredResultGroup() throws {
    let readCallID = UUID()
    let writeCallID = UUID()
    let turnID = UUID()
    let readArguments: ToolCallArguments = ["path": .string("README.md")]
    let writeArguments: ToolCallArguments = [
      "path": .string("movies.html"),
      "content": .string("<html></html>"),
    ]
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        turnID: turnID,
        prompt: "read README.md and create movies.html"
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: [
          ToolCallModelMessage(
            rawRequest: RawToolCallRequest(
              id: readCallID,
              workspaceID: UUID(),
              sessionID: UUID(),
              toolName: .readFile,
              arguments: readArguments
            )
          ).modelContextContent,
          writeFileToolCall(callID: writeCallID, arguments: writeArguments).modelContextContent,
        ].joined(separator: "\n")
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: readCallID,
          toolName: .readFile,
          payload: .readFile(
            .success(
              path: WorkspaceRelativePath(rawValue: "README.md"),
              content: ToolTextOutput(text: "Project overview")
            ))
        ),
        request: toolRequest(callID: readCallID, toolName: .readFile, arguments: readArguments),
        originalUserRequest: "read README.md and create movies.html"
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: writeCallID,
          toolName: .writeFile,
          payload: .writeFile(
            .success(path: WorkspaceRelativePath(rawValue: "movies.html"), bytesWritten: 13))
        ),
        request: toolRequest(callID: writeCallID, toolName: .writeFile, arguments: writeArguments),
        originalUserRequest: "read README.md and create movies.html"
      ),
    ]

    let input = try generationInput(from: entries)

    #expect(input.history.map(\.role) == [.user, .assistant])
    #expect(
      input.historySnapshot[1].toolCalls.map(\.id) == [
        RuntimeToolCallID.string(for: readCallID),
        RuntimeToolCallID.string(for: writeCallID),
      ])
    #expect(input.promptMessages.map(\.role) == [.tool, .tool])
    #expect(input.promptMessages[0].content.contains("Project overview"))
    #expect(input.promptMessages[1].content.contains("Wrote 13 bytes to movies.html."))
    #expect(!input.promptMessages[1].content.contains("Original user request:"))
  }

  @Test
  func mixedDeniedAndSuccessfulBatchKeepsCallAndResultOrder() throws {
    let deniedCallID = UUID()
    let successfulCallID = UUID()
    let turnID = UUID()
    let deniedArguments: ToolCallArguments = [
      "path": .string("denied.txt"),
      "content": .string("denied"),
    ]
    let successfulArguments: ToolCallArguments = [
      "path": .string("accepted.txt"),
      "content": .string("accepted"),
    ]
    let deniedRequest = toolRequest(
      callID: deniedCallID,
      toolName: .writeFile,
      arguments: deniedArguments
    )
    let successfulRequest = toolRequest(
      callID: successfulCallID,
      toolName: .writeFile,
      arguments: successfulArguments
    )
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        turnID: turnID,
        prompt: "write both files"
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: [
          ToolCallModelMessage(request: deniedRequest).modelContextContent,
          ToolCallModelMessage(request: successfulRequest).modelContextContent,
        ].joined(separator: "\n")
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: deniedCallID,
          toolName: .writeFile,
          payload: .failure(
            ToolFailure(
              toolName: .writeFile,
              path: WorkspaceRelativePath(rawValue: "denied.txt"),
              reason: .userDenied
            ))
        ),
        request: deniedRequest,
        originalUserRequest: "write both files"
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: successfulCallID,
          toolName: .writeFile,
          payload: .writeFile(
            .success(
              path: WorkspaceRelativePath(rawValue: "accepted.txt"),
              bytesWritten: 8
            ))
        ),
        request: successfulRequest,
        originalUserRequest: "write both files"
      ),
    ]

    let input = try generationInput(from: entries)
    let rawMessages = DefaultMessageGenerator().generate(
      messages: input.history + input.promptMessages
    )
    let rawAssistantToolCalls = try #require(
      rawMessages[1]["tool_calls"] as? [[String: any Sendable]]
    )

    #expect(
      rawAssistantToolCalls.compactMap { $0["id"] as? String } == [
        RuntimeToolCallID.string(for: deniedCallID),
        RuntimeToolCallID.string(for: successfulCallID),
      ])
    #expect(
      rawMessages[2]["tool_call_id"] as? String
        == RuntimeToolCallID.string(for: deniedCallID))
    #expect(
      rawMessages[3]["tool_call_id"] as? String
        == RuntimeToolCallID.string(for: successfulCallID))
    #expect(input.promptMessages[0].content.contains("\"status\":\"denied\""))
    #expect(input.promptMessages[0].content.contains("\"kind\":\"user_denied\""))
    #expect(input.promptMessages[0].content.contains("Tool call denied by user."))
    #expect(input.promptMessages[1].content.contains("Wrote 8 bytes to accepted.txt."))
  }

  @Test
  func laterUserTurnHistoryKeepsStructuredToolResult() throws {
    let callID = UUID()
    let turnID = UUID()
    let transcript = ModelPromptProjection(entries: [
      try ModelFacingPromptRenderer.userPromptEntry(turnID: turnID, prompt: "read README.md"),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: toolCallContent(
          callID: callID,
          toolName: .readFile,
          arguments: ["path": .string("README.md")]
        )
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: callID,
          toolName: .readFile,
          payload: .readFile(
            .success(
              path: WorkspaceRelativePath(rawValue: "README.md"),
              content: ToolTextOutput(text: "Project overview")
            ))
        ),
        request: toolRequest(
          callID: callID,
          toolName: .readFile,
          arguments: ["path": .string("README.md")]
        ),
        originalUserRequest: "read README.md"
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: "README.md is a project file."
      ),
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "what did you read?"),
    ])

    let history = try MLXHistoryRenderer.generationHistoryMessages(from: transcript)

    #expect(history.map(\.role) == [.user, .assistant, .tool, .assistant])
    #expect(history[2].content.contains("TOOL_RESULT_JSON:"))
    #expect(history[2].content.contains("Project overview"))
    #expect(history[2].content.contains("Tool receipt:") == false)
    #expect(history[3].content.contains("README.md is a project file."))
  }

  // The native tool result is rendered as the same structured tool message in
  // both the prompt batch and later history, so the cached KV prefix survives
  // the turn boundary.
  @Test
  func cachePrefixSurvivesUserTurnAfterToolObservation() throws {
    let callID = UUID()
    let turnID = UUID()
    let toolTurnEntries = [
      try ModelFacingPromptRenderer.userPromptEntry(turnID: turnID, prompt: "read README.md"),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: toolCallContent(
          callID: callID,
          toolName: .readFile,
          arguments: ["path": .string("README.md")]
        )
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: callID,
          toolName: .readFile,
          payload: .readFile(
            .success(
              path: WorkspaceRelativePath(rawValue: "README.md"),
              content: ToolTextOutput(text: "Project overview")
            ))
        ),
        request: toolRequest(
          callID: callID,
          toolName: .readFile,
          arguments: ["path": .string("README.md")]
        ),
        originalUserRequest: "read README.md"
      ),
    ]

    // What the runtime caches after the tool follow-up completes:
    // history before the prompt + structured prompt batch + assistant(output).
    let followUpInput = try generationInput(from: toolTurnEntries)
    let cachedPrefix =
      followUpInput.historySnapshot
      + followUpInput.promptSnapshot
      + [
        ProviderPromptMessage(
          role: Chat.Message.Role.assistant.rawValue,
          content: "README.md is a project file."
        )
      ]

    // The next user turn: the observation now lives in history in the same
    // structured tool form that was sent as the prompt.
    let nextTurn = ModelPromptProjection(
      entries: toolTurnEntries + [
        try ModelFacingPromptRenderer.assistantOutputEntry(
          turnID: turnID, content: "README.md is a project file."),
        try ModelFacingPromptRenderer.userPromptEntry(prompt: "what did you read?"),
      ])
    let currentHistory = try MLXHistoryRenderer.generationInput(from: nextTurn).historySnapshot

    // Same position, same wire form: the prefilled structured tool result is
    // identical to its later history rendering.
    #expect(cachedPrefix.map(\.role) == ["user", "assistant", "tool", "assistant"])
    #expect(cachedPrefix[1].toolCalls.count == 1)
    #expect(cachedPrefix[2].toolCallID == RuntimeToolCallID.string(for: callID))
    #expect(cachedPrefix[2].content.contains("TOOL_RESULT_JSON:"))
    #expect(currentHistory[2].content.contains("TOOL_RESULT_JSON:"))
    #expect(cachedPrefix[2] == currentHistory[2])
    #expect(cachedPrefix == currentHistory)
    #expect(MLXSessionCachePolicy.isPrefix(cachedPrefix, of: currentHistory))
    #expect(
      MLXSessionCachePolicy.firstMismatchIndex(
        cachedPrefix: cachedPrefix,
        currentHistory: currentHistory
      ) == nil)
  }

  @Test
  func nativeToolCallBoundaryPreservesAssistantWhitespaceForPrefixParity() throws {
    let callID = UUID()
    let turnID = UUID()
    let visibleOutput = "\n\nThe issue is that buffer is unavailable.\n\n"
    let arguments: ToolCallArguments = [
      "path": .string("main.py"),
      "old_text": .string("buffer(bytes(samples))"),
      "new_text": .string("bytes(samples)"),
    ]
    let userEntry = try ModelFacingPromptRenderer.userPromptEntry(
      turnID: turnID,
      prompt: "fix main.py"
    )
    let initialInput = try generationInput(from: [userEntry])
    let cachedPrefix =
      initialInput.historySnapshot
      + initialInput.promptSnapshot
      + [
        MLXChatRuntime.nativeToolCallBoundarySnapshot(
          output: visibleOutput,
          nativeToolCalls: [
            ChatRuntimeToolCall(
              id: RuntimeToolCallID.string(for: callID),
              name: ToolName.editFile.rawValue,
              arguments: arguments
            )
          ]
        )
      ]

    let currentInput = try generationInput(from: [
      userEntry,
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: visibleOutput
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: callID,
          toolName: .editFile,
          payload: .editFile(
            .success(
              path: WorkspaceRelativePath(rawValue: "main.py"),
              diff: nil,
              matchStrategy: .exact
            ))
        ),
        request: toolRequest(
          callID: callID,
          toolName: .editFile,
          arguments: arguments
        ),
        originalUserRequest: "fix main.py"
      ),
    ])

    #expect(cachedPrefix[1].content == visibleOutput)
    #expect(cachedPrefix == currentInput.historySnapshot)
    #expect(MLXSessionCachePolicy.isPrefix(cachedPrefix, of: currentInput.historySnapshot))
    #expect(
      MLXSessionCachePolicy.firstMismatchIndex(
        cachedPrefix: cachedPrefix,
        currentHistory: currentInput.historySnapshot
      ) == nil)
  }

  @Test
  func cachePrefixSurvivesToolNoticeBeforeNextToolResult() throws {
    let readCallID = UUID()
    let writeCallID = UUID()
    let turnID = UUID()
    let originalPrompt = "read README.md and write summary.txt"
    let readArguments: ToolCallArguments = ["path": .string("README.md")]
    let writeArguments: ToolCallArguments = [
      "path": .string("summary.txt"),
      "content": .string("Project summary"),
    ]
    let followUpNotice =
      "Continue using the latest tool observation to answer the original user request."
    let entriesBeforeSecondToolCall = [
      try ModelFacingPromptRenderer.userPromptEntry(turnID: turnID, prompt: originalPrompt),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: toolCallContent(
          callID: readCallID,
          toolName: .readFile,
          arguments: readArguments
        )
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: readCallID,
          toolName: .readFile,
          payload: .readFile(
            .success(
              path: WorkspaceRelativePath(rawValue: "README.md"),
              content: ToolTextOutput(text: "Project overview")
            ))
        ),
        request: toolRequest(callID: readCallID, toolName: .readFile, arguments: readArguments),
        originalUserRequest: originalPrompt,
        modelFollowUpNotice: followUpNotice
      ),
    ]
    let secondToolCallBoundary = try ModelFacingPromptRenderer.assistantOutputEntry(
      turnID: turnID,
      content: toolCallContent(
        callID: writeCallID,
        toolName: .writeFile,
        arguments: writeArguments
      )
    )

    // What MLX has consumed before the follow-up generation starts: normal
    // history plus the structured tool prompt that carries the follow-up notice.
    let followUpInput = try generationInput(from: entriesBeforeSecondToolCall)
    let cachedPrefix = followUpInput.historySnapshot + followUpInput.promptSnapshot

    // The follow-up generation then calls another tool. A later rebuild must
    // keep the consumed tool message byte-identical and only append the new
    // assistant(tool_calls) boundary to history.
    let writeFollowUpInput = try generationInput(
      from: entriesBeforeSecondToolCall + [
        secondToolCallBoundary,
        try ModelFacingPromptRenderer.toolResultEntry(
          turnID: turnID,
          toolResult: ToolResultModelMessage(
            callID: writeCallID,
            toolName: .writeFile,
            payload: .writeFile(
              .success(path: WorkspaceRelativePath(rawValue: "summary.txt"), bytesWritten: 15))
          ),
          request: toolRequest(
            callID: writeCallID,
            toolName: .writeFile,
            arguments: writeArguments
          ),
          originalUserRequest: originalPrompt
        ),
      ]
    )
    let currentHistory = writeFollowUpInput.historySnapshot
    let trace = MLXSessionCachePolicy.trace(
      mode: .appendDelta,
      reason: .appendOnlyDelta,
      currentHistory: currentHistory,
      currentIdentity: MLXSessionCachePolicy.cacheIdentity(
        systemPrompt: "Use concise coding steps.",
        settings: .agentDefault,
        projectionMode: MLXHistoryRenderer.runtimeProjectionMode
      ),
      cachedPrefix: cachedPrefix,
      cachedIdentity: MLXSessionCachePolicy.cacheIdentity(
        systemPrompt: "Use concise coding steps.",
        settings: .agentDefault,
        projectionMode: MLXHistoryRenderer.runtimeProjectionMode
      ),
      appendOnly: MLXSessionCachePolicy.isPrefix(cachedPrefix, of: currentHistory),
      mismatchReason: nil,
      firstMismatchIndex: nil
    )

    #expect(cachedPrefix.map(\.role) == ["user", "assistant", "tool"])
    #expect(currentHistory.map(\.role) == ["user", "assistant", "tool", "assistant"])
    #expect(cachedPrefix[2].toolCallID == RuntimeToolCallID.string(for: readCallID))
    #expect(currentHistory[2].toolCallID == RuntimeToolCallID.string(for: readCallID))
    #expect(
      cachedPrefix[2].content.contains(
        "\"next_step\":\"Continue using the latest tool observation"))
    #expect(cachedPrefix[2] == currentHistory[2])
    #expect(MLXSessionCachePolicy.isPrefix(cachedPrefix, of: currentHistory))
    #expect(
      MLXSessionCachePolicy.firstMismatchIndex(
        cachedPrefix: cachedPrefix,
        currentHistory: currentHistory
      ) == cachedPrefix.count)
    #expect(trace.cacheMode == .appendDelta)
    #expect(trace.appendOnly)
    #expect(trace.reusedMessageCount == 3)
    #expect(trace.appendedMessageCount == 1)
    #expect(writeFollowUpInput.promptSnapshot.map(\.role) == ["tool"])
    #expect(
      writeFollowUpInput.promptSnapshot[0].toolCallID
        == RuntimeToolCallID.string(for: writeCallID))
    #expect(writeFollowUpInput.promptSnapshot[0].content.contains("[Follow-up]") == false)
  }

  @Test
  func cachePrefixSurvivesWriteToolResultBoundary() throws {
    let readCallID = UUID()
    let writeCallID = UUID()
    let turnID = UUID()
    let originalPrompt = "read README.md and write summary.txt"
    let readArguments: ToolCallArguments = ["path": .string("README.md")]
    let writeArguments: ToolCallArguments = [
      "path": .string("summary.txt"),
      "content": .string("Project summary"),
    ]
    let entriesBeforeWriteResult = [
      try ModelFacingPromptRenderer.userPromptEntry(turnID: turnID, prompt: originalPrompt),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: toolCallContent(
          callID: readCallID,
          toolName: .readFile,
          arguments: readArguments
        )
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: readCallID,
          toolName: .readFile,
          payload: .readFile(
            .success(
              path: WorkspaceRelativePath(rawValue: "README.md"),
              content: ToolTextOutput(text: "Project overview")
            ))
        ),
        request: toolRequest(callID: readCallID, toolName: .readFile, arguments: readArguments),
        originalUserRequest: originalPrompt
      ),
    ]
    let writeRequest = toolRequest(
      callID: writeCallID,
      toolName: .writeFile,
      arguments: writeArguments
    )
    let writeBoundary = try ModelFacingPromptRenderer.assistantOutputEntry(
      turnID: turnID,
      content: toolCallContent(
        callID: writeCallID,
        toolName: .writeFile,
        arguments: writeArguments
      )
    )

    let writeGenerationInput = try generationInput(from: entriesBeforeWriteResult)
    let cachedPrefix =
      writeGenerationInput.historySnapshot
      + writeGenerationInput.promptSnapshot
      + [
        ProviderPromptMessage(
          role: Chat.Message.Role.assistant.rawValue,
          content: "",
          toolCalls: [
            ProviderToolCall(
              id: RuntimeToolCallID.string(for: writeCallID),
              name: ToolName.writeFile.rawValue,
              arguments: writeArguments
            )
          ]
        )
      ]
    let currentHistory = try generationInput(
      from: entriesBeforeWriteResult + [
        writeBoundary,
        try ModelFacingPromptRenderer.toolResultEntry(
          turnID: turnID,
          toolResult: ToolResultModelMessage(
            callID: writeCallID,
            toolName: .writeFile,
            payload: .writeFile(
              .success(path: WorkspaceRelativePath(rawValue: "summary.txt"), bytesWritten: 15))
          ),
          request: writeRequest,
          originalUserRequest: originalPrompt
        ),
      ]
    ).historySnapshot

    #expect(cachedPrefix.map(\.role) == ["user", "assistant", "tool", "assistant"])
    #expect(currentHistory[3].toolCalls.map(\.id) == [RuntimeToolCallID.string(for: writeCallID)])
    #expect(cachedPrefix == currentHistory)
    #expect(MLXSessionCachePolicy.isPrefix(cachedPrefix, of: currentHistory))
    #expect(
      MLXSessionCachePolicy.firstMismatchIndex(
        cachedPrefix: cachedPrefix,
        currentHistory: currentHistory
      ) == nil)
  }

  @Test
  func writeToolResultFollowUpUsesStructuredToolResultAsPrompt() throws {
    let callID = UUID()
    let turnID = UUID()
    let writeResult = ToolResultModelMessage(
      callID: callID,
      toolName: .writeFile,
      payload: .writeFile(
        .success(path: WorkspaceRelativePath(rawValue: "movies.html"), bytesWritten: 13))
    )
    let writeRequest = toolRequest(
      callID: callID,
      toolName: .writeFile,
      arguments: [
        "path": .string("movies.html"),
        "content": .string("<html></html>"),
      ]
    )
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        turnID: turnID,
        prompt: "create movies.html"
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: writeFileToolCall(
          callID: callID,
          arguments: [
            "path": .string("movies.html"),
            "content": .string("<html></html>"),
          ]
        ).modelContextContent
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: writeResult,
        request: writeRequest,
        originalUserRequest: nil
      ),
    ]
    let (history, prompt) = try generationHistoryAndPrompt(from: entries)

    #expect(history.map(\.role) == [.user, .assistant])
    #expect(prompt.role == .tool)
    #expect(!prompt.content.contains("Original user request:"))
    #expect(prompt.content.contains("Summary: Wrote 13 bytes to movies.html."))
    #expect(!prompt.content.contains("Do not include generated file contents"))
    #expect(!prompt.content.contains("No more tools may run in this response."))
  }

  @Test
  func unstructuredWriteResultReplaysAsOrdinaryUserObservation() throws {
    let callID = UUID()
    let writeResult = try ModelFacingPromptRenderer.toolResultEntry(
      toolResult: ToolResultModelMessage(
        callID: callID,
        toolName: .writeFile,
        payload: .writeFile(
          .success(path: WorkspaceRelativePath(rawValue: "movies.html"), bytesWritten: 13)
        )
      ),
      request: toolRequest(
        callID: callID,
        toolName: .writeFile,
        arguments: [
          "path": .string("movies.html"),
          "content": .string("<html></html>"),
        ]
      ),
      originalUserRequest: nil
    )

    let rendered = try MLXHistoryRenderer.templateMessages(
      from: ModelPromptProjection(entries: [writeResult]),
      attachments: [],
      systemPrompt: ""
    )

    #expect(rendered.map(\.role) == [.user])
    #expect(rendered[0].content.contains("\"tool\":\"write_file\""))
    #expect(rendered[0].content.contains("Summary: Wrote 13 bytes to movies.html."))
  }

  @Test
  func cacheTraceReportsAppendOnlyDelta() {
    let prefix = MLXHistoryRenderer.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    let appendedHistory = MLXHistoryRenderer.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
      .tool("result", id: "call_1"),
    ])
    let identity = MLXSessionCachePolicy.cacheIdentity(
      systemPrompt: "Use concise coding steps.",
      settings: .agentDefault,
      projectionMode: .fullHistory
    )

    let trace = MLXSessionCachePolicy.trace(
      mode: .appendDelta,
      reason: .appendOnlyDelta,
      currentHistory: appendedHistory,
      currentIdentity: identity,
      cachedPrefix: prefix,
      cachedIdentity: identity,
      appendOnly: MLXSessionCachePolicy.isPrefix(prefix, of: appendedHistory),
      mismatchReason: nil,
      firstMismatchIndex: nil
    )

    #expect(trace.cacheMode == .appendDelta)
    #expect(trace.cacheReason == .appendOnlyDelta)
    #expect(trace.appendOnly)
    #expect(trace.reusedMessageCount == 2)
    #expect(trace.appendedMessageCount == 1)
    #expect(trace.mismatchReason == nil)
  }

  @Test
  func deltaBeginsWithToolResultDetectsReusedSubcaseToolPrompt() {
    // Reused subcase: cached prefix equals the whole history, so the delta is the
    // prompt. A tool-response prompt must force a rebuild; a user prompt must not.
    let history = [
      ProviderPromptMessage(role: "user", content: "hi"),
      ProviderPromptMessage(role: "assistant", content: "call"),
    ]
    #expect(
      MLXSessionCachePolicy.deltaBeginsWithToolResult(
        cachedPrefixCount: history.count,
        historySnapshot: history,
        promptFirstRole: "tool"))
    #expect(
      !MLXSessionCachePolicy.deltaBeginsWithToolResult(
        cachedPrefixCount: history.count,
        historySnapshot: history,
        promptFirstRole: "user"))
    #expect(
      !MLXSessionCachePolicy.deltaBeginsWithToolResult(
        cachedPrefixCount: history.count,
        historySnapshot: history,
        promptFirstRole: nil))
  }

  @Test
  func deltaBeginsWithToolResultDetectsAppendDeltaToolTail() {
    // Append-delta subcase: the cached prefix is shorter than history, so the delta
    // starts inside history at cachedPrefixCount. Detect a tool tail there.
    let history = [
      ProviderPromptMessage(role: "user", content: "hi"),
      ProviderPromptMessage(role: "assistant", content: "call"),
      ProviderPromptMessage(role: "tool", content: "result"),
    ]
    #expect(
      MLXSessionCachePolicy.deltaBeginsWithToolResult(
        cachedPrefixCount: 2,
        historySnapshot: history,
        promptFirstRole: nil))

    let nonToolTail = [
      ProviderPromptMessage(role: "user", content: "hi"),
      ProviderPromptMessage(role: "assistant", content: "call"),
      ProviderPromptMessage(role: "user", content: "again"),
    ]
    #expect(
      !MLXSessionCachePolicy.deltaBeginsWithToolResult(
        cachedPrefixCount: 2,
        historySnapshot: nonToolTail,
        promptFirstRole: nil))
  }

  @Test
  func cacheTraceReportsToolFollowUpRebuild() {
    let prefix = MLXHistoryRenderer.messageSnapshot(from: [
      .user("hello"),
      .assistant("calling read_file"),
    ])
    let followUpHistory = MLXHistoryRenderer.messageSnapshot(from: [
      .user("hello"),
      .assistant("calling read_file"),
      .tool("result", id: "call_1"),
    ])
    let identity = MLXSessionCachePolicy.cacheIdentity(
      systemPrompt: "Use concise coding steps.",
      settings: .agentDefault,
      projectionMode: .fullHistory
    )

    let trace = MLXSessionCachePolicy.trace(
      mode: .dirtyRebuild,
      reason: .toolFollowUpRebuild,
      currentHistory: followUpHistory,
      currentIdentity: identity,
      cachedPrefix: prefix,
      cachedIdentity: identity,
      appendOnly: MLXSessionCachePolicy.isPrefix(prefix, of: followUpHistory),
      mismatchReason: "tool_follow_up_response",
      firstMismatchIndex: nil
    )

    #expect(trace.cacheMode == .dirtyRebuild)
    #expect(trace.cacheReason == .toolFollowUpRebuild)
    #expect(MLXSessionCacheReason.toolFollowUpRebuild.rawValue == "tool_follow_up_rebuild")
    #expect(trace.mismatchReason == "tool_follow_up_response")
  }

  @Test
  func cacheTraceReportsHistoryMismatch() {
    let prefix = MLXHistoryRenderer.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    let changedHistory = MLXHistoryRenderer.messageSnapshot(from: [
      .user("hello"),
      .assistant("different"),
    ])
    let identity = MLXSessionCachePolicy.cacheIdentity(
      systemPrompt: "Use concise coding steps.",
      settings: .agentDefault,
      projectionMode: .fullHistory
    )

    let trace = MLXSessionCachePolicy.trace(
      mode: .dirtyRebuild,
      reason: .historyChanged,
      currentHistory: changedHistory,
      currentIdentity: identity,
      cachedPrefix: prefix,
      cachedIdentity: identity,
      appendOnly: MLXSessionCachePolicy.isPrefix(prefix, of: changedHistory),
      mismatchReason: "history_changed",
      firstMismatchIndex: MLXSessionCachePolicy.firstMismatchIndex(
        cachedPrefix: prefix,
        currentHistory: changedHistory
      )
    )

    #expect(trace.cacheMode == .dirtyRebuild)
    #expect(trace.cacheReason == .historyChanged)
    #expect(!trace.appendOnly)
    #expect(trace.mismatchReason == "history_changed")
    #expect(trace.firstMismatchIndex == 1)
  }

  @Test
  func cacheInvalidationReasonsMapToDirtyRebuildReasons() {
    #expect(
      MLXSessionCacheReason.generationInvalidationReason(from: .cancelled)
        == .invalidatedGenCancelled)
    #expect(
      MLXSessionCacheReason.generationInvalidationReason(from: .interrupted)
        == .invalidatedGenInterrupted)
    #expect(
      MLXSessionCacheReason.generationInvalidationReason(from: .downstreamTerminated)
        == .invalidatedGenDownstreamTerminated)
    #expect(
      MLXSessionCacheReason.generationInvalidationReason(from: .runtimeError)
        == .invalidatedGenRuntimeError)
  }

  @Test
  func modelStreamMarksConsumerTerminationAsDownstreamTerminated() async throws {
    let recorder = MLXStreamInvalidationRecorder()
    try await consumeFirstModelStreamEvent(recorder: recorder)

    try await waitUntilAsync {
      await recorder.firstReason != nil
    }
    #expect(await recorder.firstReason == .downstreamTerminated)
  }

  @Test
  func modelStreamPlanCancelsUpstreamTaskWhenConsumerTerminates() async throws {
    let recorder = MLXStreamInvalidationRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      let task = Task {
        try? await Task.sleep(for: .seconds(5))
        continuation.yield(.chunk("late"))
      }
      continuation.yield(.chunk("tool"))
      continuation.onTermination = { _ in
        task.cancel()
      }
    }
    var plan: MLXModelStreamPlan? = MLXModelStreamProcessor.modelStreamPlan(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { _ in },
      markCancelled: { reason in
        await recorder.record(reason)
      },
      memoryCacheClearer: MLXMemoryCacheClearer { _ in }
    )
    let upstreamTask = try #require(plan?.task)
    var outputStream: AsyncThrowingStream<ChatModelStreamEvent, Error>? = try #require(plan?.stream)
    plan = nil

    let (firstEventStream, firstEventContinuation) = AsyncStream<Void>.makeStream()
    let consumerTask = consumeFirstEventAndWait(
      from: try #require(outputStream),
      firstEventContinuation: firstEventContinuation
    )
    outputStream = nil
    defer {
      consumerTask.cancel()
    }

    _ = try await withTestTimeout(.seconds(5)) {
      var firstEventIterator = firstEventStream.makeAsyncIterator()
      return await firstEventIterator.next()
    }
    consumerTask.cancel()
    try await withTestTimeout(.seconds(5)) {
      await consumerTask.value
    }
    try await waitUntilAsync {
      let firstReason = await recorder.firstReason
      return upstreamTask.isCancelled && firstReason == .downstreamTerminated
    }
  }

  @Test
  func modelStreamMemoryClearPolicyClearsOnlyDirtyRuntimeState() {
    #expect(MLXModelStreamProcessor.memoryClearReason(for: .completed) == nil)
    #expect(MLXModelStreamProcessor.memoryClearReason(for: .downstreamTerminated) == nil)
    #expect(MLXModelStreamProcessor.memoryClearReason(for: .cancelled) == nil)
    #expect(MLXModelStreamProcessor.memoryClearReason(for: .nativeToolCallBoundary) == nil)
    #expect(MLXModelStreamProcessor.memoryClearReason(for: .runtimeError) == .runtimeError)
    #expect(
      MLXModelStreamProcessor.memoryClearReason(for: .interruptedStream) == .interruptedStream)
  }

  @Test
  func completedModelStreamDoesNotClearMemoryCache() async throws {
    let memoryClearRecorder = MLXMemoryClearRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("done"))
      continuation.yield(
        .info(
          GenerateCompletionInfo(
            promptTokenCount: 8,
            generationTokenCount: 1,
            promptTime: 0.1,
            generationTime: 0.1
          )
        ))
      continuation.finish()
    }
    let stream = MLXModelStreamProcessor.modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { _ in },
      markCancelled: { _ in },
      memoryCacheClearer: MLXMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    try await drainModelStream(stream)

    #expect(await memoryClearRecorder.reasons.isEmpty)
  }

  @Test
  func tokenLimitedModelStreamFailsInsteadOfCompletingTruncatedOutput() async throws {
    let memoryClearRecorder = MLXMemoryClearRecorder()
    let invalidationRecorder = MLXStreamInvalidationRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("<tool_call><function=write_file>partial"))
      continuation.yield(
        .info(
          GenerateCompletionInfo(
            promptTokenCount: 8,
            generationTokenCount: 2_048,
            promptTime: 0.1,
            generationTime: 1,
            stopReason: .length
          )
        ))
      continuation.finish()
    }
    let stream = MLXModelStreamProcessor.modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { _ in
        Issue.record("A token-limited response must not be marked complete.")
      },
      markCancelled: { reason in
        await invalidationRecorder.record(reason)
      },
      memoryCacheClearer: MLXMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    do {
      try await drainModelStream(stream)
      Issue.record("Expected token-limit failure.")
    } catch MLXChatRuntimeError.generationTokenLimitReached {
      #expect(await invalidationRecorder.firstReason == .interrupted)
      #expect(await memoryClearRecorder.reasons == [.interruptedStream])
    } catch {
      Issue.record("Expected token-limit error, got \(error).")
    }
  }

  @Test
  func thoughtChannelParserSplitsThoughtBlocksAcrossChunks() {
    var parser = GemmaThoughtChannelParser()

    let segments = [
      parser.append("<|chan"),
      parser.append("nel|>thought The user said hey."),
      parser.append(" I should greet them.<chan"),
      parser.append("nel|>Hello"),
      parser.append(" there."),
      parser.finish(),
    ].flatMap { $0 }

    #expect(
      segments == [
        .thinking(" The user said hey."),
        .thinking(" I should greet them."),
        .visible("Hello"),
        .visible(" there."),
      ])
  }

  @Test
  func thoughtChannelParserSupportsAsymmetricThoughtMarker() {
    var parser = GemmaThoughtChannelParser()

    let segments = [
      parser.append("<|chan"),
      parser.append("nel>thought I should answer."),
      parser.append("<channel|>Done."),
      parser.finish(),
    ].flatMap { $0 }

    #expect(
      segments == [
        .thinking(" I should answer."),
        .visible("Done."),
      ])
  }

  @Test
  func modelStreamSeparatesThoughtChannelChunks() async throws {
    let memoryClearRecorder = MLXMemoryClearRecorder()
    let completionRecorder = MLXStreamCompletionRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("<|channel>thought"))
      continuation.yield(.chunk(" The user said hey."))
      continuation.yield(.chunk("<channel|>Hello"))
      continuation.yield(.chunk(" there."))
      continuation.yield(
        .info(
          GenerateCompletionInfo(
            promptTokenCount: 8,
            generationTokenCount: 8,
            promptTime: 0.1,
            generationTime: 0.1
          )
        ))
      continuation.finish()
    }
    let stream = MLXModelStreamProcessor.modelStream(
      from: source,
      reasoningTraceFormat: .gemmaChannel,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { output in
        await completionRecorder.record(output)
      },
      markCancelled: { _ in },
      memoryCacheClearer: MLXMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    var chunks: [String] = []
    var thinkingChunks: [String] = []
    var iterator = stream.makeAsyncIterator()
    while let event = try await iterator.next() {
      switch event {
      case .chunk(let chunk):
        chunks.append(chunk)
      case .thinkingChunk(let chunk):
        thinkingChunks.append(chunk)
      case .toolCall, .completed:
        break
      }
    }

    #expect(chunks.joined() == "Hello there.")
    #expect(thinkingChunks.joined() == " The user said hey.")
    #expect(await completionRecorder.firstOutput == "Hello there.")
    #expect(await memoryClearRecorder.reasons.isEmpty)
  }

  @Test
  func qwenThinkTagParserStartsInThinkingMode() {
    var parser = QwenThinkTagParser()

    let segments = [
      parser.append("The user said hey."),
      parser.append("</th"),
      parser.append("ink>\n\nHello."),
      parser.finish(),
    ].flatMap { $0 }

    #expect(
      segments == [
        .thinking("The user said hey."),
        .visible("\n\nHello."),
      ])
  }

  @Test
  func qwenThinkTagParserStripsOptionalOpeningTag() {
    var parser = QwenThinkTagParser()

    let segments = [
      parser.append("<th"),
      parser.append("ink>Reasoning"),
      parser.append("</think>Answer"),
      parser.finish(),
    ].flatMap { $0 }

    #expect(
      segments == [
        .thinking("Reasoning"),
        .visible("Answer"),
      ])
  }

  @Test
  func modelStreamSeparatesQwenThinkTagChunks() async throws {
    let memoryClearRecorder = MLXMemoryClearRecorder()
    let completionRecorder = MLXStreamCompletionRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("The user said hey."))
      continuation.yield(.chunk("</th"))
      continuation.yield(.chunk("ink>\n\nHello"))
      continuation.yield(.chunk(" there."))
      continuation.yield(
        .info(
          GenerateCompletionInfo(
            promptTokenCount: 8,
            generationTokenCount: 8,
            promptTime: 0.1,
            generationTime: 0.1
          )
        ))
      continuation.finish()
    }
    let stream = MLXModelStreamProcessor.modelStream(
      from: source,
      reasoningTraceFormat: .qwenThinkTags,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { output in
        await completionRecorder.record(output)
      },
      markCancelled: { _ in },
      memoryCacheClearer: MLXMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    var chunks: [String] = []
    var thinkingChunks: [String] = []
    var iterator = stream.makeAsyncIterator()
    while let event = try await iterator.next() {
      switch event {
      case .chunk(let chunk):
        chunks.append(chunk)
      case .thinkingChunk(let chunk):
        thinkingChunks.append(chunk)
      case .toolCall, .completed:
        break
      }
    }

    #expect(chunks.joined() == "\n\nHello there.")
    #expect(thinkingChunks.joined() == "The user said hey.")
    #expect(await completionRecorder.firstOutput == "\n\nHello there.")
    #expect(await memoryClearRecorder.reasons.isEmpty)
  }

  @Test
  func cancellationModelStreamDoesNotClearMemoryCache() async throws {
    let memoryClearRecorder = MLXMemoryClearRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("partial"))
      continuation.finish(throwing: CancellationError())
    }
    let stream = MLXModelStreamProcessor.modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { _ in },
      markCancelled: { _ in },
      memoryCacheClearer: MLXMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    do {
      try await drainModelStream(stream)
      Issue.record("Expected cancellation to propagate from model stream.")
    } catch is CancellationError {
      #expect(await memoryClearRecorder.reasons.isEmpty)
    }
  }

  @Test
  func runtimeErrorModelStreamClearsMemoryCache() async throws {
    let memoryClearRecorder = MLXMemoryClearRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("partial"))
      continuation.finish(throwing: MLXTestStreamError())
    }
    let stream = MLXModelStreamProcessor.modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { _ in },
      markCancelled: { _ in },
      memoryCacheClearer: MLXMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    do {
      try await drainModelStream(stream)
      Issue.record("Expected runtime error to propagate from model stream.")
    } catch is MLXTestStreamError {
      #expect(await memoryClearRecorder.reasons == [.runtimeError])
    }
  }

  @Test
  func interruptedModelStreamClearsMemoryCache() async throws {
    let memoryClearRecorder = MLXMemoryClearRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("partial"))
      continuation.finish()
    }
    let stream = MLXModelStreamProcessor.modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { _ in },
      markCancelled: { _ in },
      memoryCacheClearer: MLXMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    do {
      try await drainModelStream(stream)
      Issue.record("Expected interrupted stream to throw.")
    } catch MLXChatRuntimeError.interruptedStream {
      #expect(await memoryClearRecorder.reasons == [.interruptedStream])
    } catch {
      Issue.record("Expected interrupted stream error, got \(error).")
    }
  }

  @Test
  func unloadAndClearContextClearMemoryCacheWithExplicitReasons() async {
    let memoryClearRecorder = MLXMemoryClearRecorder()
    let runtime = MLXChatRuntime(
      memoryCacheClearer: MLXMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      },
      debugTraceStore: temporaryDebugTraceStore()
    )

    await runtime.unload()
    await runtime.clearContext()

    #expect(await memoryClearRecorder.reasons == [.unload, .clearContext])
  }

  @Test
  func unloadWaitsForActiveGenerationToDrainBeforeClearingMemoryCache() async throws {
    try await assertLifecycleOperationDrainsBeforeMemoryClear(reason: .unload) { runtime in
      await runtime.unload()
    }
  }

  @Test
  func clearContextWaitsForActiveGenerationToDrainBeforeClearingMemoryCache() async throws {
    try await assertLifecycleOperationDrainsBeforeMemoryClear(reason: .clearContext) { runtime in
      await runtime.clearContext()
    }
  }

  @Test
  func modelStreamCompletesNativeToolCallAsCleanBoundary() async throws {
    let recorder = MLXStreamInvalidationRecorder()
    let boundaryRecorder = MLXNativeBoundaryRecorder()
    let memoryClearRecorder = MLXMemoryClearRecorder()
    let toolCall = MLXLMCommon.ToolCall(
      function: .init(
        name: "read_file",
        arguments: ["path": "README.md"]
      )
    )
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.toolCall(toolCall))
      continuation.yield(
        .info(
          GenerateCompletionInfo(
            promptTokenCount: 8,
            generationTokenCount: 1,
            promptTime: 0.1,
            generationTime: 0.1
          )
        ))
      continuation.finish()
    }
    let stream = MLXModelStreamProcessor.modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { _ in
        await recorder.record(.signatureMismatch)
      },
      markNativeToolCallBoundary: { output, nativeToolCalls in
        await boundaryRecorder.record(output: output, nativeToolCalls: nativeToolCalls)
      },
      markCancelled: { reason in
        await recorder.record(reason)
      },
      memoryCacheClearer: MLXMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    var iterator = stream.makeAsyncIterator()
    let firstEvent = try await iterator.next()
    guard case .toolCall(let runtimeToolCall) = firstEvent else {
      Issue.record("Expected native tool call to be forwarded to the chat runtime.")
      return
    }
    #expect(runtimeToolCall.name == "read_file")

    _ = try await iterator.next()
    try await waitUntilAsync {
      await boundaryRecorder.firstBoundary?.nativeToolCalls.count == 1
    }
    #expect(await recorder.firstReason == nil)
    #expect(await boundaryRecorder.firstBoundary?.output == "")
    #expect(await boundaryRecorder.firstBoundary?.nativeToolCalls.first?.name == "read_file")
    #expect(await memoryClearRecorder.reasons.isEmpty)
  }

  @Test
  func modelStreamCompletesNativeToolCallWithoutInfoAsCleanBoundary() async throws {
    let recorder = MLXStreamInvalidationRecorder()
    let boundaryRecorder = MLXNativeBoundaryRecorder()
    let memoryClearRecorder = MLXMemoryClearRecorder()
    let toolCall = MLXLMCommon.ToolCall(
      function: .init(
        name: "read_file",
        arguments: ["path": "README.md"]
      )
    )
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.toolCall(toolCall))
      continuation.finish()
    }
    let stream = MLXModelStreamProcessor.modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { _ in
        await recorder.record(.signatureMismatch)
      },
      markNativeToolCallBoundary: { output, nativeToolCalls in
        await boundaryRecorder.record(output: output, nativeToolCalls: nativeToolCalls)
      },
      markCancelled: { reason in
        await recorder.record(reason)
      },
      memoryCacheClearer: MLXMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    var iterator = stream.makeAsyncIterator()
    let firstEvent = try await iterator.next()
    guard case .toolCall(let runtimeToolCall) = firstEvent else {
      Issue.record("Expected native tool call to be forwarded to the chat runtime.")
      return
    }
    #expect(runtimeToolCall.name == "read_file")
    #expect(try await iterator.next() == nil)
    try await waitUntilAsync {
      await boundaryRecorder.firstBoundary?.nativeToolCalls.count == 1
    }
    #expect(await recorder.firstReason == nil)
    #expect(await boundaryRecorder.firstBoundary?.output == "")
    #expect(await memoryClearRecorder.reasons.isEmpty)
  }

  @Test
  func modelStreamNormalizesDuplicateNativeToolCallIDs() async throws {
    let boundaryRecorder = MLXNativeBoundaryRecorder()
    let duplicateID = "call_0123456789ABCDEF0123456789ABCDEF"
    let firstToolCall = MLXLMCommon.ToolCall(
      function: .init(name: "read_file", arguments: ["path": "README.md"]),
      id: duplicateID
    )
    let secondToolCall = MLXLMCommon.ToolCall(
      function: .init(name: "list_files", arguments: ["path": "."]),
      id: duplicateID
    )
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.toolCall(firstToolCall))
      continuation.yield(.toolCall(secondToolCall))
      continuation.yield(
        .info(
          GenerateCompletionInfo(
            promptTokenCount: 8,
            generationTokenCount: 1,
            promptTime: 0.1,
            generationTime: 0.1
          )
        ))
      continuation.finish()
    }
    let stream = MLXModelStreamProcessor.modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { _ in },
      markNativeToolCallBoundary: { output, nativeToolCalls in
        await boundaryRecorder.record(output: output, nativeToolCalls: nativeToolCalls)
      },
      markCancelled: { _ in },
      memoryCacheClearer: MLXMemoryCacheClearer { _ in }
    )

    var iterator = stream.makeAsyncIterator()
    let firstEvent = try await iterator.next()
    let secondEvent = try await iterator.next()
    guard case .toolCall(let firstRuntimeToolCall) = firstEvent,
      case .toolCall(let secondRuntimeToolCall) = secondEvent
    else {
      Issue.record("Expected two native tool call events.")
      return
    }
    _ = try await iterator.next()
    try await waitUntilAsync {
      await boundaryRecorder.firstBoundary?.nativeToolCalls.count == 2
    }

    #expect(firstRuntimeToolCall.id == "call_0123456789abcdef0123456789abcdef")
    #expect(secondRuntimeToolCall.id != firstRuntimeToolCall.id)
    #expect(RuntimeToolCallID.uuid(from: secondRuntimeToolCall.id) != nil)
    #expect(
      await boundaryRecorder.firstBoundary?.nativeToolCalls.map(\.id)
        == [firstRuntimeToolCall.id, secondRuntimeToolCall.id])
  }

  @Test
  func nativeMLXToolContextMapsRegistryToMLXToolSpecs() throws {
    let toolContext = ChatRuntimeToolContext(
      registry: ToolExecutorRegistry.readOnly.toolRegistry
    )

    let specs = try #require(MLXToolMapper.toolSpecs(from: toolContext))
    let readFileSpec = try #require(
      specs.first { spec in
        let function = spec["function"] as? [String: any Sendable]
        return function?["name"] as? String == "read_file"
      })
    let function = try #require(readFileSpec["function"] as? [String: any Sendable])
    let parameters = try #require(function["parameters"] as? [String: any Sendable])
    let properties = try #require(parameters["properties"] as? [String: any Sendable])
    let path = try #require(properties["path"] as? [String: any Sendable])
    let limit = try #require(properties["limit"] as? [String: any Sendable])

    #expect(readFileSpec["type"] as? String == "function")
    #expect(parameters["type"] as? String == "object")
    #expect(parameters["additionalProperties"] as? Bool == false)
    #expect(path["type"] as? String == "string")
    #expect(limit["type"] as? String == "integer")
  }

  @Test
  func nativeMLXFinishTaskSchemaIsClosedRequiredAndAgentOnly() throws {
    let agentContext = ChatRuntimeToolContext(
      registry: ToolExecutorRegistry.codingAgentRegistry(todoWriteEnabled: false).toolRegistry
    )

    let agentSpecs = try #require(MLXToolMapper.toolSpecs(from: agentContext))
    let finishSpec = try #require(
      agentSpecs.first { spec in
        let function = spec["function"] as? [String: any Sendable]
        return function?["name"] as? String == ToolName.finishTask.rawValue
      })
    let function = try #require(finishSpec["function"] as? [String: any Sendable])
    let parameters = try #require(function["parameters"] as? [String: any Sendable])
    let properties = try #require(parameters["properties"] as? [String: any Sendable])
    let status = try #require(properties["status"] as? [String: any Sendable])
    let summary = try #require(properties["summary"] as? [String: any Sendable])

    #expect(parameters["additionalProperties"] as? Bool == false)
    #expect(parameters["required"] as? [String] == ["status", "summary"])
    #expect(status["type"] as? String == "string")
    #expect(status["enum"] as? [String] == ["done", "blocked", "needs_user"])
    #expect(summary["type"] as? String == "string")

    let chatWebContext = ChatRuntimeToolContext(
      registry: ToolExecutorRegistry.chatWeb.toolRegistry
    )
    let chatWebSpecs = try #require(MLXToolMapper.toolSpecs(from: chatWebContext))
    #expect(
      chatWebSpecs.contains { spec in
        let function = spec["function"] as? [String: any Sendable]
        return function?["name"] as? String == ToolName.finishTask.rawValue
      } == false)
  }

  @Test
  func nativeMLXNilToolContextProducesNoToolSpecs() {
    #expect(MLXToolMapper.toolSpecs(from: nil) == nil)
  }

  @Test
  func nativeMLXToolContextPassesRawParametersSchemaThroughVerbatim() throws {
    let rawSchema = ToolArgumentValue.object([
      "type": .string("object"),
      "properties": .object([
        "filter": .object([
          "type": .string("object"),
          "properties": .object([
            "state": .object([
              "type": .string("string"),
              "enum": .array([.string("open"), .string("closed")]),
            ])
          ]),
        ])
      ]),
      "required": .array([.string("filter")]),
    ])
    let definition = ToolDefinition(
      name: ToolName(rawValue: "mcp__github__list_issues"),
      description: "List issues.",
      parameters: [],
      rawParametersSchema: rawSchema,
      capabilities: [.externalService],
      riskLevel: .high
    )
    let toolContext = ChatRuntimeToolContext(registry: ToolRegistry(tools: [definition]))

    let specs = try #require(MLXToolMapper.toolSpecs(from: toolContext))
    let function = try #require(specs.first?["function"] as? [String: any Sendable])
    let parameters = try #require(function["parameters"] as? [String: any Sendable])
    let properties = try #require(parameters["properties"] as? [String: any Sendable])
    let filter = try #require(properties["filter"] as? [String: any Sendable])
    let filterProperties = try #require(filter["properties"] as? [String: any Sendable])
    let state = try #require(filterProperties["state"] as? [String: any Sendable])

    #expect(function["name"] as? String == "mcp__github__list_issues")
    #expect(parameters["required"] as? [String] == ["filter"])
    #expect(filter["type"] as? String == "object")
    #expect(state["enum"] as? [String] == ["open", "closed"])
  }

  @Test
  func nativeMLXToolContextDropsNullValuesFromRawSchema() throws {
    // pydantic-based MCP servers (e.g. mcp-server-git) emit `"default": null`;
    // the Jinja chat-template engine cannot convert NSNull, so nulls must not
    // survive the ToolSpec mapping.
    let rawSchema = ToolArgumentValue.object([
      "type": .string("object"),
      "properties": .object([
        "start_timestamp": .object([
          "type": .string("string"),
          "default": .null,
        ])
      ]),
    ])
    let definition = ToolDefinition(
      name: ToolName(rawValue: "mcp__git__git_log"),
      description: "Show commit logs.",
      parameters: [],
      rawParametersSchema: rawSchema,
      capabilities: [.externalService],
      riskLevel: .high
    )
    let toolContext = ChatRuntimeToolContext(registry: ToolRegistry(tools: [definition]))

    let specs = try #require(MLXToolMapper.toolSpecs(from: toolContext))
    let function = try #require(specs.first?["function"] as? [String: any Sendable])
    let parameters = try #require(function["parameters"] as? [String: any Sendable])
    let properties = try #require(parameters["properties"] as? [String: any Sendable])
    let startTimestamp = try #require(properties["start_timestamp"] as? [String: any Sendable])

    #expect(startTimestamp["type"] as? String == "string")
    #expect(startTimestamp.keys.contains("default") == false)
    #expect(containsNSNull(parameters) == false)
  }

  private func containsNSNull(_ value: Any) -> Bool {
    if value is NSNull {
      return true
    }
    if let dict = value as? [String: Any] {
      return dict.values.contains(where: containsNSNull(_:))
    }
    if let array = value as? [Any] {
      return array.contains(where: containsNSNull(_:))
    }
    return false
  }

  @Test
  func nativeMLXToolContextDefinesSimpleParametersAsStrings() throws {
    let toolContext = ChatRuntimeToolContext(
      registry: ToolExecutorRegistry.codingAgent.toolRegistry
    )

    let specs = try #require(MLXToolMapper.toolSpecs(from: toolContext))
    let todoSpec = try #require(
      specs.first { spec in
        let function = spec["function"] as? [String: any Sendable]
        return function?["name"] as? String == "todo_write"
      })
    let function = try #require(todoSpec["function"] as? [String: any Sendable])
    let parameters = try #require(function["parameters"] as? [String: any Sendable])
    let properties = try #require(parameters["properties"] as? [String: any Sendable])
    let item1 = try #require(properties["item1"] as? [String: any Sendable])
    let item2 = try #require(properties["item2"] as? [String: any Sendable])
    let done1 = try #require(properties["done1"] as? [String: any Sendable])
    let askSpec = try #require(
      specs.first { spec in
        let function = spec["function"] as? [String: any Sendable]
        return function?["name"] as? String == "ask_user"
      })
    let askFunction = try #require(askSpec["function"] as? [String: any Sendable])
    let askParameters = try #require(askFunction["parameters"] as? [String: any Sendable])
    let askProperties = try #require(askParameters["properties"] as? [String: any Sendable])
    let option1 = try #require(askProperties["option1"] as? [String: any Sendable])
    let option2 = try #require(askProperties["option2"] as? [String: any Sendable])

    #expect(item1["type"] as? String == "string")
    #expect(item1["items"] == nil)
    #expect(item2["type"] as? String == "string")
    #expect(item2["items"] == nil)
    #expect(done1["type"] as? String == "boolean")
    #expect(done1["items"] == nil)
    #expect(option1["type"] as? String == "string")
    #expect(option1["items"] == nil)
    #expect(option2["type"] as? String == "string")
    #expect(option2["items"] == nil)
  }

  @Test
  func mlxToolCallMapsToRuntimeToolCallArguments() {
    let mlxToolCall = MLXLMCommon.ToolCall(
      function: .init(
        name: "read_file",
        arguments: [
          "path": .string("README.md"),
          "limit": .int(20),
          "include_hidden": .bool(false),
        ]
      )
    )

    let runtimeToolCall = MLXToolMapper.chatRuntimeToolCall(from: mlxToolCall)

    #expect(runtimeToolCall.name == "read_file")
    #expect(runtimeToolCall.arguments["path"] == .string("README.md"))
    #expect(runtimeToolCall.arguments["limit"] == .number(20))
    #expect(runtimeToolCall.arguments["include_hidden"] == .bool(false))
  }

  private func consumeFirstEventAndWait(
    from stream: AsyncThrowingStream<ChatModelStreamEvent, Error>,
    firstEventContinuation: AsyncStream<Void>.Continuation
  ) -> Task<Void, Never> {
    Task {
      do {
        let firstEvent = try await withTestTimeout(.seconds(5)) {
          var iterator = stream.makeAsyncIterator()
          return try await iterator.next()
        }
        guard case .chunk("tool") = firstEvent else {
          Issue.record("Expected first model stream event to be the initial chunk.")
          firstEventContinuation.finish()
          return
        }
        firstEventContinuation.yield(())
        firstEventContinuation.finish()
        try await Task.sleep(for: .seconds(5))
      } catch {
        firstEventContinuation.finish()
      }
    }
  }

  private func consumeFirstModelStreamEvent(recorder: MLXStreamInvalidationRecorder) async throws {
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      let task = Task {
        continuation.yield(.chunk("tool"))
        try? await Task.sleep(for: .seconds(5))
        continuation.yield(.chunk("late"))
      }
      continuation.onTermination = { _ in
        task.cancel()
      }
    }
    let stream = MLXModelStreamProcessor.modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      debugTraceStore: temporaryDebugTraceStore(),
      markCompleted: { _ in },
      markCancelled: { reason in
        await recorder.record(reason)
      },
      memoryCacheClearer: MLXMemoryCacheClearer { _ in }
    )

    do {
      let firstEvent = try await withTestTimeout(.seconds(5)) {
        var iterator = stream.makeAsyncIterator()
        return try await iterator.next()
      }
      guard case .chunk("tool") = firstEvent else {
        Issue.record("Expected first model stream event to be the initial chunk.")
        return
      }
    }
  }

  private func drainModelStream(
    _ stream: AsyncThrowingStream<ChatModelStreamEvent, Error>
  ) async throws {
    var iterator = stream.makeAsyncIterator()
    while try await iterator.next() != nil {}
  }

  private func temporaryDebugTraceStore() -> MLXDebugTraceStore {
    MLXDebugTraceStore(
      fileURL: FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        .appending(path: "mlx-trace.jsonl", directoryHint: .notDirectory)
    )
  }

  private func assertLifecycleOperationDrainsBeforeMemoryClear(
    reason: MLXMemoryClearReason,
    operation: @escaping @Sendable (MLXChatRuntime) async -> Void
  ) async throws {
    let recorder = MLXLifecycleDrainRecorder()
    let runtime = MLXChatRuntime(
      memoryCacheClearer: MLXMemoryCacheClearer { reason in
        await recorder.record(.memoryClear(reason))
      },
      debugTraceStore: temporaryDebugTraceStore()
    )
    let task = Task<Void, Never> {
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(10))
      }
      await recorder.record(.taskCancelled)
      await recorder.waitUntilAllowedToFinish()
      await recorder.record(.taskFinished)
    }
    await runtime.registerActiveGenerationForTesting(id: MLXGenerationID(rawValue: 1), task: task)

    let lifecycleTask = Task {
      await operation(runtime)
    }
    defer {
      task.cancel()
      lifecycleTask.cancel()
    }

    try await waitUntilAsync {
      await recorder.events.contains(.taskCancelled)
    }
    #expect(await recorder.events == [.taskCancelled])

    await recorder.allowTaskToFinish()
    try await withTestTimeout(.seconds(5)) {
      await lifecycleTask.value
    }

    #expect(await recorder.events == [.taskCancelled, .taskFinished, .memoryClear(reason)])
  }

  private func projectedEntries(
    from entries: [ModelContextEntry]
  ) -> [ProjectedModelContextEntry] {
    ModelPromptProjection(entries: entries)
      .projectedEntries(mode: MLXHistoryRenderer.runtimeProjectionMode)
  }

  private func workspaceInstructionsTurn(
    prompt: String,
    response: String,
    state: WorkspaceInstructionsPromptContext? = nil
  ) -> ChatTurn {
    let baseContext = CurrentPromptContext.empty(.focusedFileDefault)
    let promptContext = state.map(baseContext.appendingWorkspaceInstructions) ?? baseContext
    return ChatTurn(
      status: .completed,
      items: [
        .userMessage(UserTurnMessage(content: prompt, promptContext: promptContext)),
        .assistantMessage(AssistantTurnMessage(content: response)),
      ]
    )
  }

  private func workspaceInstructionsProviderMessages(
    turns: [ChatTurn]
  ) -> [ProviderPromptMessage] {
    ProviderPromptProjection.normalized(
      from: ChatModelContextBuilder().transcript(
        from: ChatSession(turns: turns, interactionMode: .agent)
      )
    ).messages
  }

  private func generationInput(
    from entries: [ModelContextEntry]
  ) throws -> MLXGenerationInput {
    try MLXHistoryRenderer.generationInput(from: ModelPromptProjection(entries: entries))
  }

  private func generationHistoryAndPrompt(
    from entries: [ModelContextEntry]
  ) throws -> (history: [Chat.Message], prompt: Chat.Message) {
    let projectedEntries = projectedEntries(from: entries)
    let lastPromptIndex = try #require(
      projectedEntries.lastIndex { $0.role == .user || $0.role == .tool }
    )
    let history = try MLXHistoryRenderer.generationHistoryMessages(
      from: projectedEntries[..<lastPromptIndex]
    )
    let prompt = MLXHistoryRenderer.chatMessage(from: projectedEntries[lastPromptIndex])
    return (history, prompt)
  }

  private func writeFileToolCall(
    callID: UUID,
    arguments: ToolCallArguments
  ) -> ToolCallModelMessage {
    ToolCallModelMessage(
      rawRequest: RawToolCallRequest(
        id: callID,
        workspaceID: UUID(),
        sessionID: UUID(),
        toolName: .writeFile,
        arguments: arguments
      ))
  }

  private func toolCallContent(
    callID: UUID,
    toolName: ToolName,
    arguments: ToolCallArguments
  ) -> String {
    ToolCallModelMessage(
      rawRequest: RawToolCallRequest(
        id: callID,
        workspaceID: UUID(),
        sessionID: UUID(),
        toolName: toolName,
        arguments: arguments
      )
    ).modelContextContent
  }

  private func toolRequest(
    callID: UUID,
    toolName: ToolName,
    arguments: ToolCallArguments
  ) -> ToolCallRequest {
    let rawRequest = RawToolCallRequest(
      id: callID,
      workspaceID: UUID(),
      sessionID: UUID(),
      toolName: toolName,
      arguments: arguments
    )
    return ToolCallRequestValidator().validate(
      rawRequest,
      registry: ToolExecutorRegistry.codingAgent.toolRegistry
    )
  }

  private func defaultCacheTrace() -> MLXSessionCacheTrace {
    MLXSessionCacheTrace(
      cacheMode: .newSession,
      cacheReason: .newSessionNoCache,
      contextSignature: "context",
      previousContextSignature: nil,
      appendOnly: false,
      reusedMessageCount: 0,
      appendedMessageCount: 0,
      mismatchReason: nil,
      firstMismatchIndex: nil,
      systemPromptChanged: nil,
      currentPromptContextChanged: nil
    )
  }
}

private struct EOSStopTestTokenIterator: TokenIteratorProtocol {
  let tokens: [Int]
  private var index = 0
  private(set) var tokenCount = 0

  var maxTokens: Int? {
    tokens.count
  }

  var promptPrefillTime: TimeInterval {
    0
  }

  init(tokens: [Int]) {
    self.tokens = tokens
  }

  func makeIterator() -> EOSStopTestTokenIterator {
    self
  }

  mutating func next() -> Int? {
    guard index < tokens.count else {
      return nil
    }
    defer {
      index += 1
      tokenCount += 1
    }
    return tokens[index]
  }

  mutating func discardGeneratedToken() {}
}

private struct EOSStopTestTokenizer: Tokenizer {
  func encode(text: String, addSpecialTokens: Bool) -> [Int] {
    text.utf8.map(Int.init)
  }

  func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
    tokenIds.map { tokenID in
      switch tokenID {
      case 65:
        "A"
      case 66:
        "B"
      case 106:
        "<eot>"
      default:
        ""
      }
    }.joined()
  }

  func convertTokenToId(_ token: String) -> Int? {
    nil
  }

  func convertIdToToken(_ id: Int) -> String? {
    nil
  }

  var bosToken: String? {
    nil
  }

  var eosToken: String? {
    nil
  }

  var unknownToken: String? {
    nil
  }

  func applyChatTemplate(
    messages: [[String: any Sendable]],
    tools: [[String: any Sendable]]?,
    additionalContext: [String: any Sendable]?
  ) throws -> [Int] {
    []
  }
}

private actor MLXStreamInvalidationRecorder {
  private var reasons: [MLXSessionInvalidationReason] = []

  var firstReason: MLXSessionInvalidationReason? {
    reasons.first
  }

  func record(_ reason: MLXSessionInvalidationReason) {
    reasons.append(reason)
  }
}

private actor MLXStreamCompletionRecorder {
  private var outputs: [String] = []

  var firstOutput: String? {
    outputs.first
  }

  func record(_ output: String) {
    outputs.append(output)
  }
}

private actor MLXNativeBoundaryRecorder {
  private var boundaries: [(output: String, nativeToolCalls: [ChatRuntimeToolCall])] = []

  var firstBoundary: (output: String, nativeToolCalls: [ChatRuntimeToolCall])? {
    boundaries.first
  }

  func record(output: String, nativeToolCalls: [ChatRuntimeToolCall]) {
    boundaries.append((output, nativeToolCalls))
  }
}

private actor MLXMemoryClearRecorder {
  private var recordedReasons: [MLXMemoryClearReason] = []

  var reasons: [MLXMemoryClearReason] {
    recordedReasons
  }

  func record(_ reason: MLXMemoryClearReason) {
    recordedReasons.append(reason)
  }
}

private enum MLXLifecycleDrainEvent: Equatable {
  case taskCancelled
  case taskFinished
  case memoryClear(MLXMemoryClearReason)
}

private actor MLXLifecycleDrainRecorder {
  private var recordedEvents: [MLXLifecycleDrainEvent] = []
  private var shouldFinish = false
  private var finishContinuation: CheckedContinuation<Void, Never>?

  var events: [MLXLifecycleDrainEvent] {
    recordedEvents
  }

  func record(_ event: MLXLifecycleDrainEvent) {
    recordedEvents.append(event)
  }

  func waitUntilAllowedToFinish() async {
    if shouldFinish {
      return
    }

    await withCheckedContinuation { continuation in
      finishContinuation = continuation
    }
  }

  func allowTaskToFinish() {
    shouldFinish = true
    finishContinuation?.resume()
    finishContinuation = nil
  }
}

private struct MLXTestStreamError: Error {}

private struct MLXStreamWaitTimeoutError: Error {}

private func waitUntilAsync(
  timeout: Duration = .seconds(2),
  condition: () async -> Bool
) async throws {
  let start = ContinuousClock.now
  while await condition() == false {
    if ContinuousClock.now - start > timeout {
      throw MLXStreamWaitTimeoutError()
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}
