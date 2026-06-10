import LocalCoderCore
import SwiftUI
import WebKit

struct HTMLPreviewState: Equatable {
  let url: URL
  let readAccessRootURL: URL
  let relativePath: WorkspaceRelativePath

  var title: String {
    url.lastPathComponent
  }
}

enum HTMLPreviewResolutionError: LocalizedError, Equatable {
  case unsupportedFileType(String)
  case notAFile

  var errorDescription: String? {
    switch self {
    case .unsupportedFileType(let path):
      "Preview only supports HTML files: \(path)"
    case .notAFile:
      "Preview path is not a file."
    }
  }
}

struct HTMLPreviewResolver: Sendable {
  func resolve(path: String, in workspace: Workspace) throws -> HTMLPreviewState {
    try workspace.withSecurityScopedAccess {
      let resolvedURL = try workspace.resolveAllowedPath(path)
      let fileExtension = resolvedURL.pathExtension.lowercased()
      guard fileExtension == "html" || fileExtension == "htm" else {
        throw HTMLPreviewResolutionError.unsupportedFileType(path)
      }

      var isDirectory: ObjCBool = false
      guard
        FileManager.default.fileExists(
          atPath: resolvedURL.path(percentEncoded: false),
          isDirectory: &isDirectory
        ), !isDirectory.boolValue
      else {
        throw HTMLPreviewResolutionError.notAFile
      }

      return HTMLPreviewState(
        url: resolvedURL,
        readAccessRootURL: workspace.rootURL,
        relativePath: workspace.relativePath(for: resolvedURL)
      )
    }
  }
}

struct HTMLPreviewPane: View {
  let preview: HTMLPreviewState
  let onClose: () -> Void

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

      HTMLPreviewWebView(preview: preview)
        .accessibilityIdentifier("html-preview-webview")
    }
    .frame(minWidth: 360, idealWidth: 460)
    .background(.background)
    .overlay(alignment: .leading) {
      Divider()
    }
    .accessibilityIdentifier("html-preview-pane")
  }
}

struct HTMLPreviewWebView: NSViewRepresentable {
  let preview: HTMLPreviewState

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.allowsBackForwardNavigationGestures = true
    webView.setValue(false, forKey: "drawsBackground")
    webView.navigationDelegate = context.coordinator
    webView.setAccessibilityIdentifier("html-preview-webview")
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    context.coordinator.preview = preview
    guard webView.url != preview.url else {
      return
    }
    webView.loadFileURL(preview.url, allowingReadAccessTo: preview.readAccessRootURL)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(preview: preview)
  }

  final class Coordinator: NSObject, WKNavigationDelegate {
    var preview: HTMLPreviewState

    init(preview: HTMLPreviewState) {
      self.preview = preview
    }
  }
}
