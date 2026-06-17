import SumikaCore
import SwiftUI

/// A compact circular context-window gauge shown in the composer's control row.
/// The ring alone communicates how full the context is; the exact token values
/// live in a popover (Claude Code style) so the composer stays uncluttered.
struct ComposerContextRing: View {
  let usage: ChatContextUsage?
  @State private var isPopoverPresented = false

  var body: some View {
    if let usage, let fraction = usage.fraction {
      Button {
        isPopoverPresented.toggle()
      } label: {
        ContextRing(fraction: fraction, tint: ContextUsageTint.color(for: fraction))
          .frame(width: 15, height: 15)
          .padding(.horizontal, 2)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Context window usage")
      .accessibilityIdentifier("composer.contextRing")
      .accessibilityLabel("Context window usage")
      .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
        ContextUsagePopover(usage: usage)
      }
    }
  }
}

private struct ContextRing: View {
  let fraction: Double
  let tint: Color
  var lineWidth: CGFloat = 2.5

  var body: some View {
    ZStack {
      Circle()
        .stroke(Color.secondary.opacity(0.2), lineWidth: lineWidth)
      Circle()
        .trim(from: 0, to: min(max(fraction, 0.0001), 1))
        .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
  }
}

private struct ContextUsagePopover: View {
  let usage: ChatContextUsage

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text("Context window")
          .foregroundStyle(.secondary)
        Spacer(minLength: 24)
        Text(headline)
          .monospacedDigit()
      }
      .font(.callout)

      if let fraction = usage.fraction {
        ContextProgressBar(
          fraction: fraction,
          tint: ContextUsageTint.color(for: fraction),
          height: 5
        )
      }

      if usage.accuracy == .estimate || usage.isStale {
        Text("Estimated; the exact count updates when the model is idle.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(14)
    .frame(width: 280, alignment: .leading)
  }

  private var headline: String {
    let prefix = usage.accuracy == .estimate ? "~" : ""
    let used = CompactTokens.format(usage.usedTokens)
    guard let tokenLimit = usage.tokenLimit, let fraction = usage.fraction else {
      return "\(prefix)\(used)"
    }

    let percent = Int((fraction * 100).rounded())
    return "\(prefix)\(used) / \(CompactTokens.format(tokenLimit)) (\(percent)%)"
  }
}

private struct ContextProgressBar: View {
  let fraction: Double
  let tint: Color
  var height: CGFloat = 3

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.secondary.opacity(0.2))
        Capsule()
          .fill(tint)
          .frame(width: geometry.size.width * min(max(fraction, 0), 1))
      }
    }
    .frame(height: height)
  }
}

enum CompactTokens {
  static func format(_ value: Int) -> String {
    guard value >= 1000 else {
      return "\(value)"
    }

    return String(format: "%.1fk", Double(value) / 1000)
  }
}

enum ContextUsageTint {
  static func color(for fraction: Double) -> Color {
    switch fraction {
    case ..<0.85: .accentColor
    case ..<1.0: .orange
    default: .red
    }
  }
}
