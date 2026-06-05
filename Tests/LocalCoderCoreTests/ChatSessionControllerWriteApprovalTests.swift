import Foundation
import Testing

@testable import LocalCoderCore

@MainActor
struct ChatSessionControllerWriteApprovalTests {
  @Test
  func writeFileToolCallWaitsForApprovalWithoutWriting() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(turns: [
      [
        writeFileActionWithoutClosingDelimiter(
          path: "movies.html",
          content: """
            <!doctype html>
            <html>
            <body>Movies</body>
            </html>
            """
        )
      ]
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.draft = "create a html file in the current folder"

    controller.sendMessage(in: workspace, sessionID: sessionID)

    try await waitUntil { controller.chatSession.turns.first?.status == .awaitingApproval }

    let outputURL = workspace.rootURL.appending(path: "movies.html")
    #expect(!controller.isGenerating)
    #expect(controller.hasPendingApproval)
    #expect(controller.chatSession.toolCalls.count == 1)
    #expect(controller.chatSession.toolCalls[0].status == .awaitingApproval)
    #expect(controller.chatSession.toolCalls[0].request.toolName == .writeFile)
    #expect(controller.chatSession.messages.count == 2)
    #expect(controller.chatSession.messages[1].kind == .toolCall)
    #expect(!FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)))

    controller.draft = "are you there"
    #expect(!controller.canSend)

    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.count == 1)
    #expect(capturedSystemPrompts[0].contains("write_file"))
    #expect(capturedSystemPrompts[0].contains("Do not generate Python"))
  }

