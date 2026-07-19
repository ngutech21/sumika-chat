import SumikaCore
import SwiftUI

/// A combo-box style list of slash-command suggestions shown above the composer
/// input while the user is typing a `/command` token.
struct SlashCommandSuggestionList: View {
  let suggestions: [SlashCommandDescriptor]
  let selectedIndex: Int
  let onSelect: (SlashCommandDescriptor) -> Void
  let onHighlight: (Int) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, descriptor in
        row(descriptor, index: index)
      }
    }
    .padding(4)
    .glassPanel(cornerRadius: 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("slash-command-suggestions")
  }

  private func row(_ descriptor: SlashCommandDescriptor, index: Int) -> some View {
    HStack(spacing: 8) {
      Text(descriptor.token)
        .font(.system(.callout, design: .monospaced))
        .fontWeight(.medium)

      if let argumentHint = descriptor.argumentHint {
        Text(argumentHint)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.tertiary)
      }

      Spacer(minLength: 16)

      Text(descriptor.summary)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      index == selectedIndex ? Color.accentColor.opacity(0.18) : Color.clear,
      in: RoundedRectangle(cornerRadius: 5)
    )
    .contentShape(Rectangle())
    .onTapGesture {
      onSelect(descriptor)
    }
    .onHover { isHovering in
      if isHovering {
        onHighlight(index)
      }
    }
    .accessibilityIdentifier("slash-command-suggestion.\(descriptor.name)")
  }
}
