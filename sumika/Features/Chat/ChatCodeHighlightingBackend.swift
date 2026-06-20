import SumikaCore

enum ChatCodeHighlightingBackend {
  private static let sharedBackend: any CodeHighlightingBackend =
    SwiftTreeSitterCodeHighlightingBackend()

  static let sharedStreamingHighlighter = StreamingCodeHighlighter(backend: sharedBackend)
}