  @Test
  func approvingWriteFileWritesContentAndAllowsFinalAssistantResponse() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let htmlContent = """
      <!doctype html>
      <html>
      <body>
      <table><tr><td>Alien</td><td>Heat</td><td>Jaws</td></tr></table>
      </body>
      </html>
      """
    let runtime = ChatSessionFakeChatModelRuntime(turns: [
      [writeFileAction(path: "movies.html", content: htmlContent)],
      ["Updated movies.html with the movie table."],
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.draft = "create a html file in the current folder"

    controller.sendMessage(in: workspace, sessionID: sessionID)
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
    #expect(
      controller.chatSession.focusedFileState.activePath
        == WorkspaceRelativePath(rawValue: "movies.html"))
    #expect(controller.chatSession.focusedFileState.recentPaths.first?.source == .writeFile)
    #expect(
      controller.chatSession.focusedFileState.snapshots[
        WorkspaceRelativePath(rawValue: "movies.html")]?.excerpt == htmlContent)
    #expect(controller.chatSession.messages.count == 4)
    #expect(controller.chatSession.messages[2].kind == .toolResult)
    #expect(controller.chatSession.messages[2].toolResult?.toolName == .writeFile)
    #expect(
      controller.chatSession.messages[3].content == "Updated movies.html with the movie table.")

    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 2)
    let finalFollowUpContext = try #require(capturedMessages.last)
    #expect(finalFollowUpContext.last?.role == .user)
    #expect(
      finalFollowUpContext.last?.content.contains(
        "Use the preceding tool result to answer the user's request.") == true)
    #expect(finalFollowUpContext.last?.content.contains("No more tools may run") == true)
    #expect(
      finalFollowUpContext.first(where: { $0.role == .user })?.content.contains("write_file")
        == true)
  }

  @Test
  func approvingWriteFileRecordsFinalModeToolAttemptInsteadOfLeavingActionText() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(turns: [
      [writeFileAction(path: "movies.html", content: "<html></html>")],
      [
        """
        <action name="read_file">
        <path>README.md</path>
        </action>
        """
      ],
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.draft = "create a html file in the current folder"

    controller.sendMessage(in: workspace, sessionID: sessionID)
    try await waitUntil { controller.chatSession.turns.first?.status == .awaitingApproval }
    let toolCallID = try #require(controller.chatSession.toolCalls.first?.id)

    controller.approveToolCall(id: toolCallID, in: workspace)
    try await waitUntil { controller.chatSession.turns.first?.status == .completed }

    #expect(controller.chatSession.toolCalls.count == 2)
    #expect(controller.chatSession.toolCalls[0].request.toolName == .writeFile)
    #expect(controller.chatSession.toolCalls[0].status == .completed)
    #expect(controller.chatSession.toolCalls[1].request.toolName == .readFile)
    #expect(controller.chatSession.toolCalls[1].status == .failed)
    #expect(!controller.chatSession.messages.contains { $0.content.contains("<action") })
    guard case .failure(let failure) = controller.chatSession.messages.last?.toolResult?.payload
    else {
      Issue.record("Expected final-mode action to be recorded as a structured failure.")
      return
    }
    #expect(failure.reason == .finalModeToolAttempt(requestedTool: .readFile))
  }

  @Test
  func denyingWriteFileDoesNotWriteAndAllowsFinalAssistantResponse() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(turns: [
      [writeFileAction(path: "movies.html", content: "<html></html>")],
      ["I will not write the file. I can describe the change instead."],
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.draft = "create a html file in the current folder"

    controller.sendMessage(in: workspace, sessionID: sessionID)
    try await waitUntil { controller.chatSession.turns.first?.status == .awaitingApproval }
    let toolCallID = try #require(controller.chatSession.toolCalls.first?.id)

    controller.denyToolCall(id: toolCallID)
    try await waitUntil { !controller.isGenerating }

    let outputURL = workspace.rootURL.appending(path: "movies.html")
    #expect(!FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)))
    #expect(!controller.hasPendingApproval)
    #expect(controller.chatSession.turns.first?.status == .completed)
    #expect(controller.chatSession.toolCalls[0].status == .denied)
    #expect(controller.chatSession.toolCalls[0].resultPreview?.affectedPaths == ["movies.html"])
    guard case .failure(let writeFailure) = controller.chatSession.toolCalls[0].resultPayload else {
      Issue.record("Expected denied write_file failure payload.")
      return
    }
    #expect(writeFailure.path == WorkspaceRelativePath(rawValue: "movies.html"))
    #expect(controller.chatSession.messages.count == 4)
    #expect(controller.chatSession.messages[2].toolResult?.preview.status == .denied)
    #expect(controller.chatSession.messages[2].toolResult?.preview.affectedPaths == ["movies.html"])
    #expect(
      controller.chatSession.messages[3].content
        == "I will not write the file. I can describe the change instead.")

    controller.draft = "are you there"
    #expect(controller.canSend)

    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 2)
    let finalFollowUpContext = try #require(capturedMessages.last)
    #expect(finalFollowUpContext.last?.role == .user)
    #expect(finalFollowUpContext.last?.content.contains("No more tools may run") == true)
  }

  @Test
  func denyingWriteFileRecordsFinalModeToolAttemptInsteadOfLeavingActionText() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(turns: [
      [writeFileAction(path: "movies.html", content: "<html></html>")],
      [
        """
        <action name="read_file">
        <path>README.md</path>
        </action>
        """
      ],
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.draft = "create a html file in the current folder"

    controller.sendMessage(in: workspace, sessionID: sessionID)
    try await waitUntil { controller.chatSession.turns.first?.status == .awaitingApproval }
    let toolCallID = try #require(controller.chatSession.toolCalls.first?.id)

    controller.denyToolCall(id: toolCallID)
    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.toolCalls.count == 2)
    #expect(controller.chatSession.toolCalls[0].request.toolName == .writeFile)
    #expect(controller.chatSession.toolCalls[0].status == .denied)
    #expect(controller.chatSession.toolCalls[1].request.toolName == .readFile)
    #expect(controller.chatSession.toolCalls[1].status == .failed)
    #expect(!controller.chatSession.messages.contains { $0.content.contains("<action") })
    guard case .failure(let failure) = controller.chatSession.messages.last?.toolResult?.payload
    else {
      Issue.record("Expected final-mode action to be recorded as a structured failure.")
      return
    }
    #expect(failure.reason == .finalModeToolAttempt(requestedTool: .readFile))
  }

  @Test
  func editFileToolCallWaitsForApprovalWithPreviewWithoutWriting() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(turns: [
      [
        editFileAction(
          path: "README.md",
          oldText: "project notes",
          newText: "updated notes"
        )
      ]
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.draft = "update the readme"

    controller.sendMessage(in: workspace, sessionID: sessionID)

    try await waitUntil { controller.chatSession.turns.first?.status == .awaitingApproval }

    let readmeURL = workspace.rootURL.appending(path: "README.md")
    #expect(!controller.isGenerating)
    #expect(controller.hasPendingApproval)
    #expect(controller.chatSession.toolCalls.count == 1)
    #expect(controller.chatSession.toolCalls[0].status == .awaitingApproval)
    #expect(controller.chatSession.toolCalls[0].request.toolName == .editFile)
    #expect(
      controller.chatSession.toolCalls[0].resultPreview?.text.contains("-project notes") == true)
    #expect(
      controller.chatSession.toolCalls[0].resultPreview?.text.contains("+updated notes") == true)
    #expect(try String(contentsOf: readmeURL, encoding: .utf8) == "project notes")
  }

  @Test
  func readFileCanBeFollowedByEditFileAwaitingApproval() async throws {
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
      [
        editFileAction(
          path: "README.md",
          oldText: "project notes",
          newText: "project notes\n\n| One | Two | Three |"
        )
      ],
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.draft = "add a table with 3 columns to README.md"

    controller.sendMessage(in: workspace, sessionID: sessionID)

    try await waitUntil { controller.chatSession.turns.first?.status == .awaitingApproval }

    let readmeURL = workspace.rootURL.appending(path: "README.md")
    #expect(!controller.isGenerating)
    #expect(controller.hasPendingApproval)
    #expect(controller.chatSession.toolCalls.count == 2)
    #expect(controller.chatSession.toolCalls[0].status == .completed)
    #expect(controller.chatSession.toolCalls[0].request.toolName == .readFile)
    #expect(controller.chatSession.toolCalls[1].status == .awaitingApproval)
    #expect(controller.chatSession.toolCalls[1].request.toolName == .editFile)
    #expect(
      controller.chatSession.toolCalls[1].resultPreview?.text.contains(
        "+| One | Two | Three |") == true)
    #expect(try String(contentsOf: readmeURL, encoding: .utf8) == "project notes")

    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.count == 2)
    #expect(capturedSystemPrompts[1].contains("call edit_file with exact old_text copied from"))
    #expect(capturedSystemPrompts[1].contains("Available tools: read_file"))
    #expect(!capturedSystemPrompts[1].contains("Tool calling:"))
  }

  @Test
  func approvingNonTerminalToolContinuesToolLoopForFollowUpAction() async throws {
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
      [
        editFileAction(
          path: "README.md",
          oldText: "project notes",
          newText: "project notes\n\n| One | Two | Three |"
        )
      ],
    ])
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: ToolOrchestrator(
        executorRegistry: ToolExecutorRegistry([
          AnyToolExecutor(ApprovalRequiredReadFileToolExecutor()),
          AnyToolExecutor(EditFileToolExecutor()),
        ]))
    )
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.draft = "read README.md and then add a table"

    controller.sendMessage(in: workspace, sessionID: sessionID)
    try await waitUntil { controller.chatSession.turns.first?.status == .awaitingApproval }
    let readToolCallID = try #require(controller.chatSession.toolCalls.first?.id)

    controller.approveToolCall(id: readToolCallID, in: workspace)

    try await waitUntil {
      controller.chatSession.toolCalls.count == 2
        && controller.chatSession.toolCalls[1].status == .awaitingApproval
    }

    let readmeURL = workspace.rootURL.appending(path: "README.md")
    #expect(!controller.isGenerating)
    #expect(controller.hasPendingApproval)
    #expect(controller.chatSession.turns.first?.status == .awaitingApproval)
    #expect(controller.chatSession.toolCalls[0].request.toolName == .readFile)
    #expect(controller.chatSession.toolCalls[0].status == .completed)
    #expect(controller.chatSession.toolCalls[1].request.toolName == .editFile)
    #expect(controller.chatSession.toolCalls[1].status == .awaitingApproval)
    #expect(
      controller.chatSession.toolCalls[1].resultPreview?.text.contains(
        "+| One | Two | Three |") == true)
    #expect(try String(contentsOf: readmeURL, encoding: .utf8) == "project notes")

    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.count == 2)
    #expect(capturedSystemPrompts[1].contains("call edit_file with exact old_text copied from"))
    #expect(capturedSystemPrompts[1].contains("Available tools: read_file"))
    #expect(!capturedSystemPrompts[1].contains("Tool calling:"))
  }

  @Test
  func approvingEditFileWritesContentAndAllowsFinalAssistantResponse() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(turns: [
      [
        editFileAction(
          path: "README.md",
          oldText: "project notes",
          newText: "updated notes"
        )
      ],
      ["Updated README.md."],
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.draft = "update the readme"

    controller.sendMessage(in: workspace, sessionID: sessionID)
    try await waitUntil { controller.chatSession.turns.first?.status == .awaitingApproval }
    let toolCallID = try #require(controller.chatSession.toolCalls.first?.id)

    controller.approveToolCall(id: toolCallID, in: workspace)

    try await waitUntil { controller.chatSession.turns.first?.status == .completed }

    let readmeURL = workspace.rootURL.appending(path: "README.md")
    #expect(try String(contentsOf: readmeURL, encoding: .utf8) == "updated notes")
    #expect(!controller.isGenerating)
    #expect(!controller.hasPendingApproval)
    #expect(controller.chatSession.toolCalls[0].status == .completed)
    #expect(
      controller.chatSession.focusedFileState.activePath
        == WorkspaceRelativePath(rawValue: "README.md"))
    #expect(controller.chatSession.focusedFileState.recentPaths.first?.source == .editFile)
    #expect(controller.chatSession.messages.count == 4)
    #expect(controller.chatSession.messages[2].kind == .toolResult)
    #expect(controller.chatSession.messages[2].toolResult?.toolName == .editFile)
    #expect(controller.chatSession.messages[3].content == "Updated README.md.")

    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 2)
  }

  @Test
  func denyingEditFileDoesNotWriteAndAllowsFinalAssistantResponse() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(turns: [
      [
        editFileAction(
          path: "README.md",
          oldText: "project notes",
          newText: "updated notes"
        )
      ],
      ["I will leave README.md unchanged."],
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.draft = "update the readme"

    controller.sendMessage(in: workspace, sessionID: sessionID)
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
    guard case .failure(let editFailure) = controller.chatSession.toolCalls[0].resultPayload else {
      Issue.record("Expected denied edit_file failure payload.")
      return
    }
    #expect(editFailure.path == WorkspaceRelativePath(rawValue: "README.md"))
    #expect(controller.chatSession.messages.count == 4)
    #expect(controller.chatSession.messages[2].toolResult?.preview.status == .denied)
    #expect(controller.chatSession.messages[2].toolResult?.preview.affectedPaths == ["README.md"])
    #expect(controller.chatSession.messages[3].content == "I will leave README.md unchanged.")
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
        ChatSession(
          id: sessionID,
          selectedModelID: ManagedModelCatalog.defaultModelID,
          systemPrompt: ChatPromptDefaults.codingSystemPrompt,
          generationSettings: .codingDefault
        )
      ]
    )
  }

  private func writeFileAction(path: String, content: String) -> String {
    """
    <action name="write_file">
    <path>\(path)</path>
    <content delimiter="LC_PAYLOAD_V1">
    \(content)
    LC_PAYLOAD_V1
    </content>
    </action>
    """
  }

  private func writeFileActionWithoutClosingDelimiter(path: String, content: String) -> String {
    """
    <action name="write_file">
    <path>\(path)</path>
    <content delimiter="LC_PAYLOAD_V1">
    \(content)
    </content>
    </action>
    """
  }

  private func editFileAction(path: String, oldText: String, newText: String) -> String {
    """
    <action name="edit_file">
    <path>\(path)</path>
    <old_text delimiter="LC_PAYLOAD_V1">
    \(oldText)
    LC_PAYLOAD_V1
    </old_text>
    <new_text delimiter="LC_PAYLOAD_V1">
    \(newText)
    LC_PAYLOAD_V1
    </new_text>
    </action>
    """
  }
}

