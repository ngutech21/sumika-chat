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
  @State private var isResultExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Label("Tool result", systemImage: toolResult.systemImage)
          .font(.headline)

        Spacer(minLength: 8)

        Text(toolResult.preview.status.rawValue)
          .font(.caption.weight(.medium))
          .foregroundStyle(toolResult.statusColor)
      }

      LabeledContent("Tool", value: toolResult.toolName.rawValue)
      Text("Call ID \(toolResult.callID.uuidString)")
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)

      if !toolResult.metaSummary.isEmpty {
        Text(toolResult.metaSummary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      if !toolResult.preview.text.isEmpty {
        DisclosureGroup(isExpanded: $isResultExpanded) {
          Divider()
          Text(toolResult.preview.text)
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
}

extension ToolResultModelMessage {
  var systemImage: String {
    preview.status == .success ? "checkmark.circle" : "exclamationmark.triangle"
  }

  var statusColor: Color {
    switch preview.status {
    case .success:
      .green
    case .failed, .denied:
      .orange
    }
  }

  var metaSummary: String {
    var parts: [String] = []

    if !preview.affectedPaths.isEmpty {
      parts.append(pathSummary)
    }

    if preview.truncated {
      parts.append("truncated")
    }

    parts.append(resultSizeSummary)
    return parts.joined(separator: " · ")
  }

  private var pathSummary: String {
    guard let firstPath = preview.affectedPaths.first else {
      return ""
    }

    if preview.affectedPaths.count == 1 {
      return firstPath
    }

    return "\(firstPath) +\(preview.affectedPaths.count - 1) paths"
  }

  private var resultSizeSummary: String {
    let lineCount = preview.text.isEmpty ? 0 : preview.text.components(separatedBy: .newlines).count
    let byteCount = preview.text.utf8.count
    let formattedBytes = ByteCountFormatter.string(
      fromByteCount: Int64(byteCount),
      countStyle: .file
    )
    return "\(lineCount) lines, \(formattedBytes)"
  }
}
