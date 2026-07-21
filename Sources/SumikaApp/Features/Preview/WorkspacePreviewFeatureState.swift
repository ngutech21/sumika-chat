import Foundation
import Observation
import SumikaCore

@MainActor
@Observable
final class WorkspacePreviewFeatureState {
  var htmlPreview: HTMLPreviewState?
  var filePreview: FilePreviewState?
  var htmlPreviewRequestID = UUID()
  private(set) var errorMessage: String?

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

  @discardableResult
  func showHTMLPreview(path: String, in workspace: Workspace) -> Bool {
    do {
      htmlPreview = try htmlPreviewResolver.resolve(path: path, in: workspace)
      htmlPreviewRequestID = UUID()
      filePreview = nil
      errorMessage = nil
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  @discardableResult
  func showFilePreview(path: String, in workspace: Workspace) -> Bool {
    do {
      filePreview = try filePreviewResolver.resolve(path: path, in: workspace)
      htmlPreview = nil
      errorMessage = nil
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func clearError() {
    errorMessage = nil
  }

  func closeHTMLPreview() {
    htmlPreview = nil
  }

  func closeFilePreview() {
    filePreview = nil
  }

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  func closeAll() {
    htmlPreview = nil
    filePreview = nil
  }
}
