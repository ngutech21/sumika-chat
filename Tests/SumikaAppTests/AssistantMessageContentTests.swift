import SumikaCore
import Testing

@testable import SumikaApp

@MainActor
struct AssistantMessageContentTests {
  @Test
  func bareAssistantURLStaysInMarkdownParagraphForAutolinking() {
    let blocks = AssistantMessageRenderBlocks.blocks(
      for: "Source: https://example.com/path?q=1"
    )

    #expect(
      blocks == [
        .paragraph(
          .init(
            id: .init(rawValue: "assistant-render-block-0"),
            text: "Source: https://example.com/path?q=1"
          ))
      ])
  }

  @Test
  func openFenceProjectsToCodeBlockBeforeClosingFenceExists() {
    let blocks = AssistantMessageRenderBlocks.blocks(
      for: """
        Intro
        ```swift
        let value
        """
    )

    #expect(blocks.count == 2)
    #expect(
      blocks.first
        == .paragraph(
          .init(id: .init(rawValue: "assistant-render-block-0"), text: "Intro\n"))
    )

    guard case .codeBlock(let codeBlock) = blocks.last else {
      Issue.record("Expected open fence to produce a code block")
      return
    }

    #expect(codeBlock.id == .init(rawValue: "assistant-render-block-1"))
    #expect(codeBlock.language == "swift")
    #expect(codeBlock.text == "let value")
    #expect(codeBlock.isClosed == false)
  }

  @Test
  func inferredRawCodePreservesOriginalContent() throws {
    let content = """

      {
        "name": "sumika"
      }

      """

    let blocks = AssistantMessageRenderBlocks.blocks(for: content)

    #expect(blocks.count == 1)
    guard case .codeBlock(let codeBlock) = try #require(blocks.first) else {
      Issue.record("Expected inferred JSON to produce a code block")
      return
    }
    #expect(codeBlock.id == .init(rawValue: "assistant-render-block-0"))
    #expect(codeBlock.language == "json")
    #expect(codeBlock.text == content)
    #expect(codeBlock.isClosed)
  }

  @Test
  func explicitFenceRemainsAuthoritativeInsideMarkdown() throws {
    let content = """
      Intro

      ```typescript
      const width: number = 1280
      ```
      Outro
      """

    let blocks = AssistantMessageRenderBlocks.blocks(for: content)

    #expect(blocks.count == 3)
    guard case .paragraph(let intro) = blocks[0],
      case .codeBlock(let codeBlock) = blocks[1],
      case .paragraph(let outro) = blocks[2]
    else {
      Issue.record("Expected paragraph, explicit code block, paragraph")
      return
    }
    #expect(intro.text == "Intro\n\n")
    #expect(codeBlock.language == "typescript")
    #expect(codeBlock.text == "const width: number = 1280\n")
    #expect(codeBlock.isClosed)
    #expect(outro.text == "Outro")
  }
}
