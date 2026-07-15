import SumikaCore

struct NativeTranscriptCodeHighlightDescriptor: Equatable, Hashable {
  var rowID: String
  var blockID: String
  var language: CodeLanguage?
  var isClosed: Bool
  var code: String

  init(rowID: String, codeBlock: AssistantRenderBlock.CodeBlock) {
    self.rowID = rowID
    blockID = codeBlock.id.rawValue
    language = CodeLanguage(fenceLanguage: codeBlock.language)
    isClosed = codeBlock.isClosed
    code = codeBlock.text
  }

  var highlightBlockID: CodeHighlightBlockID {
    CodeHighlightBlockID(rawValue: "\(rowID)#\(blockID)")
  }

  var highlightBlockKey: String {
    highlightBlockID.rawValue
  }
}

struct NativeTranscriptCodeHighlightKey: Equatable, Hashable {
  var descriptor: NativeTranscriptCodeHighlightDescriptor
  var version: Int
}

@MainActor
final class NativeTranscriptCodeHighlightStore {
  private let highlighter: StreamingCodeHighlighter
  private var nextVersionByBlockID: [String: Int] = [:]
  private var latestVersionByBlockID: [String: Int] = [:]
  private var latestKeyByDescriptor:
    [NativeTranscriptCodeHighlightDescriptor:
      NativeTranscriptCodeHighlightKey] = [:]
  private var inFlightKeyByDescriptor:
    [NativeTranscriptCodeHighlightDescriptor:
      NativeTranscriptCodeHighlightKey] = [:]
  private var highlightedCodeByKey: [NativeTranscriptCodeHighlightKey: HighlightedCode] = [:]

  init(
    highlighter: StreamingCodeHighlighter = ChatCodeHighlightingBackend.sharedStreamingHighlighter
  ) {
    self.highlighter = highlighter
  }

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  var cachedEntryCount: Int {
    highlightedCodeByKey.count
  }

  // Benchmark-only; keeps all cache dimensions visible without affecting policy.
  // swiftlint:disable:next unused_declaration
  var performanceEntryCountsForTesting: TranscriptPerformanceDiagnostics.HighlightStoreEntryCounts {
    TranscriptPerformanceDiagnostics.HighlightStoreEntryCounts(
      descriptors: latestKeyByDescriptor.count,
      inFlight: inFlightKeyByDescriptor.count,
      versions: nextVersionByBlockID.count + latestVersionByBlockID.count
    )
  }

  func highlightedCode(
    rowID: String,
    codeBlock: AssistantRenderBlock.CodeBlock
  ) -> HighlightedCode? {
    let descriptor = NativeTranscriptCodeHighlightDescriptor(rowID: rowID, codeBlock: codeBlock)
    guard let key = latestKeyByDescriptor[descriptor] else {
      return nil
    }
    return highlightedCodeByKey[key]
  }

  @discardableResult
  func beginHighlight(
    rowID: String,
    for codeBlock: AssistantRenderBlock.CodeBlock
  ) -> NativeTranscriptCodeHighlightKey? {
    let descriptor = NativeTranscriptCodeHighlightDescriptor(rowID: rowID, codeBlock: codeBlock)
    if highlightedCode(rowID: rowID, codeBlock: codeBlock) != nil
      || inFlightKeyByDescriptor[descriptor] != nil
    {
      return nil
    }

    let version = (nextVersionByBlockID[descriptor.highlightBlockKey] ?? 0) + 1
    nextVersionByBlockID[descriptor.highlightBlockKey] = version
    latestVersionByBlockID[descriptor.highlightBlockKey] = version

    let key = NativeTranscriptCodeHighlightKey(descriptor: descriptor, version: version)
    latestKeyByDescriptor[descriptor] = key
    inFlightKeyByDescriptor[descriptor] = key
    return key
  }

  func requestHighlight(
    rowID: String,
    codeBlock: AssistantRenderBlock.CodeBlock,
    onUpdate: @escaping @MainActor (String) -> Void
  ) {
    guard let key = beginHighlight(rowID: rowID, for: codeBlock) else {
      return
    }

    Task { [weak self, highlighter] in
      let result = await highlighter.highlight(
        CodeHighlightRequest(
          blockID: key.descriptor.highlightBlockID,
          version: key.version,
          code: key.descriptor.code,
          language: key.descriptor.language,
          isClosed: key.descriptor.isClosed
        )
      )

      await MainActor.run {
        guard let self else {
          return
        }
        _ = self.completeHighlight(result, for: key, rowID: rowID, onUpdate: onUpdate)
      }
    }
  }

  @discardableResult
  func completeHighlight(
    _ result: CodeHighlightResult?,
    for key: NativeTranscriptCodeHighlightKey,
    rowID: String,
    onUpdate: @MainActor (String) -> Void
  ) -> Bool {
    defer {
      if inFlightKeyByDescriptor[key.descriptor] == key {
        inFlightKeyByDescriptor[key.descriptor] = nil
      }
    }

    guard
      latestVersionByBlockID[key.descriptor.highlightBlockKey] == key.version,
      inFlightKeyByDescriptor[key.descriptor] == key,
      result?.blockID == key.descriptor.highlightBlockID,
      result?.version == key.version,
      let highlightedCode = result?.highlightedCode
    else {
      return false
    }

    highlightedCodeByKey[key] = highlightedCode
    onUpdate(rowID)
    return true
  }

  func prune(activeDescriptors: Set<NativeTranscriptCodeHighlightDescriptor>) {
    latestKeyByDescriptor = latestKeyByDescriptor.filter { activeDescriptors.contains($0.key) }
    highlightedCodeByKey = highlightedCodeByKey.filter {
      activeDescriptors.contains($0.key.descriptor)
    }
    inFlightKeyByDescriptor = inFlightKeyByDescriptor.filter { activeDescriptors.contains($0.key) }

    let activeBlockIDs = Set(activeDescriptors.map(\.highlightBlockKey))
    latestVersionByBlockID = latestVersionByBlockID.filter { activeBlockIDs.contains($0.key) }
    nextVersionByBlockID = nextVersionByBlockID.filter { activeBlockIDs.contains($0.key) }
  }
}
