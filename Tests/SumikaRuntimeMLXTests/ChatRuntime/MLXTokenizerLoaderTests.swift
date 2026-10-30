import Foundation
import MLX
import MLXLMCommon
import SumikaTestSupport
import Testing
import Tokenizers
import XCTest

@testable import SumikaRuntimeMLX

@Suite
struct MLXTokenizerLoaderTests {
  @Test(arguments: TokenizerFixture.allCases)
  func productionLoaderPreservesTokenizerBehavior(fixture: TokenizerFixture) async throws {
    let (tokenizer, upstream) = try await fixture.load()
    for special in [false, true] {
      let ids = upstream.encode(text: "hello <think> world", addSpecialTokens: special)
      #expect(tokenizer.encode(text: "hello <think> world", addSpecialTokens: special) == ids)
      #expect(
        tokenizer.decode(tokenIds: ids, skipSpecialTokens: special)
          == upstream.decode(tokens: ids, skipSpecialTokens: special))
    }
    #expect(tokenizer.bosToken == upstream.bosToken)
    #expect(tokenizer.eosToken == upstream.eosToken)
    #expect(tokenizer.unknownToken == upstream.unknownToken)
    for token in ["<bos>", "<eos>", "<unk>", "<think>", "missing"] {
      #expect(tokenizer.convertTokenToId(token) == upstream.convertTokenToId(token))
    }
    for id in [-1, 0, 65, 256, Int.max] {
      #expect(tokenizer.convertIdToToken(id) == upstream.convertIdToToken(id))
    }
    let messages: [[String: any Sendable]] = [["role": "user", "content": "hello"]]
    let tools: [[String: any Sendable]] = [["function": ["name": "inspect"]]]
    let context: [String: any Sendable] = ["suffix": "extra"]
    #expect(
      try tokenizer.applyChatTemplate(messages: messages, tools: tools, additionalContext: context)
        == upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: context))
    #expect(
      try tokenizer.applyChatTemplate(messages: messages)
        == upstream.applyChatTemplate(messages: messages))
  }

  @Test
  func missingTemplateMapsToMLXError() async throws {
    let (tokenizer, _) = try await TokenizerFixture.byteLevel.load(template: nil)
    #expect(throws: MLXLMCommon.TokenizerError.missingChatTemplate) {
      try tokenizer.applyChatTemplate(messages: [["role": "user", "content": "hello"]])
    }
  }

  @Test(arguments: TokenizerFixture.allCases)
  func streamingMatchesOrdinaryDecoding(fixture: TokenizerFixture) async throws {
    let (tokenizer, upstream) = try await fixture.load()
    #expect(upstream.makeStreamDecoder().isIncremental == (fixture != .buffered))
    for text in [
      "", "hello  world\n\n\t next ", "hello \u{e9} e\u{301} \u{fffd}",
      "\u{1f600}\u{1f469}\u{200d}\u{1f4bb}\u{1f1e9}\u{1f1ea}",
      "<think>plan</think><tool_call>{\"name\":\"inspect\"}</tool_call>",
    ] {
      let ids = tokenizer.encode(text: text, addSpecialTokens: false)
      let expected = tokenizer.decode(tokenIds: ids)
      var decoder = tokenizer.makeStreamingDetokenizer()
      var output = ""
      for id in ids {
        decoder.append(token: id)
        output += decoder.next() ?? ""
        #expect(expected.utf8.starts(with: output.utf8))
        #expect(decoder.next() == nil)
      }
      if fixture == .buffered { #expect(output.isEmpty) }
      output += decoder.finish() ?? ""
      #expect(output.utf8.elementsEqual(expected.utf8))
      #expect(decoder.finish() == nil)
      #expect(decoder.next() == nil)
    }
  }

  @Test
  func splitBytesUnreadOutputAndIndependentStreams() async throws {
    let (tokenizer, _) = try await TokenizerFixture.byteLevel.load()
    var first = tokenizer.makeStreamingDetokenizer()
    var second = tokenizer.makeStreamingDetokenizer()
    first.append(token: 0xC3)
    second.append(token: 65)
    #expect(first.next() == nil)
    #expect(second.next() == "A")
    first.append(token: 0xA9)
    #expect(first.next() == "\u{e9}")
    for byte in [0xF0, 0x9F, 0x98] {
      first.append(token: byte)
      #expect(first.next() == nil)
    }
    first.append(token: 0x80)
    first.append(token: 66)
    first.append(token: 0xC3)
    #expect(first.finish() == "\u{1f600}B\u{fffd}")
    #expect(first.finish() == nil)
    second.append(token: 67)
    #expect(second.finish() == "C")
    #expect(second.finish() == nil)
    var empty = tokenizer.makeStreamingDetokenizer()
    #expect(empty.finish() == nil)
  }

  @Test(arguments: TokenizerFixture.allCases)
  func finalFlushMatchesMalformedByteDecoding(fixture: TokenizerFixture) async throws {
    let (tokenizer, _) = try await fixture.load()
    for ids in [[0xC3], [65, 0xF0, 0x9F], [0xC3, 0xA9, 0xFF]] {
      var decoder = tokenizer.makeStreamingDetokenizer()
      for id in ids { decoder.append(token: id) }
      #expect(decoder.finish() == tokenizer.decode(tokenIds: ids))
      #expect(decoder.finish() == nil)
    }
  }

  @Test(arguments: [false, true], TokenizerFixture.allCases)
  func reasoningAndTypedToolCallsSurviveFinalFlush(
    gemma: Bool, fixture: TokenizerFixture
  ) async throws {
    let (tokenizer, _) = try await fixture.load()
    let reasoning = gemma ? "<|channel>thought\nplan<channel|>" : "<think>plan</think>"
    let call =
      gemma
      ? "<|tool_call>call:inspect{query:<|\"|>hello \u{e9} \u{1f600}<|\"|>,count:2,enabled:true,tags:[\"a\",\"b\"],config:{limit:3},nothing:null}<tool_call|>"
      : "<tool_call><function=inspect><parameter=query>hello \u{e9} \u{1f600}</parameter><parameter=count>2</parameter><parameter=enabled>true</parameter><parameter=tags>[\"a\",\"b\"]</parameter><parameter=config>{\"limit\":3}</parameter><parameter=nothing>null</parameter></function></tool_call>"
    var handler = TextToolTokenLoopHandler(
      tokenizer: tokenizer, format: gemma ? .gemma4 : .qwen35, tools: Self.tools,
      reasoning: (config: gemma ? .gemma4 : QwenReasoningProtocol.tagged, primedInside: false))
    var events: [Generation] = []
    for id in tokenizer.encode(text: reasoning + call + "done", addSpecialTokens: false) {
      _ = handler.onToken(id, logProbabilities: nil) {
        events.append($0)
        return true
      }
    }
    _ = handler.onGenerationEnd {
      events.append($0)
      return true
    }
    let calls = events.compactMap(\.toolCall)
    #expect(calls.count == 1)
    #expect(calls.first?.function.name == "inspect")
    #expect(
      calls.first?.function.arguments == [
        "query": .string("hello \u{e9} \u{1f600}"), "count": .int(2), "enabled": .bool(true),
        "tags": .array([.string("a"), .string("b")]), "config": .object(["limit": .int(3)]),
        "nothing": .null,
      ])
    #expect(events.compactMap(\.rejectedToolCall).isEmpty)
    #expect(events.compactMap(\.reasoning).joined() == "plan")
    #expect(events.compactMap(\.chunk).joined() == "done")
  }

  private static var tools: [[String: any Sendable]] {
    let properties: [String: any Sendable] = [
      "query": ["type": "string"], "count": ["type": "integer"],
      "enabled": ["type": "boolean"], "tags": ["type": "array"],
      "config": ["type": "object"], "nothing": ["type": "null"],
    ]
    let parameters: [String: any Sendable] = ["type": "object", "properties": properties]
    let function: [String: any Sendable] = ["name": "inspect", "parameters": parameters]
    return [["type": "function", "function": function]]
  }
}