private struct ApprovalRequiredReadFileToolExecutor: TypedToolExecutor {
  static let definition = ToolDefinition.readFile

  func evaluatePermission(
    _ input: ReadFileInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    do {
      let resolvedPath = try context.workspace.resolveAllowedPath(input.path)
      return ToolPermissionEvaluation(
        decision: .requiresApproval,
        reason: "Reading this file requires approval in this test.",
        riskLevel: .low,
        normalizedPaths: [resolvedPath.path(percentEncoded: false)],
        workspaceRelativePaths: [context.workspace.relativePath(for: resolvedPath)]
      )
    } catch {
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: error.localizedDescription,
        riskLevel: .low
      )
    }
  }

  func previewApproval(_ input: ReadFileInput, context: ToolContext) async -> ToolResultPreview? {
    do {
      let resolvedPath = try context.workspace.resolveAllowedPath(input.path)
      return ToolResultPreview(
        status: .success,
        text: "Read \(context.workspace.relativePath(for: resolvedPath).rawValue).",
        affectedPaths: [context.workspace.relativePath(for: resolvedPath).rawValue]
      )
    } catch {
      return ToolResultPreview(status: .failed, text: error.localizedDescription)
    }
  }

  func run(_ input: ReadFileInput, context: ToolContext) async -> ToolResultPayload {
    do {
      let resolvedPath = try context.workspace.resolveAllowedPath(input.path)
      let relativePath = context.workspace.relativePath(for: resolvedPath)
      let content = try String(contentsOf: resolvedPath, encoding: .utf8)
      return .readFile(
        .success(
          path: relativePath,
          content: ToolTextOutput(text: "1: \(content)", truncated: false)
        ))
    } catch {
      return .readFile(
        .failed(
          path: WorkspaceRelativePath(rawValue: input.path),
          reason: .executionError(error.localizedDescription)
        ))
    }
  }
}
