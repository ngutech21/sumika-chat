import Foundation
import SumikaCore

extension ChatSession {
  func markdownTranscript(turns: [ChatTurn]? = nil) -> String {
    var sections = ["# \(title)"]
    for turn in turns ?? self.turns {
      for item in turn.items {
        let role: String
        let content: String
        let attachments: [ChatAttachment]
        switch item {
        case .userMessage(let message):
          role = "User"
          content = message.content
          attachments = message.attachments
        case .assistantMessage(let message):
          role = "Assistant"
          content = message.content
          attachments = message.attachments
        case .assistantThinking, .tool:
          continue
        }
        var parts = [content].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        parts += attachments.map { "Attachment: \($0.displayName)" }
        guard !parts.isEmpty else { continue }
        sections.append("## \(role)\n\n" + parts.joined(separator: "\n\n"))
      }
    }
    return sections.joined(separator: "\n\n") + "\n"
  }
}
