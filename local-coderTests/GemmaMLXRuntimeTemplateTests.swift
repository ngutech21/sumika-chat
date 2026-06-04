import Foundation
import LocalCoderCore
import MLXLMCommon
import Testing

@testable import local_coder

@Suite
struct GemmaMLXRuntimeTemplateTests {
  @Test
  func templateMessagesEmbedSystemPromptAndAlternateAfterTerminalWriteResult() throws {
    let callID = UUID()
    let messages: [ChatModelContextMessage] = [
      ChatModelContextMessage(role: .user, content: "create index.htm"),
      ChatModelContextMessage(
        role: .assistant,
        content: writeFileToolCall(
          callID: callID,
          arguments: [
            "path": .string("index.htm"),
            "content": .string("<html></html>"),
          ]
        ).modelContextContent
      ),
      ChatModelContextMessage(
        role: .assistant,
        content: ToolResultModelMessage(
          callID: callID,
          toolName: .writeFile,
          preview: ToolResultPreview(
            status: .success,
            text: "index.htm · 1 lines, 13 bytes",
            affectedPaths: ["index.htm"]
          )
        ).modelContextContent
      ),
      ChatModelContextMessage(role: .user, content: "change the background color to green"),
    ]

    let rendered = try GemmaMLXRuntime.templateMessages(
      from: messages,
      attachments: [],
      systemPrompt: "Use concise coding steps."
    )

    #expect(rendered.map(\.role) == [.user, .assistant, .user])
    #expect(!rendered[0].content.contains("System instructions:"))
    #expect(rendered[2].content.contains("System instructions:"))
    #expect(rendered[2].content.contains("Use concise coding steps."))
    #expect(rendered[1].content.contains("Tool call write_file requested."))
    #expect(rendered[1].content.contains("Tool write_file completed with status success."))
    #expect(!rendered.contains { $0.role == .system })
  }

  @Test
  func generationHistoryUsesFrozenSystemPromptSnapshot() throws {
    let callID = UUID()
    let messages: [ChatModelContextMessage] = [
      ChatModelContextMessage(
        role: .user,
        content: "create index.htm",
        systemPromptSnapshot: "Use concise coding steps."
      ),
      ChatModelContextMessage(
        role: .assistant,
        content: writeFileToolCall(
          callID: callID,
          arguments: ["path": .string("index.htm")]
        ).modelContextContent
      ),
      ChatModelContextMessage(
        role: .assistant,
        content: ToolResultModelMessage(
          callID: callID,
          toolName: .writeFile,
          preview: ToolResultPreview(
            status: .success,
            text: "index.htm · 1 lines, 13 bytes",
            affectedPaths: ["index.htm"]
          )
        ).modelContextContent
      ),
    ]

    let history = try GemmaMLXRuntime.generationHistoryMessages(
      from: messages[...],
      systemPrompt: "No tools may run now."
    )

    #expect(history.map(\.role) == [.user, .assistant])
    #expect(history[0].content.contains("System instructions:"))
    #expect(history[0].content.contains("Use concise coding steps."))
    #expect(!history[0].content.contains("No tools may run now."))
    #expect(!history.contains { $0.role == .system })
  }

  @Test
  func renderedHistoryDoesNotRewriteFirstUserWhenToolPromptModeChanges() throws {
    let initialUser = ChatModelContextMessage(
      role: .user,
      content: "create index.htm",
      systemPromptSnapshot: "When tools are available, use them."
    )
    let initialRendered = try GemmaMLXRuntime.templateMessages(
      from: [initialUser],
      attachments: [],
      systemPrompt: "When tools are available, use them."
    )

    let messages: [ChatModelContextMessage] = [
      initialUser,
      ChatModelContextMessage(role: .assistant, content: "Tool call write_file requested."),
      ChatModelContextMessage(
        role: .user,
        content: "Tool write_file completed with status success.",
        systemPromptSnapshot: "No more tools may run in this response."
      ),
      ChatModelContextMessage(role: .assistant, content: "Done."),
    ]

    let history = try GemmaMLXRuntime.generationHistoryMessages(
      from: messages[...],
      systemPrompt: "A later prompt mode should not rewrite history."
    )

    #expect(history.map(\.role) == [.user, .assistant, .user, .assistant])
    #expect(history[0].content == initialRendered[0].content)
    #expect(history[2].content.contains("No more tools may run in this response."))
    #expect(!history[0].content.contains("No more tools may run in this response."))
    #expect(!history[0].content.contains("A later prompt mode should not rewrite history."))
  }

