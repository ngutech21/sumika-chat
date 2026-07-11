import Foundation
import Testing

@testable import SumikaCore

@Suite(.serialized)
@MainActor
struct ChatSessionControllerWriteApprovalTests {
  @Test
  func nativeWriteFileToolCallWaitsForApprovalWithoutWriting() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: [
              "path": .string("movies.html"),
              "content": .string("<!doctype html>\n<html>Movies</html>\n"),
            ]
          ))
      ]
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.sendMessage(
      prompt: "create a html file in the current folder", in: workspace, sessionID: sessionID)

    try await waitUntil { controller.chatSession.turns.first?.status == .awaitingApproval }

    let outputURL = workspace.rootURL.appending(path: "movies.html")
    #expect(!controller.isGenerating)
    #expect(controller.hasPendingApproval)
    #expect(controller.chatSession.toolCalls.count == 1)
    #expect(controller.chatSession.toolCalls[0].status == .awaitingApproval)
    #expect(controller.chatSession.toolCalls[0].request.toolName == .writeFile)
    #expect(controller.chatSession.testMessages.count == 2)
    #expect(controller.chatSession.testMessages[1].kind == .toolCall)
    #expect(!FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)))
  }

  @Test
  func pendingApprovalDoesNotBlockCanSend() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: [
              "path": .string("movies.html"),
              "content": .string("<!doctype html>\n<html>Movies</html>\n"),
            ]
          ))
      ]
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.sendMessage(
      prompt: "create a html file in the current folder", in: workspace, sessionID: sessionID)
    try await waitUntil { controller.chatSession.turns.first?.status == .awaitingApproval }

    #expect(controller.hasPendingApproval)
    #expect(controller.canSend(prompt: "skip that and explain the current state"))
  }

  @Test
  func sendingNewMessageInterruptsPendingApprovalWithoutResumingOldTurn() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: [
              "path": .string("movies.html"),
              "content": .string("<!doctype html>\n<html>Movies</html>\n"),
            ]
          ))
      ],
      [.chunk("I will explain the current state instead.")],
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.sendMessage(
      prompt: "create a html file in the current folder", in: workspace, sessionID: sessionID)
    try await waitUntil { controller.chatSession.turns.first?.status == .awaitingApproval }
    let toolCallID = try #require(controller.chatSession.toolCalls.first?.id)

    controller.sendMessage(
      prompt: "skip that and explain the current state", in: workspace, sessionID: sessionID)

    try await waitUntil {
      controller.chatSession.turns.count == 2 && !controller.isGenerating
    }

    let outputURL = workspace.rootURL.appending(path: "movies.html")
    #expect(!FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)))
    #expect(controller.chatSession.turns[0].status == .cancelled)
    #expect(controller.chatSession.turns[0].modelContextPolicy == .excluded)
    #expect(controller.chatSession.toolCalls.first?.status == .denied)
    #expect(controller.chatSession.toolCalls.first?.resultPreview?.status == .denied)
    #expect(controller.chatSession.turns[1].status == .completed)
    #expect(
      controller.chatSession.testMessages.last?.content
        == "I will explain the current state instead.")

    controller.approveToolCall(id: toolCallID, in: workspace)
    await Task.yield()

    #expect(controller.chatSession.toolCalls.first?.status == .denied)
    #expect(controller.chatSession.turns[0].status == .cancelled)

    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 2)
    #expect(
      capturedMessages[1].contains { message in
        message.role == .user && message.content.contains("skip that and explain the current state")
      })
    #expect(
      !capturedMessages[1].contains { message in
        message.role == .user && message.content.contains("create a html file")
      })
  }

  @Test
  func approvingNativeWriteFileWritesContentAndAllowsFinalAssistantResponse() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let htmlContent = "<!doctype html>\n<html>Movies</html>\n"
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: [
              "path": .string("movies.html"),
              "content": .string(htmlContent),
            ]
          ))
      ],
      [.chunk("Updated movies.html.")],
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.sendMessage(
      prompt: "create a html file in the current folder", in: workspace, sessionID: sessionID)
    try await waitUntil { controller.chatSession.turns.first?.status == .awaitingApproval }
    let toolCallID = try #require(controller.chatSession.toolCalls.first?.id)

    controller.approveToolCall(id: toolCallID, in: workspace)

    try await waitUntil { controller.chatSession.turns.first?.status == .completed }

    let outputURL = workspace.rootURL.appending(path: "movies.html")
    #expect(try String(contentsOf: outputURL, encoding: .utf8) == htmlContent)
    #expect(!controller.isGenerating)
    #expect(!controller.hasPendingApproval)
    #expect(controller.chatSession.toolCalls[0].status == .completed)
    #expect(controller.chatSession.toolCalls[0].resultPreview?.status == .success)
    #expect(controller.chatSession.testMessages.count == 3)
    #expect(controller.chatSession.testMessages[1].kind == .toolResult)
    #expect(controller.chatSession.testMessages[1].toolCall?.toolName == .writeFile)
    #expect(controller.chatSession.testMessages[1].toolResult?.toolName == .writeFile)
    #expect(controller.chatSession.testMessages[2].content == "Updated movies.html.")

    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 2)
    #expect(capturedMessages.last?.last?.content.contains("No more tools are available") == false)
    #expect(capturedMessages.last?.last?.role == .tool)
    #expect(capturedMessages.last?.last?.content.contains("Wrote") == true)
    #expect(
      capturedMessages.last?.last?.content.contains(
        "Continue using the latest tool observation"
      )
        == true)
    #expect(
      capturedMessages.last?.last?.content.contains("Do not include generated file contents")
        == false)
    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.last?.contains("No more tools may run") == false)
    #expect(
      capturedSystemPrompts.last?.contains("Do not include generated file contents")
        == false)
    #expect(capturedSystemPrompts.last?.contains("Never say files were changed") == true)
    #expect(capturedSystemPrompts.last?.contains("no workspace change happened") == true)
    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans.last?.transientInstructions.isEmpty == true)
    #expect(capturedPromptPlans.last?.toolContext != nil)
  }

  @Test
  func denyingNativeEditFileDoesNotWriteAndAllowsFinalAssistantResponse() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "edit_file",
            arguments: [
              "path": .string("README.md"),
              "old_text": .string("project notes"),
              "new_text": .string("updated notes"),
            ]
          ))
      ],
      [.chunk("I will leave README.md unchanged.")],
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.sendMessage(prompt: "update the readme", in: workspace, sessionID: sessionID)
    try await waitUntil { controller.chatSession.turns.first?.status == .awaitingApproval }
    let toolCallID = try #require(controller.chatSession.toolCalls.first?.id)

    controller.denyToolCall(id: toolCallID)
    try await waitUntil { !controller.isGenerating }

    let readmeURL = workspace.rootURL.appending(path: "README.md")
    #expect(try String(contentsOf: readmeURL, encoding: .utf8) == "project notes")
    #expect(!controller.hasPendingApproval)
    #expect(controller.chatSession.turns.first?.status == .completed)
    #expect(controller.chatSession.toolCalls[0].status == .denied)
    #expect(controller.chatSession.toolCalls[0].resultPreview?.affectedPaths == ["README.md"])
    #expect(controller.chatSession.testMessages.count == 3)
    #expect(controller.chatSession.testMessages[1].toolResult?.preview.status == .denied)
    #expect(controller.chatSession.testMessages[2].content == "I will leave README.md unchanged.")
  }

  private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let start = ContinuousClock.now
    while !condition() {
      if start.duration(to: .now) > timeout {
        Issue.record("Timed out waiting for condition")
        throw TestWaitTimeoutError()
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func makeWorkspace(sessionID: ChatSession.ID) throws -> Workspace {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "sumika-tests-\(UUID().uuidString)",
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
        ChatSession(
          id: sessionID,
          selectedModelID: ManagedModelCatalog.defaultModelID,
          modeSettings: testModeSettings(
            systemPrompt: ChatPromptDefaults.agentSystemPrompt,
            generationSettings: .agentDefault
          )
        )
      ]
    )
  }
}
