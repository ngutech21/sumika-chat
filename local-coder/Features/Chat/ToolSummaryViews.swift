import AppKit
import LocalCoderCore
import SwiftUI

struct ToolExecutionSummaryView: View {
  let toolCallRecord: ToolCallRecord
  let generationMetrics: ChatGenerationMetrics?
  let onApprove: (ToolCallRecord.ID) -> Void
  let onDeny: (ToolCallRecord.ID) -> Void
  let onAnswerAskUser: (ToolCallRecord.ID, String) -> Void
  @State private var isDetailsExpanded = false
  @State private var isResultExpanded = false

  var body: some View {
    let toolCall = ToolCallModelMessage(request: toolCallRecord.request)
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 7) {
        Image(systemName: toolCallRecord.status.executionSystemImage)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(toolCallRecord.status.executionColor)
          .accessibilityHidden(true)

        Text("Tool")
          .foregroundStyle(.secondary)

        Text(toolCall.toolName.rawValue)
          .fontWeight(.semibold)
          .lineLimit(1)

        if let headerSummary = toolCall.headerSummary {
          Text(":")
            .foregroundStyle(.secondary)

          Text(headerSummary)
            .fontWeight(.semibold)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Spacer(minLength: 8)

        if hasDetails {
          Button {
            isDetailsExpanded.toggle()
          } label: {
            Image(systemName: isDetailsExpanded ? "chevron.down" : "chevron.right")
              .font(.caption2.weight(.semibold))
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help(isDetailsExpanded ? "Hide details" : "Show details")
          .accessibilityLabel(isDetailsExpanded ? "Hide tool details" : "Show tool details")
        }
      }

      if showsDetails {
        ToolCallDetailsView(
          toolCall: toolCall,
          toolCallRecord: toolCallRecord,
          generationMetrics: generationMetrics,
          showsPreview: toolCallRecord.status == .awaitingApproval
        )
      }

      if toolCallRecord.status == .awaitingUserAnswer,
        let input = toolCallRecord.askUserInput
      {
        AskUserAnswerView(
          toolCallID: toolCallRecord.id,
          input: input,
          onAnswer: onAnswerAskUser
        )
      }

      if toolCallRecord.status == .awaitingApproval || toolCallRecord.status == .awaitingUserAnswer
      {
        HStack(spacing: 8) {
          Button {
            onApprove(toolCallRecord.id)
          } label: {
            Label("Approve", systemImage: "checkmark")
          }
          .controlSize(.small)
          .accessibilityLabel("Approve tool call")

          Button(role: .destructive) {
            onDeny(toolCallRecord.id)
          } label: {
            Label("Deny", systemImage: "xmark")
          }
          .controlSize(.small)
          .accessibilityLabel("Deny tool call")
        }
      }

      if let resultPayload = toolCallRecord.resultPayload {
        Divider()

        ToolExecutionResultView(
          toolResult: ToolResultModelMessage(record: toolCallRecord),
          toolCallRecord: toolCallRecord,
          payload: resultPayload,
          isExpanded: $isResultExpanded
        )
      }
    }
    .font(.caption)
    .padding(.vertical, 8)
    .padding(.leading, 16)
    .padding(.trailing, 8)
    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    .overlay(alignment: .leading) {
      Capsule()
        .fill(toolCallRecord.status.executionColor)
        .frame(width: 3)
        .padding(.vertical, 7)
        .padding(.leading, 5)
    }
    .accessibilityLabel(accessibilityLabel(toolCall: toolCall))
  }

  private var hasDetails: Bool {
    let toolCall = ToolCallModelMessage(request: toolCallRecord.request)
    return !toolCall.transcriptArguments.isEmpty
      || toolCallRecord.approvalPreview?.text.isEmpty == false
      || generationMetrics != nil
  }

  private var showsDetails: Bool {
    isDetailsExpanded || toolCallRecord.status == .awaitingApproval
  }

  private func accessibilityLabel(toolCall: ToolCallModelMessage) -> String {
    var parts = ["Tool \(toolCall.toolName.rawValue)", toolCallRecord.status.displayName]
    if let generationMetrics {
      parts.append(generationMetrics.tokenRateSummary)
    }
    return parts.joined(separator: ", ")
  }
}

