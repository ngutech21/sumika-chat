import Foundation
import Observation
import SumikaCore

@MainActor
@Observable
final class WorkspacePreviewFeatureState {
  var htmlPreview: HTMLPreviewState?
  var filePreview: FilePreviewState?
  var htmlPreviewRequestID = UUID()

  @ObservationIgnored private let htmlPreviewResolver: HTMLPreviewResolver
  @ObservationIgnored private let filePreviewResolver: FilePreviewResolver

  init(
    htmlPreviewResolver: HTMLPreviewResolver = HTMLPreviewResolver(),
    filePreviewResolver: FilePreviewResolver = FilePreviewResolver()
  ) {
    self.htmlPreviewResolver = htmlPreviewResolver
    self.filePreviewResolver = filePreviewResolver
  }

  var isVisible: Bool {
    htmlPreview != nil || filePreview != nil
  }

  func showHTMLPreview(path: String, in workspace: Workspace) throws {
    htmlPreview = try htmlPreviewResolver.resolve(path: path, in: workspace)
    htmlPreviewRequestID = UUID()
    filePreview = nil
  }

  func showFilePreview(path: String, in workspace: Workspace) throws {
    filePreview = try filePreviewResolver.resolve(path: path, in: workspace)
    htmlPreview = nil
  }

  func closeHTMLPreview() {
    htmlPreview = nil
  }

  func closeFilePreview() {
    filePreview = nil
  }

  func closeAll() {
    htmlPreview = nil
    filePreview = nil
  }
}
