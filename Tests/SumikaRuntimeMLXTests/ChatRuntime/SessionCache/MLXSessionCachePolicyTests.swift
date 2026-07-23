import Foundation
import MLXLMCommon
import Testing

@testable import SumikaCore
@testable import SumikaRuntimeMLX

#if canImport(SumikaTestSupport)
  import SumikaTestSupport
#endif
@Suite()
struct MLXSessionCachePolicyTests {
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
  func cacheContextSignatureCanonicalizesToolCallPayload() {
    let first = [
      ProviderPromptMessage(
        role: "assistant",
        content: "",
        toolCalls: [
          ProviderToolCall(
            id: "call-1",
            name: "read_file",
            arguments: ["z": .number(2), "a": .string("x")]
          )
        ]
      )
    ]
    let reordered = [
      ProviderPromptMessage(
        role: "assistant",
        content: "",
        toolCalls: [
          ProviderToolCall(
            id: "call-1",
            name: "read_file",
            arguments: ["a": .string("x"), "z": .number(2)]
          )
        ]
      )
    ]

    #expect(
      MLXSessionCachePolicy.contextSignature(for: first)
        == MLXSessionCachePolicy.contextSignature(for: reordered))
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
      systemPromptChanged: nil
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
  func cacheTraceReportsAppendOnlyDelta() {
    let prefix = providerMessages(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    let appendedHistory = providerMessages(from: [
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
    let prefix = providerMessages(from: [
      .user("hello"),
      .assistant("calling read_file"),
    ])
    let followUpHistory = providerMessages(from: [
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
    let prefix = providerMessages(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    let changedHistory = providerMessages(from: [
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

  private func providerMessages(
    from messages: [Chat.Message]
  ) -> [ProviderPromptMessage] {
    messages.map { message in
      ProviderPromptMessage(role: message.role.rawValue, content: message.content)
    }
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

}
