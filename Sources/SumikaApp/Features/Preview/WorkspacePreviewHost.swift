import SwiftUI

struct WorkspacePreviewHost: View {
  let previewState: WorkspacePreviewFeatureState
  let browserToolService: HTMLPreviewBrowserToolService
  @State private var htmlPreviewRefreshID = UUID()
  @State private var htmlPreviewConsoleEntries: [HTMLPreviewConsoleEntry] = []

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = Self._printChanges()
    #endif

    previewContent
      .onChange(of: previewState.htmlPreviewRequestID) {
        resetHTMLPreviewConsole()
      }
  }

  @ViewBuilder
  private var previewContent: some View {
    if let htmlPreview = previewState.htmlPreview {
      HTMLPreviewPane(
        preview: htmlPreview,
        refreshID: htmlPreviewRefreshID,
        browserToolService: browserToolService,
        consoleEntries: htmlPreviewConsoleEntries,
        onConsoleMessage: { entry in
          Task { @MainActor in
            htmlPreviewConsoleEntries.append(entry)
          }
        },
        onRefresh: {
          resetHTMLPreviewConsole()
          htmlPreviewRefreshID = UUID()
        },
        onClose: {
          resetHTMLPreviewConsole()
          previewState.closeHTMLPreview()
          Task {
            await browserToolService.clear()
          }
        }
      )
      .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    if let filePreview = previewState.filePreview {
      FilePreviewPane(
        preview: filePreview,
        onClose: {
          previewState.closeFilePreview()
        }
      )
      .transition(.move(edge: .trailing).combined(with: .opacity))
    }
  }

  private func resetHTMLPreviewConsole() {
    htmlPreviewConsoleEntries.removeAll()
  }
}