  @Test
  func templateMessagesApplyFallbackSystemPromptOnlyToLegacyLastUser() throws {
    let messages: [ChatModelContextMessage] = [
      ChatModelContextMessage(role: .user, content: "first request"),
      ChatModelContextMessage(role: .assistant, content: "first response"),
      ChatModelContextMessage(role: .user, content: "follow-up request"),
    ]

    let rendered = try GemmaMLXRuntime.templateMessages(
      from: messages,
      attachments: [],
      systemPrompt: "Current prompt fallback."
    )

    #expect(rendered.map(\.role) == [.user, .assistant, .user])
    #expect(!rendered[0].content.contains("Current prompt fallback."))
    #expect(rendered[2].content.contains("Current prompt fallback."))
  }

  @Test
  func templateMessagesPreserveFocusedFileSystemContextInsideFirstUserMessage() throws {
    let messages: [ChatModelContextMessage] = [
      ChatModelContextMessage(
        role: .system,
        content: """
          Current focused file: index.htm
          Source: previous write_file
          Known content excerpt:
          <html><body><table><tr><td>Movie</td></tr></table></body></html>
          Explicit file paths in the user request or tool call take precedence.
          """),
      ChatModelContextMessage(role: .user, content: "change the background color to green"),
    ]

    let rendered = try GemmaMLXRuntime.templateMessages(
      from: messages,
      attachments: [],
      systemPrompt: "Use concise coding steps."
    )

    #expect(rendered.map(\.role) == [.user])
    #expect(rendered[0].content.contains("Use concise coding steps."))
    #expect(rendered[0].content.contains("Current focused file: index.htm"))
    #expect(rendered[0].content.contains("<html><body><table>"))
    #expect(rendered[0].content.contains("User request:"))
    #expect(rendered[0].content.contains("change the background color to green"))
  }

  @Test
  func generationPromptPreservesFocusedFileSystemContextOnFirstTurn() throws {
    let messages: [ChatModelContextMessage] = [
      ChatModelContextMessage(
        role: .system,
        content: """
          Current focused file: index.htm
          Source: previous read_file
          Known content excerpt:
          <h1>Dashboard</h1>
          Explicit file paths in the user request or tool call take precedence.
          """),
      ChatModelContextMessage(
        role: .user,
        content: "explain this",
        systemPromptSnapshot: "Use concise coding steps."
      ),
    ]
    let lastUserIndex = try #require(messages.lastIndex(where: { $0.role == .user }))

    let history = try GemmaMLXRuntime.generationHistoryMessages(
      from: messages[..<lastUserIndex]
    )
    let prompt = GemmaMLXRuntime.generationPromptMessage(
      from: messages,
      lastUserIndex: lastUserIndex,
      attachments: [],
      systemPrompt: "A later fallback should not be needed."
    )

    #expect(history.isEmpty)
    #expect(prompt.content.contains("Use concise coding steps."))
    #expect(prompt.content.contains("Current focused file: index.htm"))
    #expect(prompt.content.contains("<h1>Dashboard</h1>"))
    #expect(prompt.content.contains("User request:"))
    #expect(prompt.content.contains("explain this"))
  }

