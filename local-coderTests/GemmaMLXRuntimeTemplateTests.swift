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
    let messages: [ChatMessage] = [
      ChatMessage(userContent: "create index.htm"),
      ChatMessage(
        toolCall: writeFileToolCall(
          callID: callID,
          arguments: [
            "path": .string("index.htm"),
            "content": .string("<html></html>"),
          ])
      ),
      ChatMessage(
        toolResult: ToolResultModelMessage(
          callID: callID,
          toolName: .writeFile,
          preview: ToolResultPreview(
            status: .success,
            text: "index.htm · 1 lines, 13 bytes",
            affectedPaths: ["index.htm"]
          )
        )
      ),
      ChatMessage(userContent: "change the background color to green"),
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
    let messages: [ChatMessage] = [
      ChatMessage(userContent: "create index.htm"),
      ChatMessage(
        toolCall: writeFileToolCall(
          callID: callID,
          arguments: ["path": .string("index.htm")])
      ),
      ChatMessage(
        toolResult: ToolResultModelMessage(
          callID: callID,
          toolName: .writeFile,
          preview: ToolResultPreview(
            status: .success,
            text: "index.htm · 1 lines, 13 bytes",
            affectedPaths: ["index.htm"]
          )
        )
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
    let messages: [ChatMessage] = [
      ChatMessage(
        systemContent: """
          Current focused file: index.htm
          Source: previous write_file
          Known content excerpt:
          <html><body><table><tr><td>Movie</td></tr></table></body></html>
          Explicit file paths in the user request or tool call take precedence.
          """),
      ChatMessage(userContent: "change the background color to green"),
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
