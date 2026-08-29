import Foundation
import Observation
import SumikaCore

enum WorkspacePreview: Equatable {
  case html(HTMLPreviewState)
  case file(FilePreviewState)
  case skill(SkillPreviewState)

  var isHTML: Bool {
    if case .html = self {
      return true
    }
    return false
  }
}

@MainActor
@Observable
final class WorkspacePreviewFeatureState {
  private(set) var preview: WorkspacePreview?
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
    preview != nil
  }

  @discardableResult
  func showHTMLPreview(path: String, in workspace: Workspace) -> Bool {
    do {
      preview = .html(try htmlPreviewResolver.resolve(path: path, in: workspace))
      htmlPreviewRequestID = UUID()
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
      preview = .file(try filePreviewResolver.resolve(path: path, in: workspace))
      errorMessage = nil
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func showSkillPreview(_ request: SkillPreviewRequest) {
    preview = .skill(SkillPreviewState(request: request))
    errorMessage = nil
  }

  func clearError() {
    errorMessage = nil
  }

  func closePreview() {
    preview = nil
  }
}
