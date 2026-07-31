import Foundation
import MLXLMCommon
import XCTest

@testable import SumikaCore
@testable import SumikaRuntimeMLX

nonisolated final class MLXQwenTemplateReasoningTests: XCTestCase {
  func testLocalQwenTemplateKeepsRawAndReconstructedReasoningTokenIdentical() async throws {
    guard
      let modelDirectory = ManagedModelCatalog.model(
        id: "qwen3.6-35b-a3b-optiq-4bit"
      )?.localDirectoryURL
    else {
      throw XCTSkip("The Qwen3.6 OptiQ catalog entry is unavailable.")
    }
    guard
      FileManager.default.fileExists(
        atPath: modelDirectory.appending(path: "tokenizer.json").path(percentEncoded: false)
      ),
      FileManager.default.fileExists(
        atPath: modelDirectory.appending(path: "chat_template.jinja").path(percentEncoded: false)
      )
    else {
      throw XCTSkip("The local Qwen3.6 OptiQ tokenizer fixture is not installed.")
    }

    let tokenizer = try await makeHuggingFaceTokenizerLoader().load(from: modelDirectory)
    let reasoning = "I should calculate carefully."
    let visibleAnswer = "The result is 42."
    let rawHistory: [Chat.Message] = [
      .user("Solve it"),
      .assistant("\(reasoning)\n</think>\n\n\(visibleAnswer)"),
      .user("Explain it"),
    ]
    let reconstructedHistory: [Chat.Message] =
      [
        .user("Solve it")
      ]
      + MLXHistoryRenderer.chatMessages(
        from: [
          ProviderPromptMessage(
            role: Chat.Message.Role.assistant.rawValue,
            content: visibleAnswer,
            reasoningContent: reasoning
          )
        ],
        supportsHistoricalReasoningPreservation: true
      ) + [
        .user("Explain it")
      ]
    let additionalContext = try MLXHistoryRenderer.generationInput(
      from: ModelPromptProjection(entries: [
        try ModelFacingPromptRenderer.userPromptEntry(prompt: "Explain it")
      ]),
      reasoningEnabled: true,
      supportsHistoricalReasoningPreservation: true
    ).additionalContext

    let rawTokens = try tokenizer.applyChatTemplate(
      messages: DefaultMessageGenerator().generate(messages: rawHistory),
      tools: nil,
      additionalContext: additionalContext
    )
    let reconstructedTokens = try tokenizer.applyChatTemplate(
      messages: DefaultMessageGenerator().generate(messages: reconstructedHistory),
      tools: nil,
      additionalContext: additionalContext
    )

    XCTAssertEqual(rawTokens, reconstructedTokens)

    let rawToolBoundary: [Chat.Message] = [
      .user("Inspect README.md"),
      .assistant(
        "\(reasoning)\n</think>\n\nI will inspect it.",
        toolCalls: [
          MLXLMCommon.ToolCall(
            function: .init(
              name: ToolName.readFile.rawValue,
              arguments: ["path": "README.md"]
            ),
            id: "call-1"
          )
        ]
      ),
      .tool("README contents", id: "call-1"),
      .user("Continue"),
    ]
    let reconstructedToolBoundary: [Chat.Message] =
      [
        .user("Inspect README.md")
      ]
      + MLXHistoryRenderer.chatMessages(
        from: [
          ProviderPromptMessage(
            role: Chat.Message.Role.assistant.rawValue,
            content: "I will inspect it.",
            reasoningContent: reasoning,
            toolCalls: [
              ProviderToolCall(
                id: "call-1",
                name: ToolName.readFile.rawValue,
                arguments: ["path": .string("README.md")]
              )
            ]
          )
        ],
        supportsHistoricalReasoningPreservation: true
      ) + [
        .tool("README contents", id: "call-1"),
        .user("Continue"),
      ]
    let rawToolTokens = try tokenizer.applyChatTemplate(
      messages: DefaultMessageGenerator().generate(messages: rawToolBoundary),
      tools: nil,
      additionalContext: additionalContext
    )
    let reconstructedToolTokens = try tokenizer.applyChatTemplate(
      messages: DefaultMessageGenerator().generate(messages: reconstructedToolBoundary),
      tools: nil,
      additionalContext: additionalContext
    )

    XCTAssertEqual(rawToolTokens, reconstructedToolTokens)

    let reasoningDisabledContext = try MLXHistoryRenderer.generationInput(
      from: ModelPromptProjection(entries: [
        try ModelFacingPromptRenderer.userPromptEntry(prompt: "Continue")
      ]),
      reasoningEnabled: false,
      supportsHistoricalReasoningPreservation: true
    ).additionalContext
    XCTAssertEqual(reasoningDisabledContext["enable_thinking"] as? Bool, false)
    XCTAssertEqual(reasoningDisabledContext["preserve_thinking"] as? Bool, true)
    XCTAssertEqual(
      try tokenizer.applyChatTemplate(
        messages: DefaultMessageGenerator().generate(messages: rawToolBoundary),
        tools: nil,
        additionalContext: reasoningDisabledContext
      ),
      try tokenizer.applyChatTemplate(
        messages: DefaultMessageGenerator().generate(messages: reconstructedToolBoundary),
        tools: nil,
        additionalContext: reasoningDisabledContext
      )
    )
  }
}