  @Test
  func focusedFileSystemContextDoesNotRewriteHistoricalUserMessage() throws {
    let initialUser = ChatModelContextMessage(
      role: .user,
      content: "summarize the current page",
      systemPromptSnapshot: "Use concise coding steps."
    )
    let initialRendered = try GemmaMLXRuntime.templateMessages(
      from: [initialUser],
      attachments: [],
      systemPrompt: "Use concise coding steps."
    )
    let messages: [ChatModelContextMessage] = [
      initialUser,
      ChatModelContextMessage(role: .assistant, content: "The page has a small table."),
      ChatModelContextMessage(
        role: .system,
        content: """
          Current focused file: robots.html
          Source: previous read_file
          Known content excerpt:
          <table><tr><td>Robot</td></tr></table>
          Explicit file paths in the user request or tool call take precedence.
          """),
      ChatModelContextMessage(
        role: .user,
        content: "change the heading",
        systemPromptSnapshot: "No more tools may run in this response."
      ),
    ]
    let lastUserIndex = try #require(messages.lastIndex(where: { $0.role == .user }))

    let history = try GemmaMLXRuntime.generationHistoryMessages(
      from: messages[..<lastUserIndex],
      systemPrompt: "A later prompt should not rewrite history."
    )
    let prompt = GemmaMLXRuntime.generationPromptMessage(
      from: messages,
      lastUserIndex: lastUserIndex,
      attachments: [],
      systemPrompt: "A later prompt should not rewrite history."
    )

    #expect(history.map(\.role) == [.user, .assistant])
    #expect(history[0].content == initialRendered[0].content)
    #expect(!history[0].content.contains("Current focused file: robots.html"))
    #expect(!history[0].content.contains("No more tools may run in this response."))
    #expect(prompt.content.contains("No more tools may run in this response."))
    #expect(prompt.content.contains("Current focused file: robots.html"))
    #expect(prompt.content.contains("<table><tr><td>Robot</td></tr></table>"))
    #expect(prompt.content.contains("change the heading"))
  }

  @Test
  func legacyCurrentPromptUsesFallbackWithFocusedFileSystemContext() throws {
    let messages: [ChatModelContextMessage] = [
      ChatModelContextMessage(role: .user, content: "first request"),
      ChatModelContextMessage(role: .assistant, content: "first response"),
      ChatModelContextMessage(
        role: .system,
        content: """
          Current focused file: index.swift
          Source: previous read_file
          Explicit file paths in the user request or tool call take precedence.
          """),
      ChatModelContextMessage(role: .user, content: "explain the focused file"),
    ]
    let lastUserIndex = try #require(messages.lastIndex(where: { $0.role == .user }))

    let history = try GemmaMLXRuntime.generationHistoryMessages(
      from: messages[..<lastUserIndex]
    )
    let prompt = GemmaMLXRuntime.generationPromptMessage(
      from: messages,
      lastUserIndex: lastUserIndex,
      attachments: [],
      systemPrompt: "Current prompt fallback."
    )

    #expect(history.map(\.role) == [.user, .assistant])
    #expect(!history[0].content.contains("Current prompt fallback."))
    #expect(!history[0].content.contains("Current focused file: index.swift"))
    #expect(prompt.content.contains("Current prompt fallback."))
    #expect(prompt.content.contains("Current focused file: index.swift"))
  }

  @Test
  func templateMessagesDoNotTeachGemmaInternalInvalidToolActions() throws {
    let callID = UUID()
    let messages: [ChatModelContextMessage] = [
      ChatModelContextMessage(role: .user, content: "change the table heading"),
      ChatModelContextMessage(
        role: .user,
        content: ToolResultModelMessage(
          callID: callID,
          toolName: .invalid,
          payload: .invalidTool(
            InvalidToolResult(
              originalName: "edit_file",
              reason: .parserError("Assistant described a tool call without an action block.")
            )),
          preview: ToolResultPreview(
            status: .failed,
            text: "The tool call was invalid: missing tagged action block."
          )
        ).modelContextContent
      ),
    ]

    let rendered = try GemmaMLXRuntime.templateMessages(
      from: messages,
      attachments: [],
      systemPrompt: "Use concise coding steps."
    )

    #expect(rendered.map(\.role) == [.user])
    #expect(!rendered.contains { $0.content.contains("<action name=\"invalid\">") })
    #expect(rendered[0].content.contains("The tool call was invalid"))
  }

