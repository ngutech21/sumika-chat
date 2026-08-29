import AppKit
import SumikaCore
import SwiftUI

struct SkillPreviewRequest: Equatable, Sendable {
  let skill: ActivatedSkill
  let displayName: String
}

struct SkillPreviewState: Equatable {
  let title: String
  let portablePath: String
  let rawContent: String
  let content: Content

  enum Content: Equatable {
    case markdown(String)
    case empty
    case unformatted(String)
  }

  init(request: SkillPreviewRequest) {
    title = request.displayName
    portablePath = request.skill.portablePath
    rawContent = request.skill.content
    guard let body = SkillCatalog.persistedMarkdownBody(in: request.skill) else {
      content = .unformatted(request.skill.content)
      return
    }
    content =
      body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? .empty
      : .markdown(body)
  }
}

struct SkillPreviewPane: View {
  let preview: SkillPreviewState
  let onClose: () -> Void
  @State private var didCopy = false

  var body: some View {
    VStack(spacing: 0) {
      header

      Divider()

      content
    }
    .frame(minWidth: 360, idealWidth: 460)
    .background(.background)
    .overlay(alignment: .leading) {
      Divider()
    }
    .accessibilityIdentifier("skill-preview-pane")
  }

  private var header: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(preview.title)
          .font(.headline)
          .lineLimit(1)
          .truncationMode(.middle)
          .accessibilityIdentifier("skill-preview-title")
        Text("Used in this message · \(preview.portablePath)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .accessibilityIdentifier("skill-preview-subtitle")
      }

      Spacer()

      Button {
        copyContent()
      } label: {
        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
          .frame(width: 16, height: 16)
      }
      .buttonStyle(.borderless)
      .help(didCopy ? "Copied" : "Copy skill source")
      .accessibilityLabel("Copy skill source")
      .accessibilityIdentifier("skill-preview-copy-button")

      Button(action: onClose) {
        Image(systemName: "xmark")
          .frame(width: 16, height: 16)
      }
      .buttonStyle(.borderless)
      .help("Hide skill")
      .accessibilityLabel("Hide skill")
      .accessibilityIdentifier("skill-preview-close-button")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  @ViewBuilder
  private var content: some View {
    switch preview.content {
    case .markdown(let markdown):
      ScrollView(.vertical) {
        SkillMarkdownPreview(markdown: markdown)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(12)
      }
      .accessibilityIdentifier("skill-preview-content")

    case .empty:
      ContentUnavailableView(
        "This skill contains no instructions.",
        systemImage: "text.page"
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityIdentifier("skill-preview-empty-content")

    case .unformatted(let source):
      VStack(alignment: .leading, spacing: 0) {
        Label("Could not format this skill", systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)

        Divider()

        ScrollView([.vertical, .horizontal]) {
          Text(source.isEmpty ? " " : source)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(12)
        }
      }
      .accessibilityIdentifier("skill-preview-unformatted-content")
    }
  }

  private func copyContent() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(preview.rawContent, forType: .string)
    didCopy = true

    Task {
      try? await Task.sleep(for: .seconds(1.2))
      didCopy = false
    }
  }
}

private struct SkillMarkdownPreview: NSViewRepresentable {
  let markdown: String

  func makeNSView(context _: Context) -> NativeSkillMarkdownBlocksView {
    let view = NativeSkillMarkdownBlocksView()
    view.update(markdown: markdown)
    return view
  }

  func updateNSView(_ view: NativeSkillMarkdownBlocksView, context _: Context) {
    view.update(markdown: markdown)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView: NativeSkillMarkdownBlocksView,
    context _: Context
  ) -> CGSize? {
    let width = max(proposal.width ?? nsView.fittingSize.width, 1)
    nsView.setFrameSize(NSSize(width: width, height: nsView.frame.height))
    nsView.layoutSubtreeIfNeeded()
    return CGSize(width: width, height: ceil(nsView.fittingSize.height))
  }
}

private final class NativeSkillMarkdownBlocksView: NSStackView {
  private var renderedMarkdown: String?
  private var entryWidthConstraints: [NSLayoutConstraint] = []

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    orientation = .vertical
    alignment = .leading
    distribution = .gravityAreas
    spacing = 8
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Skill instructions")
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(markdown: String) {
    guard renderedMarkdown != markdown else {
      return
    }
    renderedMarkdown = markdown
    for constraint in entryWidthConstraints {
      constraint.isActive = false
    }
    entryWidthConstraints.removeAll()
    NativeReusableRowViewStyle.removeAllArrangedSubviews(from: self)

    for block in NativeTranscriptMarkdownRenderer.skillPreviewBlocks(for: markdown) {
      let view: NSView
      switch block {
      case .text(let attributedString):
        let textView = NativeTranscriptTextView(openLink: Self.openWebLink)
        textView.setAttributedText(attributedString)
        view = textView
      case .table(let table):
        view = NativeTranscriptTableView(table: table, openLink: Self.openWebLink)
      }
      addArrangedSubview(view)
      let widthConstraint = view.widthAnchor.constraint(equalTo: widthAnchor)
      widthConstraint.isActive = true
      entryWidthConstraints.append(widthConstraint)
    }
  }

  private static func openWebLink(_ url: URL) {
    guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
      return
    }
    NSWorkspace.shared.open(url)
  }
}
