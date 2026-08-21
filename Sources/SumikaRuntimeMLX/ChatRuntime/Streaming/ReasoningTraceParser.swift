import MLXLMCommon
import SumikaCore

struct ReasoningTraceParser {
  enum BoundaryState: Equatable {
    case absent
    case open
    case closed

    var isOpen: Bool {
      if case .open = self {
        return true
      }
      return false
    }

    var isClosed: Bool {
      if case .closed = self {
        return true
      }
      return false
    }
  }

  struct QwenValidation: Equatable, Sendable {
    let responseStopStrings: Set<String>
  }

  enum Segment: Equatable {
    case visible(String)
    case thinking(String)
    case thinkingCompleted
  }

  private enum Storage {
    case none(PassThroughReasoningTraceParser)
    case gemma(GemmaThoughtChannelParser)
    case qwen(QwenThinkTagParser)
  }

  private var storage: Storage

  var boundaryState: BoundaryState {
    switch storage {
    case .none:
      .absent
    case .gemma(let parser):
      parser.boundaryState
    case .qwen(let parser):
      parser.boundaryState
    }
  }

  init(
    format: ReasoningTraceFormat,
    qwenValidation: QwenValidation? = nil
  ) throws {
    switch format {
    case .none:
      guard qwenValidation == nil else {
        throw MLXThinkingBudgetFailure.incompatibleReasoningProtocol
      }
      storage = .none(PassThroughReasoningTraceParser())
    case .gemmaChannel:
      guard qwenValidation == nil else {
        throw MLXThinkingBudgetFailure.incompatibleReasoningProtocol
      }
      storage = .gemma(GemmaThoughtChannelParser())
    case .qwenThinkTags:
      storage = .qwen(QwenThinkTagParser(validation: qwenValidation))
    }
  }

  mutating func append(_ chunk: String) throws -> [Segment] {
    switch storage {
    case .none(var parser):
      let segments = parser.append(chunk)
      storage = .none(parser)
      return segments
    case .gemma(var parser):
      let segments = parser.append(chunk)
      storage = .gemma(parser)
      return segments
    case .qwen(var parser):
      let segments = try parser.append(chunk)
      storage = .qwen(parser)
      return segments
    }
  }

  mutating func prepareForToolCall() -> [Segment] {
    switch storage {
    case .none(var parser):
      let segments = parser.prepareForToolCall()
      storage = .none(parser)
      return segments
    case .gemma(var parser):
      let segments = parser.prepareForToolCall()
      storage = .gemma(parser)
      return segments
    case .qwen(var parser):
      let segments = parser.prepareForToolCall()
      storage = .qwen(parser)
      return segments
    }
  }

  mutating func finish(discardingProtocolTail: Bool = false) throws -> [Segment] {
    switch storage {
    case .none(var parser):
      let segments = parser.finish()
      storage = .none(parser)
      return segments
    case .gemma(var parser):
      let segments = parser.finish()
      storage = .gemma(parser)
      return segments
    case .qwen(var parser):
      let segments = try parser.finish(discardingProtocolTail: discardingProtocolTail)
      storage = .qwen(parser)
      return segments
    }
  }
}

private struct PassThroughReasoningTraceParser {
  mutating func append(_ chunk: String) -> [ReasoningTraceParser.Segment] {
    chunk.isEmpty ? [] : [.visible(chunk)]
  }

  mutating func finish() -> [ReasoningTraceParser.Segment] {
    []
  }

  mutating func prepareForToolCall() -> [ReasoningTraceParser.Segment] {
    []
  }
}

private struct GemmaThoughtChannelParser {
  private static let thoughtMarkers = [
    "<|channel|>thought",
    "<|channel>thought",
  ]
  private static let closeMarker = "<channel|>"

  private var pending = ""
  private var isReadingThought = false
  private var hasEmittedThought = false
  private var hasObservedThought = false

  var boundaryState: ReasoningTraceParser.BoundaryState {
    if isReadingThought {
      return .open
    }
    return hasObservedThought ? .closed : .absent
  }

  mutating func append(_ chunk: String) -> [ReasoningTraceParser.Segment] {
    pending += chunk
    var segments: [ReasoningTraceParser.Segment] = []

    while !pending.isEmpty {
      if isReadingThought {
        guard let closeRange = pending.range(of: Self.closeMarker) else {
          let retained = longestSuffixMatchingPrefix(in: pending, of: Self.closeMarker)
          let emitEnd = pending.index(pending.endIndex, offsetBy: -retained.count)
          appendSegment(.thinking(String(pending[..<emitEnd])), to: &segments)
          pending = retained
          return segments
        }
        appendSegment(.thinking(String(pending[..<closeRange.lowerBound])), to: &segments)
        pending.removeSubrange(pending.startIndex..<closeRange.upperBound)
        isReadingThought = false
        hasEmittedThought = false
        segments.append(.thinkingCompleted)
        continue
      }

      if let thoughtRange = Self.firstMarkerRange(in: pending, markers: Self.thoughtMarkers) {
        appendSegment(.visible(String(pending[..<thoughtRange.lowerBound])), to: &segments)
        pending.removeSubrange(pending.startIndex..<thoughtRange.upperBound)
        isReadingThought = true
        hasEmittedThought = false
        hasObservedThought = true
        continue
      }

      let retained = longestSuffixMatchingAnyPrefix(in: pending, of: Self.thoughtMarkers)
      let emitEnd = pending.index(pending.endIndex, offsetBy: -retained.count)
      appendSegment(.visible(String(pending[..<emitEnd])), to: &segments)
      pending = retained
      return segments
    }

    return segments
  }

