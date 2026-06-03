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
    #expect(rendered[0].content.contains("System instructions:"))
    #expect(rendered[0].content.contains("Use concise coding steps."))
    #expect(rendered[1].content.contains("Tool call write_file requested."))
    #expect(rendered[1].content.contains("Tool write_file completed with status success."))
    #expect(!rendered.contains { $0.role == .system })
  }

  @Test
  func generationHistoryEmbedsSystemPromptWithoutAddingSystemRole() throws {
    let callID = UUID()
    let messages: [ChatModelContextMessage] = [
      ChatModelContextMessage(role: .user, content: "create index.htm"),
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
      systemPrompt: "Use concise coding steps."
    )

    #expect(history.map(\.role) == [.user, .assistant])
    #expect(history[0].content.contains("System instructions:"))
    #expect(!history.contains { $0.role == .system })
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
  func cacheDecisionReusesOnlyExactRenderedPrefix() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedReusable: true,
      invalidationReason: nil,
      currentHistory: prefix,
      currentSettings: settings
    )

    #expect(decision.shouldReuse)
    #expect(decision.trace.cacheMode == .sessionReused)
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
      cachedReusable: true,
      invalidationReason: nil,
      currentHistory: changedHistory,
      currentSettings: settings
    )

    #expect(!decision.shouldReuse)
    #expect(decision.trace.cacheMode == .invalidatedSignatureMismatch)
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
      cachedReusable: true,
      invalidationReason: nil,
      currentHistory: prefix,
      currentSettings: changedSettings
    )

    #expect(!decision.shouldReuse)
    #expect(decision.trace.cacheMode == .invalidatedSignatureMismatch)
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
      cachedReusable: true,
      invalidationReason: nil,
      currentHistory: changedFocusedContext,
      currentSettings: settings
    )

    #expect(!decision.shouldReuse)
    #expect(decision.trace.cacheMode == .invalidatedSignatureMismatch)
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
      cachedReusable: true,
      invalidationReason: nil,
      currentHistory: changedBasePrompt,
      currentSettings: settings
    )

    #expect(!decision.shouldReuse)
    #expect(decision.trace.mismatchReason == "history_prefix_mismatch")
    #expect(decision.trace.firstMismatchIndex == 0)
    #expect(decision.trace.systemPromptChanged == true)
    #expect(decision.trace.focusedContextChanged == false)
  }

  @Test
  func cacheDecisionInvalidatesAfterCancelledOrInterruptedStream() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])

    let cancelled = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedReusable: false,
      invalidationReason: .cancelled,
      currentHistory: prefix,
      currentSettings: settings
    )
    let interrupted = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedReusable: false,
      invalidationReason: .interrupted,
      currentHistory: prefix,
      currentSettings: settings
    )

    #expect(!cancelled.shouldReuse)
    #expect(cancelled.trace.cacheMode == .invalidatedCancelled)
    #expect(!interrupted.shouldReuse)
    #expect(interrupted.trace.cacheMode == .invalidatedInterrupted)
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
}
