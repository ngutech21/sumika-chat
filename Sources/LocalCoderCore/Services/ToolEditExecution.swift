import Foundation

public struct EditFileInput: Decodable, Sendable {
  public let path: String
  public let oldText: String
  public let newText: String

  private enum CodingKeys: String, CodingKey {
    case path
    case oldText = "old_text"
    case newText = "new_text"
  }
}

public struct EditFileToolExecutor: TypedToolExecutor {
  public static let definition = ToolDefinition.editFile

  public func evaluatePermission(
    _ input: EditFileInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    do {
      let resolvedPath = try context.workspace.resolveAllowedPath(input.path)
      return ToolPermissionEvaluation(
        decision: .requiresApproval,
        reason: "Editing files inside the workspace requires approval.",
        riskLevel: .high,
        normalizedPaths: [resolvedPath.path(percentEncoded: false)]
      )
    } catch {
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: error.localizedDescription,
        riskLevel: .high
      )
    }
  }

  public func previewApproval(_ input: EditFileInput, context: ToolContext) async
    -> ToolResultPreview?
  {
    do {
      return try context.workspace.withSecurityScopedAccess {
        let edit = try validatedEdit(input, context: context)
        return ToolResultPreview(
          status: .success,
          text: Self.diffPreview(for: edit),
          affectedPaths: [edit.resolvedURL.path(percentEncoded: false)]
        )
      }
    } catch {
      return ToolResultPreview(status: .failed, text: error.localizedDescription)
    }
  }

  public func run(_ input: EditFileInput, context: ToolContext) async -> ToolResultPreview {
    do {
      return try context.workspace.withSecurityScopedAccess {
        let edit = try validatedEdit(input, context: context)
        try edit.updatedContent.write(to: edit.resolvedURL, atomically: true, encoding: .utf8)
        return ToolResultPreview(
          status: .success,
          text: "Edited \(input.path).",
          affectedPaths: [edit.resolvedURL.path(percentEncoded: false)]
        )
      }
    } catch {
      return ToolResultPreview(status: .failed, text: error.localizedDescription)
    }
  }

  private func validatedEdit(
    _ input: EditFileInput,
    context: ToolContext
  ) throws -> ValidatedEdit {
    guard !input.oldText.isEmpty else {
      throw EditFileValidationError.emptyOldText
    }

    guard input.oldText != input.newText else {
      throw EditFileValidationError.identicalReplacement
    }

    let resolvedURL = try context.workspace.resolveAllowedPath(input.path)
    let data = try Data(contentsOf: resolvedURL)
    guard let content = String(data: data, encoding: .utf8) else {
      throw EditFileValidationError.nonUTF8
    }

    let matches = Self.matchRanges(of: input.oldText, in: content, maxCount: 2)
    guard let match = matches.first else {
      throw EditFileValidationError.oldTextNotFound
    }
    guard matches.count == 1 else {
      throw EditFileValidationError.ambiguousOldText
    }

    var updatedContent = content
    updatedContent.replaceSubrange(match, with: input.newText)
    return ValidatedEdit(
      path: input.path,
      resolvedURL: resolvedURL,
      oldText: input.oldText,
      newText: input.newText,
      updatedContent: updatedContent
    )
  }

  private static func matchRanges(
    of needle: String,
    in haystack: String,
    maxCount: Int
  ) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var searchStart = haystack.startIndex

    while ranges.count < maxCount,
      let range = haystack.range(
        of: needle,
        options: [],
        range: searchStart..<haystack.endIndex
      )
    {
      ranges.append(range)
      searchStart = haystack.index(after: range.lowerBound)
    }

    return ranges
  }

  private static func diffPreview(for edit: ValidatedEdit) -> String {
    let removedLines = edit.oldText.split(separator: "\n", omittingEmptySubsequences: false)
    let addedLines = edit.newText.split(separator: "\n", omittingEmptySubsequences: false)
    let removed = removedLines.map { "-\($0)" }.joined(separator: "\n")
    let added = addedLines.map { "+\($0)" }.joined(separator: "\n")

    return """
      --- \(edit.path)
      +++ \(edit.path)
      @@
      \(removed)
      \(added)
      """
  }
}

nonisolated private struct ValidatedEdit {
  public let path: String
  public let resolvedURL: URL
  public let oldText: String
  public let newText: String
  public let updatedContent: String
}

public enum EditFileValidationError: LocalizedError {
  case emptyOldText
  case identicalReplacement
  case nonUTF8
  case oldTextNotFound
  case ambiguousOldText

  public var errorDescription: String? {
    switch self {
    case .emptyOldText:
      "edit_file old_text must not be empty."
    case .identicalReplacement:
      "edit_file new_text must be different from old_text."
    case .nonUTF8:
      "File is not valid UTF-8 text."
    case .oldTextNotFound:
      "edit_file old_text was not found."
    case .ambiguousOldText:
      "edit_file old_text matched more than once."
    }
  }
}
