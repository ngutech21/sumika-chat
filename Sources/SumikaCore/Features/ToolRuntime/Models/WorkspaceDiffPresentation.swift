import Foundation

/// Projects the stored file records; budgets never change the canonical snapshot.
enum WorkspaceDiffPresentation {
  static func prefix(_ text: String, bytes: Int) -> String {
    utf8Prefix(Data(text.utf8.prefix(max(0, bytes))))
  }

  static func utf8Prefix(_ data: Data) -> String {
    for dropped in 0...min(3, data.count) {
      if let value = String(data: data.dropLast(dropped), encoding: .utf8) { return value }
    }
    return ""
  }

  static func display(_ snapshot: WorkspaceDiffSnapshot, maxBytes: Int = 48 * 1024)
    -> ToolTextOutput
  {
    let files = fittedFiles(snapshot, limit: maxBytes) { files in
      displayText(snapshot, files: files).utf8.count
    }
    let text = displayText(snapshot, files: files)
    return ToolTextOutput(
      text: prefix(text, bytes: maxBytes),
      truncated: files.count < snapshot.files.count || files.contains(where: \.truncated)
        || text.utf8.count > maxBytes,
      redacted: snapshot.files.contains(where: \.redacted))
  }

  static func projection(
    _ snapshot: WorkspaceDiffSnapshot, files: [WorkspaceDiffFile]? = nil
  ) -> ToolResultProjection {
    let selected = files ?? snapshot.files
    let omitted = snapshot.files.count - selected.count
    let truncated = omitted > 0 || selected.contains(where: \.truncated)
    let fields: [ToolResultModelMetadataField] = [
      .init(
        name: "summary",
        value: .object([
          .init(name: "files_changed", value: .int(snapshot.files.count)),
          .init(name: "staged", value: totals(snapshot.files.compactMap(\.staged))),
          .init(
            name: "unstaged",
            value: totals(snapshot.files.compactMap(\.unstaged).filter { $0.kind != .untracked })),
          .init(
            name: "untracked",
            value: totals(snapshot.files.compactMap(\.unstaged).filter { $0.kind == .untracked })),
        ])),
      .init(name: "files", value: .array(selected.map(fileMetadata)), includeDefault: true),
      .init(name: "omitted_files", value: .int(omitted)),
      .init(name: "truncated", value: .bool(truncated), includeDefault: true),
      .init(name: "redacted", value: .bool(snapshot.files.contains(where: \.redacted))),
    ]
    return ToolResultProjection(
      display: .workspaceDiff(
        path: snapshot.path, content: files == nil ? display(snapshot) : ToolTextOutput(text: "")),
      observation: .success(
        toolName: .workspaceDiff,
        affectedPaths: snapshot.files.isEmpty
          ? [snapshot.path ?? WorkspaceRelativePath(rawValue: ".")] : selected.map(\.path),
        blocks: blocks(snapshot, files: selected)),
      metadata: ToolResultModelMetadata(kind: "workspace_diff", fields: fields),
      workspaceDiff: files == nil ? snapshot : nil)
  }

  static func boundedModelProjection(
    _ snapshot: WorkspaceDiffSnapshot, maxCharacters: Int,
    render: (ToolResultProjection) -> String
  ) -> ToolResultProjection {
    let files = fittedFiles(snapshot, limit: maxCharacters) { files in
      render(projection(snapshot, files: files)).count
    }
    return projection(snapshot, files: files)
  }

  private static func fittedFiles(
    _ snapshot: WorkspaceDiffSnapshot, limit: Int, size: ([WorkspaceDiffFile]) -> Int
  ) -> [WorkspaceDiffFile] {
    var low = 0
    var high = snapshot.files.count
    while low < high {
      let middle = (low + high + 1) / 2
      if size(snapshot.files.prefix(middle).map { limitedFile($0, bytes: 0) }) <= limit {
        low = middle
      } else {
        high = middle - 1
      }
    }
    let selected = Array(snapshot.files.prefix(low))
    low = 0
    high = 4 * 1024
    while low < high {
      let middle = (low + high + 1) / 2
      if size(selected.map { limitedFile($0, bytes: middle) }) <= limit {
        low = middle
      } else {
        high = middle - 1
      }
    }
    return selected.map { limitedFile($0, bytes: low) }
  }

  private static func limitedFile(_ source: WorkspaceDiffFile, bytes: Int) -> WorkspaceDiffFile {
    var file = source
    let parts = source.changes.filter { !$0.patch.text.isEmpty }.count
    func limited(_ source: WorkspaceDiffChange?) -> WorkspaceDiffChange? {
      guard var change = source else { return nil }
      let text = prefix(change.patch.text, bytes: bytes / max(1, parts))
      if text.utf8.count < change.patch.text.utf8.count {
        change.patch.truncated = true
        if text.isEmpty { change.omission = .budget }
      }
      change.patch.text = text
      return change
    }
    file.staged = limited(source.staged)
    file.unstaged = limited(source.unstaged)
    return file
  }

  private static func displayText(_ snapshot: WorkspaceDiffSnapshot, files: [WorkspaceDiffFile])
    -> String
  {
    blocks(snapshot, files: files).map { block in
      switch block {
      case .summary(let text): return text
      case .fileContent(_, let content): return content.text
      default: return ""
      }
    }.joined(separator: "\n")
  }

