import Foundation
import MLX
import MLXLMCommon
import XCTest

@testable import SumikaRuntimeMLX

nonisolated final class MLXThinkingBudgetCloseTests: XCTestCase {
  override func setUpWithError() throws {
    try super.setUpWithError()
    let libraryURL = Bundle(for: Self.self).resourceURL?
      .appending(path: "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
    guard let libraryURL, (try? libraryURL.checkResourceIsReachable()) == true else {
      throw XCTSkip("MLX default.metallib is unavailable in the SwiftPM test bundle.")
    }
  }

  func testForcedCloseMatchesCanonicalReasoningBoundary() throws {
    try Device.withDefaultDevice(.cpu) {
      try Stream.withNewDefaultStream(device: .cpu) {
        let tokenizer = BudgetCloseTestTokenizer()
        for body in ["requests_b.jsonl: a few lines,", "plan\n", ""] {
          let generated = try MLXBudgetCloseTestSupport.close(
            body: body, maximumTokenCount: tokenizer.encode(text: body).count,
            tokenizer: tokenizer)
          let reasoning = body.trimmingCharacters(in: .whitespacesAndNewlines)
          XCTAssertEqual(tokenizer.decode(tokenIds: generated), reasoning + "\n</think>\n\n")
        }
      }
    }
  }

  func testUnicodeCompletionStillPrecedesTheCanonicalClose() throws {
    try Device.withDefaultDevice(.cpu) {
      try Stream.withNewDefaultStream(device: .cpu) {
        let tokenizer = BudgetCloseTestTokenizer()
        let generated = try MLXBudgetCloseTestSupport.close(
          body: "é", maximumTokenCount: 1, tokenizer: tokenizer)
        XCTAssertEqual(tokenizer.decode(tokenIds: generated), "é\n</think>\n\n")
      }
    }
  }

  func testNaturalAndImplicitClosesRemainUnforced() throws {
    try Device.withDefaultDevice(.cpu) {
      try Stream.withNewDefaultStream(device: .cpu) {
        let tokenizer = BudgetCloseTestTokenizer()
        for body in ["plan\n</think>", "plan</think>", "plan<tool_call>"] {
          var processor = try MLXBudgetCloseTestSupport.processor(
            maximumTokenCount: 128, tokenizer: tokenizer)
          let expected = tokenizer.encode(text: body + "\n\nanswer")
          let generated = expected.map { MLXBudgetCloseTestSupport.sample($0, using: &processor) }
          XCTAssertEqual(generated, expected)
        }
      }
    }
  }
}

nonisolated enum MLXBudgetCloseTestSupport {
  static func processor(
    maximumTokenCount: Int, tokenizer: any Tokenizer
  ) throws -> any LogitProcessor {
    let parameters = GenerateParameters(maxTokens: 32_768)
    let components = try MLXThinkingBudgetPlanner.makeComponents(
      maximumTokenCount: maximumTokenCount, minimumAnswerTokenCount: 1,
      reasoning: QwenReasoningProtocol.tagged, tokenizer: tokenizer,
      generateParameters: parameters, enforcementState: MLXThinkingBudgetEnforcementState())
    var processor = try XCTUnwrap(components.logitProcessor(parameters: parameters))
    processor.prompt(MLXArray(tokenizer.encode(text: "<think>\n")))
    return processor
  }

  static func close(
    body: String, maximumTokenCount: Int, tokenizer: any Tokenizer
  ) throws -> [Int] {
    var processor = try processor(maximumTokenCount: maximumTokenCount, tokenizer: tokenizer)
    var generated = tokenizer.encode(text: body).map { sample($0, using: &processor) }
    let end = try XCTUnwrap(tokenizer.encode(text: "</think>").first)
    let newline = try XCTUnwrap(tokenizer.encode(text: "\n\n").first)
    for _ in 0..<16 {
      let text = tokenizer.decode(tokenIds: generated)
      if text.hasSuffix("</think>\n\n") { return generated }
      generated.append(sample(text.contains("</think>") ? newline : end, using: &processor))
    }
    XCTFail("The budget did not emit a complete reasoning close.")
    return generated
  }

  static func sample(_ candidate: Int, using processor: inout any LogitProcessor) -> Int {
    let logits = MLXArray(Array(repeating: Float(-100), count: max(candidate + 1, 2048)))
    let preferred = putAlong(logits, MLXArray([candidate]), values: MLXArray([Float(100)]), axis: 0)
    let sampled = argMax(processor.process(logits: preferred))
    processor.didSample(token: sampled)
    let token = sampled.item(Int.self)
    processor.didEmit(token: token)
    return token
  }
}

nonisolated struct BudgetCloseTestTokenizer: Tokenizer {
  func encode(text: String, addSpecialTokens: Bool) -> [Int] {
    var bytes = Array(text.utf8)
    var tokens: [Int] = []
    let markers = [("<think>", 1), ("</think>", 2), ("<tool_call>", 3), ("\n\n", 4)]
    while !bytes.isEmpty {
      if let marker = markers.first(where: { bytes.starts(with: $0.0.utf8) }) {
        tokens.append(marker.1)
        bytes.removeFirst(marker.0.utf8.count)
      } else {
        tokens.append(1000 + Int(bytes.removeFirst()))
      }
    }
    return tokens
  }

  func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
    let bytes = tokenIds.flatMap { token -> [UInt8] in
      switch token {
      case 1: Array("<think>".utf8)
      case 2: Array("</think>".utf8)
      case 3: Array("<tool_call>".utf8)
      case 4: Array("\n\n".utf8)
      default: [UInt8(token - 1000)]
      }
    }
    // Preserve the incomplete UTF-8 replacement that the budget processor detects.
    // swiftlint:disable:next optional_data_string_conversion
    return String(decoding: bytes, as: UTF8.self)
  }

  func convertTokenToId(_ token: String) -> Int? { nil }
  func convertIdToToken(_ id: Int) -> String? { nil }
  var bosToken: String? { nil }
  var eosToken: String? { nil }
  var unknownToken: String? { nil }

  func applyChatTemplate(
    messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
    additionalContext: [String: any Sendable]?
  ) throws -> [Int] { [] }
}
