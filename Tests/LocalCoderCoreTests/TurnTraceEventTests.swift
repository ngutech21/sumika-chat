import Foundation
import Testing

@testable import LocalCoderCore

struct TurnTraceEventTests {
  @Test
  func phaseRawValuesStayStableForJSONLAnalysis() {
    #expect(TurnTracePhase.contextBuild.rawValue == "context_build")
    #expect(TurnTracePhase.tokenizeContextUsage.rawValue == "tokenize_context_usage")
    #expect(TurnTracePhase.renderSystemPrompt.rawValue == "render_system_prompt")
    #expect(TurnTracePhase.runtimeStreamStart.rawValue == "runtime_stream_start")
    #expect(TurnTracePhase.runtimeTTFT.rawValue == "runtime_ttft")
    #expect(TurnTracePhase.runtimeDecode.rawValue == "runtime_decode")
    #expect(TurnTracePhase.runtimePartialDecode.rawValue == "runtime_partial_decode")
    #expect(TurnTracePhase.toolParse.rawValue == "tool_parse")
    #expect(TurnTracePhase.toolExecute.rawValue == "tool_execute")
    #expect(TurnTracePhase.uiFlush.rawValue == "ui_flush")
    #expect(TurnTracePhase.persist.rawValue == "persist")
    #expect(TurnTracePhase.memoryClear.rawValue == "memory_clear")
  }

  @Test
  func eventEncodesStableFieldNamesAndPhaseValue() throws {
    let turnID = UUID()
    let generationID = UUID()
    let event = TurnTraceEvent(
      turnID: turnID,
      generationID: generationID,
      phase: .runtimeTTFT,
      durationMs: 1234.5,
      promptBytes: 42,
      promptTokens: 11,
      messageCount: 3,
      toolLoopIteration: 2,
      toolName: "read_file",
      ttftMs: 1234.5,
      tokensPerSecond: 21.5,
      cacheMode: "mlx_default",
      cacheReason: "invalidated_history_prefix_mismatch",
      memoryClearReason: "runtime_error",
      interactionMode: .agent,
      contextSignature: "ctx-new",
      previousContextSignature: "ctx-old",
      appendOnly: true,
      reusedMessageCount: 4,
      appendedMessageCount: 2,
      mismatchReason: "history_prefix_mismatch",
      firstMismatchIndex: 1,
      systemPromptChanged: true,
      currentPromptContextChanged: false,
      toolCallFormat: "native",
      toolValidationStatus: "invalid",
      toolValidationError: "Unknown argument(s): id, status.",
      toolOriginalName: "todo_write",
      toolArgumentKeys: ["id", "status"],
      toolArguments: [
        ToolArgumentTrace(
          name: "id",
          valueType: "string",
          preview: "setup",
          previewTruncated: false
        )
      ],
      imageCount: 2,
      imageTypes: ["image/png", "image/jpeg"],
      imageByteCount: 4096
    )

    let data = try JSONEncoder().encode(event)
    let object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    #expect(object["turnID"] as? String == turnID.uuidString)
    #expect(object["generationID"] as? String == generationID.uuidString)
    #expect(object["phase"] as? String == "runtime_ttft")
    #expect(object["durationMs"] as? Double == 1234.5)
    #expect(object["promptBytes"] as? Int == 42)
    #expect(object["promptTokens"] as? Int == 11)
    #expect(object["messageCount"] as? Int == 3)
    #expect(object["toolLoopIteration"] as? Int == 2)
    #expect(object["toolName"] as? String == "read_file")
    #expect(object["ttftMs"] as? Double == 1234.5)
    #expect(object["tokensPerSecond"] as? Double == 21.5)
    #expect(object["cacheMode"] as? String == "mlx_default")
    #expect(object["cacheReason"] as? String == "invalidated_history_prefix_mismatch")
    #expect(object["memoryClearReason"] as? String == "runtime_error")
    #expect(object["interactionMode"] as? String == "agent")
    #expect(object["contextSignature"] as? String == "ctx-new")
    #expect(object["previousContextSignature"] as? String == "ctx-old")
    #expect(object["appendOnly"] as? Bool == true)
    #expect(object["reusedMessageCount"] as? Int == 4)
    #expect(object["appendedMessageCount"] as? Int == 2)
    #expect(object["mismatchReason"] as? String == "history_prefix_mismatch")
    #expect(object["firstMismatchIndex"] as? Int == 1)
    #expect(object["systemPromptChanged"] as? Bool == true)
    #expect(object["currentPromptContextChanged"] as? Bool == false)
    #expect(object["toolCallFormat"] as? String == "native")
    #expect(object["toolValidationStatus"] as? String == "invalid")
    #expect(object["toolValidationError"] as? String == "Unknown argument(s): id, status.")
    #expect(object["toolOriginalName"] as? String == "todo_write")
    #expect(object["toolArgumentKeys"] as? [String] == ["id", "status"])
    #expect(object["imageCount"] as? Int == 2)
    #expect(object["imageTypes"] as? [String] == ["image/png", "image/jpeg"])
    #expect(object["imageByteCount"] as? Int == 4096)

    let toolArguments = try #require(object["toolArguments"] as? [[String: Any]])
    #expect(toolArguments.count == 1)
    #expect(toolArguments.first?["name"] as? String == "id")
    #expect(toolArguments.first?["valueType"] as? String == "string")
    #expect(toolArguments.first?["preview"] as? String == "setup")
    #expect(toolArguments.first?["previewTruncated"] as? Bool == false)
  }
}
