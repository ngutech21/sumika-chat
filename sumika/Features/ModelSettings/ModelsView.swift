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
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Text(model.title)
              .font(.body.weight(.semibold))
            if model.isRecommended {
              Text("Recommended")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.10), in: Capsule())
            }
          }

          Text(model.subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(model.detail)
            .font(.callout)
            .foregroundStyle(.secondary)
          Text(model.storageEstimate)
            .font(.caption)
            .foregroundStyle(.tertiary)
        }

        Spacer()

        actionView
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
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private var actionView: some View {
    switch installState {
    case .installed:
      Button {
        onSelect()
      } label: {
        Label(
          isSelected ? "Selected" : "Use",
          systemImage: isSelected ? "checkmark" : "checkmark.circle")
      }
      .controlSize(.small)
      .disabled(isSelected)
    case .downloading:
      Button {
      } label: {
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.small)
          Text("Installing")
        }
      }
      .controlSize(.small)
      .disabled(true)
    case .notInstalled, .failed:
      Button {
        onDownload()
      } label: {
        Label("Install", systemImage: "square.and.arrow.down")
      }
      .controlSize(.small)
    }
  }
}
