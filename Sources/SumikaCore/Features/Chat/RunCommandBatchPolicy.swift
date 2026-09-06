import Foundation

enum RunCommandBatchPolicy {
  /// The first valid request reserves its signature, regardless of execution outcome.
  static func blockedRecords(
    for requests: [ToolCallRequest], workspace: Workspace
  ) -> [ToolCallRecord.ID: ToolCallRecord] {
    var originals: [RunCommandExecutionSignature: ToolCallRecord.ID] = [:]
    var blocked: [ToolCallRecord.ID: ToolCallRecord] = [:]
    for request in requests {
      guard case .runCommand(let input) = request.payload,
        let signature = try? RunCommandExecutionSignature(input: input, workspace: workspace)
      else {
        continue
      }
      guard let originalCallID = originals[signature] else {
        originals[signature] = request.id
        continue
      }
      let result = RunCommandDuplicateResult(originalCallID: originalCallID)
      blocked[request.id] = ToolCallRecord(
        request: request,
        evaluation: ToolPermissionEvaluation(
          decision: .denied, reason: result.preview.text, riskLevel: .high),
        state: .failed(.runCommandDuplicate(result))
      )
    }
    return blocked
  }
}

extension ToolCallRecord {
  var isUnexecutedCommandDuplicate: Bool {
    if case .runCommandDuplicate = resultPayload { return true }
    return false
  }
}
