import Foundation
import Testing

@testable import SumikaCore

struct ChatSessionTests {
  @Test
  func activeModeSettingsFollowInteractionMode() {
    var session = ChatSession(
      modeSettings: ChatModeSettingsSet(
        chat: ChatModeSettings(
          systemPrompt: "Chat prompt",
          generationSettings: ChatGenerationSettings(
            temperature: 1.0, topP: 0.95, topK: 20, maxTokens: 512)),
        agent: ChatModeSettings(
          systemPrompt: "Agent prompt",
          generationSettings: ChatGenerationSettings(
            temperature: 0.1, topP: 0.8, topK: 10, maxTokens: 256))
      ),
      interactionMode: .chat
    )

    #expect(session.systemPrompt == "Chat prompt")
    #expect(session.generationSettings.temperature == 1.0)

    session.interactionMode = .agent

    #expect(session.systemPrompt == "Agent prompt")
    #expect(session.generationSettings.temperature == 0.1)
  }

  @Test
  func updatingActivePromptMutatesOnlyActiveMode() {
    var session = ChatSession()

    session.systemPrompt = "Custom chat prompt"
    session.generationSettings.temperature = 1.4

    #expect(session.modeSettings.chat.systemPrompt == "Custom chat prompt")
    #expect(session.modeSettings.chat.generationSettings.temperature == 1.4)
    #expect(session.modeSettings.agent.systemPrompt == ChatPromptDefaults.agentSystemPrompt)
    #expect(session.modeSettings.agent.generationSettings == .agentDefault)
  }

