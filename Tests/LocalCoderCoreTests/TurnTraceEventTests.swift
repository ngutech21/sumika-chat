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
      interactionMode: .agent
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
    #expect(object["interactionMode"] as? String == "agent")
  }
}
