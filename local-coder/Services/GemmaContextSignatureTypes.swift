import Foundation
import LocalCoderCore
import MLXLMCommon

nonisolated struct GemmaMessageSnapshot: Equatable, Sendable {
  let role: String
  let content: String
  /// Identities of images prefilled with this message. Part of the prefix
  /// comparison so identical text with different images never reuses a
  /// cached session.
  let imageSignatures: [String]

  init(role: String, content: String, imageSignatures: [String] = []) {
    self.role = role
    self.content = content
    self.imageSignatures = imageSignatures
  }
}

nonisolated struct GemmaHistoryItem: Sendable {
  let role: Chat.Message.Role
  let content: String
  let imageSignatures: [String]
}

nonisolated struct GemmaRenderedContextSignature: Equatable, Sendable {
  let rendererVersion: Int
  let projectionMode: ModelContextProjectionMode
  let systemPromptHash: String
  let renderedHistoryHash: String
  let generationSettingsHash: String
  let nativeToolSchemaHash: String

  var traceValue: String {
    "renderer-v\(rendererVersion):projection-\(projectionMode.signatureComponent):system-\(systemPromptHash):history-\(renderedHistoryHash):settings-\(generationSettingsHash):tools-\(nativeToolSchemaHash)"
  }

  /// Whether two signatures describe the same prefilled KV prefix.
  ///
  /// `nativeToolSchemaHash` is deliberately excluded: the Gemma chat template
  /// never renders tool specs into the prompt, so `session.tools` only affects
  /// decode-time tool-call parsing, not the prefilled bytes. Gating prefix
  /// reuse on it made the final tool-loop answer (empty registry -> "none")
  /// re-prefill the whole context spuriously, the same way sampling params used
  /// to. The hash stays in `traceValue` for diagnostics.
  func hasSamePrefill(as other: GemmaRenderedContextSignature) -> Bool {
    rendererVersion == other.rendererVersion
      && projectionMode == other.projectionMode
      && systemPromptHash == other.systemPromptHash
      && renderedHistoryHash == other.renderedHistoryHash
      && generationSettingsHash == other.generationSettingsHash
  }
}

nonisolated enum CurrentPromptContextRuntimeBoundary: Equatable, Sendable {
  case attachedFile
  case focusedFile
  case ambiguousRecentFiles

  var marker: String {
    switch self {
    case .attachedFile:
      "Attached file:"
    case .focusedFile:
      "Current focused file:"
    case .ambiguousRecentFiles:
      "Recent files are ambiguous:"
    }
  }

  static let all: [CurrentPromptContextRuntimeBoundary] = [
    .attachedFile,
    .focusedFile,
    .ambiguousRecentFiles,
  ]
}

nonisolated struct CurrentPromptContextRuntimeBoundaryMatch: Equatable, Sendable {
  let boundary: CurrentPromptContextRuntimeBoundary
  let range: Range<String.Index>
}

nonisolated struct CurrentPromptContextRuntimeBlock: Equatable, Sendable {
  let boundary: CurrentPromptContextRuntimeBoundary
  let content: String
}
