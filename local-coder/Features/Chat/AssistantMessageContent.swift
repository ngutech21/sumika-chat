import LocalCoderCore
import MarkdownUI
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
  let highlightingBackend: any CodeHighlightingBackend

  init(
    blocks: [AssistantRenderBlock],
    highlightingBackend: any CodeHighlightingBackend = ChatCodeHighlightingBackend.shared
  ) {
    self.blocks = blocks
    self.highlightingBackend = highlightingBackend
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
            highlightingBackend: highlightingBackend
          )
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }
}

private enum ChatCodeHighlightingBackend {
  static let shared: any CodeHighlightingBackend = SwiftTreeSitterCodeHighlightingBackend()
}

struct CodeBlockView: View {
  let codeBlock: AssistantRenderBlock.CodeBlock
  let highlightingBackend: any CodeHighlightingBackend
  @State private var highlightedCode: HighlightedCode?

  init(
    codeBlock: AssistantRenderBlock.CodeBlock,
    highlightingBackend: any CodeHighlightingBackend = ChatCodeHighlightingBackend.shared
  ) {
    self.codeBlock = codeBlock
    self.highlightingBackend = highlightingBackend
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
      await updateHighlightedCode()
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
      language: codeBlock.language ?? ""
    )
  }

  private var highlightedText: Text {
    let currentHighlight =
      highlightedCode
      ?? .plain(
        code: codeBlock.text,
        language: normalizedLanguage
      )
    let code = currentHighlight.code.isEmpty ? visibleCodeText : currentHighlight.code
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

  @MainActor
  private func updateHighlightedCode() async {
    let language = normalizedLanguage
    let code = codeBlock.text
    highlightedCode = .plain(code: code, language: language)

    guard !codeBlock.text.isEmpty else {
      return
    }

    let backend = highlightingBackend

    do {
      let highlightedCode = try await backend.highlight(
        code: code,
        language: language,
        theme: .chat
      )
      guard !Task.isCancelled else {
        return
      }
      self.highlightedCode = highlightedCode
    } catch {
      guard !Task.isCancelled else {
        return
      }
      highlightedCode = .plain(code: code, language: language)
    }
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

private struct HighlightRequest: Equatable, Hashable {
  var code: String
  var language: String
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
