import SwiftUI

struct WorkspacePreviewHost: View {
  @Binding var htmlPreview: HTMLPreviewState?
  let htmlPreviewRequestID: UUID
  @Binding var filePreview: FilePreviewState?
  let browserToolService: HTMLPreviewBrowserToolService
  @State private var htmlPreviewRefreshID = UUID()
  @State private var htmlPreviewConsoleEntries: [HTMLPreviewConsoleEntry] = []

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = Self._printChanges()
    #endif

    previewContent
      .onChange(of: htmlPreviewRequestID) {
        resetHTMLPreviewConsole()
      }
  }

  @ViewBuilder
  private var previewContent: some View {
    if let htmlPreview {
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
          self.htmlPreview = nil
          Task {
            await browserToolService.clear()
          }
        }
      )
      .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    if let filePreview {
      FilePreviewPane(
        preview: filePreview,
        onClose: {
          self.filePreview = nil
        }
      )
      .transition(.move(edge: .trailing).combined(with: .opacity))
    }
  }

  private func resetHTMLPreviewConsole() {
    htmlPreviewConsoleEntries.removeAll()
  }
}
