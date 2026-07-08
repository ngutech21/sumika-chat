import Testing

@testable import SumikaCore

struct ChatSessionTitleGeneratorTests {
  @Test
  func titleUsesNormalizedFirstPrompt() {
    let title = ChatSessionTitleGenerator.title(
      fromFirstPrompt: "  build   a snake game\nin python  "
    )

    #expect(title == "build a snake game in python")
  }

  @Test
  func titleTruncatesAtWordBoundary() {
    let title = ChatSessionTitleGenerator.title(
      fromFirstPrompt:
        "Implement automatic chat session naming from the first submitted user prompt"
    )

    #expect(title == "Implement automatic chat session naming from")
    #expect(title.count <= ChatSessionTitleGenerator.maximumLength)
  }

  @Test
  func emptyPromptFallsBackToDefaultTitle() {
    let title = ChatSessionTitleGenerator.title(fromFirstPrompt: " \n\t ")

    #expect(title == ChatSession.defaultTitle)
  }
}
