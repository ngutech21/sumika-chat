import Foundation
import Testing

@testable import SumikaCore

@Suite
struct ProviderPromptProjectionTests {
  @Test
  func byteLedgerCountsFinalNormalizedMessageFieldsOnce() throws {
    let anchorID = try uuid("00000000-0000-0000-0000-000000000001")
    let middleID = try uuid("00000000-0000-0000-0000-000000000002")
    let candidateID = try uuid("00000000-0000-0000-0000-000000000003")
    let entries = [
      try entry(id: anchorID, role: .user, content: "A", imageSignatures: ["ignored"]),
      try entry(id: middleID, role: .assistant, content: "é"),
      try entry(id: candidateID, role: .user, content: "B"),
    ]

    let projection = ProviderPromptProjection.normalized(
      from: ModelPromptProjection(entries: entries)
    )

    #expect(projection.messages.map(\.content) == ["A", "é", "B"])
    #expect(projection.messages.map(\.projectedPayloadByteCount) == [5, 12, 5])
    #expect(projection.byteLedger.entries.map(\.payloadByteRange) == [0..<5, 5..<17, 17..<22])
    #expect(projection.byteLedger.totalByteCount == 22)
    #expect(
      projection.byteLedger.interveningByteCount(
        afterSourceEntryID: anchorID,
        beforeSourceEntryID: candidateID
      ) == 12)
  }

  @Test
  func normalizationMergesMessagesAndPreservesSourceProvenance() throws {
    let firstID = try uuid("00000000-0000-0000-0000-000000000011")
    let secondID = try uuid("00000000-0000-0000-0000-000000000012")
    let projection = ProviderPromptProjection.normalized(
      from: ModelPromptProjection(
        entries: [
          try entry(id: firstID, role: .user, content: "first"),
          try entry(id: secondID, role: .user, content: "second"),
        ]
      )
    )

    #expect(projection.messages.count == 1)
    #expect(projection.messages[0].content == "first\n\nsecond")
    #expect(projection.messages[0].sourceEntryIDs == [firstID, secondID])
    #expect(
      projection.messages[0].sourceContentByteRanges
        == [
          ProviderPromptSourceContentByteRange(
            sourceEntryID: firstID,
            contentByteRange: 0..<5
          ),
          ProviderPromptSourceContentByteRange(
            sourceEntryID: secondID,
            contentByteRange: 7..<13
          ),
        ])
    #expect(
      projection.byteLedger.interveningByteCount(
        afterSourceEntryID: firstID,
        beforeSourceEntryID: secondID
      ) == 2)
  }

  @Test
  func structuredToolPayloadUsesCanonicalJSONAndSeparateResultMessage() throws {
    let callID = try uuid("00000000-0000-0000-0000-000000000021")
    let assistantID = try uuid("00000000-0000-0000-0000-000000000022")
    let resultID = try uuid("00000000-0000-0000-0000-000000000023")
    let toolCall = ToolCallModelMessage(
      callID: callID,
      toolName: .readFile,
      arguments: [],
      rawArguments: [
        "z": .number(2),
        "a": .string("x"),
      ]
    )
    let entries = [
      try entry(role: .user, content: "inspect"),
      try ModelContextEntry(
        id: assistantID,
        body: .assistantOutput(AssistantOutputContext(content: toolCall.modelContextContent)),
        frozenContent: FrozenModelContent(
          role: .assistant,
          content: toolCall.modelContextContent
        )
      ),
      try ModelContextEntry(
        id: resultID,
        body: .toolObservation(
          ToolObservationContext(
            callID: callID,
            toolName: .readFile,
            status: .success,
            content: "file contents",
            toolCall: toolCall
          )
        ),
        frozenContent: FrozenModelContent(role: .tool, content: "file contents")
      ),
    ]

    let projection = ProviderPromptProjection.normalized(
      from: ModelPromptProjection(entries: entries)
    )
    let assistant = projection.messages[1]
    let result = projection.messages[2]
    let runtimeCallID = RuntimeToolCallID.string(for: callID)
    let expectedJSON =
      "{\"arguments\":{\"a\":\"x\",\"z\":2},\"id\":\"\(runtimeCallID)\",\"name\":\"read_file\"}"

    #expect(projection.messages.map(\.role) == ["user", "assistant", "tool"])
    #expect(assistant.content.isEmpty)
    #expect(assistant.toolCalls[0].canonicalPayloadJSON == expectedJSON)
    #expect(assistant.sourceEntryIDs == [assistantID, resultID])
    #expect(result.toolCallID == runtimeCallID)
    #expect(result.sourceEntryIDs == [resultID])
    #expect(
      assistant.projectedPayloadByteCount
        == "assistant".utf8.count + expectedJSON.utf8.count)
    #expect(
      result.projectedPayloadByteCount
        == "tool".utf8.count + "file contents".utf8.count + runtimeCallID.utf8.count)
  }

  @Test
  func generationSegmentsKeepAssistantToolCallInHistoryAndResultsInPrompt() throws {
    let callID = try uuid("00000000-0000-0000-0000-000000000031")
    let toolCall = ToolCallModelMessage(
      callID: callID,
      toolName: .listFiles,
      arguments: [],
      rawArguments: [:]
    )
    let entries = [
      try entry(role: .user, content: "list files"),
      try ModelContextEntry(
        body: .assistantOutput(AssistantOutputContext(content: toolCall.modelContextContent)),
        frozenContent: FrozenModelContent(
          role: .assistant,
          content: toolCall.modelContextContent
        )
      ),
      try ModelContextEntry(
        body: .toolObservation(
          ToolObservationContext(
            callID: callID,
            toolName: .listFiles,
            status: .success,
            content: "README.md",
            toolCall: toolCall
          )
        ),
        frozenContent: FrozenModelContent(role: .tool, content: "README.md")
      ),
      try entry(role: .user, content: "read it"),
    ]

    let segments = try #require(
      ProviderPromptProjection.generationSegments(
        from: ModelPromptProjection(entries: entries)
      )
    )

    #expect(segments.history.messages.map(\.role) == ["user", "assistant"])
    #expect(segments.history.messages[1].toolCalls.count == 1)
    #expect(segments.prompt.messages.map(\.role) == ["tool", "user"])
    #expect(segments.prompt.messages[0].toolCallID == RuntimeToolCallID.string(for: callID))
  }

  @Test
  func providerEqualityIgnoresProvenanceButIncludesImageIdentity() {
    let firstID = UUID()
    let secondID = UUID()
    let first = ProviderPromptMessage(
      role: "user",
      content: "same",
      imageSignatures: ["sha256:image"],
      sourceEntryIDs: [firstID]
    )
    let samePayload = ProviderPromptMessage(
      role: "user",
      content: "same",
      imageSignatures: ["sha256:image"],
      sourceEntryIDs: [secondID]
    )
    let differentImage = ProviderPromptMessage(
      role: "user",
      content: "same",
      imageSignatures: ["sha256:other"],
      sourceEntryIDs: [firstID]
    )

    #expect(first == samePayload)
    #expect(first != differentImage)
    #expect(first.projectedPayloadByteCount == samePayload.projectedPayloadByteCount)
  }

  private func entry(
    id: UUID = UUID(),
    role: ModelContextRole,
    content: String,
    imageSignatures: [String] = []
  ) throws -> ModelContextEntry {
    let body: ModelContextEntryBody =
      switch role {
      case .user:
        .userPrompt(
          UserPromptContext(prompt: content, imageSignatures: imageSignatures)
        )
      case .assistant:
        .assistantOutput(AssistantOutputContext(content: content))
      case .tool:
        .toolObservation(
          ToolObservationContext(
            callID: UUID(),
            toolName: .invalid,
            status: .success,
            content: content
          )
        )
      }
    return try ModelContextEntry(
      id: id,
      body: body,
      frozenContent: FrozenModelContent(role: role, content: content)
    )
  }

  private func uuid(_ string: String) throws -> UUID {
    try #require(UUID(uuidString: string))
  }
}
