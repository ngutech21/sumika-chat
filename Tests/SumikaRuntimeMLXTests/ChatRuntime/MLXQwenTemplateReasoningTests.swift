import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import XCTest

@testable import SumikaCore
@testable import SumikaRuntimeMLX

nonisolated final class MLXQwenTemplateReasoningTests: XCTestCase {
  func testSwiftBudgetClosePreservesToolContinuationPrefix() async throws {
    guard
      let modelDirectory = ManagedModelCatalog.model(id: "Swift-1.5-4bit-MLX")?.localDirectoryURL,
      FileManager.default.fileExists(atPath: modelDirectory.appending(path: "tokenizer.json").path),
      FileManager.default.fileExists(
        atPath: modelDirectory.appending(path: "chat_template.jinja").path)
    else {
      throw XCTSkip("The local Swift-1.5 tokenizer fixture is not installed.")
    }
    let libraryURL = Bundle(for: Self.self).resourceURL?
      .appending(path: "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
    guard let libraryURL, (try? libraryURL.checkResourceIsReachable()) == true else {
      throw XCTSkip("MLX default.metallib is unavailable in the SwiftPM test bundle.")
    }

    let tokenizer = try await makeHuggingFaceTokenizerLoader().load(from: modelDirectory)
    try Device.withDefaultDevice(.cpu) {
      try Stream.withNewDefaultStream(device: .cpu) {
        let generator = Qwen3VLMessageGenerator()
        let context: [String: any Sendable] = [
          "enable_thinking": true, "preserve_thinking": true, "reasoning_effort": "medium",
        ]
        let history: [Chat.Message] = [.user("Inspect README.md")]
        let prompt = try tokenizer.applyChatTemplate(
          messages: generator.generate(messages: history), tools: nil, additionalContext: context)
        let toolText = """
          <tool_call>
          <function=read_file>
          <parameter=path>
          README.md
          </parameter>
          </function>
          </tool_call>
          """
        let eos = try XCTUnwrap(tokenizer.convertTokenToId("<|im_end|>"))
        for body in ["requests_b.jsonl: a few lines,", "plan\n"] {
          let generated = try MLXBudgetCloseTestSupport.close(
            body: body, maximumTokenCount: tokenizer.encode(text: body).count,
            tokenizer: tokenizer)
          let messages =
            history + [
              .assistant(
                "<think>\n" + tokenizer.decode(tokenIds: generated),
                toolCalls: [
                  MLXLMCommon.ToolCall(
                    function: .init(name: "read_file", arguments: ["path": "README.md"]),
                    id: "call-1")
                ]),
              .tool("README contents", id: "call-1"),
            ]
          let continuation = try tokenizer.applyChatTemplate(
            messages: generator.generate(messages: messages), tools: nil, additionalContext: context
          )
          let cached = prompt + generated + tokenizer.encode(text: toolText) + [eos]
          XCTAssertEqual(Array(continuation.prefix(cached.count)), cached, "Reasoning: \(body)")
        }
      }
    }
  }

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
      reasoningSelection: .on,
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
      reasoningSelection: .off,
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
