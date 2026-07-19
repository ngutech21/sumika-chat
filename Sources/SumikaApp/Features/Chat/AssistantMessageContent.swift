import SumikaCore

enum AssistantMessageRenderBlocks {
  static func blocks(for content: String) -> [AssistantRenderBlock] {
    AssistantRenderBlockParser().parse(
      AssistantMarkdownPreprocessor.renderableContent(for: content)
    )
  }
}
