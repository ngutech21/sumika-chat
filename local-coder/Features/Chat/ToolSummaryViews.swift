import LocalCoderCore
import SwiftUI

struct ToolCallSummaryView: View {
  let toolCall: ToolCallModelMessage
  let toolCallRecord: ToolCallRecord?
  let onApprove: (ToolCallRecord.ID) -> Void
  let onDeny: (ToolCallRecord.ID) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label {
        HStack(spacing: 4) {
          Text("Tool call:")
          Text(toolCall.toolName.rawValue)
            .fontWeight(.semibold)
        }
      } icon: {
        Image(systemName: "wrench.and.screwdriver")
      }
      .font(.headline)

      if !toolCall.transcriptArguments.isEmpty {
        ForEach(toolCall.transcriptArguments) { argument in
          LabeledContent(argument.name, value: argument.value)
        }
      }

      Text("Call ID \(toolCall.callID.uuidString)")
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)

      if let toolCallRecord {
        Divider()
        LabeledContent("Status", value: toolCallRecord.status.displayName)
        LabeledContent("Risk", value: toolCallRecord.evaluation.riskLevel.rawValue)

        if !toolCallRecord.evaluation.reason.isEmpty {
          Text(toolCallRecord.evaluation.reason)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if !toolCallRecord.evaluation.normalizedPaths.isEmpty {
          Text(toolCallRecord.evaluation.normalizedPaths.joined(separator: "\n"))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(3)
        }

        if toolCallRecord.status == .awaitingApproval,
          let preview = toolCallRecord.resultPreview,
          !preview.text.isEmpty
        {
          Text(preview.text)
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }

        if toolCallRecord.status == .awaitingApproval {
          HStack(spacing: 8) {
            Button {
              onApprove(toolCallRecord.id)
            } label: {
              Label("Approve", systemImage: "checkmark.circle")
            }
            .controlSize(.small)

            Button(role: .destructive) {
              onDeny(toolCallRecord.id)
            } label: {
              Label("Deny", systemImage: "xmark.circle")
            }
            .controlSize(.small)
          }
        }
      }
    }
    .font(.callout)
  }
}

extension ToolCallStatus {
  fileprivate var displayName: String {
    switch self {
    case .pending:
      "pending"
    case .awaitingApproval:
      "awaiting approval"
    case .approved:
      "approved"
    case .denied:
      "denied"
    case .running:
      "running"
    case .completed:
      "completed"
    case .failed:
      "failed"
    case .cancelled:
      "cancelled"
    }
  }
}

struct ToolResultSummaryView: View {
  let toolResult: ToolResultModelMessage
  let toolCallRecord: ToolCallRecord?
  @State private var isResultExpanded = false

  var body: some View {
    let display = displayPayload
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Label("Tool result", systemImage: toolResult.systemImage)
          .font(.headline)

        Spacer(minLength: 8)

        Text(display.status.rawValue)
          .font(.caption.weight(.medium))
          .foregroundStyle(display.statusColor)
      }

      LabeledContent("Tool", value: toolResult.toolName.rawValue)
      Text("Call ID \(toolResult.callID.uuidString)")
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)

      if !display.metaSummary.isEmpty {
        Text(display.metaSummary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      if !display.text.isEmpty {
        DisclosureGroup(isExpanded: $isResultExpanded) {
          Divider()
          Text(display.text)
            .font(.system(.callout, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        } label: {
          Text(isResultExpanded ? "Hide result" : "Show result")
            .font(.caption.weight(.medium))
        }
        .buttonStyle(.plain)
      }
    }
    .font(.callout)
  }

  private var displayPayload: ToolDisplayPayload {
    guard let request = toolCallRecord?.request else {
      let preview = toolResult.payload.preview
      return .summary(
        status: preview.status,
        text: preview.text,
        affectedPaths: preview.affectedPaths.map(WorkspaceRelativePath.init(rawValue:))
      )
    }

    return ToolResultProjector.project(
      payload: toolResult.payload,
      request: request,
      policy: .default
    ).display
  }
}

extension ToolResultModelMessage {
  var systemImage: String {
    payload.status == .success ? "checkmark.circle" : "exclamationmark.triangle"
  }
}

extension ToolDisplayPayload {
  var metaSummary: String {
    var parts: [String] = []

    if !affectedPaths.isEmpty {
      parts.append(pathSummary)
    }

    if truncated {
      parts.append("truncated")
    }

    parts.append(resultSizeSummary)
    return parts.joined(separator: " · ")
  }

  private var pathSummary: String {
    guard let firstPath = affectedPaths.first else {
      return ""
    }

    if affectedPaths.count == 1 {
      return firstPath.rawValue
    }

    return "\(firstPath.rawValue) +\(affectedPaths.count - 1) paths"
  }

  private var resultSizeSummary: String {
    let lineCount = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
    let byteCount = text.utf8.count
    let formattedBytes = ByteCountFormatter.string(
      fromByteCount: Int64(byteCount),
      countStyle: .file
    )
    return "\(lineCount) lines, \(formattedBytes)"
  }

  fileprivate var status: ToolResultStatus {
    switch self {
    case .fileContent:
      .success
    case .fileList:
      .success
    case .searchResults:
      .success
    case .workspaceDiff:
      .success
    case .summary(let status, _, _):
      status
    }
  }

  fileprivate var statusColor: Color {
    switch status {
    case .success:
      .green
    case .failed, .denied:
      .orange
    }
  }

  fileprivate var affectedPaths: [WorkspaceRelativePath] {
    switch self {
    case .fileContent(let path, _):
      [path]
    case .fileList(let root, _, _):
      [root]
    case .searchResults(let root, _, _, _):
      [root]
    case .workspaceDiff(let path, _):
      [path ?? WorkspaceRelativePath(rawValue: ".")]
    case .summary(_, _, let affectedPaths):
      affectedPaths
    }
  }

  fileprivate var truncated: Bool {
    switch self {
    case .fileContent(_, let content):
      content.truncated
    case .fileList(_, _, let truncated):
      truncated
    case .searchResults(_, _, _, let truncated):
      truncated
    case .workspaceDiff(_, let content):
      content.truncated
    case .summary:
      false
    }
  }

  fileprivate var text: String {
    switch self {
    case .fileContent(_, let content):
      return content.text
    case .fileList(_, let entries, _):
      return entries.isEmpty
        ? "(empty)"
        : entries.map { entry in
          entry.kind == .directory ? entry.path.rawValue + "/" : entry.path.rawValue
        }.joined(separator: "\n")
    case .searchResults(_, _, let matches, _):
      return matches.isEmpty
        ? "(no matches)"
        : matches.map { "\($0.path.rawValue):\($0.line): \($0.snippet)" }
          .joined(separator: "\n")
    case .workspaceDiff(_, let content):
      return content.text
    case .summary(_, let text, _):
      return text
    }
  }
}
