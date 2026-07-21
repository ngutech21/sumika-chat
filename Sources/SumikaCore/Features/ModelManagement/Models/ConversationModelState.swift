import Foundation

struct ConversationModelState: Equatable, Sendable {
  let selectedModel: ManagedModel
  let loadState: ModelLoadState
  let contextTokenLimit: Int
  let operationID: UUID
}
