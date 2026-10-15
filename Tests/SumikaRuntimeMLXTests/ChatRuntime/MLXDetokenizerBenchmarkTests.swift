import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import XCTest

@testable import SumikaCore
@testable import SumikaRuntimeMLX

/// Opt-in comparisons use installed assets only and keep the baseline out of production.
nonisolated final class MLXDetokenizerBenchmarkTests: XCTestCase {
  func testInstalledTokenizerDecoderCPU() async throws {
    let models = try benchmarkModels()
    print("| Model | Payload | Tokens | Naive CPU ms | Incremental CPU ms |")
    print("| --- | --- | ---: | ---: | ---: |")
    for model in models {
      let tokenizer = try await makeHuggingFaceTokenizerLoader().load(from: model.localDirectoryURL)
      let payloads = [
        ("text", "A local assistant reads files carefully and explains its results. "),
        ("json", #"{"path":"src/main.swift","enabled":true,"count":42,"content":"hello world"},"#),
        (
          "tool",
          "<tool_call><function=write_file><parameter=content>hello \u{e9} \u{1f600} "
            + String(repeating: "let value = 42; ", count: 80)
            + "</parameter><parameter=path>main.swift</parameter></function></tool_call>"
        ),
      ]
      for (name, payload) in payloads {
        var text = payload
        var ids = tokenizer.encode(text: text, addSpecialTokens: false)
        while ids.count < 8_192 {
          text += text
          ids = tokenizer.encode(text: text, addSpecialTokens: false)
        }
        for count in [1_024, 4_096, 8_192] {
          let tokens = Array(ids.prefix(count))
          let expected = tokenizer.decode(tokenIds: tokens)
          var samples: [[Double]] = [[], []]
          for trial in 0...3 {
            for incremental in trial.isMultiple(of: 2) ? [false, true] : [true, false] {
              var decoder: any StreamingDetokenizer =
                incremental
                ? tokenizer.makeStreamingDetokenizer()
                : NaiveStreamingDetokenizer(tokenizer: tokenizer)
              let started = cpuTime()
              var output = ""
              for token in tokens {
                decoder.append(token: token)
                output += decoder.next() ?? ""
              }
              output += decoder.finish() ?? ""
              let milliseconds = (cpuTime() - started) * 1_000
              XCTAssertEqual(Array(output.utf8), Array(expected.utf8))
              XCTAssertNil(decoder.finish())
              if trial > 0 { samples[incremental ? 1 : 0].append(milliseconds) }
            }
          }
          print(
            "| \(model.id) | \(name) | \(count) | \(number(median(samples[0]))) | \(number(median(samples[1]))) |"
          )
        }
      }
    }
  }

  func testInstalledModelGenerationThroughput() async throws {
    let models = try benchmarkModels()
    let library = Bundle(for: Self.self).resourceURL?
      .appending(path: "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
    guard let library, FileManager.default.fileExists(atPath: library.path) else {
      throw XCTSkip("MLX default.metallib is unavailable in the test bundle.")
    }
    GPU.metallib = library
    print(
      "Greedy ChatSession; maxTokens=512; fresh conversation cache; one warmup + three paired trials; alternating order."
    )
    print("| Model | Decoder | Runs | Generated tokens | Decode tok/s | Request wall ms |")
    print("| --- | --- | ---: | ---: | ---: | ---: |")
    for model in models {
      let loader = makeHuggingFaceTokenizerLoader()
      let container =
        if let adapted = try await Swift15ModelLoader.loadIfSupported(
          from: model.localDirectoryURL, using: loader)
        {
          adapted
        } else if model.supportsImageInput {
          try await VLMModelFactory.shared.loadContainer(
            from: model.localDirectoryURL, using: loader)
        } else {
          try await LLMModelFactory.shared.loadContainer(
            from: model.localDirectoryURL, using: loader)
        }
      let tokenizer = await container.tokenizer
      var samples: [[GenerationSample]] = [[], []]
      for trial in 0...3 {
        var paired: [GenerationSample] = []
        for incremental in trial.isMultiple(of: 2) ? [false, true] : [true, false] {
          await container.update {
            $0.tokenizer = BenchmarkTokenizer(base: tokenizer, incremental: incremental)
          }
          let sample = try await generate(container: container)
          paired.append(sample)
          if trial > 0 { samples[incremental ? 1 : 0].append(sample) }
        }
        XCTAssertEqual(paired[0].output, paired[1].output)
        XCTAssertEqual(paired[0].tokens, paired[1].tokens)
      }
      for index in 0...1 {
        let values = samples[index]
        print(
          "| \(model.id) | \(index == 0 ? "naive" : "incremental") | \(values.count) | \(number(median(values.map { Double($0.tokens) }))) | \(number(median(values.map(\.tokensPerSecond)))) | \(number(median(values.map(\.wallMilliseconds)))) |"
        )
      }
    }
  }

  private func benchmarkModels() throws -> [ManagedModel] {
    guard ProcessInfo.processInfo.environment["SUMIKA_DETOKENIZER_BENCHMARK"] == "1" else {
      throw XCTSkip("Set SUMIKA_DETOKENIZER_BENCHMARK=1 for local-only Release measurements.")
    }
    let ids =
      ProcessInfo.processInfo.environment["SUMIKA_DETOKENIZER_MODELS"]?
      .split(separator: ",").map(String.init) ?? ["gemma4-e4b-qat-4bit", "qwen3.8-27B-OptiQ-4bit"]
    return try ids.map { id in
      let model = try XCTUnwrap(ManagedModelCatalog.model(id: id))
      guard
        FileManager.default.fileExists(
          atPath: model.localDirectoryURL.appending(path: "tokenizer.json").path)
      else {
        throw XCTSkip("Benchmark model is not installed: \(model.localDirectoryName)")
      }
      return model
    }
  }

  private struct GenerationSample {
    let output: String
    let tokens: Int
    let tokensPerSecond: Double
    let wallMilliseconds: Double
  }

  private func generate(container: ModelContainer) async throws -> GenerationSample {
    let session = ChatSession(
      container, generateParameters: GenerateParameters(maxTokens: 512, temperature: 0),
      additionalContext: ["enable_thinking": false])
    let prompt =
      "Return a single line JSON object with a records array of 200 objects, each with sequential id, name, enabled, and description fields. No Markdown or commentary."
    StreamOrDevice.default.stream.synchronize()
    let started = ProcessInfo.processInfo.systemUptime
    var output = ""
    var completion: GenerateCompletionInfo?
    do {
      for try await event in session.streamDetails(to: prompt) {
        if let chunk = event.chunk { output += chunk }
        if let info = event.info { completion = info }
        XCTAssertNil(event.rejectedToolCall)
      }
      await session.synchronize()
    } catch {
      await session.synchronize()
      await session.clear()
      throw error
    }
    StreamOrDevice.default.stream.synchronize()
    let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
    await session.clear()
    let info = try XCTUnwrap(completion)
    XCTAssertFalse(output.isEmpty)
    return GenerationSample(
      output: output, tokens: info.generationTokenCount,
      tokensPerSecond: info.tokensPerSecond, wallMilliseconds: elapsed)
  }

  private func cpuTime() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)) / 1_000_000_000
  }

  private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
  private func number(_ value: Double) -> String { String(format: "%.3f", value) }
}

nonisolated private struct BenchmarkTokenizer: Tokenizer {
  let base: any Tokenizer
  let incremental: Bool

  func encode(text: String, addSpecialTokens: Bool) -> [Int] {
    base.encode(text: text, addSpecialTokens: addSpecialTokens)
  }
  func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
    base.decode(tokenIds: tokenIds, skipSpecialTokens: skipSpecialTokens)
  }
  func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
  func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
  var bosToken: String? { base.bosToken }
  var eosToken: String? { base.eosToken }
  var unknownToken: String? { base.unknownToken }
  func applyChatTemplate(
    messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
    additionalContext: [String: any Sendable]?
  ) throws -> [Int] {
    try base.applyChatTemplate(
      messages: messages, tools: tools, additionalContext: additionalContext)
  }
  func makeStreamingDetokenizer() -> any StreamingDetokenizer {
    incremental ? base.makeStreamingDetokenizer() : NaiveStreamingDetokenizer(tokenizer: base)
  }
}
