import Foundation

public struct ChatModelContextBuilder: Sendable {
  public func messages(
    from state: ChatSessionState,
    includingTurnID: ChatTurnRecord.ID? = nil
  ) -> [ChatMessage] {
    let excludedTurnIDs = Set(
      state.turns.compactMap { turn -> ChatTurnRecord.ID? in
        guard turn.modelContextPolicy == .excluded, turn.id != includingTurnID else {
          return nil
        }
        return turn.id
      }
    )

    let transcriptMessages: [ChatMessage]
    if excludedTurnIDs.isEmpty {
      transcriptMessages = state.messages
    } else {
      transcriptMessages = state.messages.filter { message in
        guard let turnID = message.turnID else {
          return true
        }
        return !excludedTurnIDs.contains(turnID)
      }
    }

    guard let focusedFileContext = focusedFileContextMessage(from: state.focusedFileState) else {
      return transcriptMessages
    }

    return [focusedFileContext] + transcriptMessages
  }

  private func focusedFileContextMessage(from state: FocusedFileState) -> ChatMessage? {
    if let activePath = state.activePath {
      let focusedPath = state.recentPaths.first { $0.path == activePath }
      var lines = [
        "Current focused file: \(activePath.rawValue)"
      ]
      if let focusedPath {
        lines.append("Source: \(focusedPath.source.modelContextDescription)")
      }
      if let snapshot = state.snapshots[activePath], let excerpt = snapshot.excerpt {
        lines.append("Known content excerpt:")
        lines.append(excerpt)
      }
      lines.append("Explicit file paths in the user request or tool call take precedence.")
      return ChatMessage(systemContent: lines.joined(separator: "\n"))
    }

    let ambiguousPaths = state.recentPaths.filter { $0.confidence == .ambiguous }
    guard !ambiguousPaths.isEmpty else {
      return nil
    }

    let paths = ambiguousPaths.prefix(3).map { "- \($0.path.rawValue)" }
    let content = """
      Recent files are ambiguous:
      \(paths.joined(separator: "\n"))
      Do not assume a single active file unless the user names one.
      """
    return ChatMessage(systemContent: content)
  }
}

nonisolated extension FocusedPathSource {
  fileprivate var modelContextDescription: String {
    switch self {
    case .readFile:
      return "previous read_file"
    case .writeFile:
      return "previous write_file"
    case .editFile:
      return "previous edit_file"
    case .attachment:
      return "attachment"
    }
  }
}