  mutating func finish() -> [ReasoningTraceParser.Segment] {
    guard !pending.isEmpty else {
      return []
    }
    let segment: ReasoningTraceParser.Segment =
      if isReadingThought {
        .thinking(pending)
      } else {
        .visible(pending)
      }
    pending = ""
    return [segment]
  }

  mutating func prepareForToolCall() -> [ReasoningTraceParser.Segment] {
    var segments: [ReasoningTraceParser.Segment] = []
    if !pending.isEmpty {
      appendSegment(isReadingThought ? .thinking(pending) : .visible(pending), to: &segments)
      pending = ""
    }
    if isReadingThought, hasEmittedThought {
      segments.append(.thinkingCompleted)
    }
    isReadingThought = false
    hasEmittedThought = false
    return segments
  }

  private mutating func appendSegment(
    _ segment: ReasoningTraceParser.Segment,
    to segments: inout [ReasoningTraceParser.Segment]
  ) {
    switch segment {
    case .visible(let text), .thinking(let text):
      guard !text.isEmpty else {
        return
      }
      segments.append(segment)
      if case .thinking = segment {
        hasEmittedThought = true
      }
    case .thinkingCompleted:
      segments.append(segment)
    }
  }

  private static func firstMarkerRange(
    in value: String,
    markers: [String]
  ) -> Range<String.Index>? {
    markers
      .compactMap { value.range(of: $0) }
      .min { lhs, rhs in
        if lhs.lowerBound == rhs.lowerBound {
          return lhs.upperBound > rhs.upperBound
        }
        return lhs.lowerBound < rhs.lowerBound
      }
  }
}

private struct QwenThinkTagParser {
  private enum State {
    case thinking
    case response
  }

  private struct ForbiddenMarker: Sendable {
    let value: String
    let failure: MLXThinkingBudgetFailure
  }

  private static let unexpectedChatBoundary = "<|im_start|>"

  private let configuration: ReasoningConfig
  private let forbiddenResponseMarkers: [ForbiddenMarker]?
  private var pending = ""
  private var state = State.thinking
  private var mayStartWithOpenMarker = true
  private var hasEmittedThinking = false

  var boundaryState: ReasoningTraceParser.BoundaryState {
    switch state {
    case .thinking:
      .open
    case .response:
      .closed
    }
  }

  init(validation: ReasoningTraceParser.QwenValidation?) {
    let configuration = QwenReasoningProtocol.tagged
    self.configuration = configuration
    forbiddenResponseMarkers = validation.map { validation in
      [
        ForbiddenMarker(
          value: configuration.startDelimiter,
          failure: .reopenedReasoning
        ),
        ForbiddenMarker(
          value: configuration.endDelimiter,
          failure: .duplicateReasoningClose
        ),
        ForbiddenMarker(
          value: Self.unexpectedChatBoundary,
          failure: .unexpectedChatBoundary
        ),
      ]
        + validation.responseStopStrings
        .filter { !$0.isEmpty }
        .sorted()
        .map {
          ForbiddenMarker(value: $0, failure: .unexpectedChatBoundary)
        }
    }
  }

  mutating func append(_ chunk: String) throws -> [ReasoningTraceParser.Segment] {
    pending += chunk
    var segments: [ReasoningTraceParser.Segment] = []

    while !pending.isEmpty {
      switch state {
      case .thinking:
        if mayStartWithOpenMarker {
          if pending.hasPrefix(configuration.startDelimiter) {
            pending.removeFirst(configuration.startDelimiter.count)
            mayStartWithOpenMarker = false
            continue
          }
          if pending.count < configuration.startDelimiter.count,
            configuration.startDelimiter.hasPrefix(pending)
          {
            return segments
          }
          mayStartWithOpenMarker = false
        }

        guard let endMarker = firstEndMarker(in: pending) else {
          let retained = longestSuffixMatchingAnyPrefix(
            in: pending,
            of: reasoningEndMarkers
          )
          let emitEnd = pending.index(pending.endIndex, offsetBy: -retained.count)
          appendSegment(.thinking(String(pending[..<emitEnd])), to: &segments)
          pending = retained
          return segments
        }

        appendSegment(
          .thinking(String(pending[..<endMarker.range.lowerBound])),
          to: &segments
        )
        if endMarker.value == configuration.endDelimiter {
          pending.removeSubrange(pending.startIndex..<endMarker.range.upperBound)
        } else {
          pending = String(pending[endMarker.range.lowerBound...])
        }
        state = .response
        mayStartWithOpenMarker = false
        hasEmittedThinking = false
        segments.append(.thinkingCompleted)
        continue
      case .response:
        try consumeResponse(into: &segments)
        return segments
      }
    }

    return segments
  }

