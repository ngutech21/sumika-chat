import SumikaCore
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
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(tileTint.opacity(0.16))
          .frame(width: 30, height: 30)
          .overlay {
            Image(systemName: tileSymbol)
              .font(.system(size: 15, weight: .medium))
              .foregroundStyle(tileTint)
          }

        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 8) {
            Text(model.displayName)
              .font(.body.weight(.medium))

            if model.isRecommended {
              Text("Recommended")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.14), in: Capsule())
            }

            if model.stability == .experimental {
              Label("Experimental", systemImage: "testtube.2")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .accessibilityIdentifier("model-experimental-badge-\(model.id)")
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

        Spacer(minLength: 12)

        VStack(alignment: .trailing, spacing: 3) {
          Text(model.estimatedDownloadSize)
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
          HStack(spacing: 4) {
            if isActive || isDownloaded {
              Circle()
                .fill(statusTint)
                .frame(width: 6, height: 6)
            }
            Text(statusText)
              .font(.caption)
              .foregroundStyle(statusTint)
          }
        }

        Image(systemName: "checkmark")
          .font(.body.weight(.semibold))
          .foregroundStyle(Color.accentColor)
          .opacity(isSelected ? 1 : 0)
          .frame(width: 16)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!canSelect && !isSelected)
    .listRowBackground(isSelected ? Color.accentColor.opacity(0.10) : nil)
    .accessibilityIdentifier("model-row-\(model.id)")
  }

  private var tileSymbol: String { "cpu" }

  private var tileTint: Color {
    isSelected ? .accentColor : .secondary
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
    Group {
      LabeledContent("Runtime") {
        Label(modelState.label, systemImage: modelState.systemImage)
          .foregroundStyle(modelState.tint)
      }

      LabeledContent("Download") {
        Label(downloadState.label, systemImage: "arrow.down.circle")
          .foregroundStyle(downloadTint)
      }

      LabeledContent("Context") {
        if let usage = contextUsage, let fraction = usage.fraction {
          HStack(spacing: 10) {
            Gauge(value: min(max(fraction, 0), 1)) {
              EmptyView()
            }
            .gaugeStyle(.accessoryLinearCapacity)
            .tint(ContextUsageTint.color(for: fraction))
            .frame(width: 90)

            Text(usage.summary)
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
        } else {
          Text(contextUsage?.summary ?? "Not loaded")
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
      }

      LabeledContent("Memory") {
        Text(processUsage?.memorySummary ?? "Measuring")
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
    }
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

struct ModelAdvancedSettings: View {
  let model: ManagedModel
  @Binding var systemPrompt: String
  @Binding var generationSettings: ChatGenerationSettings
  @Binding var contextTokenLimit: Int
  let canChangeContextTokenLimit: Bool

  var body: some View {
    Group {
      Section("Generation") {
        VStack(alignment: .leading, spacing: 6) {
          Label("System Prompt", systemImage: "text.quote")
          TextField("System Prompt", text: $systemPrompt, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(4...8)
            .labelsHidden()
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
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
      }

      Section("Advanced") {
        Toggle(isOn: maxKVSizeEnabled) {
          SettingValueLabel(title: "Custom KV Cache", value: formattedMaxKVSize)
        }

        Stepper(value: maxKVSizeValue, in: 4096...131072, step: 4096) {
          SettingValueLabel(title: "KV Cache Limit", value: formattedMaxKVSize)
        }
        .disabled(generationSettings.maxKVSize == nil)

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

        Button("Coding Defaults") {
          systemPrompt = model.defaultSystemPrompt
          generationSettings = model.defaultGenerationSettings
          contextTokenLimit = model.defaultContextTokenLimit
        }
      }
    }
  }

  private var formattedContextTokenLimit: String {
    "\(contextTokenLimit / 1024)K"
  }

  private var formattedMaxKVSize: String {
    guard let maxKVSize = generationSettings.maxKVSize else {
      return "Runtime"
    }

    return "\(maxKVSize / 1024)K"
  }

  private var maxKVSizeEnabled: Binding<Bool> {
    Binding(
      get: { generationSettings.maxKVSize != nil },
      set: { isEnabled in
        generationSettings.maxKVSize = isEnabled ? contextTokenLimit : nil
      }
    )
  }

  private var maxKVSizeValue: Binding<Int> {
    Binding(
      get: { generationSettings.maxKVSize ?? contextTokenLimit },
      set: { generationSettings.maxKVSize = $0 }
    )
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
