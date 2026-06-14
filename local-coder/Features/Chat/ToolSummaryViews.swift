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

  private let detailIndent: CGFloat = 17

  var body: some View {
    let toolCall = ToolCallModelMessage(request: toolCallRecord.request)
    let resultDisplay = resultDisplayPayload
    let detailsAvailable = hasDetails(resultDisplay: resultDisplay)
    VStack(alignment: .leading, spacing: 6) {
      Button {
        isDetailsExpanded.toggle()
      } label: {
        HStack(spacing: 6) {
          ToolStatusIndicator(status: displayStatus)

          Text(toolCall.toolName.rawValue)
            .fontWeight(.medium)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .layoutPriority(1)

          if let headerSummary = toolCall.headerSummary {
            Text(headerSummary)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }

          if detailsAvailable {
            Image(systemName: showsDetails ? "chevron.down" : "chevron.right")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.tertiary)
          }

          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!detailsAvailable)
      .help(showsDetails ? "Hide details" : "Show details")

      if showsDetails {
        VStack(alignment: .leading, spacing: 6) {
          ToolCallDetailsView(
            toolCall: toolCall,
            toolCallRecord: toolCallRecord,
            showsPreview: toolCallRecord.status == .awaitingApproval
          )

          if let resultDisplay, !resultDisplay.text.isEmpty {
            ToolDetailTextView(text: resultDisplay.text)
          }

          ToolGenerationMetricsDetail(generationMetrics: generationMetrics)
        }
        .padding(.leading, detailIndent)
      }

      if toolCallRecord.status == .awaitingUserAnswer,
        let input = toolCallRecord.askUserInput
      {
        AskUserAnswerView(
          toolCallID: toolCallRecord.id,
          input: input,
          onAnswer: onAnswerAskUser
        )
        .padding(.leading, detailIndent)
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
          .buttonStyle(.bordered)
          .tint(.green)
          .accessibilityLabel("Approve tool call")

          Button(role: .destructive) {
            onDeny(toolCallRecord.id)
          } label: {
            Label("Deny", systemImage: "xmark")
          }
          .controlSize(.small)
          .buttonStyle(.bordered)
          .accessibilityLabel("Deny tool call")
        }
        .padding(.leading, detailIndent)
        .padding(.top, 1)
      }
    }
    .font(.caption)
    .padding(.vertical, 3)
    .accessibilityLabel(accessibilityLabel(toolCall: toolCall))
  }

  /// The projected result of the tool call, if it has finished executing.
  private var resultDisplayPayload: ToolDisplayPayload? {
    guard toolCallRecord.resultPayload != nil else {
      return nil
    }
    return ToolResultModelMessage(record: toolCallRecord).displayPayload(for: toolCallRecord)
  }

  /// The status shown on the turn's single row. Once a result exists it reflects
  /// the command's own outcome (a tool can finish while its command fails), so a
  /// failed run reads as a failure rather than a misleading success.
  private var displayStatus: ToolCallStatus {
    guard let payload = toolCallRecord.resultPayload else {
      return toolCallRecord.status
    }
    switch payload.status {
    case .success:
      return .completed
    case .failed:
      return .failed
    case .denied:
      return .denied
    }
  }

  private func hasDetails(resultDisplay: ToolDisplayPayload?) -> Bool {
    let toolCall = ToolCallModelMessage(request: toolCallRecord.request)
    if !toolCall.transcriptArguments.isEmpty {
      return true
    }
    if toolCallRecord.approvalPreview?.text.isEmpty == false {
      return true
    }
    if generationMetrics != nil {
      return true
    }
    if let resultDisplay, !resultDisplay.text.isEmpty {
      return true
    }
    return false
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

  fileprivate var isInProgress: Bool {
    switch self {
    case .pending, .running:
      true
    default:
      false
    }
  }

  fileprivate var quietSystemImage: String {
    switch self {
    case .completed:
      "checkmark"
    case .failed, .denied:
      "xmark"
    case .cancelled:
      "minus"
    case .awaitingApproval, .awaitingUserAnswer:
      "exclamationmark"
    case .pending, .running:
      "ellipsis"
    }
  }

  fileprivate var quietColor: Color {
    switch self {
    case .completed:
      .green
    case .failed, .denied:
      .orange
    case .cancelled:
      .secondary
    case .awaitingApproval, .awaitingUserAnswer:
      .orange
    case .pending, .running:
      .secondary
    }
  }
}

/// A muted status indicator for a tool turn: a small spinner while work is in
/// flight, otherwise a quiet tinted glyph (check / cross / needs-attention).
private struct ToolStatusIndicator: View {
  let status: ToolCallStatus

  var body: some View {
    Group {
      if status.isInProgress {
        ProgressView()
          .controlSize(.small)
          .scaleEffect(0.7)
      } else {
        Image(systemName: status.quietSystemImage)
          .font(.caption.weight(.semibold))
          .foregroundStyle(status.quietColor)
      }
    }
    .frame(width: 13, height: 13)
    .accessibilityHidden(true)
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
  var showsPreview = true

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
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
