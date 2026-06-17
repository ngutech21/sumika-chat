import AppKit
import SumikaCore
import SwiftUI

struct TodoPlanPanel: View {
  let todoState: TodoState
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.easeOut(duration: 0.18)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "checklist")
            .foregroundStyle(Color.accentColor)

          VStack(alignment: .leading, spacing: 2) {
            Text("Plan")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)

            Text(compactTitle)
              .font(.callout)
              .lineLimit(1)
          }

          Spacer(minLength: 12)

          Text(progressSummary)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

          Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("agent.todoPanel.toggle")
      .accessibilityLabel(isExpanded ? "Collapse Agent plan" : "Expand Agent plan")

      if isExpanded {
        Divider()
          .padding(.vertical, 8)

        if todoState.items.count <= 4 {
          todoItems
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .accessibilityIdentifier("agent.todoPanel.items")
        } else {
          ScrollView {
            todoItems
          }
          .frame(maxHeight: 132)
          .transition(.opacity.combined(with: .move(edge: .bottom)))
          .accessibilityIdentifier("agent.todoPanel.items")
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: 640)
    .glassPanel(cornerRadius: 12)
    .shadow(color: Color.black.opacity(0.14), radius: 16, x: 0, y: 8)
    .accessibilityIdentifier("agent.todoPanel")
  }

  private var compactTitle: String {
    if let inProgress = todoState.items.first(where: { $0.status == .inProgress }) {
      return inProgress.content
    }
    if let blocked = todoState.items.first(where: { $0.status == .blocked }) {
      return blocked.content
    }
    return todoState.items.first?.content ?? "Agent plan"
  }

  private var progressSummary: String {
    let completedCount = todoState.items.filter { $0.status == .completed }.count
    return "\(completedCount)/\(todoState.items.count) done"
  }

  private var todoItems: some View {
    VStack(alignment: .leading, spacing: 7) {
      ForEach(todoState.items) { item in
        TodoPlanItemRow(item: item)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct TodoPlanItemRow: View {
  let item: TodoItem

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: item.status.systemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(item.status.tint)
        .frame(width: 14)

      Text(item.content)
        .font(.callout)
        .lineLimit(2)

      Spacer(minLength: 8)

      Text(item.status.displayName)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .padding(.vertical, 1)
  }
}

extension TodoStatus {
  fileprivate var systemImage: String {
    switch self {
    case .pending:
      "circle"
    case .inProgress:
      "arrow.triangle.2.circlepath"
    case .completed:
      "checkmark.circle.fill"
    case .blocked:
      "exclamationmark.octagon.fill"
    }
  }

  fileprivate var tint: Color {
    switch self {
    case .pending:
      .secondary
    case .inProgress:
      .accentColor
    case .completed:
      .green
    case .blocked:
      .orange
    }
  }
}
