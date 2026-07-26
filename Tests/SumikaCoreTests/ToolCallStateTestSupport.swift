@testable import SumikaCore

extension ToolCallState {
  var preview: ToolResultPreview? {
    resultPayload?.preview ?? approvalPreview
  }
}
