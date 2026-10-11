import Foundation
import MLXLMCommon
import XCTest

@testable import SumikaCore
@testable import SumikaRuntimeMLX

nonisolated final class Swift15MTPRealModelTests: XCTestCase {
  func testInstalledSwiftGreedyParityAcrossTurnsAndToolResult() async throws {
    guard ProcessInfo.processInfo.environment["SUMIKA_RUN_SWIFT15_MTP_TEST"] == "1" else {
      throw XCTSkip("Set SUMIKA_RUN_SWIFT15_MTP_TEST=1 to run the local Swift MTP test.")
    }
    let metalLibrary = Bundle(for: Self.self).resourceURL?
      .appending(path: "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
    guard let metalLibrary, FileManager.default.fileExists(atPath: metalLibrary.path) else {
      throw XCTSkip("MLX default.metallib is unavailable in the SwiftPM test bundle.")
    }
    let model = try XCTUnwrap(ManagedModelCatalog.model(id: "Swift-1.5-4bit-MLX"))
    let directory = model.localDirectoryURL
    guard FileManager.default.fileExists(atPath: directory.appending(path: "config.json").path)
    else { throw XCTSkip("The local Swift 1.5 model is not installed.") }
    let loaded = try await Swift15ModelLoader.loadIfSupported(
      from: directory, using: makeHuggingFaceTokenizerLoader(), loadMTPDrafter: true)
    let target = try XCTUnwrap(loaded).target
    let drafter = try XCTUnwrap(loaded?.mtpDrafter)
    let parameters = GenerateParameters(maxTokens: 64, temperature: 0)
    let context: [String: any Sendable] = ["enable_thinking": false]
    let tools: [ToolSpec] = [
      [
        "type": "function",
        "function": [
          "name": "read_file", "description": "Read a local file.",
          "parameters": [
            "type": "object", "properties": ["path": ["type": "string"]], "required": ["path"],
          ] as [String: any Sendable],
        ] as [String: any Sendable],
      ]
    ]
    let greedy = ChatSession(
      target, generateParameters: parameters, additionalContext: context, tools: tools)
    let mtp = ChatSession(
      target, speculativeDecoding: try .init(mtpDrafter: drafter, blockSize: 2),
      generateParameters: parameters, additionalContext: context, tools: tools)
    let call = ToolCall(
      function: .init(name: "read_file", arguments: ["path": "receipt.txt"]), id: "receipt")
    let inputs: [[Chat.Message]] = [
      [.user("Reply with exactly: Hello from Swift.")],
      [.user("Repeat your previous reply.")],
      [
        .user("Read receipt.txt and reply with only its receipt code."),
        .assistant("", toolCalls: [call]),
        .tool("COBALT-731", id: "receipt", name: "read_file"),
      ],
    ]
    var acceptedTotal = 0
    for (index, input) in inputs.enumerated() {
      let baseline = try await collect(greedy.streamDetails(to: input))
      let drafted = try await collect(mtp.streamDetails(to: input))
      XCTAssertEqual(drafted.text, baseline.text)
      XCTAssertEqual(drafted.calls, baseline.calls)
      XCTAssertTrue(drafted.calls.isEmpty)
      XCTAssertNil(baseline.info.speculativeDecodingTelemetry)
      XCTAssertGreaterThan(try XCTUnwrap(drafted.info.speculativeDecodingTelemetry).roundCount, 0)
      let proposed = try XCTUnwrap(drafted.info.proposedDraftTokens)
      let accepted = try XCTUnwrap(drafted.info.acceptedDraftTokens)
      XCTAssertGreaterThan(proposed, 0)
      XCTAssertLessThanOrEqual(accepted, proposed)
      XCTAssertNil(drafted.info.passthroughReason)
      XCTAssertNil(drafted.info.speculativeDecodingFallbackReason)
      if index > 0 {
        XCTAssertGreaterThan(baseline.info.cachedPromptTokenCount, 0)
        XCTAssertGreaterThan(drafted.info.cachedPromptTokenCount, 0)
      }
      if index == 2 { XCTAssertTrue(drafted.text.contains("COBALT-731")) }
      acceptedTotal += accepted
      print(
        "SWIFT15 MTP turn=\(index + 1) accepted=\(accepted)/\(proposed) "
          + "greedy_decode=\(baseline.info.tokensPerSecond) mtp_decode=\(drafted.info.tokensPerSecond) "
          + "greedy_prefill=\(baseline.info.promptTime) mtp_prefill=\(drafted.info.promptTime) "
          + "greedy_cached=\(baseline.info.cachedPromptTokenCount) mtp_cached=\(drafted.info.cachedPromptTokenCount) "
          + "greedy_total=\(baseline.elapsed) mtp_total=\(drafted.elapsed)")
    }
    XCTAssertGreaterThan(acceptedTotal, 0)
  }

  private func collect(_ stream: AsyncThrowingStream<Generation, Error>) async throws
    -> (text: String, calls: [ToolCall], info: GenerateCompletionInfo, elapsed: TimeInterval)
  {
    let start = Date()
    var text = ""
    var calls: [ToolCall] = []
    var completion: GenerateCompletionInfo?
    for try await event in stream {
      if let chunk = event.chunk { text += chunk }
      if let call = event.toolCall { calls.append(call) }
      if let info = event.info { completion = info }
    }
    return (text, calls, try XCTUnwrap(completion), Date().timeIntervalSince(start))
  }
}
