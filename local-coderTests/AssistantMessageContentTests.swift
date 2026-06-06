import LocalCoderCore
import Testing

@testable import local_coder

@MainActor
struct AssistantMessageContentTests {
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
}
