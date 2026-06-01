import Testing

@testable import local_coder

struct ChatMessageTests {
    @Test
    func detectsStreamingToolCallMarkupPrefixes() {
        let partialMessages = [
            "<",
            "<act",
            "<action",
            "<action name=\"list_files\">",
        ]

        for content in partialMessages {
            let message = ChatMessage(role: .assistant, content: content)

            #expect(message.containsStreamingToolCallMarkup)
        }
    }

    @Test
    func ignoresPlainAssistantContentWhenDetectingStreamingToolCallMarkup() {
        let message = ChatMessage(role: .assistant, content: "Here are the files:")

        #expect(!message.containsStreamingToolCallMarkup)
    }

    @Test
    func ignoresAnnotatedToolCallsWhenDetectingStreamingToolCallMarkup() {
        let message = ChatMessage(
            role: .assistant,
            content: "<action name=\"list_files\"></action>",
            toolCall: ToolCallModelMessage(toolName: .listFiles, arguments: [])
        )

        #expect(!message.containsStreamingToolCallMarkup)
    }
}