  private static func blocks(_ snapshot: WorkspaceDiffSnapshot, files: [WorkspaceDiffFile])
    -> [ToolObservationBlock]
  {
    guard !snapshot.files.isEmpty else { return [.summary("No workspace changes.")] }
    var blocks: [ToolObservationBlock] = [.summary("Changed files: \(snapshot.files.count)")]
    for (label, changes) in [
      ("Staged", snapshot.files.compactMap(\.staged)),
      ("Unstaged", snapshot.files.compactMap(\.unstaged).filter { $0.kind != .untracked }),
      ("Untracked", snapshot.files.compactMap(\.unstaged).filter { $0.kind == .untracked }),
    ] where !changes.isEmpty {
      let counts = lineTotals(changes)
      blocks.append(
        .summary(
          "\(label) totals: +\(counts.additions.map(String.init) ?? "?")/-\(counts.deletions.map(String.init) ?? "?")"
        ))
    }
    for file in files {
      var descriptions: [String] = []
      var patches: [ToolObservationBlock] = []
      for (label, change) in [("Staged", file.staged), ("Unstaged", file.unstaged)] {
        guard let change else { continue }
        let label = change.kind == .untracked ? "Untracked" : label
        let counts =
          " +\(change.additions.map(String.init) ?? "?")/-\(change.deletions.map(String.init) ?? "?")"
        let original = change.originalPath.map { " from \(quoted($0.rawValue))" } ?? ""
        let omission = change.omission.map { " [\($0.rawValue)]" } ?? ""
        descriptions.append("\(label): \(change.kind.rawValue)\(original)\(counts)\(omission)")
        if !change.patch.text.isEmpty {
          patches.append(
            .fileContent(
              path: file.path,
              content: ToolTextOutput(
                text: "\(label) patch:\n\(change.patch.text)", truncated: change.patch.truncated,
                redacted: change.patch.redacted)))
        }
      }
      let flags = file.truncated ? " [patch truncated]" : ""
      blocks.append(
        .summary("\(quoted(file.path.rawValue))\(flags)\n\(descriptions.joined(separator: "; "))"))
      if patches.isEmpty {
        patches.append(
          .fileContent(
            path: file.path,
            content: ToolTextOutput(text: "", truncated: file.truncated, redacted: file.redacted)))
      }
      blocks.append(contentsOf: patches)
    }
    if files.count < snapshot.files.count {
      blocks.append(
        .summary("Omitted files: \(snapshot.files.count - files.count). Use a narrower path."))
    }
    return blocks
  }

  private static func fileMetadata(_ file: WorkspaceDiffFile) -> ToolResultModelMetadataValue {
    var fields: [ToolResultModelMetadataField] = [
      .init(name: "path", value: .string(file.path.rawValue)),
      .init(name: "patch_truncated", value: .bool(file.truncated)),
    ]
    if let staged = file.staged {
      fields.append(.init(name: "staged", value: changeMetadata(staged)))
    }
    if let unstaged = file.unstaged {
      fields.append(
        .init(
          name: unstaged.kind == .untracked ? "untracked" : "unstaged",
          value: changeMetadata(unstaged)))
    }
    return .object(fields)
  }

  private static func changeMetadata(_ change: WorkspaceDiffChange) -> ToolResultModelMetadataValue
  {
    var fields: [ToolResultModelMetadataField] = [
      .init(name: "status", value: .string(change.kind.rawValue)),
      .init(
        name: "additions", value: change.additions.map(ToolResultModelMetadataValue.int) ?? .null),
      .init(
        name: "deletions", value: change.deletions.map(ToolResultModelMetadataValue.int) ?? .null),
      .init(name: "patch_truncated", value: .bool(change.patch.truncated)),
    ]
    if let path = change.originalPath {
      fields.append(.init(name: "original_path", value: .string(path.rawValue)))
    }
    if let omission = change.omission {
      fields.append(.init(name: "patch_omitted", value: .string(omission.rawValue)))
    }
    if change.patch.redacted { fields.append(.init(name: "redacted", value: .bool(true))) }
    return .object(fields)
  }

  private static func totals(_ changes: [WorkspaceDiffChange]) -> ToolResultModelMetadataValue {
    let counts = lineTotals(changes)
    return .object([
      .init(
        name: "additions",
        value: counts.additions.map(ToolResultModelMetadataValue.int) ?? .null),
      .init(
        name: "deletions",
        value: counts.deletions.map(ToolResultModelMetadataValue.int) ?? .null),
      .init(
        name: "counts_complete", value: .bool(counts.additions != nil && counts.deletions != nil)),
    ])
  }

  private static func lineTotals(_ changes: [WorkspaceDiffChange]) -> (
    additions: Int?, deletions: Int?
  ) {
    func sum(_ values: [Int?]) -> Int? {
      var total = 0
      for value in values {
        guard let value, value >= 0 else { return nil }
        let next = total.addingReportingOverflow(value)
        guard !next.overflow else { return nil }
        total = next.partialValue
      }
      return total
    }
    return (sum(changes.map(\.additions)), sum(changes.map(\.deletions)))
  }

  private static func quoted(_ text: String) -> String {
    // JSON escaping keeps filenames containing newlines distinct from patch lines.
    guard let data = try? JSONEncoder().encode(text),
      let value = String(data: data, encoding: .utf8)
    else { return "\"\"" }
    return value
  }
}
