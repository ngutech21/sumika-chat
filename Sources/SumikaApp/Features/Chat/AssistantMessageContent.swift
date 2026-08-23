import SumikaCore

enum AssistantMessageRenderBlocks {
  static func blocks(for content: String) -> [AssistantRenderBlock] {
    let parsedBlocks = AssistantRenderBlockParser().parse(content)
    if parsedBlocks.contains(where: \AssistantRenderBlock.isCodeBlock) {
      return parsedBlocks
    }

    switch AssistantContentPresentationClassifier.classify(content) {
    case .markdown:
      return parsedBlocks
    case .rawCode(let language):
      return [
        .codeBlock(
          .init(
            id: .init(rawValue: "assistant-render-block-0"),
            language: language.rawValue,
            text: content,
            isClosed: true
          )
        )
      ]
    }
  }
}

extension AssistantRenderBlock {
  fileprivate var isCodeBlock: Bool {
    guard case .codeBlock = self else {
      return false
    }
    return true
  }
}
