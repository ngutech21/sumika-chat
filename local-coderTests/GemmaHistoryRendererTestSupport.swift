import Foundation
import LocalCoderCore
import MLXLMCommon

@testable import local_coder

extension GemmaHistoryRenderer {
  /// Test-only convenience that builds cache snapshots straight from chat
  /// messages without normalization. Production code derives snapshots via
  /// `generationHistorySnapshot(from:)` instead.
  nonisolated static func messageSnapshot(
    from messages: [Chat.Message]
  ) -> [GemmaMessageSnapshot] {
    messages.map { message in
      GemmaMessageSnapshot(role: message.role.rawValue, content: message.content)
    }
  }
}
