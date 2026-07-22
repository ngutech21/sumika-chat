import Foundation
import MLXLMCommon
import SumikaCore
import Testing

@testable import SumikaRuntimeMLX

@Suite(.serialized)
struct MLXDebugTraceStoreTests {
  @Test
  func turnTraceEventDoesNotWriteWhenDebugTraceIsDisabled() async throws {
    unsetenv("SUMIKA_DEBUG_TRACE")
    let fileURL = temporaryTraceFileURL()
    let store = MLXDebugTraceStore(fileURL: fileURL)

    await store.recordTurnTraceEvent(
      TurnTraceEvent(phase: .runtimeTTFT, durationMs: 10, ttftMs: 10)
    )

    #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
  }

  @Test
  func turnTraceEventWritesToMLXTraceJSONLWhenDebugTraceIsEnabled() async throws {
    setenv("SUMIKA_DEBUG_TRACE", "1", 1)
    defer {
      unsetenv("SUMIKA_DEBUG_TRACE")
    }
    let turnID = UUID()
    let generationID = UUID()
    let fileURL = temporaryTraceFileURL()
    let store = MLXDebugTraceStore(fileURL: fileURL)

    await store.recordTurnTraceEvent(
      TurnTraceEvent(
        turnID: turnID,
        generationID: generationID,
        phase: .runtimeTTFT,
        durationMs: 123.5,
        messageCount: 2,
        ttftMs: 123.5,
        cacheMode: "reused_session",
        cacheReason: "reused_session",
        memoryClearReason: "runtime_error",
        contextSignature: "ctx-new",
        previousContextSignature: "ctx-old",
        appendOnly: true,
        reusedMessageCount: 3,
        appendedMessageCount: 1,
        mismatchReason: "history_prefix_mismatch",
        firstMismatchIndex: 2,
        systemPromptChanged: false,
        toolCallFormat: "native",
        toolValidationStatus: "invalid",
        toolValidationError: "Unknown argument(s): id, status.",
        toolOriginalName: "todo_write",
        toolArgumentKeys: ["id", "status"],
        toolArguments: [
          ToolArgumentTrace(
            name: "id",
            valueType: "string",
            preview: "setup-project",
            previewTruncated: false
          )
        ]
      )
    )

    let data = try Data(contentsOf: fileURL)
    let line = try #require(String(data: data, encoding: .utf8)?.split(separator: "\n").first)
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    )

    #expect(object["kind"] as? String == "turn_trace")
    #expect(object["turnID"] as? String == turnID.uuidString)
    #expect(object["generationID"] as? String == generationID.uuidString)
    #expect(object["phase"] as? String == "runtime_ttft")
    #expect(object["durationMs"] as? Double == 123.5)
    #expect(object["messageCount"] as? Int == 2)
    #expect(object["ttftMs"] as? Double == 123.5)
    #expect(object["cacheMode"] as? String == "reused_session")
    #expect(object["cacheReason"] as? String == "reused_session")
    #expect(object["memoryClearReason"] as? String == "runtime_error")
    #expect(object["contextSignature"] as? String == "ctx-new")
    #expect(object["previousContextSignature"] as? String == "ctx-old")
    #expect(object["appendOnly"] as? Bool == true)
    #expect(object["reusedMessageCount"] as? Int == 3)
    #expect(object["appendedMessageCount"] as? Int == 1)
    #expect(object["mismatchReason"] as? String == "history_prefix_mismatch")
    #expect(object["firstMismatchIndex"] as? Int == 2)
    #expect(object["systemPromptChanged"] as? Bool == false)
    #expect(object["toolCallFormat"] as? String == "native")
    #expect(object["toolValidationStatus"] as? String == "invalid")
    #expect(object["toolValidationError"] as? String == "Unknown argument(s): id, status.")
    #expect(object["toolOriginalName"] as? String == "todo_write")
    #expect(object["toolArgumentKeys"] as? [String] == ["id", "status"])

