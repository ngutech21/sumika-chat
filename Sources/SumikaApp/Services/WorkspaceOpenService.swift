import AppKit
import Foundation

enum WorkspaceOpenDestination: Equatable, Sendable {
  case finder
  case visualStudioCode
}

@MainActor
protocol WorkspaceOpening: AnyObject {
  func open(_ url: URL, destination: WorkspaceOpenDestination) async throws
}

@MainActor
final class MacWorkspaceOpenService: WorkspaceOpening {
  private let workspace: NSWorkspace
  private let fileManager: FileManager

  init(
    workspace: NSWorkspace = .shared,
    fileManager: FileManager = .default
  ) {
    self.workspace = workspace
    self.fileManager = fileManager
  }

  func open(_ url: URL, destination: WorkspaceOpenDestination) async throws {
    let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
    switch destination {
    case .finder:
      let didOpen = workspace.selectFile(
        nil,
        inFileViewerRootedAtPath: resolvedURL.path(percentEncoded: false)
      )
      if !didOpen {
        throw WorkspaceOpenError.openFailed("Finder")
      }
    case .visualStudioCode:
      let appURL = try visualStudioCodeApplicationURL()
      try await open(resolvedURL, withApplicationAt: appURL)
    }
  }

  private func visualStudioCodeApplicationURL() throws -> URL {
    if let appURL = workspace.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
      return appURL
    }

    let candidatePaths = [
      "/Applications/Visual Studio Code.app",
      "~/Applications/Visual Studio Code.app",
    ]

    for path in candidatePaths {
      let expandedPath = (path as NSString).expandingTildeInPath
      if fileManager.fileExists(atPath: expandedPath) {
        return URL(filePath: expandedPath, directoryHint: .isDirectory)
      }
    }

    throw WorkspaceOpenError.applicationNotFound("Visual Studio Code")
  }

  private func open(
    _ url: URL,
    withApplicationAt appURL: URL
  ) async throws {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      workspace.open(
        [url],
        withApplicationAt: appURL,
        configuration: configuration
      ) { _, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }
}

enum WorkspaceOpenError: LocalizedError, Equatable {
  case applicationNotFound(String)
  case noActiveWorkspace
  case openFailed(String)

  var errorDescription: String? {
    switch self {
    case .applicationNotFound(let appName):
      "\(appName) was not found in /Applications or ~/Applications."
    case .noActiveWorkspace:
      "No active workspace is selected."
    case .openFailed(let appName):
      "Could not open workspace in \(appName)."
    }
  }
}
