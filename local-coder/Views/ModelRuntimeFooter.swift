import LocalCoderCore
import SwiftUI

/// A muted runtime-telemetry line pinned to the bottom of the sidebar. Shows the
/// model process's memory and CPU at a glance, with the full breakdown in a
/// popover. RAM/CPU describe the app-global model process, so they belong here
/// rather than in the per-session composer.
struct ModelRuntimeFooter: View {
  let processUsage: ProcessResourceUsage?
  @State private var isPopoverPresented = false

  var body: some View {
    Button {
      isPopoverPresented.toggle()
    } label: {
      HStack(spacing: 7) {
        Circle()
          .fill(statusColor)
          .frame(width: 7, height: 7)

        Text(summary)
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .lineLimit(1)

        Spacer(minLength: 0)

        Image(systemName: "chevron.up")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .help("Model runtime resource usage")
    .accessibilityIdentifier("sidebar.modelRuntimeFooter")
    .accessibilityLabel("Model runtime resource usage")
    .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
      ModelRuntimePopover(processUsage: processUsage)
    }
  }

  private var summary: String {
    guard let processUsage else {
      return "Measuring…"
    }

    return "\(processUsage.memorySummary) · \(processUsage.cpuSummary)"
  }

  private var statusColor: Color {
    processUsage == nil ? Color.secondary.opacity(0.5) : .green
  }
}

private struct ModelRuntimePopover: View {
  let processUsage: ProcessResourceUsage?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Model runtime")
        .font(.headline)

      VStack(alignment: .leading, spacing: 6) {
        row("Memory", processUsage?.memorySummary ?? "Measuring…")
        row("CPU", processUsage?.cpuSummary ?? "Measuring…")
      }
    }
    .padding(14)
    .frame(width: 220, alignment: .leading)
  }

  private func row(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label)
        .foregroundStyle(.secondary)
      Spacer(minLength: 16)
      Text(value)
        .monospacedDigit()
    }
    .font(.callout)
  }
}
