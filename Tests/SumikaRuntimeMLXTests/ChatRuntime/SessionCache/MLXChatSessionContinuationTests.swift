import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXVLM
import XCTest

@testable import SumikaCore
@testable import SumikaRuntimeMLX

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
    let reasoning: String
    let toolCalls: [MLXLMCommon.ToolCall]
    let info: GenerateCompletionInfo
  }

  private struct RecordingMessageGenerator: MessageGenerator {
    let log: ContinuationMessageLog
    let base: any MessageGenerator

    func generate(messages: [Chat.Message]) -> [Message] {
      log.record(messages)
      return base.generate(messages: messages)
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

  private struct ScriptedLogitProcessor: LogitProcessor {
    let tokens: [Int]
    private var index = 0

    init(tokens: [Int]) { self.tokens = tokens }
    mutating func prompt(_: MLXArray) { index = 0 }
    mutating func didSample(token _: MLXArray) { index += 1 }
    func process(logits: MLXArray) -> MLXArray {
      var forced = [Float](repeating: -.infinity, count: logits.dim(-1))
      forced[index < tokens.count ? tokens[index] : 256] = 0
      return MLXArray(forced).reshaped(logits.shape)
    }
  }

  // shortcut: ASCII Qwen fixtures only; installed-tokenizer tests cover actual templates.
  private struct ReasoningTokenizer: Tokenizer {
    let renderedTokensContinuation: AsyncStream<[Int]>.Continuation
    var bosToken: String? { nil }
    var eosToken: String? { "<|im_end|>" }
    var unknownToken: String? { nil }

    func encode(text: String, addSpecialTokens _: Bool) -> [Int] {
      text.components(separatedBy: "<|im_end|>").enumerated().flatMap { index, part in
        (index == 0 ? [] : [256]) + part.utf8.map(Int.init)
      }
    }

    func decode(tokenIds: [Int], skipSpecialTokens _: Bool) -> String {
      tokenIds.map { $0 == 256 ? "<|im_end|>" : UnicodeScalar($0).map(String.init) ?? "" }.joined()
    }

    func convertTokenToId(_ token: String) -> Int? { token == eosToken ? 256 : nil }
    func convertIdToToken(_ id: Int) -> String? { decode(tokenIds: [id]) }

    func applyChatTemplate(
      messages: [[String: any Sendable]],
      tools _: [[String: any Sendable]]?,
      additionalContext _: [String: any Sendable]?
    ) throws -> [Int] {
      var rendered = ""
      for message in messages {
        let role = message["role"] as? String ?? ""
        var content =
          message["content"] as? String
          ?? (message["content"] as? [[String: String]])?.compactMap { $0["text"] }.joined()
          ?? ""
        var reasoning = message["reasoning_content"] as? String
        if role == "assistant", reasoning == nil, content.hasPrefix("<think>"),
          let close = content.range(of: "</think>")
        {
          reasoning = String(
            content[content.index(content.startIndex, offsetBy: 7)..<close.lowerBound])
          content = String(content[close.upperBound...])
        }
        rendered += role + "\n"
        if let reasoning {
          rendered +=
            "<think>\n" + reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n</think>\n\n"
        }
        rendered += content.trimmingCharacters(in: .whitespacesAndNewlines)
        for call in message["tool_calls"] as? [[String: any Sendable]] ?? [] {
          let function = call["function"] as? [String: any Sendable] ?? [:]
          let arguments = function["arguments"] as? [String: any Sendable] ?? [:]
          rendered += "<tool_call><function=\(function["name"] as? String ?? "")>"
          for name in arguments.keys.sorted() {
            rendered += "<parameter=\(name)>\(arguments[name] as? String ?? "")</parameter>"
          }
          rendered += "</function></tool_call>"
        }
        rendered += "<|im_end|>\n"
      }
      rendered += "assistant\n<think>\n"
      let tokens = encode(text: rendered)
      renderedTokensContinuation.yield(tokens)
      return tokens
    }
  }

  private struct PrefixPreservingTokenizer: Tokenizer {
    let renderedTokensContinuation: AsyncStream<[Int]>.Continuation

    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }

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

  func testQwenReasoningContinuationsMatchCanonicalHistoryRebuilds() async throws {
    for generator in [DefaultMessageGenerator(), Qwen3VLMessageGenerator()]
      as [any MessageGenerator]
    {
      for usesTool in [false, true] {
        try await Self.verifyReasoningContinuation(generator: generator, usesTool: usesTool)
      }
    }
  }

  private static func verifyReasoningContinuation(
    generator: any MessageGenerator, usesTool: Bool
  ) async throws {
    try await Device.withDefaultDevice(.cpu) {
      try await Stream.withNewDefaultStream(device: .cpu) {
        let (renderedTokens, continuation) = AsyncStream<[Int]>.makeStream()
        var renderedIterator = renderedTokens.makeAsyncIterator()
        let tokenizer = ReasoningTokenizer(renderedTokensContinuation: continuation)
        let messageLog = ContinuationMessageLog()
        let context = makeContext(
          tokenizer: tokenizer, messageLog: messageLog,
          vocabularySize: 257,
          configuration: ModelConfiguration(
            id: "qwen-reasoning", eosTokenIds: [256], toolCallFormat: .qwen35,
            reasoningConfig: QwenReasoningProtocol.tagged),
          messageGenerator: generator)
        let firstAnswer =
          usesTool
          ? "<tool_call><function=get_weather><parameter=city>Paris</parameter></function></tool_call>"
          : "The result is 42."
        let firstTokens = tokenizer.encode(text: "plan\n</think>\n\n" + firstAnswer) + [256]
        let secondTokens = tokenizer.encode(text: "check\n</think>\n\nDone.") + [256]
        let parameters = GenerateParameters(maxTokens: 512, temperature: 0)
        let additionalContext: [String: any Sendable] = [
          "enable_thinking": true, "preserve_thinking": true,
        ]
        let warmSession = MLXLMCommon.ChatSession(
          context, generateParameters: parameters,
          components: GenerationComponents(logitProcessorFactory: {
            ScriptedLogitProcessor(tokens: firstTokens)
          }),
          additionalContext: additionalContext, tools: [weatherTool])
        let firstPasses = try await collectPasses(
          warmSession.streamDetails(to: [.user("Solve it")]))
        let first = try XCTUnwrap(firstPasses.last)
        let nextFirstPrompt = await renderedIterator.next()
        let firstPrompt = try XCTUnwrap(nextFirstPrompt)
        XCTAssertEqual(first.reasoning, "plan")
        XCTAssertEqual(first.text, usesTool ? "" : firstAnswer)
        XCTAssertEqual(first.toolCalls.count, usesTool ? 1 : 0)
        let call = first.toolCalls.first
        if usesTool {
          XCTAssertEqual(call?.function.name, "get_weather")
          XCTAssertEqual(call?.function.arguments, ["city": .string("Paris")])
          XCTAssertNotNil(call?.id)
        }
        let followUp: Chat.Message =
          usesTool
          ? .tool("sunny", id: call?.id) : .user("Explain it")
        let providerCalls = try first.toolCalls.map { call in
          ProviderToolCall(
            id: try XCTUnwrap(call.id), name: call.function.name,
            arguments: ["city": .string("Paris")])
        }
        let snapshot = ProviderPromptMessage(
          role: "assistant", content: first.text, reasoningContent: first.reasoning,
          toolCalls: providerCalls)
        let reconstructed = MLXHistoryRenderer.chatMessages(
          from: [snapshot], supportsHistoricalReasoningPreservation: true)
        warmSession.components = GenerationComponents(logitProcessorFactory: {
          ScriptedLogitProcessor(tokens: secondTokens)
        })
        let warmPasses = try await collectPasses(warmSession.streamDetails(to: [followUp]))
        let nextWarmRendered = await renderedIterator.next()
        let warmRendered = try XCTUnwrap(nextWarmRendered)
        let coldSession = MLXLMCommon.ChatSession(
          context, history: [.user("Solve it")] + reconstructed,
          generateParameters: parameters,
          components: GenerationComponents(logitProcessorFactory: {
            ScriptedLogitProcessor(tokens: secondTokens)
          }),
          additionalContext: additionalContext, tools: [weatherTool])
        let coldPasses = try await collectPasses(coldSession.streamDetails(to: [followUp]))
        let nextColdRendered = await renderedIterator.next()
        let coldRendered = try XCTUnwrap(nextColdRendered)
        let warm = try XCTUnwrap(warmPasses.last)
        let cold = try XCTUnwrap(coldPasses.last)
        XCTAssertEqual(warmRendered, coldRendered)
        XCTAssertTrue(warmRendered.starts(with: firstPrompt + firstTokens))
        XCTAssertEqual(warm.text, "Done.")
        XCTAssertEqual(warm.text, cold.text)
        XCTAssertEqual(warm.reasoning, cold.reasoning)
        XCTAssertEqual(
          tokenizer.decode(tokenIds: warmRendered).components(separatedBy: "plan").count, 2)
        XCTAssertGreaterThan(warm.info.cachedPromptTokenCount, 0)
        XCTAssertLessThan(warm.info.promptTokenCount, cold.info.promptTokenCount)
        XCTAssertEqual(cold.info.cachedPromptTokenCount, 0)
        XCTAssertEqual(warm.info.totalPromptTokenCount, cold.info.totalPromptTokenCount)
        if usesTool {
          for messages in messageLog.all.suffix(2) {
            let rawMessages = generator.generate(messages: messages)
            let rawCalls = rawMessages[1]["tool_calls"] as? [[String: any Sendable]]
            XCTAssertEqual(rawCalls?.first?["id"] as? String, call?.id)
            XCTAssertEqual(rawMessages[2]["tool_call_id"] as? String, call?.id)
          }
        }
      }
    }
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
        let warmSession = MLXLMCommon.ChatSession(
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

        let coldSession = MLXLMCommon.ChatSession(
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
        let warmSession = MLXLMCommon.ChatSession(
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

        let coldSession = MLXLMCommon.ChatSession(
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
    messageLog: ContinuationMessageLog,
    vocabularySize: Int = 100,
    configuration: ModelConfiguration = ModelConfiguration(id: "test", toolCallFormat: .json),
    messageGenerator: any MessageGenerator = DefaultMessageGenerator()
  ) -> ModelContext {
    let modelConfiguration = Gemma3TextConfiguration(
      modelType: "text",
      hiddenSize: 64,
      hiddenLayers: 8,
      intermediateSize: 64,
      attentionHeads: 4,
      headDim: 64,
      rmsNormEps: 0.00001,
      vocabularySize: vocabularySize,
      kvHeads: 4,
      ropeTheta: 1_000_000,
      ropeLocalBaseFreq: 10_000,
      ropeTraditional: false,
      queryPreAttnScalar: 256,
      slidingWindow: 512,
      slidingWindowPattern: 6,
      maxPositionEmbeddings: 32_768
    )
    let model = Gemma3TextModel(modelConfiguration)
    quantize(model: model, groupSize: 64, bits: 4)
    eval(model)
    let processor = TestInputProcessor(
      tokenizer: tokenizer,
      messageGenerator: RecordingMessageGenerator(log: messageLog, base: messageGenerator)
    )
    return ModelContext(
      configuration: configuration,
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
    var reasoning = ""
    var toolCalls: [MLXLMCommon.ToolCall] = []
    for try await generation in stream {
      if let chunk = generation.chunk {
        text += chunk
      }
      if let chunk = generation.reasoning {
        reasoning += chunk
      }
      if let call = generation.toolCall {
        toolCalls.append(call)
      }
      if let rejection = generation.rejectedToolCall {
        XCTFail("Unexpected rejected call: \(rejection)")
      }
      if let info = generation.info {
        passes.append(
          GeneratedPass(text: text, reasoning: reasoning, toolCalls: toolCalls, info: info))
        text = ""
        reasoning = ""
        toolCalls = []
      }
    }
    return passes
  }
}