  @Test
  func renderedContextSignatureIsDeterministicForSameHistoryAndSettings() {
    let settings = ChatGenerationSettings.codingDefault
    let history = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])

    let first = GemmaMLXRuntime.renderedContextSignature(for: history, settings: settings)
    let second = GemmaMLXRuntime.renderedContextSignature(for: history, settings: settings)

    #expect(first == second)
    #expect(first.rendererVersion == GemmaMLXRuntime.gemmaRendererVersion)
    #expect(first.traceValue == second.traceValue)
  }

  @Test
  func renderedContextSignatureChangesWhenRenderedHistoryChanges() {
    let settings = ChatGenerationSettings.codingDefault
    let history = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    let changedHistory = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("different"),
    ])

    let first = GemmaMLXRuntime.renderedContextSignature(for: history, settings: settings)
    let second = GemmaMLXRuntime.renderedContextSignature(
      for: changedHistory,
      settings: settings
    )

    #expect(first != second)
    #expect(first.renderedHistoryHash != second.renderedHistoryHash)
    #expect(first.generationSettingsHash == second.generationSettingsHash)
  }

  @Test
  func renderedContextSignatureChangesWhenGenerationSettingsChange() {
    let history = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    var changedSettings = ChatGenerationSettings.codingDefault
    changedSettings.maxTokens = 128

    let first = GemmaMLXRuntime.renderedContextSignature(
      for: history,
      settings: .codingDefault
    )
    let second = GemmaMLXRuntime.renderedContextSignature(
      for: history,
      settings: changedSettings
    )

    #expect(first != second)
    #expect(first.renderedHistoryHash == second.renderedHistoryHash)
    #expect(first.generationSettingsHash != second.generationSettingsHash)
  }

  @Test
  func renderedContextSignatureChangesWhenMaxKVSizeChanges() {
    let history = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    var changedSettings = ChatGenerationSettings.codingDefault
    changedSettings.maxKVSize = 16_384

    let first = GemmaMLXRuntime.renderedContextSignature(
      for: history,
      settings: .codingDefault
    )
    let second = GemmaMLXRuntime.renderedContextSignature(
      for: history,
      settings: changedSettings
    )

    #expect(first != second)
    #expect(first.renderedHistoryHash == second.renderedHistoryHash)
    #expect(first.generationSettingsHash != second.generationSettingsHash)
  }

  @Test
  func cacheDecisionInvalidatesWhenRendererVersionChanges() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    let cachedSignature = GemmaMLXRuntime.renderedContextSignature(
      for: prefix,
      settings: settings,
      rendererVersion: GemmaMLXRuntime.gemmaRendererVersion - 1
    )

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedContextSignature: cachedSignature,
      cachedState: .clean,
      currentHistory: prefix,
      currentSettings: settings
    )

    #expect(!decision.shouldReuse)
    #expect(decision.trace.cacheMode == .invalidatedSignatureMismatch)
    #expect(decision.trace.cacheReason == .invalidatedRendererVersionChanged)
    #expect(decision.trace.mismatchReason == "rendered_context_signature_changed")
    #expect(decision.trace.contextSignature != decision.trace.previousContextSignature)
  }

  @Test
  func cacheDecisionReportsNewSessionWhenNoCacheExists() {
    let settings = ChatGenerationSettings.codingDefault
    let history = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello")
    ])

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: nil,
      cachedSettings: nil,
      cachedState: nil,
      currentHistory: history,
      currentSettings: settings
    )

    #expect(!decision.shouldReuse)
    #expect(decision.trace.cacheMode == .newSessionHistory)
    #expect(decision.trace.cacheReason == .newSessionNoCache)
    #expect(decision.trace.mismatchReason == nil)
  }

  @Test
  func cacheDecisionReportsRenderedContextSignatureChangeSeparatelyFromRendererVersion() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    let cachedSignature = GemmaRenderedContextSignature(
      rendererVersion: GemmaMLXRuntime.gemmaRendererVersion,
      renderedHistoryHash: "different-history",
      generationSettingsHash: GemmaMLXRuntime.renderedContextSignature(
        for: prefix,
        settings: settings
      ).generationSettingsHash
    )

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedContextSignature: cachedSignature,
      cachedState: .clean,
      currentHistory: prefix,
      currentSettings: settings
    )

    #expect(!decision.shouldReuse)
    #expect(decision.trace.cacheMode == .invalidatedSignatureMismatch)
    #expect(decision.trace.cacheReason == .invalidatedRenderedContextChanged)
    #expect(decision.trace.mismatchReason == "rendered_context_signature_changed")
  }

  @Test
  func generationOwnershipBeginsMonotonicGenerations() {
    var ownership = GemmaGenerationOwnership()

    let first = ownership.beginGeneration()
    let second = ownership.beginGeneration()

    #expect(first.rawValue == 1)
    #expect(second.rawValue == 2)
    #expect(ownership.activeGenerationID == second)
  }

  @Test
  func generationOwnershipCompletesOnlyCurrentGeneration() {
    var ownership = GemmaGenerationOwnership()
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
    var ownership = GemmaGenerationOwnership()
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
    var ownership = GemmaGenerationOwnership()
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
    var registry = GemmaActiveGenerationRegistry()
    let generationID = GemmaGenerationID(rawValue: 1)
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

    await superseded.task.value
  }

  @Test
  func activeGenerationRegistryClearsOnlyCurrentGeneration() {
    var registry = GemmaActiveGenerationRegistry()
    let first = GemmaGenerationID(rawValue: 1)
    let second = GemmaGenerationID(rawValue: 2)
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
    let generationID = GemmaGenerationID(rawValue: 1)

    #expect(GemmaCachedSessionState.clean.isReusable)
    #expect(!GemmaCachedSessionState.inFlight(generationID: generationID).isReusable)
    #expect(!GemmaCachedSessionState.dirty(reason: .cancelled).isReusable)
    #expect(GemmaCachedSessionState.clean.invalidationReason == nil)
    #expect(
      GemmaCachedSessionState.inFlight(generationID: generationID).invalidationReason
        == .interrupted)
    #expect(
      GemmaCachedSessionState.dirty(reason: .runtimeError).invalidationReason == .runtimeError)
  }

  @Test
  func cachedSessionStateTransitionsOnlyForOwningGeneration() {
    let first = GemmaGenerationID(rawValue: 1)
    let second = GemmaGenerationID(rawValue: 2)
    let inFlight = GemmaCachedSessionState.inFlight(generationID: second)

    #expect(inFlight.completing(generationID: first) == nil)
    #expect(inFlight.invalidating(generationID: first, reason: .cancelled) == nil)
    #expect(inFlight.completing(generationID: second) == .clean)
    #expect(
      inFlight.invalidating(generationID: second, reason: .downstreamTerminated)
        == .dirty(reason: .downstreamTerminated))
  }

  @Test
  func cacheDecisionReusesOnlyExactRenderedPrefix() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedState: .clean,
      currentHistory: prefix,
      currentSettings: settings
    )

    #expect(decision.shouldReuse)
    #expect(decision.trace.cacheMode == .sessionReused)
    #expect(decision.trace.cacheReason == .sessionReused)
    #expect(decision.trace.appendOnly)
    #expect(decision.trace.reusedMessageCount == 2)
    #expect(decision.trace.appendedMessageCount == 0)
  }

  @Test
  func cacheDecisionInvalidatesWhenRenderedHistoryChanges() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    let changedHistory = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("different"),
    ])

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedState: .clean,
      currentHistory: changedHistory,
      currentSettings: settings
    )

    #expect(!decision.shouldReuse)
    #expect(decision.trace.cacheMode == .invalidatedSignatureMismatch)
    #expect(decision.trace.cacheReason == .invalidatedHistoryPrefixMismatch)
    #expect(!decision.trace.appendOnly)
    #expect(decision.trace.mismatchReason == "history_prefix_mismatch")
    #expect(decision.trace.firstMismatchIndex == 1)
  }

  @Test
  func cacheDecisionInvalidatesWhenSettingsChange() {
    var changedSettings = ChatGenerationSettings.codingDefault
    changedSettings.maxTokens = 128
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: .codingDefault,
      cachedState: .clean,
      currentHistory: prefix,
      currentSettings: changedSettings
    )

    #expect(!decision.shouldReuse)
    #expect(decision.trace.cacheMode == .invalidatedSignatureMismatch)
    #expect(decision.trace.cacheReason == .invalidatedSettingsChanged)
    #expect(decision.trace.mismatchReason == "settings_changed")
    #expect(decision.trace.firstMismatchIndex == nil)
  }

  @Test
  func cacheDecisionReportsFocusedContextMismatchSeparatelyFromBasePrompt() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = [
      GemmaMessageSnapshot(
        role: "user",
        content: """
          System instructions:
          Base prompt.

          Current focused file: robots.html
          Source: previous read_file
          Explicit file paths in the user request or tool call take precedence.

          User request:
          show the file
          """
      ),
      GemmaMessageSnapshot(role: "assistant", content: "hi"),
    ]
    let changedFocusedContext = [
      GemmaMessageSnapshot(
        role: "user",
        content: """
          System instructions:
          Base prompt.

          Current focused file: index.html
          Source: previous read_file
          Explicit file paths in the user request or tool call take precedence.

          User request:
          show the file
          """
      ),
      GemmaMessageSnapshot(role: "assistant", content: "hi"),
    ]

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedState: .clean,
      currentHistory: changedFocusedContext,
      currentSettings: settings
    )

    #expect(!decision.shouldReuse)
    #expect(decision.trace.cacheMode == .invalidatedSignatureMismatch)
    #expect(decision.trace.cacheReason == .invalidatedFocusedContextBoundary)
    #expect(decision.trace.mismatchReason == "history_prefix_mismatch")
    #expect(decision.trace.firstMismatchIndex == 0)
    #expect(decision.trace.systemPromptChanged == false)
    #expect(decision.trace.focusedContextChanged == true)
  }

  @Test
  func cacheDecisionReportsBasePromptMismatch() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = [
      GemmaMessageSnapshot(
        role: "user",
        content: """
          System instructions:
          Base prompt.

          User request:
          hello
          """
      )
    ]
    let changedBasePrompt = [
      GemmaMessageSnapshot(
        role: "user",
        content: """
          System instructions:
          Different base prompt.

          User request:
          hello
          """
      )
    ]

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedState: .clean,
      currentHistory: changedBasePrompt,
      currentSettings: settings
    )

    #expect(!decision.shouldReuse)
    #expect(decision.trace.cacheReason == .invalidatedToolPromptChanged)
    #expect(decision.trace.mismatchReason == "history_prefix_mismatch")
    #expect(decision.trace.firstMismatchIndex == 0)
    #expect(decision.trace.systemPromptChanged == true)
    #expect(decision.trace.focusedContextChanged == false)
  }

  @Test
  func cacheDecisionInvalidatesInFlightSessionAsInterrupted() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedState: .inFlight(generationID: GemmaGenerationID(rawValue: 1)),
      currentHistory: prefix,
      currentSettings: settings
    )

    #expect(!decision.shouldReuse)
    #expect(decision.trace.cacheMode == .invalidatedInterrupted)
    #expect(decision.trace.cacheReason == .invalidatedGenInterrupted)
  }

  @Test
  func cacheDecisionInvalidatesAfterDirtyStreamLifecycle() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])

    let cancelled = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedState: .dirty(reason: .cancelled),
      currentHistory: prefix,
      currentSettings: settings
    )
    let interrupted = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedState: .dirty(reason: .interrupted),
      currentHistory: prefix,
      currentSettings: settings
    )
    let downstreamTerminated = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedState: .dirty(reason: .downstreamTerminated),
      currentHistory: prefix,
      currentSettings: settings
    )
    let runtimeError = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedState: .dirty(reason: .runtimeError),
      currentHistory: prefix,
      currentSettings: settings
    )

    #expect(!cancelled.shouldReuse)
    #expect(cancelled.trace.cacheMode == .invalidatedCancelled)
    #expect(cancelled.trace.cacheReason == .invalidatedGenCancelled)
    #expect(!interrupted.shouldReuse)
    #expect(interrupted.trace.cacheMode == .invalidatedInterrupted)
    #expect(interrupted.trace.cacheReason == .invalidatedGenInterrupted)
    #expect(!downstreamTerminated.shouldReuse)
    #expect(downstreamTerminated.trace.cacheMode == .invalidatedDownstreamTerminated)
    #expect(downstreamTerminated.trace.cacheReason == .invalidatedGenDownstreamTerminated)
    #expect(!runtimeError.shouldReuse)
    #expect(runtimeError.trace.cacheMode == .invalidatedRuntimeError)
    #expect(runtimeError.trace.cacheReason == .invalidatedGenRuntimeError)
  }

  @Test
  func modelStreamMarksConsumerTerminationAsDownstreamTerminated() async throws {
    let recorder = GemmaStreamInvalidationRecorder()
    try await consumeFirstModelStreamEvent(recorder: recorder)

    try await waitUntilAsync {
      await recorder.firstReason != nil
    }
    #expect(await recorder.firstReason == .downstreamTerminated)
  }

  @Test
  func modelStreamPlanCancelsUpstreamTaskWhenConsumerTerminates() async throws {
    let recorder = GemmaStreamInvalidationRecorder()
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
    var plan: GemmaModelStreamPlan? = GemmaMLXRuntime.modelStreamPlan(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      markCompleted: { _ in },
      markCancelled: { reason in
        await recorder.record(reason)
      }
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

    var firstEventIterator = firstEventStream.makeAsyncIterator()
    _ = await firstEventIterator.next()
    consumerTask.cancel()
    await consumerTask.value
    try await waitUntilAsync {
      let firstReason = await recorder.firstReason
      return upstreamTask.isCancelled && firstReason == .downstreamTerminated
    }
  }

  private func consumeFirstEventAndWait(
    from stream: AsyncThrowingStream<ChatModelStreamEvent, Error>,
    firstEventContinuation: AsyncStream<Void>.Continuation
  ) -> Task<Void, Never> {
    Task {
      do {
        var iterator = stream.makeAsyncIterator()
        let firstEvent = try await iterator.next()
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

  private func consumeFirstModelStreamEvent(recorder: GemmaStreamInvalidationRecorder) async throws
  {
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
    let stream = GemmaMLXRuntime.modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      markCompleted: { _ in },
      markCancelled: { reason in
        await recorder.record(reason)
      }
    )

    do {
      var iterator = stream.makeAsyncIterator()
      let firstEvent = try await iterator.next()
      guard case .chunk("tool") = firstEvent else {
        Issue.record("Expected first model stream event to be the initial chunk.")
        return
      }
    }
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

  private func defaultCacheTrace() -> GemmaSessionCacheTrace {
    GemmaSessionCacheTrace(
      cacheMode: .newSessionHistory,
      cacheReason: .newSessionNoCache,
      contextSignature: "context",
      previousContextSignature: nil,
      appendOnly: false,
      reusedMessageCount: 0,
      appendedMessageCount: 0,
      mismatchReason: nil,
      firstMismatchIndex: nil,
      systemPromptChanged: nil,
      focusedContextChanged: nil
    )
  }
}

private actor GemmaStreamInvalidationRecorder {
  private var reasons: [GemmaSessionInvalidationReason] = []

  var firstReason: GemmaSessionInvalidationReason? {
    reasons.first
  }

  func record(_ reason: GemmaSessionInvalidationReason) {
    reasons.append(reason)
  }
}

private struct GemmaStreamWaitTimeoutError: Error {}

private func waitUntilAsync(
  timeout: Duration = .seconds(2),
  condition: () async -> Bool
) async throws {
  let start = ContinuousClock.now
  while await condition() == false {
    if ContinuousClock.now - start > timeout {
      throw GemmaStreamWaitTimeoutError()
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}
