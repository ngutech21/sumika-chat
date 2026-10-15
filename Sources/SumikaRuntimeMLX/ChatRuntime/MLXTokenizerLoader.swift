import Foundation
import MLXLMCommon
import Tokenizers

func makeHuggingFaceTokenizerLoader() -> any TokenizerLoader {
  HuggingFaceTokenizerLoader()
}

private struct HuggingFaceTokenizerLoader: TokenizerLoader {
  func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
    let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
    return HuggingFaceTokenizerBridge(upstream: upstream)
  }
}

private struct HuggingFaceTokenizerBridge: MLXLMCommon.Tokenizer {
  let upstream: any Tokenizers.Tokenizer

  func encode(text: String, addSpecialTokens: Bool) -> [Int] {
    upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
  }

  func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
    upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
  }

  func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
  func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
  var bosToken: String? { upstream.bosToken }
  var eosToken: String? { upstream.eosToken }
  var unknownToken: String? { upstream.unknownToken }

  func applyChatTemplate(
    messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
    additionalContext: [String: any Sendable]?
  ) throws -> [Int] {
    do {
      return try upstream.applyChatTemplate(
        messages: messages, tools: tools, additionalContext: additionalContext)
    } catch Tokenizers.TokenizerError.missingChatTemplate {
      throw MLXLMCommon.TokenizerError.missingChatTemplate
    }
  }

  func makeStreamingDetokenizer() -> any StreamingDetokenizer {
    HuggingFaceStreamingDetokenizer(
      decoder: upstream.makeStreamDecoder(skipSpecialTokens: false))
  }
}

private struct HuggingFaceStreamingDetokenizer: StreamingDetokenizer {
  var decoder: Tokenizers.TokenStreamDecoder
  private var pending = ""

  init(decoder: Tokenizers.TokenStreamDecoder) {
    self.decoder = decoder
  }

  mutating func append(token: Int) {
    do {
      pending += try decoder.append(token: token)
    } catch {
      preconditionFailure("Create a new detokenizer after finish(): \(error)")
    }
  }

  mutating func next() -> String? {
    guard !pending.isEmpty else { return nil }
    defer { pending = "" }
    return pending
  }

  mutating func finish() -> String? {
    pending += decoder.finish()
    return next()
  }
}
