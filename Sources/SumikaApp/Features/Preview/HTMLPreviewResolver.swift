import Foundation
import SumikaCore

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
