import Foundation
import MLXLMCommon
import Testing

@testable import SumikaCore
@testable import SumikaRuntimeMLX

#if canImport(SumikaTestSupport)
  import SumikaTestSupport
#endif
@Suite()
struct ReasoningTraceParserTests {
  @Test
  func passThroughParserEmitsOnlyVisibleText() throws {
    var parser = try ReasoningTraceParser(format: .none)

    #expect(parser.boundaryState == .absent)
    #expect(try parser.append("") == [])
    #expect(try parser.append("Visible") == [.visible("Visible")])
    #expect(try parser.finish() == [])
    #expect(parser.boundaryState == .absent)
  }

  @Test
  func protocolBoundaryStateDoesNotDependOnEmittedReasoningText() throws {
    var gemmaParser = try ReasoningTraceParser(format: .gemmaChannel)
    #expect(gemmaParser.boundaryState == .absent)
    #expect(try gemmaParser.append("<|channel|>thought") == [])
    #expect(gemmaParser.boundaryState == .open)
    #expect(gemmaParser.prepareForToolCall() == [])
    #expect(gemmaParser.boundaryState == .closed)

    var qwenParser = try ReasoningTraceParser(format: .qwenThinkTags)
    #expect(qwenParser.boundaryState == .open)
    #expect(try qwenParser.append("<think>") == [])
    #expect(qwenParser.boundaryState == .open)
    #expect(qwenParser.prepareForToolCall() == [])
    #expect(qwenParser.boundaryState == .closed)
  }

