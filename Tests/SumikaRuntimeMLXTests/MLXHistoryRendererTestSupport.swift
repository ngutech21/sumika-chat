import MLXLMCommon
import SumikaCore

@testable import SumikaRuntimeMLX

extension MLXHistoryRenderer {
  /// Test-only convenience that builds cache snapshots straight from chat
  /// messages without normalization. Production code derives snapshots via
  /// `generationHistorySnapshot(from:)` instead.
  nonisolated static func messageSnapshot(
    from messages: [Chat.Message]
  ) -> [MLXMessageSnapshot] {
    messages.map { message in
      MLXMessageSnapshot(role: message.role.rawValue, content: message.content)
    }
  }
}