nonisolated final class MLXTokenizerGenerationTests: XCTestCase {
  override func setUpWithError() throws {
    let library = Bundle(for: Self.self).resourceURL?
      .appending(path: "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
    guard let library, FileManager.default.fileExists(atPath: library.path) else {
      throw XCTSkip("MLX default.metallib is unavailable in the test bundle.")
    }
    GPU.metallib = library
  }

  func testOutputLimitFlushesOnceAndNextGenerationStartsFresh() async throws {
    let (tokenizer, _) = try await TokenizerFixture.byteLevel.load()
    for ids in [[65, 0xC3], [66, 0xF0, 0x9F, 0x98, 0x80]] {
      let (stream, task) = Stream.withNewDefaultStream(device: .cpu) {
        generateTask(
          promptTokenCount: 1, modelConfiguration: .init(id: "fixture"), tokenizer: tokenizer,
          iterator: FixtureTokenIterator(tokens: ids, maxTokens: ids.count))
      }
      var output = ""
      var completion: GenerateCompletionInfo?
      for await event in stream {
        if let chunk = event.chunk {
          XCTAssertNil(completion)
          output += chunk
        }
        if let info = event.info { completion = info }
      }
      await task.value
      XCTAssertEqual(output, tokenizer.decode(tokenIds: ids))
      XCTAssertEqual(completion?.stopReason, .length)
    }
  }

  func testCancellationFlushesConsumedTokensWithoutLeakingIntoAnotherStream() async throws {
    let (tokenizer, _) = try await TokenizerFixture.byteLevel.load()
    let ids = [65, 0xC3, 0xA9]
    let (stream, task) = Stream.withNewDefaultStream(device: .cpu) {
      generateTask(
        promptTokenCount: 1, modelConfiguration: .init(id: "fixture"), tokenizer: tokenizer,
        iterator: FixtureTokenIterator(tokens: ids, maxTokens: 100_000))
    }
    var output = ""
    var completion: GenerateCompletionInfo?
    for await event in stream {
      if let chunk = event.chunk {
        output += chunk
        task.cancel()
      }
      if let info = event.info { completion = info }
    }
    await task.value
    let count = try XCTUnwrap(completion?.generationTokenCount)
    XCTAssertEqual(completion?.stopReason, .cancelled)
    XCTAssertEqual(output, tokenizer.decode(tokenIds: (0..<count).map { ids[$0 % ids.count] }))
    var fresh = tokenizer.makeStreamingDetokenizer()
    fresh.append(token: 66)
    XCTAssertEqual(fresh.finish(), "B")
    XCTAssertNil(fresh.finish())
  }

}

nonisolated enum TokenizerFixture: CaseIterable {
  case byteLevel, sentencePiece, buffered

  func load(
    template: String? =
      "{{ messages[0]['content'] }}{% if tools %}{{ tools[0]['function']['name'] }}{% endif %}{{ suffix | default('') }}"
  ) async throws -> (any MLXLMCommon.Tokenizer, any Tokenizers.Tokenizer) {
    try await withTemporaryDirectory(named: "sumika-tokenizer") { directory in
      let direct = Set(Array(33...126) + Array(161...172) + Array(174...255))
      var extra = 256
      let alphabet = try (0...255).map { byte in
        let scalar = direct.contains(byte) ? byte : extra
        if !direct.contains(byte) { extra += 1 }
        return String(try #require(UnicodeScalar(scalar)))
      }
      let markers = [
        "<bos>", "<eos>", "<unk>", "<think>", "</think>", "<tool_call>", "</tool_call>",
        "<|channel>", "<channel|>", "<|tool_call>", "<tool_call|>", "<|\"|>",
      ]
      let pieces =
        self == .sentencePiece
        ? (0...255).map { String(format: "<0x%02X>", $0) }
          + (32...126).compactMap { UnicodeScalar($0).map(String.init) } + ["\u{2581}"]
        : alphabet
      let vocab = Dictionary(uniqueKeysWithValues: (pieces + markers).enumerated().map { ($1, $0) })
      let decoder: [String: Any] =
        switch self {
        case .byteLevel: ["type": "ByteLevel"]
        case .sentencePiece:
          [
            "type": "Sequence",
            "decoders": [
              ["type": "Replace", "pattern": ["String": "\u{2581}"], "content": " "],
              ["type": "ByteFallback"], ["type": "Fuse"],
            ],
          ]
        case .buffered:
          [
            "type": "Sequence",
            "decoders": [
              ["type": "ByteLevel"],
              ["type": "Replace", "pattern": ["String": "@@@"], "content": "!"],
            ],
          ]
        }
      let model: [String: Any] = [
        "type": "BPE", "vocab": vocab, "merges": [], "byte_fallback": true,
      ]
      let preTokenizer: [String: Any] =
        self == .sentencePiece
        ? ["type": "Metaspace", "replacement": "\u{2581}", "prepend_scheme": "never"]
        : ["type": "ByteLevel", "add_prefix_space": false, "use_regex": false]
      let addedTokens: [[String: Any]] = try markers.map {
        ["id": try #require(vocab[$0]), "content": $0, "special": true]
      }
      let single: [[String: Any]] = [
        ["SpecialToken": ["id": "<bos>", "type_id": 0]],
        ["Sequence": ["id": "A", "type_id": 0]],
      ]
      let specialTokens: [String: Any] = [
        "<bos>": [
          "id": "<bos>", "ids": [try #require(vocab["<bos>"])], "tokens": ["<bos>"],
        ]
      ]
      let data: [String: Any] = [
        "model": model, "pre_tokenizer": preTokenizer, "decoder": decoder,
        "added_tokens": addedTokens,
        "post_processor": [
          "type": "TemplateProcessing", "single": single,
          "pair": single + [["Sequence": ["id": "B", "type_id": 1]]],
          "special_tokens": specialTokens,
        ],
      ]
      try JSONSerialization.data(withJSONObject: data).write(
        to: directory.appending(path: "tokenizer.json"))
      try JSONSerialization.data(withJSONObject: [
        "bos_token": "<bos>", "eos_token": "<eos>", "unk_token": "<unk>",
        "clean_up_tokenization_spaces": true,
      ]).write(to: directory.appending(path: "tokenizer_config.json"))
      if let template {
        try Data(template.utf8).write(to: directory.appending(path: "chat_template.jinja"))
      }
      let bridge = try await makeHuggingFaceTokenizerLoader().load(from: directory)
      let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
      return (bridge, upstream)
    }
  }
}

nonisolated private struct FixtureTokenIterator: TokenIteratorProtocol {
  let tokens: [Int]
  let maxTokens: Int?
  var tokenCount = 0
  let promptPrefillTime: TimeInterval = 0

  mutating func next() -> Int? {
    if let maxTokens, tokenCount >= maxTokens { return nil }
    defer { tokenCount += 1 }
    return tokens[tokenCount % tokens.count]
  }
}
