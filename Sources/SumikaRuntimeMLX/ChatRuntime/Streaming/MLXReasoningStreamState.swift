import Foundation

/// Tracks completion of native reasoning events and validates only extracted response text.
struct MLXReasoningStreamState {
  enum BoundaryState: Equatable {
    case absent
    case open
    case closed

    var isOpen: Bool { self == .open }
    var isClosed: Bool { self == .closed }
  }

  enum Segment: Equatable {
    case visible(String)
    case thinking(String)
    case thinkingCompleted
  }

  private(set) var boundaryState = BoundaryState.absent
  private let forbiddenResponseMarkers: [String]
  private var pending = ""

  init(responseStopStrings: Set<String>? = nil) {
    forbiddenResponseMarkers =
      responseStopStrings.map {
        ["<|im_start|>"] + $0.filter { !$0.isEmpty }.sorted()
      } ?? []
  }

  mutating func appendReasoning(_ text: String) throws -> [Segment] {
    guard !text.isEmpty else { return [] }
    // A protocol prefix cannot span different semantic channels.
    _ = try finish()
    boundaryState = .open
    return [.thinking(text)]
  }

  mutating func appendResponse(_ text: String) throws -> [Segment] {
    pending += text
    guard !pending.isEmpty else { return [] }
    if forbiddenResponseMarkers.contains(where: pending.contains) {
      throw MLXThinkingBudgetFailure.unexpectedChatBoundary
    }
    let retained =
      forbiddenResponseMarkers.map { marker in
        let count = min(pending.count, marker.count - 1)
        guard count > 0 else { return "" }
        for length in stride(from: count, through: 1, by: -1) {
          let suffix = String(pending.suffix(length))
          if marker.hasPrefix(suffix) { return suffix }
        }
        return ""
      }.max { $0.count < $1.count } ?? ""
    let visible = String(pending.dropLast(retained.count))
    pending = retained
    guard !visible.isEmpty else { return [] }
    return completeReasoning() + [.visible(visible)]
  }

  mutating func prepareForToolCall() throws -> [Segment] {
    _ = try finish()
    return completeReasoning()
  }

  mutating func finish(discardingProtocolTail: Bool = false) throws -> [Segment] {
    defer { pending = "" }
    if !pending.isEmpty, !discardingProtocolTail {
      throw MLXThinkingBudgetFailure.truncatedProtocolMarker
    }
    return []
  }

  private mutating func completeReasoning() -> [Segment] {
    guard boundaryState == .open else { return [] }
    boundaryState = .closed
    return [.thinkingCompleted]
  }
}
