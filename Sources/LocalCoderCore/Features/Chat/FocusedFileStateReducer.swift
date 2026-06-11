import Crypto
import Foundation

public struct FocusedFileStateReducer: Sendable {
  public let maxRecentPaths: Int
  public let maxSnapshotCharacters: Int

  public init(
    maxRecentPaths: Int = 8,
    maxSnapshotCharacters: Int = 4_000
  ) {
    self.maxRecentPaths = maxRecentPaths
    self.maxSnapshotCharacters = maxSnapshotCharacters
  }

  public func applyingToolResult(
    _ payload: ToolResultPayload?,
    request: ToolCallRequest,
    to state: FocusedFileState,
    updatedAt: Date = Date()
  ) -> FocusedFileState {
    guard let payload, payload.status == .success else {
      return state
    }

    switch payload {
    case .readFile(.success(let path, let content)) where request.toolName == .readFile:
      return focusing(
        path,
        source: .readFile,
        content: content.text,
        fullContentAvailable: !content.truncated && !content.redacted,
        in: state,
        updatedAt: updatedAt
      )
    case .readFile:
      return state
    case .writeFile(.success(let path, _)):
      let content: String?
      if case .writeFile(let input) = request.payload {
        content = input.content
      } else {
        content = nil
      }
      return focusing(
        path,
        source: .writeFile,
        content: content,
        fullContentAvailable: content != nil,
        in: state,
        updatedAt: updatedAt
      )
    case .editFile(.success(let path, _, _)):
      let content: String?
      if case .editFile(let input) = request.payload {
        content = editedSnapshotContent(for: path, input: input, in: state)
      } else {
        content = nil
      }
      var updatedState = focusing(
        path,
        source: .editFile,
        content: content,
        fullContentAvailable: content != nil,
        in: state,
        updatedAt: updatedAt
      )
      if content == nil {
        updatedState.snapshots.removeValue(forKey: path)
      }
      return updatedState
    default:
      return state
    }
  }

  public func applyingAttachments(
    _ attachments: [ChatAttachment],
    workspace: Workspace?,
    to state: FocusedFileState,
    updatedAt: Date = Date()
  ) -> FocusedFileState {
    guard !attachments.isEmpty else {
      return state
    }

    let focusedAttachments = attachments.filter { $0.kind == .text }.map { attachment in
      let path = attachmentPath(for: attachment, workspace: workspace)
      return (path, attachment.content)
    }
    guard !focusedAttachments.isEmpty else {
      return state
    }

    if focusedAttachments.count == 1, let first = focusedAttachments.first {
      return focusing(
        first.0,
        source: .attachment,
        content: first.1,
        fullContentAvailable: true,
        in: state,
        updatedAt: updatedAt
      )
    }

    var updatedState = state
    updatedState.activePath = nil
    for attachment in focusedAttachments {
      updatedState = recordingRecent(
        attachment.0,
        source: .attachment,
        confidence: .ambiguous,
        content: attachment.1,
        fullContentAvailable: true,
        in: updatedState,
        updatedAt: updatedAt
      )
    }
    return updatedState
  }

  private func focusing(
    _ path: WorkspaceRelativePath,
    source: FocusedPathSource,
    content: String?,
    fullContentAvailable: Bool,
    in state: FocusedFileState,
    updatedAt: Date
  ) -> FocusedFileState {
    var updatedState = recordingRecent(
      path,
      source: source,
      confidence: .active,
      content: content,
      fullContentAvailable: fullContentAvailable,
      in: state,
      updatedAt: updatedAt
    )
    updatedState.activePath = path
    return updatedState
  }

  private func recordingRecent(
    _ path: WorkspaceRelativePath,
    source: FocusedPathSource,
    confidence: FocusConfidence,
    content: String?,
    fullContentAvailable: Bool,
    in state: FocusedFileState,
    updatedAt: Date
  ) -> FocusedFileState {
    var updatedState = state
    updatedState.recentPaths.removeAll { $0.path == path }
    updatedState.recentPaths.insert(
      FocusedPath(
        path: path,
        source: source,
        confidence: confidence,
        updatedAt: updatedAt
      ),
      at: 0
    )
    if updatedState.recentPaths.count > maxRecentPaths {
      updatedState.recentPaths = Array(updatedState.recentPaths.prefix(maxRecentPaths))
    }

    if let content {
      updatedState.snapshots[path] = FocusedFileSnapshot(
        contentHash: Self.contentHash(for: content),
        excerpt: Self.excerpt(from: content, limit: maxSnapshotCharacters),
        fullContentAvailable: fullContentAvailable && content.count <= maxSnapshotCharacters,
        updatedAt: updatedAt
      )
    }

    let knownPaths = Set(updatedState.recentPaths.map(\.path))
    updatedState.snapshots = updatedState.snapshots.filter { knownPaths.contains($0.key) }
    return updatedState
  }

  private func editedSnapshotContent(
    for path: WorkspaceRelativePath,
    input: EditFileInput,
    in state: FocusedFileState
  ) -> String? {
    guard let snapshot = state.snapshots[path],
      snapshot.fullContentAvailable,
      let content = snapshot.excerpt
    else {
      return nil
    }

    guard content.components(separatedBy: input.oldText).count == 2 else {
      return nil
    }

    return content.replacingOccurrences(of: input.oldText, with: input.newText)
  }

  private func attachmentPath(
    for attachment: ChatAttachment,
    workspace: Workspace?
  ) -> WorkspaceRelativePath {
    _ = workspace
    return WorkspaceRelativePath(rawValue: attachment.displayName)
  }

  private static func contentHash(for content: String) -> String {
    let digest = SHA256.hash(data: Data(content.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func excerpt(from content: String, limit: Int) -> String? {
    guard !content.isEmpty else {
      return nil
    }
    guard content.count > limit else {
      return content
    }
    return String(content.prefix(limit))
  }
}
