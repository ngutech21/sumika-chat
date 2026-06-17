import Combine
import MarkdownUI
import SumikaCore
import SwiftUI

enum AssistantMessageRenderBlocks {
  static func blocks(for content: String) -> [AssistantRenderBlock] {
    AssistantRenderBlockParser().parse(
      AssistantMarkdownPreprocessor.renderableContent(for: content)
    )
  }
}

struct AssistantMessageContent: View {
  let blocks: [AssistantRenderBlock]
  let codeHighlighter: StreamingCodeHighlighter

  init(
    blocks: [AssistantRenderBlock],
    codeHighlighter: StreamingCodeHighlighter = ChatCodeHighlightingBackend
      .sharedStreamingHighlighter
  ) {
    self.blocks = blocks
    self.codeHighlighter = codeHighlighter
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(blocks) { block in
        switch block {
        case .paragraph(let paragraph):
          Markdown(paragraph.text)
            .markdownTheme(.chatMessage)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .codeBlock(let codeBlock):
          CodeBlockView(
            codeBlock: codeBlock,
            codeHighlighter: codeHighlighter
          )
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }
}

private enum ChatCodeHighlightingBackend {
  private static let sharedBackend: any CodeHighlightingBackend =
    SwiftTreeSitterCodeHighlightingBackend()
  static let sharedStreamingHighlighter = StreamingCodeHighlighter(backend: sharedBackend)
}

struct CodeBlockView: View {
  let codeBlock: AssistantRenderBlock.CodeBlock
  let codeHighlighter: StreamingCodeHighlighter
  @StateObject private var highlightModel = CodeBlockHighlightModel()

  init(
    codeBlock: AssistantRenderBlock.CodeBlock,
    codeHighlighter: StreamingCodeHighlighter = ChatCodeHighlightingBackend
      .sharedStreamingHighlighter
  ) {
    self.codeBlock = codeBlock
    self.codeHighlighter = codeHighlighter
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let language = codeBlock.language, !language.isEmpty {
        Text(language)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.secondary.opacity(0.12))
          .accessibilityIdentifier("chat.assistantCodeBlock.language")
      }

      ScrollView(.horizontal, showsIndicators: false) {
        highlightedText
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .fixedSize(horizontal: true, vertical: false)
          .padding(10)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Color.secondary.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
    }
    .accessibilityIdentifier("chat.assistantCodeBlock")
    .task(id: highlightRequest) {
      await highlightModel.update(
        codeBlock: codeBlock,
        highlighter: codeHighlighter
      )
    }
  }

  private var visibleCodeText: String {
    if codeBlock.text.isEmpty {
      return " "
    }
    return codeBlock.text
  }

  private var normalizedLanguage: CodeLanguage? {
    CodeLanguage(fenceLanguage: codeBlock.language)
  }

  private var highlightRequest: HighlightRequest {
    HighlightRequest(
      code: codeBlock.text,
      language: codeBlock.language ?? "",
      isClosed: codeBlock.isClosed
    )
  }

  private var highlightedText: Text {
    let currentHighlight =
      highlightModel.highlightedCode
      ?? .plain(
        code: codeBlock.text,
        language: normalizedLanguage
      )
    let code = codeBlock.text.isEmpty ? visibleCodeText : codeBlock.text
    guard !currentHighlight.spans.isEmpty else {
      return Text(code)
    }

    var segments: [Text] = []
    var currentIndex = code.startIndex

    for span in currentHighlight.spans {
      guard
        let spanRange = Range(span.range.nsRange, in: code),
        currentIndex <= spanRange.lowerBound,
        spanRange.lowerBound < spanRange.upperBound
      else {
        continue
      }

      if currentIndex < spanRange.lowerBound {
        segments.append(Text(String(code[currentIndex..<spanRange.lowerBound])))
      }

      segments.append(
        Text(String(code[spanRange]))
          .foregroundColor(color(for: span.style))
      )

      currentIndex = spanRange.upperBound
    }

    if currentIndex < code.endIndex {
      segments.append(Text(String(code[currentIndex..<code.endIndex])))
    }

    return segments.reduce(Text(""), +)
  }

  private func color(for style: CodeHighlightStyle) -> Color {
    switch style {
    case .attribute:
      Color(nsColor: .systemPurple)
    case .comment:
      Color.secondary
    case .constant:
      Color(nsColor: .systemOrange)
    case .function:
      Color(nsColor: .systemBlue)
    case .keyword:
      Color(nsColor: .systemPink)
    case .number:
      Color(nsColor: .systemOrange)
    case .operatorToken:
      Color(nsColor: .systemGray)
    case .property:
      Color(nsColor: .systemTeal)
    case .punctuation:
      Color.secondary
    case .string:
      Color(nsColor: .systemGreen)
    case .type:
      Color(nsColor: .systemIndigo)
    case .variable:
      Color.primary
    }
  }
}

@MainActor
private final class CodeBlockHighlightModel: ObservableObject {
  @Published var highlightedCode: HighlightedCode?

  private var currentBlockID: CodeHighlightBlockID?
  private var currentVersion = 0
  private var currentCode = ""
  private var currentLanguage: CodeLanguage?

  func update(
    codeBlock: AssistantRenderBlock.CodeBlock,
    highlighter: StreamingCodeHighlighter
  ) async {
    let blockID = CodeHighlightBlockID(rawValue: codeBlock.id.rawValue)
    let language = CodeLanguage(fenceLanguage: codeBlock.language)
    currentVersion += 1
    let version = currentVersion

    if shouldResetHighlight(blockID: blockID, code: codeBlock.text, language: language) {
      highlightedCode = .plain(code: codeBlock.text, language: language)
    }

    currentBlockID = blockID
    currentCode = codeBlock.text
    currentLanguage = language

    let request = CodeHighlightRequest(
      blockID: blockID,
      version: version,
      code: codeBlock.text,
      language: language,
      theme: .chat,
      isClosed: codeBlock.isClosed
    )

    guard let result = await highlighter.highlight(request) else {
      return
    }

    guard
      !Task.isCancelled,
      currentBlockID == result.blockID,
      currentVersion == result.version
    else {
      return
    }

    highlightedCode = result.highlightedCode
  }

  private func shouldResetHighlight(
    blockID: CodeHighlightBlockID,
    code: String,
    language: CodeLanguage?
  ) -> Bool {
    guard currentBlockID == blockID, currentLanguage == language else {
      return true
    }

    return !code.hasPrefix(currentCode)
  }
}

private struct HighlightRequest: Equatable, Hashable {
  var code: String
  var language: String
  var isClosed: Bool
}

extension Theme {
  static let chatMessage = Theme()
    .text {
      ForegroundColor(.primary)
      FontSize(13)
    }
    .code {
      FontFamilyVariant(.monospaced)
      FontSize(.em(0.92))
      ForegroundColor(.primary)
      BackgroundColor(.secondary.opacity(0.16))
    }
    .link {
      ForegroundColor(.accentColor)
      UnderlineStyle(.single)
    }
    .paragraph { configuration in
      configuration.label
        .relativeLineSpacing(.em(0.2))
        .markdownMargin(top: 0, bottom: 8)
    }
    .listItem { configuration in
      configuration.label
        .markdownMargin(top: 2, bottom: 2)
    }
    .blockquote { configuration in
      HStack(spacing: 0) {
        Rectangle()
          .fill(Color.secondary.opacity(0.45))
          .frame(width: 3)
        configuration.label
          .padding(.leading, 8)
          .markdownTextStyle {
            ForegroundColor(.secondary)
          }
      }
      .markdownMargin(top: 4, bottom: 8)
    }
}