struct ToolCallSummaryView: View {
  let toolCall: ToolCallModelMessage
  let toolCallRecord: ToolCallRecord?
  let generationMetrics: ChatGenerationMetrics?
  let onApprove: (ToolCallRecord.ID) -> Void
  let onDeny: (ToolCallRecord.ID) -> Void
  let onAnswerAskUser: (ToolCallRecord.ID, String) -> Void
  @State private var isDetailsExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      ToolSummaryRow(
        leadingImage: "wrench.and.screwdriver",
        title: "Tool call:",
        toolName: toolCall.toolName.rawValue,
        statusImage: toolCallRecord?.status.summarySystemImage ?? "ellipsis",
        statusColor: toolCallRecord?.status.summaryColor ?? .secondary,
        detailsAvailable: hasDetails,
        isDetailsExpanded: $isDetailsExpanded
      )

      if let toolCallRecord {
        if isDetailsExpanded {
          ToolCallDetailsView(
            toolCall: toolCall,
            toolCallRecord: toolCallRecord,
            generationMetrics: generationMetrics
          )
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

        if toolCallRecord.status == .awaitingUserAnswer,
          let input = toolCallRecord.askUserInput
        {
          AskUserAnswerView(
            toolCallID: toolCallRecord.id,
            input: input,
            onAnswer: onAnswerAskUser
          )
        }
      }
    }
    .font(.caption)
    .accessibilityLabel(accessibilityLabel)
  }

  private var hasDetails: Bool {
    !toolCall.transcriptArguments.isEmpty
      || toolCallRecord?.resultPreview?.text.isEmpty == false
      || generationMetrics != nil
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
    case .awaitingUserAnswer:
      "awaiting user answer"
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
    case .awaitingApproval, .awaitingUserAnswer, .pending, .running:
      "ellipsis"
    }
  }

  fileprivate var summaryColor: Color {
    switch self {
    case .completed:
      .green
    case .failed, .denied, .cancelled:
      .orange
    case .awaitingApproval, .awaitingUserAnswer, .pending, .running:
      .secondary
    }
  }

  fileprivate var executionSystemImage: String {
    switch self {
    case .completed:
      "checkmark.circle.fill"
    case .failed, .denied:
      "xmark.circle.fill"
    case .cancelled:
      "minus.circle.fill"
    case .awaitingApproval, .awaitingUserAnswer:
      "exclamationmark.circle.fill"
    case .pending, .running:
      "ellipsis.circle.fill"
    }
  }

  fileprivate var executionColor: Color {
    switch self {
    case .completed:
      .green
    case .failed, .denied, .cancelled:
      .orange
    case .awaitingApproval, .awaitingUserAnswer:
      .yellow
    case .pending, .running:
      .secondary
    }
  }
}

private struct AskUserAnswerView: View {
  let toolCallID: ToolCallRecord.ID
  let input: AskUserInput
  let onAnswer: (ToolCallRecord.ID, String) -> Void
  @State private var selectedOption = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(input.question)
        .font(.caption)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)

      let options = input.options
      if !options.isEmpty {
        HStack(spacing: 6) {
          Picker("Answer", selection: selectedOptionBinding(options: options)) {
            ForEach(options, id: \.self) { option in
              Text(option)
                .tag(option)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .controlSize(.small)
          .frame(minWidth: 180, maxWidth: 320, alignment: .leading)
          .accessibilityIdentifier("askUser.optionPicker")

          Button {
            submitSelectedOption(options: options)
          } label: {
            Image(systemName: "arrow.up.circle.fill")
          }
          .buttonStyle(.borderless)
          .disabled(selectedAnswer(options: options).isEmpty)
          .help("Send answer")
          .accessibilityLabel("Send selected answer")
        }
      }

    }
    .padding(.top, 3)
  }

  private func selectedOptionBinding(options: [String]) -> Binding<String> {
    Binding(
      get: {
        selectedAnswer(options: options)
      },
      set: { value in
        selectedOption = value
      }
    )
  }

  private func selectedAnswer(options: [String]) -> String {
    guard !options.isEmpty else {
      return ""
    }
    return options.contains(selectedOption) ? selectedOption : options[0]
  }

  private func submitSelectedOption(options: [String]) {
    let answer = selectedAnswer(options: options)
    guard !answer.isEmpty else {
      return
    }
    onAnswer(toolCallID, answer)
  }
}

