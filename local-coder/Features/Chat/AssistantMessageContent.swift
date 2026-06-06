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

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(blocks) { block in
        switch block {
        case .paragraph(let paragraph):
          Markdown(paragraph.text)
            .markdownTheme(.chatMessage)
        case .codeBlock(let codeBlock):
          CodeBlockView(codeBlock: codeBlock)
        }
      }
    }
  }
}

struct CodeBlockView: View {
  let codeBlock: AssistantRenderBlock.CodeBlock

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
        Text(visibleCodeText)
          .font(.system(.body, design: .monospaced))
          .foregroundStyle(.primary)
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
  }

  private var visibleCodeText: String {
    if codeBlock.text.isEmpty {
      return " "
    }
    return codeBlock.text
  }
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
    .codeBlock { configuration in
      ScrollView(.horizontal, showsIndicators: true) {
        configuration.label
          .markdownTextStyle {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
            BackgroundColor(nil)
          }
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .markdownMargin(top: 4, bottom: 8)
    }
}