    let toolArguments = try #require(object["toolArguments"] as? [[String: Any]])
    #expect(toolArguments.count == 1)
    #expect(toolArguments.first?["name"] as? String == "id")
    #expect(toolArguments.first?["valueType"] as? String == "string")
    #expect(toolArguments.first?["preview"] as? String == "setup-project")
    #expect(toolArguments.first?["previewTruncated"] as? Bool == false)
  }

  @Test
  func requestTraceRecordsFinalPromptWithTransientInstructions() async throws {
    setenv("SUMIKA_DEBUG_TRACE", "1", 1)
    defer {
      unsetenv("SUMIKA_DEBUG_TRACE")
    }
    let fileURL = temporaryTraceFileURL()
    let store = MLXDebugTraceStore(fileURL: fileURL)
    let toolObservation = """
      <observation call_id="call_1" tool="read_file" status="success">
      README contents
      </observation>
      """
    let runtimeContext = """
      [Runtime Context]
      Active todo plan:
      - Inspect README.md
      """
    let promptWithTransientInstructions = MLXChatRuntime.appendTransientInstructions(
      [runtimeContext],
      toPromptSnapshot: [
        ProviderPromptMessage(
          role: Chat.Message.Role.tool.rawValue,
          content: toolObservation,
          toolCallID: "call_1"
        )
      ],
      promptMessages: [.tool(toolObservation, id: "call_1")]
    )
    let finalPrompt = promptWithTransientInstructions.promptMessages.map(\.content)
      .joined(separator: "\n\n")

    await store.traceRequest(
      id: UUID(),
      history: [(role: "tool", content: toolObservation)],
      prompt: finalPrompt,
      settings: .agentDefault,
      contextTokenLimit: nil
    )

    let data = try Data(contentsOf: fileURL)
    let line = try #require(String(data: data, encoding: .utf8)?.split(separator: "\n").first)
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    )
    let history = try #require(object["history"] as? [[String: Any]])
    let prompt = try #require(object["prompt"] as? String)

    #expect(object["kind"] as? String == "mlx_request")
    #expect(prompt.contains(runtimeContext))
    #expect(prompt.contains(toolObservation))
    #expect((history.first?["content"] as? String)?.contains(runtimeContext) == false)
    #expect((history.first?["content"] as? String)?.contains(toolObservation) == true)
  }

  @Test
  func defaultTraceFileUsesEnvironmentOverrideWhenPresent() async throws {
    setenv("SUMIKA_DEBUG_TRACE", "1", 1)
    let fileURL = temporaryTraceFileURL()
    setenv("SUMIKA_DEBUG_TRACE_FILE", fileURL.path(percentEncoded: false), 1)
    defer {
      unsetenv("SUMIKA_DEBUG_TRACE")
      unsetenv("SUMIKA_DEBUG_TRACE_FILE")
    }

    let store = MLXDebugTraceStore()

    await store.recordTurnTraceEvent(
      TurnTraceEvent(phase: .runtimeTTFT, durationMs: 10, ttftMs: 10)
    )

    #expect(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
  }

  @Test
  func defaultTraceFileUsesBasenameEnvironmentOverrideWhenPresent() async throws {
    setenv("SUMIKA_DEBUG_TRACE", "1", 1)
    let basename = "\(UUID().uuidString)-mlx-trace.jsonl"
    setenv("SUMIKA_DEBUG_TRACE_BASENAME", basename, 1)
    defer {
      unsetenv("SUMIKA_DEBUG_TRACE")
      unsetenv("SUMIKA_DEBUG_TRACE_BASENAME")
    }

    let store = MLXDebugTraceStore()

    await store.recordTurnTraceEvent(
      TurnTraceEvent(phase: .runtimeTTFT, durationMs: 10, ttftMs: 10)
    )

    let traceURL = URL.applicationSupportDirectory
      .appending(path: "Sumika", directoryHint: .isDirectory)
      .appending(path: "debug", directoryHint: .isDirectory)
      .appending(path: "traces", directoryHint: .isDirectory)
      .appending(path: basename, directoryHint: .notDirectory)
    #expect(FileManager.default.fileExists(atPath: traceURL.path(percentEncoded: false)))
  }

  private func temporaryTraceFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
      .appending(path: "mlx-trace.jsonl", directoryHint: .notDirectory)
  }
}
