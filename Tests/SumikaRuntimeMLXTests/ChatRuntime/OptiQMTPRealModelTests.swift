import Foundation
import MLXLLM
import MLXLMCommon
import XCTest

@testable import SumikaCore
@testable import SumikaRuntimeMLX

nonisolated final class OptiQMTPRealModelTests: XCTestCase {
  func testQwen27BMTPTwoTurnGreedyParity() async throws {
    guard ProcessInfo.processInfo.environment["SUMIKA_RUN_QWEN27B_MTP_TEST"] == "1" else {
      throw XCTSkip("Set SUMIKA_RUN_QWEN27B_MTP_TEST=1 to run the local 27B MTP test.")
    }
    guard Self.hasBundledMetalLibrary else {
      throw XCTSkip("MLX default.metallib is unavailable in the SwiftPM test bundle.")
    }
    let model = try XCTUnwrap(
      ManagedModelCatalog.model(id: "Qwen3.6-27B-OptiQ-4bit")
    )
    let modelDirectory = model.localDirectoryURL
    let requiredFiles = [
      "config.json",
      "model.safetensors.index.json",
      "tokenizer.json",
      "optiq/mtp.safetensors",
    ]
    guard
      requiredFiles.allSatisfy({ relativePath in
        FileManager.default.fileExists(
          atPath: modelDirectory.appending(path: relativePath).path(percentEncoded: false)
        )
      })
    else {
      throw XCTSkip("The local Qwen3.6-27B OptiQ model with MTP sidecar is not installed.")
    }

    let target = try await LLMModelFactory.shared.loadContainer(
      from: modelDirectory,
      using: makeHuggingFaceTokenizerLoader()
    )
    let speculativeDecoding = try SpeculativeDecodingConfig(
      mtpDrafter: try await BundledOptiQMTPDrafterLoader.load(for: target),
      blockSize: 2
    )
    let parameters = GenerateParameters(maxTokens: 128, temperature: 0)
    let additionalContext: [String: any Sendable] = ["enable_thinking": false]
    let greedySession = ChatSession(
      target,
      generateParameters: parameters,
      additionalContext: additionalContext
    )
    let mtpSession = ChatSession(
      target,
      speculativeDecoding: speculativeDecoding,
      generateParameters: parameters,
      additionalContext: additionalContext
    )
    let prompts = [
      "Explain actor isolation in one sentence.",
      "Now show a minimal three-line Swift example.",
    ]

    var totalAcceptedDraftTokens = 0
    for prompt in prompts {
      let greedy = try await collect(greedySession.streamDetails(to: prompt))
      let mtp = try await collect(mtpSession.streamDetails(to: prompt))

      XCTAssertEqual(mtp.text, greedy.text)
      XCTAssertNil(greedy.info.speculativeDecodingTelemetry)
      XCTAssertNil(greedy.info.proposedDraftTokens)
      XCTAssertNil(greedy.info.acceptedDraftTokens)
      XCTAssertNil(greedy.info.passthroughReason)
      let telemetry = try XCTUnwrap(mtp.info.speculativeDecodingTelemetry)
      XCTAssertGreaterThan(telemetry.roundCount, 0)
      let proposed = try XCTUnwrap(mtp.info.proposedDraftTokens)
      let accepted = try XCTUnwrap(mtp.info.acceptedDraftTokens)
      XCTAssertGreaterThan(proposed, 0)
      XCTAssertLessThanOrEqual(accepted, proposed)
      XCTAssertNil(mtp.info.passthroughReason)
      totalAcceptedDraftTokens += accepted
    }
    XCTAssertGreaterThan(totalAcceptedDraftTokens, 0)
  }

  private func collect(
    _ stream: AsyncThrowingStream<Generation, Error>
  ) async throws -> (text: String, info: GenerateCompletionInfo) {
    var text = ""
    var completion: GenerateCompletionInfo?
    for try await event in stream {
      if let chunk = event.chunk {
        text += chunk
      }
      if let info = event.info {
        completion = info
      }
    }
    return (text, try XCTUnwrap(completion))
  }

  private static var hasBundledMetalLibrary: Bool {
    let testBundle = Bundle(for: Self.self)
    let libraryURL = testBundle.resourceURL?
      .appending(path: "mlx-swift_Cmlx.bundle", directoryHint: .isDirectory)
      .appending(path: "Contents/Resources/default.metallib", directoryHint: .notDirectory)
    guard let libraryURL else {
      return false
    }
    return (try? libraryURL.checkResourceIsReachable()) == true
  }
}
