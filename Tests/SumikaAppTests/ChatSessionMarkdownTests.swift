import SumikaCore
import Testing

@testable import SumikaApp

@MainActor
struct ChatSessionMarkdownTests {
  @Test
  func preservesMessageOrderMarkdownAndCancelledHistoryWithoutInternalContext() {
    let session = ChatSession(
      title: "Example",
      turns: [
        ChatTurn(
          status: .completed,
          items: [
            .userMessage(.init(content: "Explain **Swift**")),
            .assistantThinking(.init(content: "Private reasoning")),
            .assistantMessage(.init(content: "```swift\nlet value = 1\n```")),
            .assistantMessage(.init(content: "  \n", deliveryStatus: .streaming)),
          ]
        ),
        ChatTurn(
          status: .cancelled, modelContextPolicy: .excluded,
          items: [
            .userMessage(.init(content: "Continue")),
            .assistantMessage(
              .init(
                content: "Partial reply", deliveryStatus: .cancelled,
                modelProjectionPolicy: .override("Internal prompt"))),
          ]
        ),
      ]
    )

    #expect(
      session.markdownTranscript() == """
        # Example

        ## User

        Explain **Swift**

        ## Assistant

        ```swift
        let value = 1
        ```

        ## User

        Continue

        ## Assistant

        Partial reply

        """)
  }

  @Test
  func keepsAttachmentOnlyMessagesAndEmptySessions() {
    let attachment = ChatAttachment(
      displayName: "notes.txt",
      payload: .text(.init(content: "Attachment body", byteSize: 15, contentSHA256: ""))
    )
    let session = ChatSession(
      title: "Attachments",
      turns: [
        ChatTurn(
          status: .completed,
          items: [
            .userMessage(.init(content: "", attachments: [attachment])),
            .assistantMessage(.init(content: "Done", attachments: [attachment])),
          ]
        )
      ]
    )
    #expect(
      session.markdownTranscript()
        == "# Attachments\n\n## User\n\nAttachment: notes.txt\n\n## Assistant\n\nDone\n\nAttachment: notes.txt\n"
    )
    #expect(ChatSession(title: "Empty").markdownTranscript() == "# Empty\n")
  }
}
