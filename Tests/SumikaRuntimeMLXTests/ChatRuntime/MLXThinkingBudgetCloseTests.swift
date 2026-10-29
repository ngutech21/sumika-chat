import Foundation
import MLX
import MLXLMCommon
import SumikaCore
import Synchronization
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

  func testReasoningCodeStillDeliversWriteFileAcrossBoundaryKinds() throws {
    try Device.withDefaultDevice(.cpu) {
      try Stream.withNewDefaultStream(device: .cpu) {
        let tokenizer = BudgetCloseTestTokenizer()
        let call = """
          <tool_call><function=write_file><parameter=content>print(50)</parameter>
          <parameter=path>/app/src/limiter/window.py</parameter></function></tool_call>
          """
        for body in ["`unfinished", "```python\ndef choose_limit():\n    return 50"] {
          let forced = try MLXBudgetCloseTestSupport.close(
            body: body, maximumTokenCount: tokenizer.encode(text: body).count,
            tokenizer: tokenizer)
          let natural = tokenizer.encode(text: body + "\n</think>\n\n")
          let implicit = tokenizer.encode(text: body)
          for closed in [forced, natural, implicit] {
            let outputs = MLXBudgetCloseTestSupport.events(
              tokens: closed + tokenizer.encode(text: call), tokenizer: tokenizer)
            let calls = outputs.compactMap(\.toolCall)
            XCTAssertTrue(outputs.compactMap(\.rejectedToolCall).isEmpty)
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls.first?.function.name, "write_file")
            XCTAssertEqual(calls.first?.function.arguments["content"], .string("print(50)"))
            XCTAssertEqual(
              calls.first?.function.arguments["path"], .string("/app/src/limiter/window.py"))
            XCTAssertEqual(
              outputs.compactMap(\.reasoning).joined().trimmingCharacters(
                in: .whitespacesAndNewlines),
              body)
            XCTAssertTrue(
              outputs.compactMap(\.chunk).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
      }
    }
  }

  func testNaturalAndImplicitClosesRemainUnforced() throws {
    try Device.withDefaultDevice(.cpu) {
      try Stream.withNewDefaultStream(device: .cpu) {
        let tokenizer = BudgetCloseTestTokenizer()
        for body in ["plan\n</think>", "plan</think>", "plan<tool_call>"] {
          let state = MLXThinkingBudgetEnforcementState()
          var processor = try MLXBudgetCloseTestSupport.processor(
            maximumTokenCount: 128, tokenizer: tokenizer, enforcementState: state)
          let expected = tokenizer.encode(text: body + "\n\nanswer")
          let generated = expected.map { MLXBudgetCloseTestSupport.sample($0, using: &processor) }
          XCTAssertEqual(generated, expected)
          XCTAssertNil(state.failure)
        }
      }
    }
  }

  func testEmittedReasoningTokensRejectReopenedBoundaries() throws {
    try Device.withDefaultDevice(.cpu) {
      try Stream.withNewDefaultStream(device: .cpu) {
        let tokenizer = BudgetCloseTestTokenizer()
        for text in ["</think></think><think>", "</think><think>", "<tool_call><think>"] {
          let state = MLXThinkingBudgetEnforcementState()
          var processor = try MLXBudgetCloseTestSupport.processor(
            maximumTokenCount: 128, tokenizer: tokenizer, enforcementState: state)
          for token in tokenizer.encode(text: text) { processor.didEmit(token: token) }
          XCTAssertEqual(state.failure, .reopenedReasoning)
        }
      }
    }
  }

  func testGuardUsesAcceptedTokensAndStartsInsideReasoningForCachedSuffix() throws {
    try Device.withDefaultDevice(.cpu) {
      try Stream.withNewDefaultStream(device: .cpu) {
        let tokenizer = BudgetCloseTestTokenizer()
        let state = MLXThinkingBudgetEnforcementState()
        var processor = try MLXBudgetCloseTestSupport.processor(
          maximumTokenCount: 128, tokenizer: tokenizer, enforcementState: state)
        processor.prompt(MLXArray(tokenizer.encode(text: "cached suffix")))
        let close = try XCTUnwrap(tokenizer.encode(text: "</think>").first)
        let open = try XCTUnwrap(tokenizer.encode(text: "<think>").first)
        processor.didSample(token: MLXArray(close))
        processor.didSample(token: MLXArray(open))
        XCTAssertNil(state.failure)
        processor.didEmit(token: close)
        XCTAssertNil(state.failure)
        processor.didEmit(token: close)
        XCTAssertNil(state.failure)
        processor.didEmit(token: open)
        XCTAssertEqual(state.failure, .reopenedReasoning)
      }
    }
  }

  func testSpelledMarkersInToolArgumentsRemainLiteral() throws {
    try Device.withDefaultDevice(.cpu) {
      try Stream.withNewDefaultStream(device: .cpu) {
        let tokenizer = BudgetCloseTestTokenizer()
        let state = MLXThinkingBudgetEnforcementState()
        var processor = try MLXBudgetCloseTestSupport.processor(
          maximumTokenCount: 128, tokenizer: tokenizer, enforcementState: state)
        let content = "<think></think><|im_start|>"
        let prefix = """
          plan<tool_call><function=write_file><parameter=content>
          """
        let suffix = """
          </parameter><parameter=path>/app/example.txt</parameter></function></tool_call>
          """
        let tokens =
          tokenizer.encode(text: prefix)
          + content.utf8.map { 1000 + Int($0) }
          + tokenizer.encode(text: suffix)
        for token in tokens { processor.didEmit(token: token) }
        let outputs = MLXBudgetCloseTestSupport.events(tokens: tokens, tokenizer: tokenizer)
        let calls = outputs.compactMap(\.toolCall)
        XCTAssertNil(state.failure)
        XCTAssertTrue(outputs.compactMap(\.rejectedToolCall).isEmpty)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.function.arguments["content"], .string(content))
        XCTAssertEqual(outputs.compactMap(\.reasoning).joined(), "plan")
        XCTAssertTrue(outputs.compactMap(\.chunk).joined().isEmpty)
      }
    }
  }

  func testIncompatibleReasoningTokensFailBeforeGeneration() {
    for fault in InvalidReasoningTokenizer.Fault.allCases {
      XCTAssertThrowsError(
        try MLXThinkingBudgetPlanner.makeComponents(
          maximumTokenCount: 128, minimumAnswerTokenCount: 1,
          reasoning: QwenReasoningProtocol.tagged,
          tokenizer: InvalidReasoningTokenizer(fault: fault),
          generateParameters: GenerateParameters(maxTokens: 1_024),
          enforcementState: MLXThinkingBudgetEnforcementState())
      ) { error in
        XCTAssertEqual(error as? MLXThinkingBudgetFailure, .incompatibleReasoningProtocol)
      }
    }
  }

  func testGenerationLoopPreservesLiteralCloseAndRejectsReopenedReasoning() async throws {
    for reopensReasoning in [false, true] {
      let state = MLXThinkingBudgetEnforcementState()
      let tokenizer = BudgetCloseTestTokenizer()
      let text =
        "plan</think>" + (reopensReasoning ? "<think>again</think>" : "") + """
          <tool_call><function=write_file><parameter=content>literal </think> example</parameter>
          <parameter=path>/app/example.txt</parameter></function></tool_call>
          """
      let (upstream, task) = try Stream.withNewDefaultStream(device: .cpu) {
        let processor = try MLXBudgetCloseTestSupport.processor(
          maximumTokenCount: 128, tokenizer: tokenizer, enforcementState: state)
        return generateTask(
          promptTokenCount: 1,
          modelConfiguration: .init(
            id: "budget-guard-fixture", eosTokenIds: [9_999], toolCallFormat: .qwen35,
            reasoningConfig: QwenReasoningProtocol.tagged),
          tokenizer: tokenizer,
          iterator: BudgetGuardTokenIterator(
            tokens: tokenizer.encode(text: text) + [9_999], processor: processor),
          tools: [["function": ["name": "write_file"] as [String: any Sendable]]],
          reasoningPrimedInside: true)
      }
      let generation = MLXGuardedGeneration(
        makeStream: {
          AsyncThrowingStream { continuation in
            let forwarding = Task {
              for await event in upstream { continuation.yield(event) }
              continuation.finish()
            }
            continuation.onTermination = { termination in
              if case .cancelled = termination {
                task.cancel()
                forwarding.cancel()
              }
            }
          }
        },
        synchronize: { await task.value })
      let invalidation = Mutex<MLXSessionInvalidationReason?>(nil)
      let plan = MLXModelStreamProcessor.modelStreamPlan(
        from: generation, traceID: UUID(), traceMetadata: nil,
        cacheTrace: MLXSessionCacheTrace(
          cacheMode: .newSession, cacheReason: .newSessionNoCache,
          contextSignature: "budget-guard-fixture", previousContextSignature: nil,
          appendOnly: false, reusedMessageCount: 0, appendedMessageCount: 0,
          mismatchReason: nil, firstMismatchIndex: nil, systemPromptChanged: nil),
        debugTraceStore: MLXDebugTraceStore(isEnabled: { false }),
        thinkingBudgetEnforcementState: state,
        markCompleted: { _ in },
        markCancelled: { reason in invalidation.withLock { $0 = reason } },
        memoryCacheClearer: MLXMemoryCacheClearer { _ in })
      var deliveredTools = 0
      var failure: MLXThinkingBudgetFailure?
      do {
        for try await event in plan.stream {
          if case .toolCall(let call) = event {
            deliveredTools += 1
            XCTAssertEqual(call.arguments["content"], .string("literal </think> example"))
          }
        }
      } catch let error as MLXThinkingBudgetFailure {
        failure = error
      }
      await plan.task.value
      if reopensReasoning {
        XCTAssertEqual(failure, .reopenedReasoning)
        XCTAssertEqual(deliveredTools, 0)
        XCTAssertEqual(invalidation.withLock { $0 }, .runtimeError)
      } else {
        XCTAssertNil(failure)
        XCTAssertNil(state.failure)
        XCTAssertEqual(deliveredTools, 1)
        XCTAssertNil(invalidation.withLock { $0 })
      }
    }
  }
}

