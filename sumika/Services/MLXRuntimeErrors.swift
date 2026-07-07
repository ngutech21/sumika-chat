import Foundation
import MLX

nonisolated enum MLXChatRuntimeError: LocalizedError {
  case modelNotLoaded
  case missingUserMessage
  case invalidChatTemplateMessageSequence
  case unsupportedArchitecture
  case unsupportedImageInput
  case interruptedStream

  var errorDescription: String? {
    switch self {
    case .modelNotLoaded:
      "Load a local MLX model before sending a message."
    case .missingUserMessage:
      "Enter a message before generating a reply."
    case .invalidChatTemplateMessageSequence:
      "The chat history contains a message role sequence that cannot be rendered by the model template."
    case .unsupportedArchitecture:
      "Local MLX inference requires an Apple Silicon Mac."
    case .unsupportedImageInput:
      "The selected local model cannot analyze images. Select a vision-capable model or remove the image attachment."
    case .interruptedStream:
      "Local MLX generation ended before the model reported completion."
    }
  }
}

nonisolated enum MLXMemoryClearReason: String, Equatable, Sendable {
  case unload
  case clearContext = "clear_context"
  case runtimeError = "runtime_error"
  case interruptedStream = "interrupted_stream"
}

nonisolated enum MLXModelStreamTermination: Equatable, Sendable {
  case completed
  case downstreamTerminated
  case cancelled
  case nativeToolCallBoundary
  case runtimeError
  case interruptedStream
}

nonisolated struct MLXMemoryCacheClearer: Sendable {
  static let live = MLXMemoryCacheClearer { _ in
    Memory.clearCache()
  }

  let clearCache: @Sendable (MLXMemoryClearReason) async -> Void

  init(_ clearCache: @escaping @Sendable (MLXMemoryClearReason) async -> Void) {
    self.clearCache = clearCache
  }
}
