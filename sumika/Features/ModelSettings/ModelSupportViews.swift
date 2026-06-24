import SumikaCore
import SwiftUI

struct DownloadProgressView: View {
  var title = "Downloading model"
  let progress: Double?

  var body: some View {
    if let progress {
      ProgressView(value: progress) {
        Text(title)
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

struct DrafterModelSummary: View {
  let drafter: ManagedDrafterModel
  let downloadState: ModelDownloadState
  let isDownloaded: Bool
  let isEnabled: Bool
  let isActionDisabled: Bool
  let onDownload: () -> Void

  var body: some View {
    HStack(spacing: 16) {
      Label {
        VStack(alignment: .leading, spacing: 3) {
          Text(drafter.displayName)
            .font(.body.weight(.medium))

          Text(statusText)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      } icon: {
        Image(systemName: "rectangle.stack.badge.plus")
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 16)

      Button(action: onDownload) {
        Label(actionTitle, systemImage: actionSystemImage)
      }
      .buttonStyle(.bordered)
      .disabled(isActionDisabled)
      .accessibilityIdentifier("download-drafter-button")
    }
    .padding(.vertical, 6)
  }

  private var statusText: String {
    switch downloadState {
    case .downloaded:
      return isEnabled
        ? "Downloaded and prepared for future MTP generation"
        : "Downloaded; future MTP use is disabled"
    case .downloading(let progress):
      if let progress {
        return "Downloading \(progress.formatted(.percent.precision(.fractionLength(0))))"
      }
      return "Downloading"
    case .failed(let message):
      return message
    case .idle:
      return "Optional drafter prepared for future MTP generation"
    }
  }

  private var actionTitle: String {
    if isDownloaded {
      return "Downloaded"
    }

    if case .failed = downloadState {
      return "Retry Drafter"
    }

    return "Add Drafter Model"
  }

  private var actionSystemImage: String {
    isDownloaded ? "checkmark.circle" : "plus.circle"
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

struct CurrentModelSummary: View {
  let model: ManagedModel
  let modelState: ModelLoadState
  let downloadState: ModelDownloadState
  let actionTitle: String
  let actionSystemImage: String
  let isActionDisabled: Bool
  let onAction: () -> Void

  var body: some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 3) {
        Text(summaryTitle)
          .font(.title3.weight(.semibold))
          .foregroundStyle(.primary)

        Text(summarySubtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 16)

      Button(action: onAction) {
        Label(actionTitle, systemImage: actionSystemImage)
      }
      .buttonStyle(.borderedProminent)
      .accessibilityIdentifier(actionAccessibilityIdentifier)
      .disabled(isActionDisabled)
    }
    .padding(.vertical, 8)
  }

  private var summaryTitle: String {
    if modelState == .ready {
      return "\(model.displayName) is active"
    }

    return model.displayName
  }

  private var summarySubtitle: String {
    switch modelState {
    case .ready:
      return "Ready to use in your chats"
    case .loading:
      return "Loading"
    case .failed(let message):
      return message
    case .notLoaded:
      return notLoadedSubtitle
    }
  }

  private var notLoadedSubtitle: String {
    switch downloadState {
    case .downloaded:
      return "Ready to load"
    case .idle:
      return "Download required before loading"
    case .downloading(let progress):
      if let progress {
        return "Downloading \(progress.formatted(.percent.precision(.fractionLength(0))))"
      }
      return "Downloading"
    case .failed:
      return "Download failed"
    }
  }

  private var actionAccessibilityIdentifier: String {
    switch actionTitle {
    case "Download":
      return "download-model-button"
    case "Unload":
      return "unload-model-button"
    default:
      return "load-model-button"
    }
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
  @Binding var modeSettings: ChatModeSettingsSet
  @Binding var contextTokenLimit: Int
  @Binding var drafterEnabled: Bool
  let canChangeDrafterEnabled: Bool
  let isDrafterDownloaded: Bool
  let canChangeContextTokenLimit: Bool
  @State private var selectedMode = WorkspaceInteractionMode.chat

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Generation")
          .font(.headline)

        Picker("Mode", selection: $selectedMode) {
          ForEach(WorkspaceInteractionMode.allCases, id: \.self) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        .pickerStyle(.segmented)

        VStack(alignment: .leading, spacing: 6) {
          Label("\(selectedMode.displayName) System Prompt", systemImage: "text.quote")
          TextField("System Prompt", text: selectedSystemPrompt, axis: .vertical)
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
            Text(
              selectedGenerationSettings.wrappedValue.temperature.formatted(
                .number.precision(.fractionLength(1)))
            )
            .foregroundStyle(.secondary)
            .monospacedDigit()
          }
          Slider(value: selectedTemperature, in: 0...2, step: 0.1)
        }

        Stepper(value: selectedMaxTokens, in: 128...8192, step: 128) {
          SettingValueLabel(
            title: "Response Length",
            value: "\(selectedGenerationSettings.wrappedValue.maxTokens)")
        }

        Stepper(value: $contextTokenLimit, in: 4096...131072, step: 4096) {
          SettingValueLabel(title: "Context Length", value: formattedContextTokenLimit)
        }
        .disabled(!canChangeContextTokenLimit)
      }

      Divider()

      VStack(alignment: .leading, spacing: 12) {
        Text("Advanced")
          .font(.headline)

        Toggle(isOn: maxKVSizeEnabled) {
          SettingValueLabel(title: "Custom KV Cache", value: formattedMaxKVSize)
        }

        Stepper(value: maxKVSizeValue, in: 4096...131072, step: 4096) {
          SettingValueLabel(title: "KV Cache Limit", value: formattedMaxKVSize)
        }
        .disabled(selectedGenerationSettings.wrappedValue.maxKVSize == nil)

        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Label("Top P", systemImage: "chart.line.uptrend.xyaxis")
            Spacer()
            Text(
              selectedGenerationSettings.wrappedValue.topP.formatted(
                .number.precision(.fractionLength(2)))
            )
            .foregroundStyle(.secondary)
            .monospacedDigit()
          }
          Slider(value: selectedTopP, in: 0.05...1, step: 0.05)
        }

        Stepper(value: selectedTopK, in: 0...200, step: 10) {
          SettingValueLabel(
            title: "Top K",
            value: "\(selectedGenerationSettings.wrappedValue.topK)")
        }

        if let drafter = model.drafterModel {
          Toggle(isOn: $drafterEnabled) {
            SettingValueLabel(title: "Drafter Preference", value: formattedDrafterPreference)
          }
          .disabled(!canChangeDrafterEnabled || !isDrafterDownloaded)

          LabeledContent("Drafter") {
            Text(drafter.huggingFaceRepoID)
              .textSelection(.enabled)
              .foregroundStyle(.secondary)
          }
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

        Button("Reset \(selectedMode.displayName) Defaults") {
          modeSettings[selectedMode] = model.defaultModeSettings[selectedMode]
        }

        Button("Reset Context Length") {
          contextTokenLimit = model.defaultContextTokenLimit
        }
      }
    }
    .padding(.vertical, 8)
  }

  private var formattedContextTokenLimit: String {
    "\(contextTokenLimit / 1024)K"
  }

  private var formattedMaxKVSize: String {
    guard let maxKVSize = selectedGenerationSettings.wrappedValue.maxKVSize else {
      return "Runtime"
    }

    return "\(maxKVSize / 1024)K"
  }

  private var formattedDrafterPreference: String {
    guard model.drafterModel != nil else {
      return "Unavailable"
    }
    guard isDrafterDownloaded else {
      return "Not downloaded"
    }
    return drafterEnabled ? "Prepared" : "Disabled"
  }

  private var selectedSystemPrompt: Binding<String> {
    Binding(
      get: { modeSettings[selectedMode].systemPrompt },
      set: { modeSettings[selectedMode].systemPrompt = $0 }
    )
  }

  private var selectedGenerationSettings: Binding<ChatGenerationSettings> {
    Binding(
      get: { modeSettings[selectedMode].generationSettings },
      set: { modeSettings[selectedMode].generationSettings = $0 }
    )
  }

  private var selectedTemperature: Binding<Double> {
    Binding(
      get: { selectedGenerationSettings.wrappedValue.temperature },
      set: { selectedGenerationSettings.wrappedValue.temperature = $0 }
    )
  }

  private var selectedMaxTokens: Binding<Int> {
    Binding(
      get: { selectedGenerationSettings.wrappedValue.maxTokens },
      set: { selectedGenerationSettings.wrappedValue.maxTokens = $0 }
    )
  }

  private var selectedTopP: Binding<Double> {
    Binding(
      get: { selectedGenerationSettings.wrappedValue.topP },
      set: { selectedGenerationSettings.wrappedValue.topP = $0 }
    )
  }

  private var selectedTopK: Binding<Int> {
    Binding(
      get: { selectedGenerationSettings.wrappedValue.topK },
      set: { selectedGenerationSettings.wrappedValue.topK = $0 }
    )
  }

  private var maxKVSizeEnabled: Binding<Bool> {
    Binding(
      get: { selectedGenerationSettings.wrappedValue.maxKVSize != nil },
      set: { isEnabled in
        selectedGenerationSettings.wrappedValue.maxKVSize =
          isEnabled ? contextTokenLimit : nil
      }
    )
  }

  private var maxKVSizeValue: Binding<Int> {
    Binding(
      get: { selectedGenerationSettings.wrappedValue.maxKVSize ?? contextTokenLimit },
      set: { selectedGenerationSettings.wrappedValue.maxKVSize = $0 }
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
