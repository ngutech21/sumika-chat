import Foundation
import LocalCoderCore
import Testing

@testable import local_coder

@Suite(.serialized)
struct GemmaDebugTraceStoreTests {
  @Test
  func turnTraceEventDoesNotWriteWhenDebugTraceIsDisabled() async throws {
    unsetenv("LOCAL_CODER_DEBUG_TRACE")
    let fileURL = temporaryTraceFileURL()
    let store = GemmaDebugTraceStore(fileURL: fileURL)

    await store.traceTurnEvent(
      TurnTraceEvent(phase: .runtimeTTFT, durationMs: 10, ttftMs: 10)
    )

    #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
  }

  @Test
  func turnTraceEventWritesToGemmaTraceJSONLWhenDebugTraceIsEnabled() async throws {
    setenv("LOCAL_CODER_DEBUG_TRACE", "1", 1)
    defer {
      unsetenv("LOCAL_CODER_DEBUG_TRACE")
    }
    let turnID = UUID()
    let generationID = UUID()
    let fileURL = temporaryTraceFileURL()
    let store = GemmaDebugTraceStore(fileURL: fileURL)

    await store.traceTurnEvent(
      TurnTraceEvent(
        turnID: turnID,
        generationID: generationID,
        phase: .runtimeTTFT,
        durationMs: 123.5,
        messageCount: 2,
        ttftMs: 123.5,
        cacheMode: "session_reused",
        cacheReason: "session_reused",
        contextSignature: "ctx-new",
        previousContextSignature: "ctx-old",
        appendOnly: true,
        reusedMessageCount: 3,
        appendedMessageCount: 1,
        mismatchReason: "history_prefix_mismatch",
        firstMismatchIndex: 2,
        systemPromptChanged: false,
        currentPromptContextChanged: true
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
    #expect(object["cacheMode"] as? String == "session_reused")
    #expect(object["cacheReason"] as? String == "session_reused")
    #expect(object["contextSignature"] as? String == "ctx-new")
    #expect(object["previousContextSignature"] as? String == "ctx-old")
    #expect(object["appendOnly"] as? Bool == true)
    #expect(object["reusedMessageCount"] as? Int == 3)
    #expect(object["appendedMessageCount"] as? Int == 1)
    #expect(object["mismatchReason"] as? String == "history_prefix_mismatch")
    #expect(object["firstMismatchIndex"] as? Int == 2)
    #expect(object["systemPromptChanged"] as? Bool == false)
    #expect(object["currentPromptContextChanged"] as? Bool == true)
  }

  @Test
  func defaultTraceFileUsesEnvironmentOverrideWhenPresent() async throws {
    setenv("LOCAL_CODER_DEBUG_TRACE", "1", 1)
    let fileURL = temporaryTraceFileURL()
    setenv("LOCAL_CODER_DEBUG_TRACE_FILE", fileURL.path(percentEncoded: false), 1)
    defer {
      unsetenv("LOCAL_CODER_DEBUG_TRACE")
      unsetenv("LOCAL_CODER_DEBUG_TRACE_FILE")
    }

    let store = GemmaDebugTraceStore()

    await store.traceTurnEvent(
      TurnTraceEvent(phase: .runtimeTTFT, durationMs: 10, ttftMs: 10)
    )

    #expect(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
  }

  @Test
  func defaultTraceFileUsesBasenameEnvironmentOverrideWhenPresent() async throws {
    setenv("LOCAL_CODER_DEBUG_TRACE", "1", 1)
    let basename = "\(UUID().uuidString)-gemma-trace.jsonl"
    setenv("LOCAL_CODER_DEBUG_TRACE_BASENAME", basename, 1)
    defer {
      unsetenv("LOCAL_CODER_DEBUG_TRACE")
      unsetenv("LOCAL_CODER_DEBUG_TRACE_BASENAME")
    }

    let store = GemmaDebugTraceStore()

    await store.traceTurnEvent(
      TurnTraceEvent(phase: .runtimeTTFT, durationMs: 10, ttftMs: 10)
    )

    let traceURL = URL.applicationSupportDirectory
      .appending(path: "local-coder", directoryHint: .isDirectory)
      .appending(path: "debug", directoryHint: .isDirectory)
      .appending(path: "traces", directoryHint: .isDirectory)
      .appending(path: basename, directoryHint: .notDirectory)
    #expect(FileManager.default.fileExists(atPath: traceURL.path(percentEncoded: false)))
  }

  private func temporaryTraceFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
      .appending(path: "gemma-trace.jsonl", directoryHint: .notDirectory)
  }
}
