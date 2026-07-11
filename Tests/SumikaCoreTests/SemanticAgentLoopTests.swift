import Foundation
import Testing

@testable import SumikaCore

@Suite(.serialized)
@MainActor
struct SemanticAgentLoopTests {
  @Test
  func successfulMutationsCanContinueThroughVerificationUntilFinishTask() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: [
              "path": .string("flow.txt"),
              "content": .string("one\n"),
            ]
          ))
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "read_file",
            arguments: ["path": .string("flow.txt")]
          ))
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "edit_file",
            arguments: [
              "path": .string("flow.txt"),
              "old_text": .string("one\n"),
              "new_text": .string("two\n"),
            ]
          ))
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "run_command",
            arguments: [
              "command": .string("pwd"),
              "timeoutSeconds": .number(2),
              "reason": .string("Verify the workspace command path."),
            ]
          ))
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "finish_task",
            arguments: [
              "status": .string("done"),
              "summary": .string("Completed and verified the full workflow."),
            ]
          ))
      ],
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)

    controller.sendMessage(
      prompt: "Create, inspect, update, and verify flow.txt.",
      in: workspace,
      sessionID: sessionID
    )

    try await waitUntil {
      controller.chatSession.toolCalls.count == 1 && controller.hasPendingApproval
    }
    controller.approveToolCall(
      id: try #require(controller.chatSession.toolCalls.last?.id),
      in: workspace
    )

    try await waitUntil {
      controller.chatSession.toolCalls.count == 3 && controller.hasPendingApproval
    }
    controller.approveToolCall(
      id: try #require(controller.chatSession.toolCalls.last?.id),
      in: workspace
    )

    try await waitUntil {
      controller.chatSession.toolCalls.count == 4 && controller.hasPendingApproval
    }
    controller.approveToolCall(
      id: try #require(controller.chatSession.toolCalls.last?.id),
      in: workspace
    )

    try await waitUntil { controller.chatSession.turns.first?.status == .completed }

    #expect(
      controller.chatSession.toolCalls.map(\.request.toolName)
        == [.writeFile, .readFile, .editFile, .runCommand, .finishTask]
    )
    #expect(controller.chatSession.toolCalls.allSatisfy { $0.status == .completed })
    #expect(
      controller.chatSession.testMessages.last?.content
        == "Completed and verified the full workflow."
    )
    #expect(
      try String(
        contentsOf: workspace.rootURL.appending(path: "flow.txt"),
        encoding: .utf8
      ) == "two\n"
    )

    let capturedToolContexts = await runtime.capturedToolContexts
    #expect(capturedToolContexts.count == 5)
    #expect(capturedToolContexts.allSatisfy { $0 != nil })
  }

  @Test
  func approvedWriteCanLeadToAnotherApprovalRequiredWrite() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: [
              "path": .string("first.txt"),
              "content": .string("first\n"),
            ]
          ))
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: [
              "path": .string("second.txt"),
              "content": .string("second\n"),
            ]
          ))
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "finish_task",
            arguments: [
              "status": .string("done"),
              "summary": .string("Created both files."),
            ]
          ))
      ],
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)

    controller.sendMessage(
      prompt: "Create first.txt and second.txt.",
      in: workspace,
      sessionID: sessionID
    )

    try await waitUntil {
      controller.chatSession.toolCalls.count == 1 && controller.hasPendingApproval
    }
    controller.approveToolCall(
      id: try #require(controller.chatSession.toolCalls.last?.id),
      in: workspace
    )

    try await waitUntil {
      controller.chatSession.toolCalls.count == 2 && controller.hasPendingApproval
    }
    #expect(controller.chatSession.toolCalls[0].status == .completed)
    #expect(controller.chatSession.toolCalls[1].status == .awaitingApproval)
    #expect(
      FileManager.default.fileExists(
        atPath: workspace.rootURL.appending(path: "first.txt").path(percentEncoded: false)
      )
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: workspace.rootURL.appending(path: "second.txt").path(percentEncoded: false)
      )
    )

    controller.approveToolCall(
      id: try #require(controller.chatSession.toolCalls.last?.id),
      in: workspace
    )
    try await waitUntil { controller.chatSession.turns.first?.status == .completed }

    #expect(
      controller.chatSession.toolCalls.map(\.request.toolName)
        == [.writeFile, .writeFile, .finishTask]
    )
    #expect(controller.chatSession.testMessages.last?.content == "Created both files.")

    let capturedToolContexts = await runtime.capturedToolContexts
    #expect(capturedToolContexts.count == 3)
    #expect(capturedToolContexts.allSatisfy { $0 != nil })
  }

  @Test
  func repeatedApprovalPausesDoNotResetTurnToolBatchBudget() async throws {
    let budget = ChatToolLoopLimits.defaultMaxToolLoopIterations
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    var eventTurns = (0..<budget).map { index in
      [
        ChatModelStreamEvent.toolCall(
          ChatRuntimeToolCall(
            name: "write_file",
            arguments: [
              "path": .string("file-\(index).txt"),
              "content": .string("\(index)\n"),
            ]
          ))
      ]
    }
    eventTurns.append([
      .chunk("Stopped after the turn-wide tool batch budget was exhausted.")
    ])
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: eventTurns)
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)

    controller.sendMessage(
      prompt: "Create the numbered files.",
      in: workspace,
      sessionID: sessionID
    )

    for expectedCount in 1...budget {
      try await waitUntil {
        controller.chatSession.toolCalls.count == expectedCount
          && controller.hasPendingApproval
      }
      controller.approveToolCall(
        id: try #require(controller.chatSession.toolCalls.last?.id),
        in: workspace
      )
    }

    try await waitUntil { controller.chatSession.turns.first?.status == .completed }

    #expect(controller.chatSession.turns.first?.toolCallBatchCount == budget)
    #expect(controller.chatSession.toolCalls.count == budget)
    #expect(controller.chatSession.toolCalls.allSatisfy { $0.status == .completed })

    let capturedToolContexts = await runtime.capturedToolContexts
    #expect(capturedToolContexts.count == budget + 1)
    #expect(capturedToolContexts.dropLast().allSatisfy { $0 != nil })
    #expect(capturedToolContexts[budget] == nil)
  }

  private func waitUntil(
    timeout: Duration = .seconds(3),
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let start = ContinuousClock.now
    while !condition() {
      if start.duration(to: .now) > timeout {
        Issue.record("Timed out waiting for condition")
        throw SemanticAgentLoopWaitTimeoutError()
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func makeWorkspace(sessionID: ChatSession.ID) throws -> Workspace {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "sumika-semantic-agent-loop-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
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

private struct SemanticAgentLoopWaitTimeoutError: Error {}
