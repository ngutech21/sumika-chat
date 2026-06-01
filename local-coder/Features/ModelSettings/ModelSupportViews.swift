import SwiftUI

struct DownloadProgressView: View {
  let progress: Double?

  var body: some View {
    if let progress {
      ProgressView(value: progress) {
        Text("Downloading model")
      } currentValueLabel: {
        Text(progress.formatted(.percent.precision(.fractionLength(0))))
          .monospacedDigit()
      }
    } else {
      ProgressView {
        Text("Preparing download")
      }
    }
  }
}

struct ManagedModelRow: View {
  let model: ManagedModel
  let isSelected: Bool
  let isActive: Bool
  let isDownloaded: Bool
  let downloadState: ModelDownloadState
  let canSelect: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 12) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? Color.accentColor : .secondary)

        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(model.displayName)
              .font(.headline)

            if model.isRecommended {
              Text("Recommended")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if model.requiresLargeMemory {
              Label("High memory", systemImage: "memorychip")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }

          Text(model.detail)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }

        Spacer()

        VStack(alignment: .trailing, spacing: 4) {
          Text(model.estimatedDownloadSize)
            .foregroundStyle(.secondary)
            .monospacedDigit()
          Text(statusText)
            .font(.caption)
            .foregroundStyle(statusTint)
        }
      }
      .padding(12)
      .background(isSelected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.07))
      .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .disabled(!canSelect && !isSelected)
  }

  private var statusText: String {
    if isActive {
      return "Active"
    }

    switch downloadState {
    case .downloading(let progress):
      guard let progress else {
        return "Downloading"
      }
      return progress.formatted(.percent.precision(.fractionLength(0)))
    case .failed:
      return "Failed"
    case .downloaded:
      return "Ready"
    case .idle:
      return isDownloaded ? "Ready" : "Not downloaded"
    }
  }

  private var statusTint: Color {
    if isActive || isDownloaded {
      return .green
    }

    if case .failed = downloadState {
      return .red
    }

    return .secondary
  }
}

struct ModelRuntimeStatus: View {
  let modelState: ModelLoadState
  let downloadState: ModelDownloadState
  let contextUsage: ChatContextUsage?
  let processUsage: ProcessResourceUsage?

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
      GridRow {
        StatusValue(
          title: "Runtime", systemImage: modelState.systemImage, value: modelState.label,
          tint: modelState.tint)
        StatusValue(
          title: "Download", systemImage: "arrow.down.circle", value: downloadState.label,
          tint: downloadTint)
      }

      GridRow {
        StatusValue(
          title: "Context",
          systemImage: "rectangle.stack",
          value: contextUsage?.summary ?? "Not loaded",
          tint: .secondary
        )
        StatusValue(
          title: "Memory",
          systemImage: "memorychip",
          value: processUsage?.memorySummary ?? "Measuring",
          tint: .secondary
        )
      }
    }
    .font(.callout)
  }

  private var downloadTint: Color {
    switch downloadState {
    case .downloaded:
      .green
    case .failed:
      .red
    case .idle, .downloading:
      .secondary
    }
  }
}

private struct StatusValue: View {
  let title: String
  let systemImage: String
  let value: String
  let tint: Color

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: systemImage)
        .foregroundStyle(tint)
        .frame(width: 18)
      Text(title)
      Spacer(minLength: 12)
      Text(value)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
  }
}

struct ModelAdvancedSettings: View {
  let model: ManagedModel
  @Binding var systemPrompt: String
  @Binding var generationSettings: ChatGenerationSettings
  @Binding var contextTokenLimit: Int
  let canChangeContextTokenLimit: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      LabeledContent("Hugging Face") {
        Text(model.huggingFaceRepoID)
          .textSelection(.enabled)
          .foregroundStyle(.secondary)
      }

      LabeledContent("Local Folder") {
        Text(model.localPath)
          .textSelection(.enabled)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 6) {
        Label("System Prompt", systemImage: "text.quote")
        TextField("System Prompt", text: $systemPrompt, axis: .vertical)
          .textFieldStyle(.roundedBorder)
          .lineLimit(4...8)
      }

      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Label("Creativity", systemImage: "thermometer.variable")
          Spacer()
          Text(generationSettings.temperature.formatted(.number.precision(.fractionLength(1))))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        Slider(value: $generationSettings.temperature, in: 0...2, step: 0.1)
      }

      Stepper(value: $generationSettings.maxTokens, in: 128...8192, step: 128) {
        SettingValueLabel(title: "Response Length", value: "\(generationSettings.maxTokens)")
      }

      Stepper(value: $contextTokenLimit, in: 4096...131072, step: 4096) {
        SettingValueLabel(title: "Context Length", value: formattedContextTokenLimit)
      }
      .disabled(!canChangeContextTokenLimit)

      Divider()

      VStack(alignment: .leading, spacing: 10) {
        Text("Technical Generation")
          .font(.headline)

        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Label("Top P", systemImage: "chart.line.uptrend.xyaxis")
            Spacer()
            Text(generationSettings.topP.formatted(.number.precision(.fractionLength(2))))
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
          Slider(value: $generationSettings.topP, in: 0.05...1, step: 0.05)
        }

        Stepper(value: $generationSettings.topK, in: 0...200, step: 10) {
          SettingValueLabel(title: "Top K", value: "\(generationSettings.topK)")
        }
      }

      Button("Coding Defaults") {
        systemPrompt = model.defaultSystemPrompt
        generationSettings = model.defaultGenerationSettings
        contextTokenLimit = model.defaultContextTokenLimit
      }
    }
    .padding(.top, 10)
  }

  private var formattedContextTokenLimit: String {
    "\(contextTokenLimit / 1024)K"
  }
}

private struct SettingValueLabel: View {
  let title: String
  let value: String

  var body: some View {
    HStack {
      Text(title)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
  }
}

extension ModelLoadState {
  var tint: Color {
    switch self {
    case .notLoaded, .loading:
      .secondary
    case .ready:
      .green
    case .failed:
      .red
    }
  }
}
