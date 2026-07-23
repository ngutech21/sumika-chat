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
  func passThroughParserEmitsOnlyVisibleText() {
    var parser = ReasoningTraceParser(format: .none)

    #expect(parser.append("") == [])
    #expect(parser.append("Visible") == [.visible("Visible")])
    #expect(parser.finish() == [])
  }

  @Test
  func thoughtChannelParserSplitsThoughtBlocksAcrossChunks() {
    var parser = ReasoningTraceParser(format: .gemmaChannel)

    let segments = [
      parser.append("<|chan"),
      parser.append("nel|>thought The user said hey."),
      parser.append(" I should greet them.<chan"),
      parser.append("nel|>Hello"),
      parser.append(" there."),
      parser.finish(),
    ].flatMap { $0 }

    #expect(
      segments == [
        .thinking(" The user said hey."),
        .thinking(" I should greet them."),
        .visible("Hello"),
        .visible(" there."),
      ])
  }

  @Test
  func thoughtChannelParserSupportsAsymmetricThoughtMarker() {
    var parser = ReasoningTraceParser(format: .gemmaChannel)

    let segments = [
      parser.append("<|chan"),
      parser.append("nel>thought I should answer."),
      parser.append("<channel|>Done."),
      parser.finish(),
    ].flatMap { $0 }

    #expect(
      segments == [
        .thinking(" I should answer."),
        .visible("Done."),
      ])
  }

  @Test
  func qwenThinkTagParserStartsInThinkingMode() {
    var parser = ReasoningTraceParser(format: .qwenThinkTags)

    let segments = [
      parser.append("The user said hey."),
      parser.append("</th"),
      parser.append("ink>\n\nHello."),
      parser.finish(),
    ].flatMap { $0 }

    #expect(
      segments == [
        .thinking("The user said hey."),
        .visible("\n\nHello."),
      ])
  }

  @Test
  func qwenThinkTagParserStripsOptionalOpeningTag() {
    var parser = ReasoningTraceParser(format: .qwenThinkTags)

    let segments = [
      parser.append("<th"),
      parser.append("ink>Reasoning"),
      parser.append("</think>Answer"),
      parser.finish(),
    ].flatMap { $0 }

    #expect(
      segments == [
        .thinking("Reasoning"),
        .visible("Answer"),
      ])
  }

  @Test
  func gemmaMarkersParseAcrossEveryChunkBoundary() {
    let input = "<|channel|>thoughtReasoning<channel|>Answer"

    for splitOffset in 0...input.count {
      let splitIndex = input.index(input.startIndex, offsetBy: splitOffset)
      var parser = ReasoningTraceParser(format: .gemmaChannel)
      let segments = [
        parser.append(String(input[..<splitIndex])),
        parser.append(String(input[splitIndex...])),
        parser.finish(),
      ].flatMap { $0 }

      #expect(text(for: .thinking, in: segments) == "Reasoning")
      #expect(text(for: .visible, in: segments) == "Answer")
    }
  }

  @Test
  func qwenMarkersParseAcrossEveryChunkBoundary() {
    let input = "<think>Reasoning</think>Answer"

    for splitOffset in 0...input.count {
      let splitIndex = input.index(input.startIndex, offsetBy: splitOffset)
      var parser = ReasoningTraceParser(format: .qwenThinkTags)
      let segments = [
        parser.append(String(input[..<splitIndex])),
        parser.append(String(input[splitIndex...])),
        parser.finish(),
      ].flatMap { $0 }

      #expect(text(for: .thinking, in: segments) == "Reasoning")
      #expect(text(for: .visible, in: segments) == "Answer")
    }
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
      case (.visible, .thinking), (.thinking, .visible):
        nil
      }
    }.joined()
  }

}
