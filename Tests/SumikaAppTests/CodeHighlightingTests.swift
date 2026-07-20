import SumikaCore
import Testing

@testable import SumikaApp

struct CodeHighlightingTests {
  @Test
  func streamingOpenBlockHighlightsOnlyStablePrefix() async {
    let backend = SpyCodeHighlightingBackend()
    let highlighter = StreamingCodeHighlighter(backend: backend, debounce: .zero)

    let result = await highlighter.highlight(
      CodeHighlightRequest(
        blockID: CodeHighlightBlockID(rawValue: "block-1"),
        version: 1,
        code: "print(\"hi\")\nret",
        language: .python,
        isClosed: false
      )
    )

    #expect(result?.highlightedCode.code == "print(\"hi\")\nret")
    #expect(result?.highlightedCode.spans.map(\.range.upperBound).max() == 12)
    #expect(await backend.requestedCodes() == ["print(\"hi\")\n"])
  }

  @Test
  func streamingOpenBlockWithoutStableLineStaysPlain() async {
    let backend = SpyCodeHighlightingBackend()
    let highlighter = StreamingCodeHighlighter(backend: backend, debounce: .zero)

    let result = await highlighter.highlight(
      CodeHighlightRequest(
        blockID: CodeHighlightBlockID(rawValue: "block-1"),
        version: 1,
        code: "ret",
        language: .python,
        isClosed: false
      )
    )

    #expect(result?.highlightedCode == .plain(code: "ret", language: .python))
    #expect(await backend.requestedCodes().isEmpty)
  }

  @Test
  func streamingClosedBlockHighlightsFullCode() async {
    let backend = SpyCodeHighlightingBackend()
    let highlighter = StreamingCodeHighlighter(backend: backend, debounce: .zero)

    let result = await highlighter.highlight(
      CodeHighlightRequest(
        blockID: CodeHighlightBlockID(rawValue: "block-1"),
        version: 1,
        code: "print(\"hi\")",
        language: .python,
        isClosed: true
      )
    )

    #expect(result?.highlightedCode.code == "print(\"hi\")")
    #expect(result?.highlightedCode.spans.map(\.range.upperBound).max() == 11)
    #expect(result?.cacheHit == false)
    #expect(await backend.requestedCodes() == ["print(\"hi\")"])
  }

  @Test
  func streamingClosedBlockUsesCache() async {
    let backend = SpyCodeHighlightingBackend()
    let highlighter = StreamingCodeHighlighter(backend: backend, debounce: .zero)
    let blockID = CodeHighlightBlockID(rawValue: "block-1")
    let code = #"{"name":"value"}"#

    let first = await highlighter.highlight(
      CodeHighlightRequest(
        blockID: blockID,
        version: 1,
        code: code,
        language: .json,
        isClosed: true
      )
    )
    let second = await highlighter.highlight(
      CodeHighlightRequest(
        blockID: blockID,
        version: 2,
        code: code,
        language: .json,
        isClosed: true
      )
    )

    #expect(first?.cacheHit == false)
    #expect(second?.cacheHit == true)
    #expect(await backend.requestedCodes() == [code])
  }

  @Test
  func streamingOpenBlocksAreNotCached() async {
    let backend = SpyCodeHighlightingBackend()
    let highlighter = StreamingCodeHighlighter(backend: backend, debounce: .zero)
    let blockID = CodeHighlightBlockID(rawValue: "block-1")
    let code = "echo \"hi\"\n"

    _ = await highlighter.highlight(
      CodeHighlightRequest(
        blockID: blockID,
        version: 1,
        code: code,
        language: .bash,
        isClosed: false
      )
    )
    _ = await highlighter.highlight(
      CodeHighlightRequest(
        blockID: blockID,
        version: 2,
        code: code,
        language: .bash,
        isClosed: false
      )
    )

    #expect(await backend.requestedCodes() == [code, code])
  }

  @Test
  func streamingStaleResultsAreDiscarded() async {
    let backend = ControlledCodeHighlightingBackend()
    let highlighter = StreamingCodeHighlighter(backend: backend, debounce: .zero)
    let blockID = CodeHighlightBlockID(rawValue: "block-1")
    defer {
      Task {
        await backend.releaseAll()
      }
    }

    let firstTask = Task {
      await highlighter.highlight(
        CodeHighlightRequest(
          blockID: blockID,
          version: 1,
          code: "echo \"old\"\n",
          language: .bash,
          isClosed: false
        )
      )
    }
    await backend.waitForRequestCount(1)
    let secondTask = Task {
      await highlighter.highlight(
        CodeHighlightRequest(
          blockID: blockID,
          version: 2,
          code: "echo \"new\"\n",
          language: .bash,
          isClosed: false
        )
      )
    }
    await backend.waitForRequestCount(2)
    await backend.releaseAll()

    let first = await firstTask.value
    let second = await secondTask.value

    #expect(first == nil)
    #expect(second?.version == 2)
  }

}

private actor ControlledCodeHighlightingBackend: CodeHighlightingBackend {
  private var requestCount = 0
  private var requestCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] =
    []
  private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

  func highlight(
    code: String,
    language: CodeLanguage?,
    theme _: CodeHighlightTheme
  ) async throws -> HighlightedCode {
    requestCount += 1
    resumeRequestCountWaiters()

    await withCheckedContinuation { continuation in
      releaseContinuations.append(continuation)
    }

    return HighlightedCode(
      code: code,
      language: language,
      spans: [
        HighlightSpan(
          range: HighlightTextRange(location: 0, length: code.utf16.count),
          style: .keyword,
          captureName: "keyword"
        )
      ]
    )
  }

  func waitForRequestCount(_ expectedCount: Int) async {
    guard requestCount < expectedCount else {
      return
    }

    await withCheckedContinuation { continuation in
      requestCountWaiters.append((expectedCount, continuation))
    }
  }

  func releaseAll() {
    let continuations = releaseContinuations
    releaseContinuations.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
  }

  private func resumeRequestCountWaiters() {
    var pendingWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    for waiter in requestCountWaiters {
      if requestCount >= waiter.count {
        waiter.continuation.resume()
      } else {
        pendingWaiters.append(waiter)
      }
    }
    requestCountWaiters = pendingWaiters
  }
}

private actor SpyCodeHighlightingBackend: CodeHighlightingBackend {
  private let delay: Duration?
  private var codes: [String] = []

  init(delay: Duration? = nil) {
    self.delay = delay
  }

  func highlight(
    code: String,
    language: CodeLanguage?,
    theme: CodeHighlightTheme
  ) async throws -> HighlightedCode {
    if let delay {
      try await Task.sleep(for: delay)
    }

    codes.append(code)
    return HighlightedCode(
      code: code,
      language: language,
      spans: [
        HighlightSpan(
          range: HighlightTextRange(location: 0, length: code.utf16.count),
          style: .keyword,
          captureName: "keyword"
        )
      ]
    )
  }

  func requestedCodes() -> [String] {
    codes
  }
}
