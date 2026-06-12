import Testing

@testable import LocalCoderCore

struct ChatSessionTitleDeriverTests {
  @Test
  func titleUsesNormalizedFirstPrompt() {
    let title = ChatSessionTitleDeriver.title(
      fromFirstPrompt: "  build   a snake game\nin python  "
    )

    #expect(title == "build a snake game in python")
  }

  @Test
  func titleTruncatesAtWordBoundary() {
    let title = ChatSessionTitleDeriver.title(
      fromFirstPrompt:
        "Implement automatic chat session naming from the first submitted user prompt"
    )

    #expect(title == "Implement automatic chat session naming from")
    #expect(title.count <= ChatSessionTitleDeriver.maximumLength)
  }

  @Test
  func emptyPromptFallsBackToDefaultTitle() {
    let title = ChatSessionTitleDeriver.title(fromFirstPrompt: " \n\t ")

    #expect(title == ChatSession.defaultTitle)
  }
}
