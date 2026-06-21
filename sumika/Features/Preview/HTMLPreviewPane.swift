import SumikaCore
import SwiftUI

struct HTMLPreviewPane: View {
  let preview: HTMLPreviewState
  let refreshID: UUID
  let browserToolService: HTMLPreviewBrowserToolService
  let consoleEntries: [HTMLPreviewConsoleEntry]
  let onConsoleMessage: @Sendable (HTMLPreviewConsoleEntry) -> Void
  let onRefresh: () -> Void
  let onClose: () -> Void
  @State private var isConsoleVisible = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(preview.title)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.middle)
          Text(preview.relativePath.rawValue)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Spacer()

        Button {
          isConsoleVisible.toggle()
        } label: {
          Image(systemName: isConsoleVisible ? "terminal.fill" : "terminal")
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .help(isConsoleVisible ? "Hide console" : "Show console")
        .accessibilityLabel(isConsoleVisible ? "Hide console" : "Show console")
        .accessibilityIdentifier("html-preview-console-toggle-button")

        Button(action: onRefresh) {
          Image(systemName: "arrow.clockwise")
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .help("Refresh preview")
        .accessibilityLabel("Refresh preview")
        .accessibilityIdentifier("html-preview-refresh-button")

        Button(action: onClose) {
          Image(systemName: "xmark")
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .help("Hide preview")
        .accessibilityLabel("Hide preview")
        .accessibilityIdentifier("html-preview-close-button")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)

      Divider()

      HTMLPreviewWebView(
        preview: preview,
        refreshID: refreshID,
        browserToolService: browserToolService,
        onConsoleMessage: onConsoleMessage
      )
      .accessibilityIdentifier("html-preview-webview")

      if isConsoleVisible {
        Divider()

        HTMLPreviewConsolePanel(entries: consoleEntries)
          .transition(.opacity.combined(with: .move(edge: .bottom)))
      }
    }
    .frame(minWidth: 360, idealWidth: 460)
    .background(.background)
    .overlay(alignment: .leading) {
      Divider()
    }
    .accessibilityIdentifier("html-preview-pane")
  }
}

private struct HTMLPreviewConsolePanel: View {
  let entries: [HTMLPreviewConsoleEntry]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Label("Console", systemImage: "terminal")
          .font(.caption.weight(.semibold))

        Spacer()

        Text("\(entries.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 8) {
            if entries.isEmpty {
              Text("No console output yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else {
              ForEach(entries) { entry in
                HTMLPreviewConsoleEntryRow(entry: entry)
                  .id(entry.id)
              }
            }
          }
          .padding(.vertical, 10)
        }
        .onChange(of: entries.count) {
          guard let lastEntry = entries.last else {
            return
          }
          proxy.scrollTo(lastEntry.id, anchor: .bottom)
        }
      }
    }
    .frame(height: 180)
    .background(Color(nsColor: .controlBackgroundColor))
    .accessibilityIdentifier("html-preview-console-panel")
  }
}

private struct HTMLPreviewConsoleEntryRow: View {
  let entry: HTMLPreviewConsoleEntry

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: entry.level.systemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(entry.level.tint)
        .frame(width: 14)

      VStack(alignment: .leading, spacing: 2) {
        Text(entry.message)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)

        if let detailText = entry.detailText {
          Text(detailText)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
  }
}
