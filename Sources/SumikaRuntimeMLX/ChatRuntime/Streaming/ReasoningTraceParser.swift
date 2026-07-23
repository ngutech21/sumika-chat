import SumikaCore

struct ReasoningTraceParser {
  enum Segment: Equatable {
    case visible(String)
    case thinking(String)
  }

  private enum Storage {
    case none(PassThroughReasoningTraceParser)
    case gemma(GemmaThoughtChannelParser)
    case qwen(QwenThinkTagParser)
  }

  private var storage: Storage

  init(format: ReasoningTraceFormat) {
    storage =
      switch format {
      case .none:
        .none(PassThroughReasoningTraceParser())
      case .gemmaChannel:
        .gemma(GemmaThoughtChannelParser())
      case .qwenThinkTags:
        .qwen(QwenThinkTagParser())
      }
  }

  mutating func append(_ chunk: String) -> [Segment] {
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
      let segments = parser.append(chunk)
      storage = .qwen(parser)
      return segments
    }
  }

  mutating func finish() -> [Segment] {
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
      let segments = parser.finish()
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
}

private struct GemmaThoughtChannelParser {
  private static let thoughtMarkers = [
    "<|channel|>thought",
    "<|channel>thought",
  ]
  private static let closeMarker = "<channel|>"

  private var pending = ""
  private var isReadingThought = false

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
        continue
      }

      if let thoughtRange = Self.firstMarkerRange(in: pending, markers: Self.thoughtMarkers) {
        appendSegment(.visible(String(pending[..<thoughtRange.lowerBound])), to: &segments)
        pending.removeSubrange(pending.startIndex..<thoughtRange.upperBound)
        isReadingThought = true
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
    defer {
      pending = ""
      isReadingThought = false
    }
    guard !pending.isEmpty else {
      return []
    }
    return [isReadingThought ? .thinking(pending) : .visible(pending)]
  }

  private func appendSegment(
    _ segment: ReasoningTraceParser.Segment,
    to segments: inout [ReasoningTraceParser.Segment]
  ) {
    switch segment {
    case .visible(let text), .thinking(let text):
      guard !text.isEmpty else {
        return
      }
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
  private static let openMarker = "<think>"
  private static let closeMarker = "</think>"

  private var pending = ""
  private var isReadingThinking = true
  private var mayStartWithOpenMarker = true

  mutating func append(_ chunk: String) -> [ReasoningTraceParser.Segment] {
    pending += chunk
    var segments: [ReasoningTraceParser.Segment] = []

    while !pending.isEmpty {
      if isReadingThinking {
        if mayStartWithOpenMarker {
          if pending.hasPrefix(Self.openMarker) {
            pending.removeFirst(Self.openMarker.count)
            mayStartWithOpenMarker = false
            continue
          }
          if pending.count < Self.openMarker.count, Self.openMarker.hasPrefix(pending) {
            return segments
          }
          mayStartWithOpenMarker = false
        }

        guard let closeRange = pending.range(of: Self.closeMarker) else {
          let retained = longestSuffixMatchingPrefix(in: pending, of: Self.closeMarker)
          let emitEnd = pending.index(pending.endIndex, offsetBy: -retained.count)
          appendSegment(.thinking(String(pending[..<emitEnd])), to: &segments)
          pending = retained
          return segments
        }

        appendSegment(.thinking(String(pending[..<closeRange.lowerBound])), to: &segments)
        pending.removeSubrange(pending.startIndex..<closeRange.upperBound)
        isReadingThinking = false
        continue
      }

      appendSegment(.visible(pending), to: &segments)
      pending = ""
    }

    return segments
  }

  mutating func finish() -> [ReasoningTraceParser.Segment] {
    defer {
      pending = ""
      isReadingThinking = true
      mayStartWithOpenMarker = true
    }
    guard !pending.isEmpty else {
      return []
    }
    return [isReadingThinking ? .thinking(pending) : .visible(pending)]
  }

  private func appendSegment(
    _ segment: ReasoningTraceParser.Segment,
    to segments: inout [ReasoningTraceParser.Segment]
  ) {
    switch segment {
    case .visible(let text), .thinking(let text):
      guard !text.isEmpty else {
        return
      }
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
