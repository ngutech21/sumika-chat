import AppKit
import LocalCoderCore
import SwiftUI

/// A locally resolved, read-only view of a workspace text file. Produced by the
/// `/show` slash command. The content never enters the model context — it is
/// rendered straight into a side pane.
struct FilePreviewState: Equatable {
  let relativePath: WorkspaceRelativePath
  let content: String
  let lineCount: Int
  let byteCount: Int
  let truncated: Bool

  var title: String {
    let raw = relativePath.rawValue
    return raw.split(separator: "/").last.map(String.init) ?? raw
  }
}

enum FilePreviewResolutionError: LocalizedError, Equatable {
  case notAFile
  case notUTF8Text(String)

  var errorDescription: String? {
    switch self {
    case .notAFile:
      "/show path is not a file."
    case .notUTF8Text(let path):
      "/show only supports UTF-8 text files: \(path)"
    }
  }
}

struct FilePreviewResolver: Sendable {
  /// Upper bound on the bytes read into the viewer. Generous because the
  /// content stays local and never reaches the model.
  let maxBytes: Int

  init(maxBytes: Int = 1_024 * 1_024) {
    self.maxBytes = maxBytes
  }

  func resolve(path: String, in workspace: Workspace) throws -> FilePreviewState {
    try workspace.withSecurityScopedAccess {
      let resolvedURL = try workspace.resolveAllowedPath(path)

      var isDirectory: ObjCBool = false
      guard
        FileManager.default.fileExists(
          atPath: resolvedURL.path(percentEncoded: false),
          isDirectory: &isDirectory
        ), !isDirectory.boolValue
      else {
        throw FilePreviewResolutionError.notAFile
      }

      let relativePath = workspace.relativePath(for: resolvedURL)
      let (data, truncated) = try Self.readData(at: resolvedURL, maxBytes: maxBytes)
      guard let content = Self.decodeUTF8Tolerant(data) else {
        throw FilePreviewResolutionError.notUTF8Text(relativePath.rawValue)
      }

      return FilePreviewState(
        relativePath: relativePath,
        content: content,
        lineCount: Self.lineCount(of: content),
        byteCount: content.utf8.count,
        truncated: truncated
      )
    }
  }

  private static func readData(at url: URL, maxBytes: Int) throws -> (data: Data, truncated: Bool) {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    let limit = max(maxBytes, 0)
    let data = try handle.read(upToCount: limit + 1) ?? Data()
    if data.count > limit {
      return (data.prefix(limit), true)
    }
    return (data, false)
  }

  /// Decodes UTF-8, tolerating a few trailing bytes that may have been cut in
  /// the middle of a multi-byte code point by the byte cap.
  private static func decodeUTF8Tolerant(_ data: Data) -> String? {
    if let text = String(data: data, encoding: .utf8) {
      return text
    }
    for drop in 1...3 where data.count > drop {
      if let text = String(data: data.dropLast(drop), encoding: .utf8) {
        return text
      }
    }
    return nil
  }

  private static func lineCount(of content: String) -> Int {
    content.isEmpty ? 0 : content.split(separator: "\n", omittingEmptySubsequences: false).count
  }
}

struct FilePreviewPane: View {
  let preview: FilePreviewState
  let onClose: () -> Void
  @State private var didCopy = false

  var body: some View {
    VStack(spacing: 0) {
      header

      Divider()

      ScrollView([.vertical, .horizontal]) {
        Text(preview.content.isEmpty ? " " : preview.content)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(12)
      }
      .accessibilityIdentifier("file-preview-content")

      if preview.truncated {
        Divider()
        Label(
          "File truncated to the first \(preview.byteCount.formatted(.byteCount(style: .file)))",
          systemImage: "scissors"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }
    }
    .frame(minWidth: 360, idealWidth: 460)
    .background(.background)
    .overlay(alignment: .leading) {
      Divider()
    }
    .accessibilityIdentifier("file-preview-pane")
  }

  private var header: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(preview.title)
          .font(.headline)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Spacer()

      Button {
        copyContent()
      } label: {
        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
          .frame(width: 16, height: 16)
      }
      .buttonStyle(.borderless)
      .help(didCopy ? "Copied" : "Copy file contents")
      .accessibilityLabel("Copy file contents")
      .accessibilityIdentifier("file-preview-copy-button")

      Button(action: onClose) {
        Image(systemName: "xmark")
          .frame(width: 16, height: 16)
      }
      .buttonStyle(.borderless)
      .help("Hide file")
      .accessibilityLabel("Hide file")
      .accessibilityIdentifier("file-preview-close-button")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  private var subtitle: String {
    let lines = preview.lineCount
    let lineLabel = lines == 1 ? "1 line" : "\(lines.formatted(.number)) lines"
    let size = preview.byteCount.formatted(.byteCount(style: .file))
    return "\(preview.relativePath.rawValue) · \(lineLabel) · \(size)"
  }

  private func copyContent() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(preview.content, forType: .string)
    didCopy = true

    Task {
      try? await Task.sleep(for: .seconds(1.2))
      didCopy = false
    }
  }
}