nonisolated enum MLXBudgetCloseTestSupport {
  static func processor(
    maximumTokenCount: Int, tokenizer: any Tokenizer,
    enforcementState: MLXThinkingBudgetEnforcementState = .init()
  ) throws -> any LogitProcessor {
    let parameters = GenerateParameters(maxTokens: 32_768)
    let components = try MLXThinkingBudgetPlanner.makeComponents(
      maximumTokenCount: maximumTokenCount, minimumAnswerTokenCount: 1,
      reasoning: QwenReasoningProtocol.tagged, tokenizer: tokenizer,
      generateParameters: parameters, enforcementState: enforcementState)
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

  static func events(tokens: [Int], tokenizer: any Tokenizer) -> [Generation] {
    var handler = TextToolTokenLoopHandler(
      tokenizer: tokenizer, format: .qwen35,
      tools: [["function": ["name": "write_file"] as [String: any Sendable]]],
      reasoning: (config: QwenReasoningProtocol.tagged, primedInside: true))
    var outputs: [Generation] = []
    for token in tokens {
      _ = handler.onToken(token, logProbabilities: nil) {
        outputs.append($0)
        return true
      }
    }
    _ = handler.onGenerationEnd {
      outputs.append($0)
      return true
    }
    return outputs
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

nonisolated private struct InvalidReasoningTokenizer: Tokenizer {
  enum Fault: CaseIterable { case missing, multipleTokens, aliased, unknown }

  let fault: Fault
  private let base = BudgetCloseTestTokenizer()

  func encode(text: String, addSpecialTokens: Bool) -> [Int] {
    guard text == "<think>" else {
      return base.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    switch fault {
    case .missing: return []
    case .multipleTokens: return text.utf8.map { 1000 + Int($0) }
    case .aliased: return [2]
    case .unknown: return [1]
    }
  }

  func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
    base.decode(tokenIds: tokenIds, skipSpecialTokens: skipSpecialTokens)
  }

  func convertTokenToId(_ token: String) -> Int? {
    if token == "<unknown>" { return 1 }
    return nil
  }

  func convertIdToToken(_ id: Int) -> String? { nil }
  var bosToken: String? { nil }
  var eosToken: String? { nil }
  var unknownToken: String? { fault == .unknown ? "<unknown>" : nil }

  func applyChatTemplate(
    messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
    additionalContext: [String: any Sendable]?
  ) throws -> [Int] { [] }
}

nonisolated private struct BudgetGuardTokenIterator: TokenIteratorProtocol {
  let tokens: [Int]
  var processor: any LogitProcessor
  var tokenCount = 0
  var maxTokens: Int? { tokens.count }
  var reasoningTokenCount: Int? { 0 }
  let promptPrefillTime: TimeInterval = 0

  mutating func next() -> Int? {
    guard tokenCount < tokens.count else { return nil }
    defer { tokenCount += 1 }
    return tokens[tokenCount]
  }

  mutating func recordEmittedToken(_ token: Int) {
    processor.didEmit(token: token)
  }
}
