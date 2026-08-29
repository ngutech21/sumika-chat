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

    ZStack {
      previewContent
    }
    .onChange(of: previewState.htmlPreviewRequestID) {
      resetHTMLPreviewConsole()
    }
    .onChange(of: previewState.preview) { previousPreview, currentPreview in
      resetHTMLPreviewConsole()
      guard previousPreview?.isHTML == true,
        currentPreview != nil,
        currentPreview?.isHTML != true
      else {
        return
      }
      Task {
        await browserToolService.clear()
      }
    }
  }

  @ViewBuilder
  private var previewContent: some View {
    switch previewState.preview {
    case .html(let htmlPreview):
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
          previewState.closePreview()
          Task {
            await browserToolService.clear()
          }
        }
      )
      .transition(.move(edge: .trailing).combined(with: .opacity))

    case .file(let filePreview):
      FilePreviewPane(
        preview: filePreview,
        onClose: {
          previewState.closePreview()
        }
      )
      .transition(.move(edge: .trailing).combined(with: .opacity))

    case .skill(let skillPreview):
      SkillPreviewPane(
        preview: skillPreview,
        onClose: {
          previewState.closePreview()
        }
      )
      .transition(.move(edge: .trailing).combined(with: .opacity))

    case nil:
      EmptyView()
    }
  }

  private func resetHTMLPreviewConsole() {
    htmlPreviewConsoleEntries.removeAll()
  }
}
