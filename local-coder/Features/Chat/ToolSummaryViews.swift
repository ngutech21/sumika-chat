import LocalCoderCore
import SwiftUI

struct ToolCallSummaryView: View {
  let toolCall: ToolCallModelMessage
  let toolCallRecord: ToolCallRecord?
  let generationMetrics: ChatGenerationMetrics?
  let onApprove: (ToolCallRecord.ID) -> Void
  let onDeny: (ToolCallRecord.ID) -> Void
  @State private var isDetailsExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      ToolSummaryRow(
        leadingImage: "wrench.and.screwdriver",
        title: "Tool call:",
        toolName: toolCall.toolName.rawValue,
        statusImage: toolCallRecord?.status.summarySystemImage ?? "ellipsis",
        statusColor: toolCallRecord?.status.summaryColor ?? .secondary,
        tokensPerSecond: generationMetrics?.tokensPerSecond,
        detailsAvailable: hasDetails,
        isDetailsExpanded: $isDetailsExpanded
      )

      if let toolCallRecord {
        if isDetailsExpanded {
          ToolCallDetailsView(toolCall: toolCall, toolCallRecord: toolCallRecord)
        }

        if toolCallRecord.status == .awaitingApproval {
          HStack(spacing: 6) {
            Button {
              onApprove(toolCallRecord.id)
            } label: {
              Image(systemName: "checkmark")
            }
            .help("Approve")
            .accessibilityLabel("Approve tool call")
            .controlSize(.small)

            Button(role: .destructive) {
              onDeny(toolCallRecord.id)
            } label: {
              Image(systemName: "xmark")
            }
            .help("Deny")
            .accessibilityLabel("Deny tool call")
            .controlSize(.small)
          }
        }
      }
    }
    .font(.caption)
    .accessibilityLabel(accessibilityLabel)
  }

  private var hasDetails: Bool {
    !toolCall.transcriptArguments.isEmpty
      || toolCallRecord?.resultPreview?.text.isEmpty == false
  }

  private var accessibilityLabel: String {
    var parts = ["Tool call \(toolCall.toolName.rawValue)"]
    if let toolCallRecord {
      parts.append(toolCallRecord.status.displayName)
    }
    if let generationMetrics {
      parts.append(generationMetrics.tokenRateSummary)
    }
    return parts.joined(separator: ", ")
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

  fileprivate var summarySystemImage: String {
    switch self {
    case .completed:
      "checkmark"
    case .failed, .denied, .cancelled:
      "xmark"
    case .awaitingApproval, .approved, .pending, .running:
      "ellipsis"
    }
  }

  fileprivate var summaryColor: Color {
    switch self {
    case .completed:
      .green
    case .failed, .denied, .cancelled:
      .orange
    case .awaitingApproval, .approved, .pending, .running:
      .secondary
    }
  }
}

struct ToolResultSummaryView: View {
  let toolResult: ToolResultModelMessage
  let toolCallRecord: ToolCallRecord?
  let generationMetrics: ChatGenerationMetrics?
  @State private var isResultExpanded = false

  var body: some View {
    let display = displayPayload
    VStack(alignment: .leading, spacing: 5) {
      ToolSummaryRow(
        leadingImage: "doc.text",
        title: "Tool result:",
        toolName: toolResult.toolName.rawValue,
        statusImage: display.status.summarySystemImage,
        statusColor: display.status.statusColor,
        tokensPerSecond: generationMetrics?.tokensPerSecond,
        detailsAvailable: !display.text.isEmpty,
        isDetailsExpanded: $isResultExpanded
      )

      if !display.text.isEmpty {
        if isResultExpanded {
          Text(display.text)
            .font(.system(.caption2, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(12)
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
      }
    }
    .font(.caption)
    .accessibilityLabel(accessibilityLabel(status: display.status))
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

  private func accessibilityLabel(status: ToolResultStatus) -> String {
    var parts = ["Tool result \(toolResult.toolName.rawValue)", status.rawValue]
    if let generationMetrics {
      parts.append(generationMetrics.tokenRateSummary)
    }
    return parts.joined(separator: ", ")
  }
}

extension ToolResultModelMessage {
  var systemImage: String {
    payload.status == .success ? "checkmark.circle" : "exclamationmark.triangle"
  }
}

private struct ToolSummaryRow: View {
  let leadingImage: String
  let title: String
  let toolName: String
  let statusImage: String
  let statusColor: Color
  let tokensPerSecond: Double?
  let detailsAvailable: Bool
  @Binding var isDetailsExpanded: Bool

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: leadingImage)
        .font(.caption2)
        .foregroundStyle(.secondary)

      Text(title)
        .foregroundStyle(.secondary)

      Text(toolName)
        .fontWeight(.semibold)
        .lineLimit(1)

      Image(systemName: statusImage)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(statusColor)
        .accessibilityHidden(true)

      if let tokensPerSecond {
        Text(tokensPerSecond.tokenRateSummary)
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      if detailsAvailable {
        Button {
          isDetailsExpanded.toggle()
        } label: {
          Image(systemName: isDetailsExpanded ? "chevron.down" : "chevron.right")
            .font(.caption2.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(isDetailsExpanded ? "Hide details" : "Show details")
        .accessibilityLabel(isDetailsExpanded ? "Hide details" : "Show details")
      }
    }
  }
}

private struct ToolCallDetailsView: View {
  let toolCall: ToolCallModelMessage
  let toolCallRecord: ToolCallRecord

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(toolCall.transcriptArguments) { argument in
        Text("\(argument.name): \(argument.value)")
          .lineLimit(2)
      }

      if let preview = toolCallRecord.resultPreview, !preview.text.isEmpty {
        Text(preview.text)
          .font(.system(.caption2, design: .monospaced))
          .frame(maxWidth: .infinity, alignment: .leading)
          .lineLimit(12)
          .padding(6)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
      }
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
  }
}

extension ToolResultStatus {
  fileprivate var summarySystemImage: String {
    switch self {
    case .success:
      "checkmark"
    case .failed, .denied:
      "xmark"
    }
  }

  fileprivate var statusColor: Color {
    switch self {
    case .success:
      .green
    case .failed, .denied:
      .orange
    }
  }
}

extension ChatGenerationMetrics {
  fileprivate var tokenRateSummary: String {
    tokensPerSecond.tokenRateSummary
  }
}

extension Double {
  fileprivate var tokenRateSummary: String {
    "\(formatted(.number.precision(.fractionLength(1)))) tok/s"
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
    status.statusColor
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