extension ToolCallRecord {
  fileprivate var askUserInput: AskUserInput? {
    guard case .askUser(let input) = request.payload else {
      return nil
    }
    return input
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
        detailsAvailable: !display.text.isEmpty || generationMetrics != nil,
        isDetailsExpanded: $isResultExpanded
      )

      if isResultExpanded {
        ToolGenerationMetricsDetail(generationMetrics: generationMetrics)

        if !display.text.isEmpty {
          ToolDetailTextView(text: display.text)
        }
      }
    }
    .font(.caption)
    .accessibilityLabel(accessibilityLabel(status: display.status))
  }

  private var displayPayload: ToolDisplayPayload {
    toolResult.displayPayload(for: toolCallRecord)
  }

  private func accessibilityLabel(status: ToolResultStatus) -> String {
    var parts = ["Tool result \(toolResult.toolName.rawValue)", status.rawValue]
    if let generationMetrics {
      parts.append(generationMetrics.tokenRateSummary)
    }
    return parts.joined(separator: ", ")
  }
}

private struct ToolExecutionResultView: View {
  let toolResult: ToolResultModelMessage
  let toolCallRecord: ToolCallRecord
  let payload: ToolResultPayload
  @Binding var isExpanded: Bool

  var body: some View {
    let display = toolResult.displayPayload(for: toolCallRecord)
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 7) {
        Image(systemName: display.status.summarySystemImage)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(display.status.statusColor)
          .accessibilityHidden(true)

        Text("Result")
          .foregroundStyle(.secondary)

        Text(payload.status.rawValue)
          .fontWeight(.semibold)

        if !display.metaSummary.isEmpty {
          Text(display.metaSummary)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer(minLength: 8)

        if !display.text.isEmpty {
          Button {
            isExpanded.toggle()
          } label: {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
              .font(.caption2.weight(.semibold))
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help(isExpanded ? "Hide result" : "Show result")
          .accessibilityLabel(isExpanded ? "Hide tool result" : "Show tool result")
        }
      }

      if isExpanded, !display.text.isEmpty {
        ToolDetailTextView(text: display.text)
      }
    }
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
  let generationMetrics: ChatGenerationMetrics?
  var showsPreview = true

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ToolGenerationMetricsDetail(generationMetrics: generationMetrics)

      ForEach(toolCall.transcriptArguments) { argument in
        Text("\(argument.name): \(argument.value)")
          .lineLimit(2)
      }

      if showsPreview, let preview = toolCallRecord.resultPreview, !preview.text.isEmpty {
        ToolDetailTextView(text: preview.text)
      }
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
  }
}

extension ToolResultModelMessage {
  fileprivate func displayPayload(for toolCallRecord: ToolCallRecord?) -> ToolDisplayPayload {
    guard let request = toolCallRecord?.request else {
      let preview = payload.preview
      return .summary(
        status: preview.status,
        text: preview.text,
        affectedPaths: preview.affectedPaths.map(WorkspaceRelativePath.init(rawValue:))
      )
    }

    return ToolResultProjector.project(
      payload: payload,
      request: request,
      policy: .default
    ).display
  }
}

extension ToolCallModelMessage {
  fileprivate var headerSummary: String? {
    switch toolName {
    case .runCommand:
      return argumentValue(named: "command")
    case .writeFile, .editFile, .readFile, .showFile:
      return argumentValue(named: "path")
    case .webSearch:
      return argumentValue(named: "query")
    case .webFetch:
      return argumentValue(named: "url")
    case .browserInspect:
      return argumentValue(named: "selector") ?? "document.body"
    case .browserRefresh:
      return argumentValue(named: "hard")
    default:
      return nil
    }
  }

  private func argumentValue(named name: String) -> String? {
    guard let value = arguments.first(where: { $0.name == name })?.value,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }
    return value
  }
}

private struct ToolGenerationMetricsDetail: View {
  let generationMetrics: ChatGenerationMetrics?

  var body: some View {
    if let generationMetrics {
      Text(generationMetrics.tokenRateSummary)
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }
  }
}

private struct ToolDetailTextView: View {
  let text: String

  var body: some View {
    LinkedText(
      text: text,
      font: .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
      textColor: .secondaryLabelColor
    )
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .fixedSize(horizontal: false, vertical: true)
    .padding(6)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
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
