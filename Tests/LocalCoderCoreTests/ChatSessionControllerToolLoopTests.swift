import Foundation
import Testing

@testable import LocalCoderCore

@MainActor
struct ChatSessionControllerToolLoopTests {
  @Test
  func sendMessageRunsReadOnlyToolsUntilBudgetThenSuppressesFurtherToolMarkup() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let readAction = """
      <action name="read_file">
      <path>README.md</path>
      </action>
      """
    let runtime = ChatSessionFakeChatModelRuntime(turns: [
      [readAction],
      [readAction],
      [readAction],
      [readAction],
      [readAction],
      [readAction],
      [readAction],
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.draft = "read the README repeatedly"

    controller.sendMessage(in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.toolCalls.count == 6)
    #expect(controller.chatSession.toolCalls.allSatisfy { $0.status == .completed })
    #expect(controller.chatSession.messages.last?.kind == .assistant)
    #expect(
      controller.chatSession.messages.last?.content
        == "Tool limit reached for this request. Send another message to continue.")

    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.count == 7)
    #expect(capturedSystemPrompts[1].contains("Available tools:"))
    #expect(capturedSystemPrompts[5].contains("Available tools:"))
    #expect(capturedSystemPrompts[6].contains("tool budget"))
    #expect(!capturedSystemPrompts[6].contains("Available tools:"))
  }

  @Test
  func sendMessageSuppressesFurtherNonTaggedToolIntentAfterInvalidBudget() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let invalidToolIntent = """
      Tool call edit_file requested.
      Path:
      index.html
      Old text:
      <body>
      New text:
      <body style="background: blue">
      """
    let runtime = ChatSessionFakeChatModelRuntime(
      turns: Array(repeating: [invalidToolIntent], count: 7))
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.draft = "change the background color to blue"

    controller.sendMessage(in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.toolCalls.count == 6)
    #expect(controller.chatSession.toolCalls.allSatisfy { $0.request.toolName == .invalid })
    #expect(controller.chatSession.messages.last?.kind == .assistant)
    #expect(
      controller.chatSession.messages.last?.content
        == "Tool limit reached for this request. Send another message to continue.")
    #expect(!controller.chatSession.messages.contains { $0.content == invalidToolIntent })
  }

  @Test
  func nonTaggedToolIntentIsHiddenAndReturnedToModelAsInvalidObservation() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let invalidToolIntent = """
      Tool call edit_file requested.
      Path:
      index.html
      Old text:
      <body>
      New text:
      <body style="background: blue">
      """
    let runtime = ChatSessionFakeChatModelRuntime(turns: [
      [invalidToolIntent],
      ["I need to use the tagged action format."],
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.draft = "change the background color to blue"

    controller.sendMessage(in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.toolCalls.count == 1)
    #expect(controller.chatSession.toolCalls[0].request.toolName == .invalid)
    #expect(controller.chatSession.toolCalls[0].status == .failed)
    #expect(controller.chatSession.messages[1].kind == .toolCall)
    #expect(controller.chatSession.messages[1].content.isEmpty)
    #expect(!controller.chatSession.messages.contains { $0.content == invalidToolIntent })
    #expect(
      controller.chatSession.messages.last?.content == "I need to use the tagged action format.")

    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 2)
    #expect(
      capturedMessages[1].contains { message in
        message.kind == .toolResult && message.toolResult?.toolName == .invalid
      })
  }

  @Test
  func failedEditFileResultLetsModelRecoverWithReadFile() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let editAction = """
      <action name="edit_file">
      <path>README.md</path>
      <old_text delimiter="LC_PAYLOAD_V1">
      missing text
      LC_PAYLOAD_V1
      </old_text>
      <new_text delimiter="LC_PAYLOAD_V1">
      replacement
      LC_PAYLOAD_V1
      </new_text>
      </action>
      """
    let readAction = """
      <action name="read_file">
      <path>README.md</path>
      </action>
      """
    let runtime = ChatSessionFakeChatModelRuntime(turns: [
      [editAction],
      [readAction],
      ["The file contains project notes."],
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.draft = "replace missing text in README"

    controller.sendMessage(in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.toolCalls.count == 2)
    #expect(controller.chatSession.toolCalls[0].request.toolName == .editFile)
    #expect(controller.chatSession.toolCalls[0].status == .failed)
    #expect(
      controller.chatSession.toolCalls[0].resultPreview?.text.contains("not found") == true)
    #expect(controller.chatSession.toolCalls[1].request.toolName == .readFile)
    #expect(controller.chatSession.toolCalls[1].status == .completed)
    #expect(controller.chatSession.messages.last?.content == "The file contains project notes.")
  }

  @Test
  func subsequentUserTurnsCanUseToolsAgainInSameSession() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(turns: [
      [
        """
        <action name="read_file">
        <path>README.md</path>
        </action>
        """
      ],
      ["First answer."],
      [
        """
        <action name="list_files">
        <path>.</path>
        </action>
        """
      ],
      ["Second answer."],
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready

    controller.draft = "read README.md"
    controller.sendMessage(in: workspace, sessionID: sessionID)
    try await waitUntil { !controller.isGenerating }

    controller.draft = "list files"
    controller.sendMessage(in: workspace, sessionID: sessionID)
    try await waitUntil { !controller.isGenerating && controller.chatSession.toolCalls.count == 2 }

    #expect(controller.chatSession.turns.count == 2)
    #expect(controller.chatSession.turns.allSatisfy { $0.status == .completed })
    #expect(controller.chatSession.toolCalls.map(\.request.toolName) == [.readFile, .listFiles])
    #expect(controller.chatSession.messages.last?.content == "Second answer.")

    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.count == 4)
    #expect(capturedSystemPrompts[2].contains("list_files"))
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
}