  @Test
  func encodingPersistsModeSettingsOwner() throws {
    let session = ChatSession()
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])

    #expect(object["modeSettings"] != nil)
    #expect(object["systemPrompt"] == nil)
    #expect(object["generationSettings"] == nil)
  }

  @Test
  func selectedMCPServerIDsPreserveOrderAndRemoveDuplicates() throws {
    let first = UUID()
    let second = UUID()
    let session = ChatSession(selectedMCPServerIDs: [second, first, second])

    let decoded = try JSONDecoder().decode(
      ChatSession.self,
      from: JSONEncoder().encode(session)
    )

    #expect(session.selectedMCPServerIDs == [second, first])
    #expect(decoded.selectedMCPServerIDs == [second, first])
  }

  @Test
  func decodingMissingSelectedMCPServerIDsUsesEmptyDefault() throws {
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(ChatSession())) as? [String: Any]
    )
    object.removeValue(forKey: "selectedMCPServerIDs")
    let data = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(ChatSession.self, from: data)

    #expect(decoded.selectedMCPServerIDs.isEmpty)
  }

  @Test
  func decodingMissingModeSettingsUsesDefaults() throws {
    let legacyGenerationSettings = ChatGenerationSettings(
      temperature: 1.7,
      topP: 0.5,
      topK: 4,
      maxTokens: 64
    )
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(ChatSession())) as? [String: Any]
    )
    object.removeValue(forKey: "modeSettings")
    object["systemPrompt"] = "Ignored legacy prompt"
    object["generationSettings"] = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyGenerationSettings))
        as? [String: Any]
    )
    let data = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(ChatSession.self, from: data)

    #expect(decoded.modeSettings == .defaultSettings)
  }

  @Test
  func decodingPartialModeSettingsUsesModeSpecificDefaults() throws {
    var object = try #require(
      JSONSerialization.jsonObject(
        with: JSONEncoder().encode(ChatModeSettingsSet.defaultSettings)
      ) as? [String: Any]
    )
    var chat = try #require(object["chat"] as? [String: Any])
    chat.removeValue(forKey: "systemPrompt")
    chat.removeValue(forKey: "generationSettings")
    object["chat"] = chat
    object.removeValue(forKey: "agent")
    let data = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(ChatModeSettingsSet.self, from: data)

    #expect(decoded.chat == ChatModeSettingsSet.defaultSettings.chat)
    #expect(decoded.agent == ChatModeSettingsSet.defaultSettings.agent)
  }

  @Test
  func decodingResolvesInterruptedStreamingTurns() throws {
    let completeID = UUID()
    let partialID = UUID()
    let placeholderID = UUID()
    let session = ChatSession(turns: [
      ChatTurn(
        status: .running,
        items: [
          .assistantMessage(
            AssistantTurnMessage(id: completeID, content: "Done", deliveryStatus: .complete)
          ),
          .assistantMessage(
            AssistantTurnMessage(id: partialID, content: "Half a thou", deliveryStatus: .streaming)
          ),
          .assistantMessage(
            AssistantTurnMessage(id: placeholderID, content: "", deliveryStatus: .streaming)
          ),
        ]
      )
    ])

    let decoded = try JSONDecoder().decode(
      ChatSession.self,
      from: JSONEncoder().encode(session)
    )

    let items = decoded.turns[0].items
    // Interrupted streaming messages are preserved for append-only ordering and
    // marked cancelled so reload never resurfaces them as active generation.
    #expect(items.count == 3)
    #expect(
      items.contains(
        .assistantMessage(
          AssistantTurnMessage(id: completeID, content: "Done", deliveryStatus: .complete))))
    #expect(
      items.contains(
        .assistantMessage(
          AssistantTurnMessage(id: partialID, content: "Half a thou", deliveryStatus: .cancelled))))
    #expect(
      items.contains(
        .assistantMessage(
          AssistantTurnMessage(id: placeholderID, content: "", deliveryStatus: .cancelled))))
  }

  @Test
  func decodingInterruptedStreamingTurnsIsDeterministic() throws {
    let partialID = UUID()
    let placeholderID = UUID()
    let updatedAt = Date(timeIntervalSinceReferenceDate: 42)
    let session = ChatSession(turns: [
      ChatTurn(
        status: .running,
        items: [
          .assistantMessage(
            AssistantTurnMessage(id: partialID, content: "Half a thou", deliveryStatus: .streaming)
          ),
          .assistantMessage(
            AssistantTurnMessage(id: placeholderID, content: "", deliveryStatus: .streaming)
          ),
        ],
        updatedAt: updatedAt
      )
    ])
    let encoded = try JSONEncoder().encode(session)

    let first = try JSONDecoder().decode(ChatSession.self, from: encoded)
    let second = try JSONDecoder().decode(ChatSession.self, from: encoded)

    #expect(first.turns == second.turns)
    #expect(first.turns[0].updatedAt == updatedAt)
  }

  @Test
  func decodingPreservesNonStreamingTurns() throws {
    let session = ChatSession(turns: [
      ChatTurn(
        status: .completed,
        items: [
          .assistantMessage(AssistantTurnMessage(content: "All good", deliveryStatus: .complete)),
          .assistantMessage(AssistantTurnMessage(content: "Stopped", deliveryStatus: .cancelled)),
        ]
      )
    ])

    let decoded = try JSONDecoder().decode(
      ChatSession.self,
      from: JSONEncoder().encode(session)
    )

    #expect(decoded.turns == session.turns)
  }

  @Test
  func toolCallsAreProjectedFromToolItems() {
    let record = makeToolCallRecord(status: .completed)
    let session = ChatSession(turns: [
      ChatTurn(status: .completed, items: [.tool(record)])
    ])

    #expect(session.toolCalls == [record])
    #expect(session.toolCallRecord(id: record.id) == record)
  }
}

private func makeToolCallRecord(
  request: ToolCallRequest? = nil,
  status: ToolCallStatus
) -> ToolCallRecord {
  let resolvedRequest =
    request
    ?? ToolCallRequest.validated(
      raw: RawToolCallRequest(
        workspaceID: UUID(),
        sessionID: UUID(),
        toolName: .listFiles
      ),
      payload: .listFiles(ListFilesInput(path: nil))
    )
  return ToolCallRecord(
    request: resolvedRequest,
    evaluation: ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Allowed for test.",
      riskLevel: .low
    ),
    state: toolCallState(status: status)
  )
}

private func toolCallState(status: ToolCallStatus) -> ToolCallState {
  switch status {
  case .pending:
    return .pending
  case .awaitingApproval:
    return .awaitingApproval(preview: nil)
  case .awaitingUserAnswer:
    return .awaitingUserAnswer
  case .running:
    return .running
  case .completed:
    return .completed(
      .listFiles(ListFilesResult(root: WorkspaceRelativePath(rawValue: "."), entries: [])))
  case .denied:
    return .denied(
      .failure(ToolFailure(toolName: .listFiles, path: nil, reason: .permissionDenied)))
  case .failed:
    return .failed(
      .failure(ToolFailure(toolName: .listFiles, path: nil, reason: .executionError("Failed."))))
  case .cancelled:
    return .cancelled
  }
}