  mutating func prepareForToolCall() -> [ReasoningTraceParser.Segment] {
    var segments: [ReasoningTraceParser.Segment] = []
    switch state {
    case .thinking:
      if !pending.isEmpty,
        !reasoningEndMarkers.contains(where: { $0.hasPrefix(pending) })
      {
        appendSegment(.thinking(pending), to: &segments)
      }
      pending = ""
      if hasEmittedThinking {
        segments.append(.thinkingCompleted)
      }
      state = .response
      mayStartWithOpenMarker = true
      hasEmittedThinking = false
    case .response:
      pending = ""
    }
    return segments
  }

  mutating func finish(
    discardingProtocolTail: Bool
  ) throws -> [ReasoningTraceParser.Segment] {
    guard !pending.isEmpty else {
      return []
    }
    defer { pending = "" }
    if discardingProtocolTail {
      return []
    }
    if state == .response,
      let forbiddenResponseMarkers,
      forbiddenResponseMarkers.contains(where: { $0.value.hasPrefix(pending) })
    {
      throw MLXThinkingBudgetFailure.truncatedProtocolMarker
    }
    return [state == .thinking ? .thinking(pending) : .visible(pending)]
  }

  private var reasoningEndMarkers: [String] {
    [configuration.endDelimiter]
      + configuration.implicitEndDelimiters.filter {
        $0 != configuration.endDelimiter
      }
  }

  private func firstEndMarker(
    in value: String
  ) -> (value: String, range: Range<String.Index>)? {
    reasoningEndMarkers.compactMap { marker in
      value.range(of: marker).map { (marker, $0) }
    }.min { lhs, rhs in
      if lhs.range.lowerBound == rhs.range.lowerBound {
        return lhs.range.upperBound > rhs.range.upperBound
      }
      return lhs.range.lowerBound < rhs.range.lowerBound
    }
  }

  private mutating func consumeResponse(
    into segments: inout [ReasoningTraceParser.Segment]
  ) throws {
    guard let forbiddenResponseMarkers else {
      appendSegment(.visible(pending), to: &segments)
      pending = ""
      return
    }
    if let failure = firstForbiddenMarker(
      in: pending,
      markers: forbiddenResponseMarkers
    )?.failure {
      throw failure
    }
    let retained = longestSuffixMatchingAnyPrefix(
      in: pending,
      of: forbiddenResponseMarkers.map(\.value)
    )
    let emitEnd = pending.index(pending.endIndex, offsetBy: -retained.count)
    appendSegment(.visible(String(pending[..<emitEnd])), to: &segments)
    pending = retained
  }

  private func firstForbiddenMarker(
    in value: String,
    markers: [ForbiddenMarker]
  ) -> (range: Range<String.Index>, failure: MLXThinkingBudgetFailure)? {
    markers.compactMap { marker in
      value.range(of: marker.value).map { ($0, marker.failure) }
    }.min { lhs, rhs in
      lhs.range.lowerBound < rhs.range.lowerBound
    }
  }

  private mutating func appendSegment(
    _ segment: ReasoningTraceParser.Segment,
    to segments: inout [ReasoningTraceParser.Segment]
  ) {
    switch segment {
    case .visible(let text), .thinking(let text):
      guard !text.isEmpty else {
        return
      }
      segments.append(segment)
      if case .thinking = segment {
        hasEmittedThinking = true
      }
    case .thinkingCompleted:
      segments.append(segment)
    }
  }
}

private func longestSuffixMatchingPrefix(in value: String, of marker: String) -> String {
  guard !value.isEmpty, !marker.isEmpty else {
    return ""
  }
  let maxLength = Swift.min(value.count, marker.count - 1)
  guard maxLength > 0 else {
    return ""
  }

  for length in stride(from: maxLength, through: 1, by: -1) {
    let suffix = String(value.suffix(length))
    if marker.hasPrefix(suffix) {
      return suffix
    }
  }
  return ""
}

private func longestSuffixMatchingAnyPrefix(
  in value: String,
  of markers: [String]
) -> String {
  markers
    .map { longestSuffixMatchingPrefix(in: value, of: $0) }
    .max { lhs, rhs in lhs.count < rhs.count } ?? ""
}
