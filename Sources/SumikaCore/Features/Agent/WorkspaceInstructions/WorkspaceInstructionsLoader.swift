// Crypto is used directly here; the analyzer compiler log does not attribute it reliably.
// swiftlint:disable:next unused_import
import Crypto
import Foundation

internal struct WorkspaceInstructionsDocument: Equatable, Sendable {
  package let path: WorkspaceRelativePath
  package let contentHash: String
  package let content: String

  package init(
    path: WorkspaceRelativePath,
    contentHash: String,
    content: String
  ) {
    self.path = path
    self.contentHash = contentHash
    self.content = content
  }
}

internal enum WorkspaceInstructionsLoadResult: Equatable, Sendable {
  case missing
  case found(WorkspaceInstructionsDocument)
}

internal protocol WorkspaceInstructionsLoading: Sendable {
  func loadInstructions(
    from workspace: Workspace
  ) async throws -> WorkspaceInstructionsLoadResult
}

internal enum WorkspaceInstructionsLoadingError: LocalizedError, Equatable, Sendable {
  case cannotInspectWorkspace
  case ambiguousMatches([String])
  case notRegularFile(String)
  case pathOutsideWorkspace(String)
  case cannotRead(String)
  case invalidUTF8(String)

  package var errorDescription: String? {
    switch self {
    case .cannotInspectWorkspace:
      "Could not inspect the workspace root for AGENTS.md."
    case .ambiguousMatches(let names):
      "Multiple case-insensitive AGENTS.md matches were found: \(names.joined(separator: ", "))."
    case .notRegularFile(let path):
      "Workspace instructions path is not a regular file: \(path)."
    case .pathOutsideWorkspace(let path):
      "Workspace instructions path resolves outside the workspace: \(path)."
    case .cannotRead(let path):
      "Could not read workspace instructions: \(path)."
    case .invalidUTF8(let path):
      "Workspace instructions are not valid UTF-8: \(path)."
    }
  }
}

internal struct WorkspaceInstructionsLoader: WorkspaceInstructionsLoading {
  package static let fileName = "AGENTS.md"

  package init() {}

  package func loadInstructions(
    from workspace: Workspace
  ) async throws -> WorkspaceInstructionsLoadResult {
    try await Task.detached(priority: .userInitiated) {
      try workspace.withSecurityScopedAccess {
        try loadInstructionsSynchronously(from: workspace)
      }
    }.value
  }

  private func loadInstructionsSynchronously(
    from workspace: Workspace
  ) throws -> WorkspaceInstructionsLoadResult {
    let children: [URL]
    do {
      children = try FileManager.default.contentsOfDirectory(
        at: workspace.rootURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: []
      )
    } catch {
      throw WorkspaceInstructionsLoadingError.cannotInspectWorkspace
    }

    guard
      let selectedName = try Self.selectedFileName(
        from: children.map(\.lastPathComponent)
      )
    else {
      return .missing
    }
    guard let selectedURL = children.first(where: { $0.lastPathComponent == selectedName }) else {
      return .missing
    }

    let selectedPath = selectedURL.lastPathComponent
    let resolvedURL: URL
    do {
      resolvedURL = try workspace.resolveAllowedPath(selectedPath)
    } catch WorkspacePathResolutionError.pathOutsideWorkspace {
      throw WorkspaceInstructionsLoadingError.pathOutsideWorkspace(selectedPath)
    } catch {
      throw WorkspaceInstructionsLoadingError.cannotRead(selectedPath)
    }

    do {
      let values = try resolvedURL.resourceValues(forKeys: [.isRegularFileKey])
      guard values.isRegularFile == true else {
        throw WorkspaceInstructionsLoadingError.notRegularFile(selectedPath)
      }
    } catch let error as WorkspaceInstructionsLoadingError {
      throw error
    } catch {
      throw WorkspaceInstructionsLoadingError.cannotRead(selectedPath)
    }

    let data: Data
    do {
      data = try Data(contentsOf: resolvedURL)
    } catch {
      throw WorkspaceInstructionsLoadingError.cannotRead(selectedPath)
    }
    guard let content = String(data: data, encoding: .utf8) else {
      throw WorkspaceInstructionsLoadingError.invalidUTF8(selectedPath)
    }
    let digest = SHA256.hash(data: data)
    let contentHash = digest.map { String(format: "%02x", $0) }.joined()
    return .found(
      WorkspaceInstructionsDocument(
        path: WorkspaceRelativePath(rawValue: selectedPath),
        contentHash: contentHash,
        content: content
      )
    )
  }

  static func selectedFileName(from names: [String]) throws -> String? {
    let matches = names.filter { name in
      name.compare(
        Self.fileName,
        options: [.caseInsensitive, .literal]
      ) == .orderedSame
    }
    if matches.contains(Self.fileName) {
      return Self.fileName
    }
    guard matches.count <= 1 else {
      throw WorkspaceInstructionsLoadingError.ambiguousMatches(matches.sorted())
    }
    return matches.first
  }
}

enum WorkspaceInstructionsPromptPolicy {
  static func update(
    for result: WorkspaceInstructionsLoadResult,
    in session: ChatSession
  ) -> WorkspaceInstructionsPromptContext? {
    let latest = latestState(in: session)
    switch result {
    case .missing:
      guard case .snapshot(let snapshot) = latest else {
        return nil
      }
      return .makeRemoval(path: snapshot.path)
    case .found(let document):
      if case .snapshot(let snapshot) = latest,
        snapshot.path == document.path,
        snapshot.contentHash == document.contentHash
      {
        return nil
      }
      return .makeSnapshot(
        path: document.path,
        contentHash: document.contentHash,
        content: document.content
      )
    }
  }

  static func latestState(
    in session: ChatSession
  ) -> WorkspaceInstructionsPromptContext? {
    var latest: WorkspaceInstructionsPromptContext?
    for turn in session.turns where turn.modelContextPolicy != .excluded {
      for item in turn.items {
        guard case .userMessage(let message) = item else {
          continue
        }
        for state in message.promptContext.workspaceInstructions {
          latest = state
        }
      }
    }
    return latest
  }
}
