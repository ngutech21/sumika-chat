import SumikaCore
import SwiftUI

enum ModelsTab: String, CaseIterable, Hashable {
  case text
  case audio
}

struct ModelsView: View {
  @Bindable var modelRuntime: ModelRuntimeController
  @Bindable var audioModelController: ComposerAudioModelController
  @Binding var modeSettings: ChatModeSettingsSet
  @Binding var selectedTab: ModelsTab
  let errorMessage: String?
  let canChangeModel: Bool
  let onPrepareModelRuntimeAction:
    (
      _ cancelGeneration: Bool,
      _ invalidateContext: Bool
    ) -> Void

  var body: some View {
    VStack(spacing: 0) {
      Picker("Model Type", selection: $selectedTab) {
        Text("Text").tag(ModelsTab.text)
        Text("Audio").tag(ModelsTab.audio)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 220)
      .padding(.top, 14)
      .padding(.bottom, 8)

      Group {
        switch selectedTab {
        case .text:
          textModelsForm
        case .audio:
          audioModelsForm
        }
      }
    }
    .onAppear {
      audioModelController.refreshAvailability()
    }
  }

  private var textModelsForm: some View {
    Form {
      Section {
        ForEach(modelRuntime.availableModels) { model in
          ManagedModelRow(
            model: model,
            isSelected: modelRuntime.selectedModelID == model.id,
            isActive: modelRuntime.selectedModelID == model.id
              && modelRuntime.modelState == .ready,
            isDownloaded: modelRuntime.isModelDownloaded(model),
            downloadState: modelRuntime.selectedModelID == model.id
              ? modelRuntime.downloadState : .idle,
            canSelect: canChangeModel,
            onSelect: {
              let isChangingModel = modelRuntime.selectedModelID != model.id
              onPrepareModelRuntimeAction(false, isChangingModel)
              modelRuntime.selectModel(model)
            }
          )
        }
      } header: {
        Text("Choose a model")
      }

      Section {
        CurrentModelSummary(
          model: modelRuntime.selectedModel,
          modelState: modelRuntime.modelState,
          downloadState: effectiveDownloadState,
          actionTitle: currentModelActionTitle,
          actionSystemImage: currentModelActionSystemImage,
          isActionDisabled: isCurrentModelActionDisabled,
          onAction: {
            if shouldDownloadSelectedModel {
              onPrepareModelRuntimeAction(false, false)
              modelRuntime.downloadSelectedModel()
            } else if modelRuntime.modelState == .ready {
              onPrepareModelRuntimeAction(true, true)
              modelRuntime.unloadModel()
            } else {
              onPrepareModelRuntimeAction(false, true)
              modelRuntime.loadSelectedModel()
            }
          }
        )

        if case .downloading(let progress) = modelRuntime.downloadState {
          DownloadProgressView(progress: progress)
        }

        if let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      } header: {
        Text("Current model")
          .textCase(nil)
      }

      Section {
        DisclosureGroup {
          ModelRuntimeStatus(
            modelState: modelRuntime.modelState,
            downloadState: effectiveDownloadState,
            processUsage: modelRuntime.processUsage
          )

          ModelAdvancedSettings(
            model: modelRuntime.selectedModel,
            modeSettings: $modeSettings,
            contextTokenLimit: $modelRuntime.modelContextTokenLimit,
            canChangeContextTokenLimit: modelRuntime.modelState == .notLoaded,
            generationConfigPreset: modelRuntime.modelGenerationConfigPreset
          )
        } label: {
          HStack(spacing: 12) {
            Text("Advanced settings")
              .font(.body.weight(.medium))
            Text("System prompt, creativity, response length...")
              .foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "gearshape")
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  private var audioModelsForm: some View {
    Form {
      Section {
        ForEach(audioModelController.models) { model in
          AudioModelRow(
            model: model,
            isSelected: audioModelController.selectedModelID == model.id,
            installState: audioModelController.installState(for: model.id),
            onSelect: {
              audioModelController.select(model.id)
            },
            onDownload: {
              audioModelController.download(model.id)
            }
          )
        }
      } header: {
        Text("Choose an audio model")
      } footer: {
        if audioModelController.needsMultilingualModel {
          Text(
            "Your current system language is not English. Install Parakeet v3 Multilingual for German dictation."
          )
        } else {
          Text("Audio models are downloaded on demand and used locally for composer dictation.")
        }
      }
    }
    .formStyle(.grouped)
  }

  private var effectiveDownloadState: ModelDownloadState {
    if modelRuntime.isModelDownloaded(modelRuntime.selectedModel),
      !modelRuntime.downloadState.isDownloading
    {
      return .downloaded
    }

    return modelRuntime.downloadState
  }

  private var shouldDownloadSelectedModel: Bool {
    !modelRuntime.isModelDownloaded(modelRuntime.selectedModel)
  }

  private var currentModelActionTitle: String {
    if shouldDownloadSelectedModel {
      return "Download"
    }

    return modelRuntime.modelState == .ready ? "Unload" : "Load"
  }

  private var currentModelActionSystemImage: String {
    if shouldDownloadSelectedModel {
      return "square.and.arrow.down"
    }

    return modelRuntime.modelState == .ready ? "eject" : "play.fill"
  }

  private var isCurrentModelActionDisabled: Bool {
    if shouldDownloadSelectedModel {
      return !canChangeModel || modelRuntime.downloadState.isDownloading
    }

    return modelRuntime.modelState == .loading
      || modelRuntime.downloadState.isDownloading
  }
}

private struct AudioModelRow: View {
  let model: ComposerAudioModelDescriptor
  let isSelected: Bool
  let installState: ComposerAudioModelInstallState
  let onSelect: () -> Void
  let onDownload: () -> Void

  var body: some View {
    Button(action: rowAction) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 12) {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(tileTint.opacity(0.16))
            .frame(width: 30, height: 30)
            .overlay {
              Image(systemName: "waveform")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tileTint)
            }

          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
              Text(model.title)
                .font(.body.weight(.medium))

              if model.isRecommended {
                Text("Recommended")
                  .font(.caption.weight(.medium))
                  .foregroundStyle(Color.accentColor)
                  .padding(.horizontal, 7)
                  .padding(.vertical, 2)
                  .background(Color.accentColor.opacity(0.14), in: Capsule())
              }
            }

            Text(model.subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)

            Text(model.detail)
              .font(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }

          Spacer(minLength: 12)

          VStack(alignment: .trailing, spacing: 3) {
            Text(model.storageEstimate)
              .font(.callout)
              .foregroundStyle(.secondary)
              .monospacedDigit()

            HStack(spacing: 4) {
              if showsStatusDot {
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

        if case .downloading(let progress) = installState {
          DownloadProgressView(progress: progress)
        }

        if case .failed(let message) = installState {
          Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(installState.isDownloading)
    .listRowBackground(isSelected ? Color.accentColor.opacity(0.10) : nil)
    .accessibilityIdentifier("audio-model-row-\(model.id.rawValue)")
  }

  private var tileTint: Color {
    isSelected ? .accentColor : .secondary
  }

  private var showsStatusDot: Bool {
    switch installState {
    case .installed, .downloading, .failed:
      true
    case .notInstalled:
      false
    }
  }

  private var statusText: String {
    switch installState {
    case .installed:
      return isSelected ? "Selected" : "Ready"
    case .downloading(let progress):
      guard let progress else {
        return "Installing"
      }
      return progress.formatted(.percent.precision(.fractionLength(0)))
    case .failed:
      return "Failed"
    case .notInstalled:
      return "Install"
    }
  }

  private var statusTint: Color {
    switch installState {
    case .installed:
      return isSelected ? .accentColor : .green
    case .downloading:
      return .secondary
    case .failed:
      return .red
    case .notInstalled:
      return .secondary
    }
  }

  private var rowAction: () -> Void {
    switch installState {
    case .installed:
      return onSelect
    case .notInstalled, .failed:
      return onDownload
    case .downloading:
      return {}
    }
  }
}
