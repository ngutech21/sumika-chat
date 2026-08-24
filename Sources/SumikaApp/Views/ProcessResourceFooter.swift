import SwiftUI

/// App-global memory and CPU usage shown at the bottom of the sidebar.
struct ProcessResourceFooter: View {
  let monitor: ProcessResourceMonitor
  @State private var isPopoverPresented = false

  var body: some View {
    let processUsage = monitor.usage

    Button {
      isPopoverPresented.toggle()
    } label: {
      HStack(spacing: 7) {
        Circle()
          .fill(statusColor(for: processUsage))
          .frame(width: 7, height: 7)

        Text(summary(for: processUsage))
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .lineLimit(1)

        Spacer(minLength: 0)

        Image(systemName: "chevron.up")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Sumika process resource usage")
    .accessibilityIdentifier("sidebar.processResourceFooter")
    .accessibilityLabel("Sumika process resource usage")
    .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
      ProcessResourcePopover(processUsage: processUsage)
    }
  }

  private func summary(for processUsage: ProcessResourceUsage?) -> String {
    guard let processUsage else {
      return "Measuring…"
    }

    return "\(processUsage.memorySummary) · \(processUsage.cpuSummary)"
  }

  private func statusColor(for processUsage: ProcessResourceUsage?) -> Color {
    processUsage == nil ? Color.secondary.opacity(0.5) : .green
  }
}

private struct ProcessResourcePopover: View {
  let processUsage: ProcessResourceUsage?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Sumika process")
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
