import SumikaCore
import SwiftUI

struct ModelsView: View {
  @Bindable var modelRuntime: ModelRuntimeController
  @Binding var modeSettings: ChatModeSettingsSet
  let errorMessage: String?
  let canChangeModel: Bool
  let onPrepareModelRuntimeAction:
    (
      _ cancelGeneration: Bool,
      _ invalidateContext: Bool
    ) -> Void

  var body: some View {
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
