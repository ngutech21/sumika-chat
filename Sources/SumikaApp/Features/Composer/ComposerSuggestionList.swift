import SumikaCore
import SwiftUI

enum ComposerSuggestion: Identifiable, Equatable {
  case slash(SlashCommandDescriptor)
  case skill(SkillDescriptor)

  var id: String {
    switch self {
    case .slash(let descriptor): "slash:\(descriptor.id)"
    case .skill(let descriptor): "skill:\(descriptor.id.rawValue)"
    }
  }
}

struct ComposerSuggestionList: View {
  let suggestions: [ComposerSuggestion]
  let diagnostics: [SkillDiagnostic]
  let selectedIndex: Int
  let onSelect: (ComposerSuggestion) -> Void
  let onHighlight: (Int) -> Void
  @State private var diagnosticsExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
              row(suggestion, index: index)
                .id(suggestion.id)
            }
          }
        }
        .onChange(of: selectedIndex) { _, index in
          guard suggestions.indices.contains(index) else { return }
          proxy.scrollTo(suggestions[index].id, anchor: .center)
        }
      }
      .frame(maxHeight: 320)

      if !diagnostics.isEmpty {
        Divider()
        Button {
          diagnosticsExpanded.toggle()
        } label: {
          HStack(spacing: 6) {
            Image(systemName: diagnosticsExpanded ? "chevron.down" : "chevron.right")
              .font(.caption2.weight(.semibold))
            Text("\(diagnostics.count) invalid \(diagnostics.count == 1 ? "skill" : "skills")")
              .font(.caption)
            Spacer()
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("skill-diagnostics-footer")

        if diagnosticsExpanded {
          ScrollView {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(diagnostics) { diagnostic in
                VStack(alignment: .leading, spacing: 2) {
                  Text(diagnostic.portablePath)
                    .font(.caption.monospaced())
                  Text(diagnostic.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
              }
            }
          }
          .frame(maxHeight: 120)
          .accessibilityIdentifier("skill-diagnostics-list")
        }
      }
    }
    .padding(4)
    .glassPanel(cornerRadius: 12)
    .frame(maxWidth: .infinity, maxHeight: 320, alignment: .leading)
    .accessibilityIdentifier(accessibilityIdentifier)
  }

  private var accessibilityIdentifier: String {
    if suggestions.allSatisfy({
      if case .slash = $0 { return true }
      return false
    }) {
      return "slash-command-suggestions"
    }
    return "skill-suggestions"
  }

  private func row(_ suggestion: ComposerSuggestion, index: Int) -> some View {
    HStack(spacing: 8) {
      switch suggestion {
      case .slash(let descriptor):
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
      case .skill(let descriptor):
        Text("$\(descriptor.name)")
          .font(.system(.callout, design: .monospaced))
          .fontWeight(.medium)
        Text(descriptor.description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 12)
        Text(descriptor.scope == .project ? "Project" : "Personal")
          .font(.caption2.weight(.medium))
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      index == selectedIndex ? Color.accentColor.opacity(0.18) : Color.clear,
      in: RoundedRectangle(cornerRadius: 5)
    )
    .contentShape(Rectangle())
    .onTapGesture { onSelect(suggestion) }
    .onHover { isHovering in
      if isHovering { onHighlight(index) }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(rowAccessibilityLabel(suggestion))
    .accessibilityValue(index == selectedIndex ? "Selected" : "")
    .accessibilityIdentifier(rowAccessibilityIdentifier(suggestion))
  }

  private func rowAccessibilityLabel(_ suggestion: ComposerSuggestion) -> String {
    switch suggestion {
    case .slash(let descriptor):
      "\(descriptor.token), \(descriptor.summary)"
    case .skill(let descriptor):
      "$\(descriptor.name), \(descriptor.description), "
        + (descriptor.scope == .project ? "Project" : "Personal")
    }
  }

  private func rowAccessibilityIdentifier(_ suggestion: ComposerSuggestion) -> String {
    switch suggestion {
    case .slash(let descriptor): "slash-command-suggestion.\(descriptor.name)"
    case .skill(let descriptor): "skill-suggestion.\(descriptor.id.rawValue)"
    }
  }
}
