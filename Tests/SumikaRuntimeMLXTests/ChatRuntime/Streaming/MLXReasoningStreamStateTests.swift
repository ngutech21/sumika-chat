import Testing

@testable import SumikaRuntimeMLX

struct MLXReasoningStreamStateTests {
  @Test
  func nativeChannelsKeepLiteralMarkersAndCompleteBeforeAnswer() throws {
    var state = MLXReasoningStreamState()
    #expect(state.boundaryState == .absent)
    #expect(try state.appendReasoning("plan <think>") == [.thinking("plan <think>")])
    #expect(try state.appendResponse("") == [])
    #expect(state.boundaryState == .open)
    #expect(
      try state.appendResponse("literal </think>") == [
        .thinkingCompleted, .visible("literal </think>"),
      ])
    #expect(try state.appendResponse("answer") == [.visible("answer")])
    #expect(state.boundaryState == .closed)
  }

  @Test
  func onlyAnswerOrToolEvidenceCompletesThinking() throws {
    var state = MLXReasoningStreamState()
    #expect(try state.appendReasoning("plan") == [.thinking("plan")])
    #expect(try state.finish() == [])
    #expect(try state.finish(discardingProtocolTail: true) == [])
    #expect(state.boundaryState == .open)
    #expect(try state.prepareForToolCall() == [.thinkingCompleted])
    #expect(try state.prepareForToolCall() == [])
    #expect(state.boundaryState == .closed)
  }

  @Test
  func eachNativeThinkingSpanHasItsOwnCompletion() throws {
    var state = MLXReasoningStreamState()
    _ = try state.appendReasoning("first")
    #expect(try state.appendResponse("one") == [.thinkingCompleted, .visible("one")])
    _ = try state.appendReasoning("second")
    #expect(state.boundaryState == .open)
    #expect(try state.prepareForToolCall() == [.thinkingCompleted])
  }

  @Test(arguments: ["<|im_start|>", "configured-stop"])
  func responseValidationCatchesEveryMarkerSplit(marker: String) throws {
    for offset in 0...marker.count {
      var state = MLXReasoningStreamState(responseStopStrings: ["configured-stop"])
      let index = marker.index(marker.startIndex, offsetBy: offset)
      #expect(throws: MLXThinkingBudgetFailure.unexpectedChatBoundary) {
        _ = try state.appendResponse(String(marker[..<index]))
        _ = try state.appendResponse(String(marker[index...]))
      }
    }
  }

  @Test
  func onlyNormalCompletionRejectsPartialResponseMarkers() throws {
    var state = MLXReasoningStreamState(responseStopStrings: [])
    #expect(try state.appendResponse("answer<|im_sta") == [.visible("answer")])
    #expect(throws: MLXThinkingBudgetFailure.truncatedProtocolMarker) {
      _ = try state.finish()
    }
    _ = try state.appendResponse("<|im_sta")
    #expect(try state.finish(discardingProtocolTail: true) == [])
    #expect(try state.appendResponse("later") == [.visible("later")])
  }

  @Test
  func validationNeverInspectsThinkingOrReinterpretsLiteralReasoningTags() throws {
    var state = MLXReasoningStreamState(responseStopStrings: ["configured-stop"])
    #expect(
      try state.appendReasoning("<|im_start|>configured-stop") == [
        .thinking("<|im_start|>configured-stop")
      ])
    #expect(
      try state.appendResponse("<think>literal</think>") == [
        .thinkingCompleted, .visible("<think>literal</think>"),
      ])
  }
}
