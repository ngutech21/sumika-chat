import Foundation

/// `run_command` is deliberately excluded from the read-only duplicate machinery
/// (`ToolLoopCoordinator.supportsDuplicateObservation`) because it has side effects and
/// re-running can be legitimate. This is its dedicated loop brake: when the same shell
/// command fails twice in a row within a turn, a small model is stuck re-proposing a
/// command it cannot fix (e.g. a tokenizer-mangled `git add.` instead of `git add .`).
///
/// The brake does not silently give up — it forces the next generation tools-free and the
/// notice policy escalates to the user with the failing command and error. The model still
/// gets one self-correction attempt: the brake fires only on the *second* consecutive
/// identical failure, so a corrected retry between the two failures resets the streak.
enum RunCommandRepeatPolicy {
  /// Resume-path entry point. `record` is the just-completed run_command; `priorItems`
  /// are the current turn's items. Records sharing `record.id` are skipped, so the turn
  /// history may be passed even while it still holds the awaiting-approval version of the
  /// same record.
  static func forcesFinalAfterRepeatedFailure(
    _ record: ToolCallRecord,
    priorItems: [ChatTurnItem]
  ) -> Bool {
    guard let command = failedRunCommandResult(record)?.command else {
      return false
    }
    return precededByFailure(command: command, excludingID: record.id, in: priorItems)
  }

  /// Notice-policy entry point. Returns the failing result when the turn's tail is two
  /// consecutive identical failed run_commands, otherwise `nil`.
  static func repeatedFailure(inTailOf items: [ChatTurnItem]) -> RunCommandResult? {
    guard
      let lastIndex = items.lastIndex(where: { item in
        if case .tool = item { return true }
        return false
      }),
      case .tool(let last) = items[lastIndex],
      let result = failedRunCommandResult(last),
      precededByFailure(
        command: result.command,
        excludingID: last.id,
        in: Array(items[..<lastIndex])
      )
    else {
      return nil
    }
    return result
  }

  /// Walking back from the end and skipping non-tool items and any record with
  /// `excludingID`, the first tool record encountered must be a failed run_command with
  /// the same command. A different tool, a different command, or a successful run resets
  /// the streak (returns `false`), so "inspected/edited, then re-ran" does not trigger.
  private static func precededByFailure(
    command: String,
    excludingID: UUID,
    in items: [ChatTurnItem]
  ) -> Bool {
    for item in items.reversed() {
      guard case .tool(let record) = item, record.id != excludingID else {
        continue
      }
      guard let priorCommand = failedRunCommandResult(record)?.command else {
        return false
      }
      return priorCommand == command
    }
    return false
  }

  private static func failedRunCommandResult(_ record: ToolCallRecord) -> RunCommandResult? {
    guard record.request.toolName == .runCommand,
      case .runCommand(let result)? = record.resultPayload,
      result.outcomeStatus == .failed
    else {
      return nil
    }
    return result
  }
}
