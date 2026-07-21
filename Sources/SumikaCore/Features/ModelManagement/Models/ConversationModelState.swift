import Foundation

package struct ConversationModelState: Equatable, Sendable {
  package let selectedModel: ManagedModel
  package let loadState: ModelLoadState
  package let contextTokenLimit: Int
  package let operationID: UUID

  package init(
    selectedModel: ManagedModel,
    loadState: ModelLoadState,
    contextTokenLimit: Int,
    operationID: UUID
  ) {
    self.selectedModel = selectedModel
    self.loadState = loadState
    self.contextTokenLimit = contextTokenLimit
    self.operationID = operationID
  }
}