  @Test
  func thoughtChannelParserSplitsThoughtBlocksAcrossChunks() throws {
    var parser = try ReasoningTraceParser(format: .gemmaChannel)

    let segments = [
      try parser.append("<|chan"),
      try parser.append("nel|>thought The user said hey."),
      try parser.append(" I should greet them.<chan"),
      try parser.append("nel|>Hello"),
      try parser.append(" there."),
      try parser.finish(),
    ].flatMap { $0 }

    #expect(
      segments == [
        .thinking(" The user said hey."),
        .thinking(" I should greet them."),
        .thinkingCompleted,
        .visible("Hello"),
        .visible(" there."),
      ])
  }

  @Test
  func thoughtChannelParserSupportsAsymmetricThoughtMarker() throws {
    var parser = try ReasoningTraceParser(format: .gemmaChannel)

    let segments = [
      try parser.append("<|chan"),
      try parser.append("nel>thought I should answer."),
      try parser.append("<channel|>Done."),
      try parser.finish(),
    ].flatMap { $0 }

    #expect(
      segments == [
        .thinking(" I should answer."),
        .thinkingCompleted,
        .visible("Done."),
      ])
  }

  @Test
  func thoughtChannelToolCallBoundaryKeepsSubsequentTextVisible() throws {
    var parser = try ReasoningTraceParser(format: .gemmaChannel)

    let segments = [
      try parser.append("<|channel|>thoughtReasoning"),
      parser.prepareForToolCall(),
      try parser.append("Answer"),
      try parser.finish(),
    ].flatMap { $0 }

    #expect(
      segments == [
        .thinking("Reasoning"),
        .thinkingCompleted,
        .visible("Answer"),
      ])
  }

  @Test
  func qwenThinkTagParserStartsInThinkingMode() throws {
    var parser = try ReasoningTraceParser(format: .qwenThinkTags)

    let segments = [
      try parser.append("The user said hey."),
      try parser.append("</th"),
      try parser.append("ink>\n\nHello."),
      try parser.finish(),
    ].flatMap { $0 }

    #expect(
      segments == [
        .thinking("The user said hey."),
        .thinkingCompleted,
        .visible("\n\nHello."),
      ])
  }

  @Test
  func qwenThinkTagParserStripsOptionalOpeningTag() throws {
    var parser = try ReasoningTraceParser(format: .qwenThinkTags)

    let segments = [
      try parser.append("<th"),
      try parser.append("ink>Reasoning"),
      try parser.append("</think>Answer"),
      try parser.finish(),
    ].flatMap { $0 }

    #expect(
      segments == [
        .thinking("Reasoning"),
        .thinkingCompleted,
        .visible("Answer"),
      ])
  }

  @Test
  func unfinishedReasoningDoesNotEmitCompletionAtEndOfStream() throws {
    for format in [ReasoningTraceFormat.gemmaChannel, .qwenThinkTags] {
      var parser = try ReasoningTraceParser(format: format)

      let segments = [
        try parser.append(
          format == .gemmaChannel ? "<|channel|>thoughtPartial" : "<think>Partial"
        ),
        try parser.finish(),
      ].flatMap { $0 }

      #expect(segments == [.thinking("Partial")])
    }
  }

  @Test
  func consumedCloseMarkerEmitsExactlyOneCompletionBoundary() throws {
    for (format, input) in [
      (ReasoningTraceFormat.gemmaChannel, "<|channel|>thoughtReasoning<channel|>Answer"),
      (.qwenThinkTags, "<think>Reasoning</think>Answer"),
    ] {
      for splitOffset in 0...input.count {
        let splitIndex = input.index(input.startIndex, offsetBy: splitOffset)
        var parser = try ReasoningTraceParser(format: format)
        let segments = [
          try parser.append(String(input[..<splitIndex])),
          try parser.append(String(input[splitIndex...])),
          try parser.finish(),
        ].flatMap { $0 }

        #expect(segments.filter { $0 == .thinkingCompleted }.count == 1)
      }
    }
  }

  @Test
  func gemmaMarkersParseAcrossEveryChunkBoundary() throws {
    let input = "<|channel|>thoughtReasoning<channel|>Answer"

    for splitOffset in 0...input.count {
      let splitIndex = input.index(input.startIndex, offsetBy: splitOffset)
      var parser = try ReasoningTraceParser(format: .gemmaChannel)
      let segments = [
        try parser.append(String(input[..<splitIndex])),
        try parser.append(String(input[splitIndex...])),
        try parser.finish(),
      ].flatMap { $0 }

      #expect(text(for: .thinking, in: segments) == "Reasoning")
      #expect(text(for: .visible, in: segments) == "Answer")
    }
  }

  @Test
  func qwenMarkersParseAcrossEveryChunkBoundary() throws {
    let input = "<think>Reasoning</think>Answer"

    for splitOffset in 0...input.count {
      let splitIndex = input.index(input.startIndex, offsetBy: splitOffset)
      var parser = try ReasoningTraceParser(format: .qwenThinkTags)
      let segments = [
        try parser.append(String(input[..<splitIndex])),
        try parser.append(String(input[splitIndex...])),
        try parser.finish(),
      ].flatMap { $0 }

      #expect(text(for: .thinking, in: segments) == "Reasoning")
      #expect(text(for: .visible, in: segments) == "Answer")
    }
  }

  @Test
  func qwenImplicitEndDelimiterUsesTheCanonicalProtocolState() throws {
    var parser = try ReasoningTraceParser(
      format: .qwenThinkTags,
      qwenValidation: .init(responseStopStrings: [])
    )

    let segments = try parser.append("Reasoning<tool_call>payload")

    #expect(
      segments == [
        .thinking("Reasoning"),
        .thinkingCompleted,
        .visible("<tool_call>payload"),
      ])
  }

  @Test
  func qwenToolCallBoundaryKeepsSubsequentTextInResponseState() throws {
    var parser = try ReasoningTraceParser(
      format: .qwenThinkTags,
      qwenValidation: .init(responseStopStrings: [])
    )

    let segments = [
      try parser.append("Reasoning"),
      parser.prepareForToolCall(),
      try parser.append("Answer"),
      try parser.finish(),
    ].flatMap { $0 }

    #expect(
      segments == [
        .thinking("Reasoning"),
        .thinkingCompleted,
        .visible("Answer"),
      ])
  }

  private enum SegmentKind {
    case visible
    case thinking
  }

  private func text(
    for kind: SegmentKind,
    in segments: [ReasoningTraceParser.Segment]
  ) -> String {
    segments.compactMap { segment in
      switch (kind, segment) {
      case (.visible, .visible(let text)), (.thinking, .thinking(let text)):
        text
      case (.visible, .thinking), (.thinking, .visible), (_, .thinkingCompleted):
        nil
      }
    }.joined()
  }

}
