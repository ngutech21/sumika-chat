import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import XCTest

nonisolated private final class ContinuationMessageLog: @unchecked Sendable {
  private let lock = NSLock()
  private var passes: [[Chat.Message]] = []

  func record(_ messages: [Chat.Message]) {
    lock.lock()
    passes.append(messages)
    lock.unlock()
  }

  var all: [[Chat.Message]] {
    lock.lock()
    defer { lock.unlock() }
    return passes
  }
}

nonisolated final class MLXChatSessionContinuationTests: XCTestCase {
  private struct GeneratedPass {
    let text: String
    let info: GenerateCompletionInfo
  }

  private struct RecordingMessageGenerator: MessageGenerator {
    let log: ContinuationMessageLog

    func generate(messages: [Chat.Message]) -> [Message] {
      log.record(messages)
      return DefaultMessageGenerator().generate(messages: messages)
    }
  }

  private struct TestInputProcessor: UserInputProcessor {
    let tokenizer: any Tokenizer
    let messageGenerator: any MessageGenerator

    func prepare(input: UserInput) throws -> LMInput {
      let messages = messageGenerator.generate(from: input)
      let tokens = try tokenizer.applyChatTemplate(
        messages: messages,
        tools: input.tools,
        additionalContext: input.additionalContext
      )
      return LMInput(tokens: MLXArray(tokens))
    }
  }

  private struct PrefixPreservingTokenizer: Tokenizer {
    let renderedTokensContinuation: AsyncStream<[Int]>.Continuation

    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    var eosTokenId: Int? { 101 }
    var unknownTokenId: Int? { 102 }

    func encode(text: String, addSpecialTokens _: Bool) -> [Int] {
      text.unicodeScalars.map { scalar in
        if (0xE000..<0xE064).contains(Int(scalar.value)) {
          return Int(scalar.value) - 0xE000
        }
        return Int(scalar.value) % 80 + 1
      }
    }

    func decode(tokenIds: [Int], skipSpecialTokens _: Bool) -> String {
      String(
        String.UnicodeScalarView(
          tokenIds.compactMap { UnicodeScalar(0xE000 + $0) }
        )
      )
    }

    func convertTokenToId(_: String) -> Int? { nil }

    func convertIdToToken(_ id: Int) -> String? {
      UnicodeScalar(0xE000 + id).map(String.init)
    }

    func applyChatTemplate(
      messages: [[String: any Sendable]],
      tools _: [[String: any Sendable]]?,
      additionalContext _: [String: any Sendable]?
    ) throws -> [Int] {
      var tokens: [Int] = []
      for message in messages {
        let role = message["role"] as? String
        let content = message["content"] as? String ?? ""
        switch role {
        case "system":
          tokens.append(96)
        case "user":
          tokens.append(97)
        case "tool":
          tokens.append(98)
        case "assistant":
          tokens.append(94)
        default:
          tokens.append(99)
        }
        tokens.append(contentsOf: encode(text: content, addSpecialTokens: false))
        if role != "assistant" {
          tokens.append(95)
        }
      }
      tokens.append(94)
      renderedTokensContinuation.yield(tokens)
      return tokens
    }
  }

  private final class ToolRoundTripTokenizer: Tokenizer, @unchecked Sendable {
    private let renderedTokensContinuation: AsyncStream<[Int]>.Continuation
    private let toolCallScript =
      #"<tool_call>{"name":"get_weather","arguments":{"city":"Paris"}}</tool_call>"#
    private let finalScript = "It is sunny in Paris."
    private var templatePass = 0
    private var firstPromptTokens: [Int] = []
    private var firstGeneratedTokens: [Int] = []

    init(renderedTokensContinuation: AsyncStream<[Int]>.Continuation) {
      self.renderedTokensContinuation = renderedTokensContinuation
    }

    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    var eosTokenId: Int? { 101 }
    var unknownTokenId: Int? { 102 }

    func encode(text: String, addSpecialTokens _: Bool) -> [Int] {
      text.unicodeScalars.map { Int($0.value) % 80 + 1 }
    }

    func decode(tokenIds: [Int], skipSpecialTokens _: Bool) -> String {
      if templatePass == 1, tokenIds.count > firstGeneratedTokens.count {
        firstGeneratedTokens = tokenIds
      }
      let script = templatePass == 1 ? toolCallScript : finalScript
      return String(script.prefix(min(tokenIds.count * 4, script.count)))
    }

    func convertTokenToId(_: String) -> Int? { nil }
    func convertIdToToken(_: Int) -> String? { "x" }

    func applyChatTemplate(
      messages: [[String: any Sendable]],
      tools _: [[String: any Sendable]]?,
      additionalContext _: [String: any Sendable]?
    ) throws -> [Int] {
      templatePass += 1
      let tokens: [Int]
      if templatePass == 1 {
        tokens = renderInitialPrompt(messages)
        firstPromptTokens = tokens
      } else {
        let toolResult =
          messages.last { $0["role"] as? String == "tool" }?["content"] as? String ?? ""
        tokens =
          firstPromptTokens + firstGeneratedTokens + [98]
          + encode(text: toolResult, addSpecialTokens: false) + [95, 94]
      }
      renderedTokensContinuation.yield(tokens)
      return tokens
    }

    private func renderInitialPrompt(
      _ messages: [[String: any Sendable]]
    ) -> [Int] {
      var tokens: [Int] = []
      for message in messages {
        switch message["role"] as? String {
        case "system":
          tokens.append(96)
        case "user":
          tokens.append(97)
        default:
          tokens.append(99)
        }
        tokens.append(
          contentsOf: encode(
            text: message["content"] as? String ?? "",
            addSpecialTokens: false
          )
        )
        tokens.append(95)
      }
      tokens.append(94)
      return tokens
    }
  }

  private static let weatherTool: ToolSpec = [
    "type": "function",
    "function": [
      "name": "get_weather",
      "description": "Get the weather for a city.",
      "parameters": [
        "type": "object",
        "properties": [
          "city": ["type": "string"] as [String: any Sendable]
        ] as [String: any Sendable],
        "required": ["city"],
      ] as [String: any Sendable],
    ] as [String: any Sendable],
  ]

  override func setUpWithError() throws {
    try super.setUpWithError()
    guard Self.hasBundledMetalLibrary else {
      throw XCTSkip("MLX default.metallib is unavailable in the SwiftPM test bundle.")
    }
  }

  func testPlainContinuationMatchesColdFullConversationWithLessPrefill() async throws {
    try await Self.verifyPlainContinuation()
  }

  private static func verifyPlainContinuation() async throws {
    try await Device.withDefaultDevice(.cpu) {
      try await Stream.withNewDefaultStream(device: .cpu) {
        let (renderedTokens, continuation) = AsyncStream<[Int]>.makeStream()
        var renderedIterator = renderedTokens.makeAsyncIterator()
        let tokenizer = PrefixPreservingTokenizer(renderedTokensContinuation: continuation)
        let log = ContinuationMessageLog()
        let context = Self.makeContext(tokenizer: tokenizer, messageLog: log)
        let parameters = GenerateParameters(maxTokens: 3, temperature: 0)
        let additionalContext: [String: any Sendable] = ["enable_thinking": false]
        let warmSession = ChatSession(
          context,
          instructions: "Stable instructions.",
          generateParameters: parameters,
          additionalContext: additionalContext
        )

        let first = try await Self.collectPasses(
          warmSession.streamDetails(to: [.user("first question")])
        )
        _ = await renderedIterator.next()
        let firstOutput = try XCTUnwrap(first.last?.text)
        let warm = try await Self.collectPasses(
          warmSession.streamDetails(to: [.user("second question")])
        )
        let nextWarmRendered = await renderedIterator.next()
        let warmRendered = try XCTUnwrap(nextWarmRendered)

        let coldSession = ChatSession(
          context,
          instructions: "Stable instructions.",
          generateParameters: parameters,
          additionalContext: additionalContext
        )
        let cold = try await Self.collectPasses(
          coldSession.streamDetails(
            to: [
              .user("first question"),
              .assistant(firstOutput),
              .user("second question"),
            ]
          )
        )
        let nextColdRendered = await renderedIterator.next()
        let coldRendered = try XCTUnwrap(nextColdRendered)
        let warmResult = try XCTUnwrap(warm.last)
        let coldResult = try XCTUnwrap(cold.last)

        XCTAssertEqual(parameters.temperature, 0)
        XCTAssertEqual(warmRendered, coldRendered)
        XCTAssertEqual(warmResult.text, coldResult.text)
        XCTAssertLessThan(warmResult.info.promptTokenCount, coldResult.info.promptTokenCount)
        XCTAssertEqual(coldResult.info.cachedPromptTokenCount, 0)
        XCTAssertEqual(coldResult.info.totalPromptTokenCount, coldResult.info.promptTokenCount)
        XCTAssertGreaterThan(warmResult.info.cachedPromptTokenCount, 0)
        XCTAssertEqual(warmResult.info.totalPromptTokenCount, coldResult.info.totalPromptTokenCount)
        XCTAssertEqual(warmResult.info.totalPromptTokenCount, warmRendered.count)
        XCTAssertEqual(
          warmResult.info.totalPromptTokenCount,
          warmResult.info.cachedPromptTokenCount + warmResult.info.promptTokenCount
        )
      }
    }
  }

  func testToolResultContinuationMatchesColdFullConversationWithLessPrefill() async throws {
    try await Self.verifyToolResultContinuation()
  }

  private static func verifyToolResultContinuation() async throws {
    try await Device.withDefaultDevice(.cpu) {
      try await Stream.withNewDefaultStream(device: .cpu) {
        let (renderedTokens, continuation) = AsyncStream<[Int]>.makeStream()
        var renderedIterator = renderedTokens.makeAsyncIterator()
        let tokenizer = ToolRoundTripTokenizer(renderedTokensContinuation: continuation)
        let log = ContinuationMessageLog()
        let context = Self.makeContext(tokenizer: tokenizer, messageLog: log)
        let parameters = GenerateParameters(maxTokens: 32, temperature: 0)
        let additionalContext: [String: any Sendable] = ["enable_thinking": false]
        let warmSession = ChatSession(
          context,
          instructions: "Stable instructions.",
          generateParameters: parameters,
          additionalContext: additionalContext,
          tools: [Self.weatherTool],
          toolDispatch: { _ in #"{"forecast":"sunny"}"# }
        )

        let warmPasses = try await Self.collectPasses(
          warmSession.streamDetails(to: [.user("What is the weather in Paris?")])
        )
        _ = await renderedIterator.next()
        let nextWarmRendered = await renderedIterator.next()
        let warmRendered = try XCTUnwrap(nextWarmRendered)
        let fullConversation = try XCTUnwrap(log.all.last)
        let coldInput = Array(fullConversation.drop { $0.role == .system })
        let warmResult = try XCTUnwrap(warmPasses.last)

        let coldSession = ChatSession(
          context,
          instructions: "Stable instructions.",
          generateParameters: parameters,
          additionalContext: additionalContext,
          tools: [Self.weatherTool]
        )
        let coldPasses = try await Self.collectPasses(
          coldSession.streamDetails(to: coldInput)
        )
        let nextColdRendered = await renderedIterator.next()
        let coldRendered = try XCTUnwrap(nextColdRendered)
        let coldResult = try XCTUnwrap(coldPasses.last)

        XCTAssertEqual(parameters.temperature, 0)
        XCTAssertEqual(fullConversation.map(\.role), [.system, .user, .assistant, .tool])
        XCTAssertEqual(warmRendered, coldRendered)
        XCTAssertEqual(warmResult.text, coldResult.text)
        XCTAssertLessThan(warmResult.info.promptTokenCount, coldResult.info.promptTokenCount)
        XCTAssertEqual(coldResult.info.cachedPromptTokenCount, 0)
        XCTAssertEqual(coldResult.info.totalPromptTokenCount, coldResult.info.promptTokenCount)
        XCTAssertGreaterThan(warmResult.info.cachedPromptTokenCount, 0)
        XCTAssertEqual(warmResult.info.totalPromptTokenCount, coldResult.info.totalPromptTokenCount)
        XCTAssertEqual(warmResult.info.totalPromptTokenCount, warmRendered.count)
        XCTAssertEqual(
          warmResult.info.totalPromptTokenCount,
          warmResult.info.cachedPromptTokenCount + warmResult.info.promptTokenCount
        )
      }
    }
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

  private static func makeContext(
    tokenizer: any Tokenizer,
    messageLog: ContinuationMessageLog
  ) -> ModelContext {
    let configuration = Gemma3TextConfiguration(
      modelType: "text",
      hiddenSize: 64,
      hiddenLayers: 8,
      intermediateSize: 64,
      attentionHeads: 4,
      headDim: 64,
      rmsNormEps: 0.00001,
      vocabularySize: 100,
      kvHeads: 4,
      ropeTheta: 1_000_000,
      ropeLocalBaseFreq: 10_000,
      ropeTraditional: false,
      queryPreAttnScalar: 256,
      slidingWindow: 512,
      slidingWindowPattern: 6,
      maxPositionEmbeddings: 32_768
    )
    let model = Gemma3TextModel(configuration)
    quantize(model: model, groupSize: 64, bits: 4)
    eval(model)
    let processor = TestInputProcessor(
      tokenizer: tokenizer,
      messageGenerator: RecordingMessageGenerator(log: messageLog)
    )
    return ModelContext(
      configuration: ModelConfiguration(id: "test", toolCallFormat: .json),
      model: model,
      processor: processor,
      tokenizer: tokenizer
    )
  }

  private static func collectPasses(
    _ stream: AsyncThrowingStream<Generation, Error>
  ) async throws -> [GeneratedPass] {
    var passes: [GeneratedPass] = []
    var text = ""
    for try await generation in stream {
      if let chunk = generation.chunk {
        text += chunk
      }
      if let info = generation.info {
        passes.append(GeneratedPass(text: text, info: info))
        text = ""
      }
    }
    return passes
  }
}
