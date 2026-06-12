import Foundation
import MLXLMCommon
import Tokenizers

nonisolated struct LocalDownloader: MLXLMCommon.Downloader {
  func download(
    id: String,
    revision: String?,
    matching patterns: [String],
    useLatest: Bool,
    progressHandler: @Sendable (Progress) -> Void
  ) async throws -> URL {
    throw ModelConfiguration.DirectoryError.unresolvedModelDirectory(id)
  }
}

nonisolated struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
  func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
    let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
    return LocalTokenizer(tokenizer: tokenizer)
  }
}

nonisolated struct LocalTokenizer: MLXLMCommon.Tokenizer {
  let tokenizer: any Tokenizers.Tokenizer

  func encode(text: String, addSpecialTokens: Bool) -> [Int] {
    tokenizer.encode(text: text, addSpecialTokens: addSpecialTokens)
  }

  func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
    tokenizer.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
  }

  func convertTokenToId(_ token: String) -> Int? {
    tokenizer.convertTokenToId(token)
  }

  func convertIdToToken(_ id: Int) -> String? {
    tokenizer.convertIdToToken(id)
  }

  var bosToken: String? {
    tokenizer.bosToken
  }

  var eosToken: String? {
    tokenizer.eosToken
  }

  var unknownToken: String? {
    tokenizer.unknownToken
  }

  func applyChatTemplate(
    messages: [[String: any Sendable]],
    tools: [[String: any Sendable]]?,
    additionalContext: [String: any Sendable]?
  ) throws -> [Int] {
    try tokenizer.applyChatTemplate(
      messages: messages,
      tools: tools,
      additionalContext: additionalContext
    )
  }
}
