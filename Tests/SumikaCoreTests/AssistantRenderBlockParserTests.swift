import Testing

@testable import SumikaCore

struct AssistantRenderBlockParserTests {
  @Test
  func leavesPlainMarkdownAsParagraph() {
    let blocks = AssistantRenderBlockParser().parse("Here is **bold** text.")

    #expect(
      blocks == [
        .paragraph(
          .init(id: .init(rawValue: "assistant-render-block-0"), text: "Here is **bold** text."))
      ])
  }

  @Test
  func doesNotCreateCodeBlockForPartialFence() {
    let blocks = AssistantRenderBlockParser().parse("Here is code:\n``")

    #expect(
      blocks == [
        .paragraph(
          .init(id: .init(rawValue: "assistant-render-block-0"), text: "Here is code:\n``"))
      ])
  }

  @Test
  func createsCodeBlockAsSoonAsOpeningFenceAppears() {
    let blocks = AssistantRenderBlockParser().parse(
      """
      Intro
      ```swift
      let value = 42
      """
    )

    #expect(
      blocks == [
        .paragraph(.init(id: .init(rawValue: "assistant-render-block-0"), text: "Intro\n")),
        .codeBlock(
          .init(
            id: .init(rawValue: "assistant-render-block-1"),
            language: "swift",
            text: "let value = 42",
            isClosed: false
          )
        ),
      ])
  }

  @Test
  func parsesClosedLanguageFence() {
    let blocks = AssistantRenderBlockParser().parse(
      """
      ```json
      {"ok": true}
      ```
      """
    )

    #expect(
      blocks == [
        .codeBlock(
          .init(
            id: .init(rawValue: "assistant-render-block-0"),
            language: "json",
            text: "{\"ok\": true}\n",
            isClosed: true
          )
        )
      ])
  }

  @Test
  func parsesFenceLongerThanThreeBackticks() {
    let blocks = AssistantRenderBlockParser().parse(
      """
      ````swift
      let markdownFence = "```"
      ````
      After
      """
    )

    #expect(
      blocks == [
        .codeBlock(
          .init(
            id: .init(rawValue: "assistant-render-block-0"),
            language: "swift",
            text: "let markdownFence = \"```\"\n",
            isClosed: true
          )
        ),
        .paragraph(.init(id: .init(rawValue: "assistant-render-block-1"), text: "After")),
      ])
  }

  @Test
  func ignoresShorterFenceInsideLongerCodeBlock() {
    let blocks = AssistantRenderBlockParser().parse(
      """
      ````markdown
      ```swift
      let value = 42
      ```
      ````
      After
      """
    )

    #expect(
      blocks == [
        .codeBlock(
          .init(
            id: .init(rawValue: "assistant-render-block-0"),
            language: "markdown",
            text: "```swift\nlet value = 42\n```\n",
            isClosed: true
          )
        ),
        .paragraph(.init(id: .init(rawValue: "assistant-render-block-1"), text: "After")),
      ])
  }

  @Test
  func parsesParagraphCodeParagraphTransitions() {
    let blocks = AssistantRenderBlockParser().parse(
      """
      Before

      ```bash
      just test-core
      ```
      After
      """
    )

    #expect(
      blocks == [
        .paragraph(.init(id: .init(rawValue: "assistant-render-block-0"), text: "Before\n\n")),
        .codeBlock(
          .init(
            id: .init(rawValue: "assistant-render-block-1"),
            language: "bash",
            text: "just test-core\n",
            isClosed: true
          )
        ),
        .paragraph(.init(id: .init(rawValue: "assistant-render-block-2"), text: "After")),
      ])
  }

  @Test
  func keepsCurrentCodeBlockIDStableWhileStreaming() {
    let parser = AssistantRenderBlockParser()
    let firstPass = parser.parse(
      """
      Intro
      ```swift
      let
      """
    )
    let secondPass = parser.parse(
      """
      Intro
      ```swift
      let value = 42
      """
    )

    #expect(firstPass.count == 2)
    #expect(secondPass.count == 2)
    #expect(firstPass[0] == secondPass[0])
    #expect(firstPass[1].id == secondPass[1].id)
  }

  @Test
  func keepsCompletedBlockIDsStableWhenLaterChunksArrive() {
    let parser = AssistantRenderBlockParser()
    let firstPass = parser.parse(
      """
      Intro
      ```swift
      let value = 42
      ```
      """
    )
    let secondPass = parser.parse(
      """
      Intro
      ```swift
      let value = 42
      ```
      Outro
      """
    )

    #expect(firstPass.count == 2)
    #expect(secondPass.count == 3)
    #expect(firstPass[0].id == secondPass[0].id)
    #expect(firstPass[1].id == secondPass[1].id)
    #expect(firstPass[0] == secondPass[0])
    #expect(firstPass[1] == secondPass[1])
  }
}
