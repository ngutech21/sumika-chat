import LocalCoderCore
import SwiftUI

struct ModelsView: View {
  @Bindable var modelRuntime: ModelRuntimeController
  @Binding var systemPrompt: String
  @Binding var generationSettings: ChatGenerationSettings
  let contextUsage: ChatContextUsage?
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
        Text("Available models")
      } footer: {
        Text(
          "Downloads are explicit so you stay in control of storage and network use."
        )
      }

      Section {
        ModelRuntimeStatus(
          modelState: modelRuntime.modelState,
          downloadState: effectiveDownloadState,
          contextUsage: contextUsage,
          processUsage: modelRuntime.processUsage
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

        HStack(spacing: 10) {
          Spacer()

          Button {
            onPrepareModelRuntimeAction(false, false)
            modelRuntime.downloadSelectedModel()
          } label: {
            Label("Download", systemImage: "square.and.arrow.down")
          }
          .disabled(
            !canChangeModel
              || modelRuntime.downloadState.isDownloading
              || modelRuntime.isModelDownloaded(modelRuntime.selectedModel))

          Button {
            if modelRuntime.modelState == .ready {
              onPrepareModelRuntimeAction(true, true)
              modelRuntime.unloadModel()
            } else {
              onPrepareModelRuntimeAction(false, true)
              modelRuntime.loadSelectedModel()
            }
          } label: {
            Label(modelActionTitle, systemImage: modelActionSystemImage)
          }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier(
            modelRuntime.modelState == .ready ? "unload-model-button" : "load-model-button"
          )
          .disabled(isModelActionDisabled)
        }
      } header: {
        Text(modelRuntime.selectedModel.displayName)
          .textCase(nil)
      } footer: {
        Text(selectedModelStatusText)
      }

      ModelAdvancedSettings(
        model: modelRuntime.selectedModel,
        systemPrompt: $systemPrompt,
        generationSettings: $generationSettings,
        contextTokenLimit: $modelRuntime.modelContextTokenLimit,
        canChangeContextTokenLimit: modelRuntime.modelState == .notLoaded
      )
    }
    .formStyle(.grouped)
  }

  private var selectedModelStatusText: String {
    if modelRuntime.selectedModel.stability == .experimental {
      return
        "\(modelRuntime.selectedModel.estimatedDownloadSize), experimental"
    }

    if modelRuntime.selectedModel.requiresLargeMemory {
      return "\(modelRuntime.selectedModel.estimatedDownloadSize), needs a lot of memory"
    }

    return
      "\(modelRuntime.selectedModel.estimatedDownloadSize), \(modelRuntime.selectedModel.summary.lowercased())"
  }

  private var effectiveDownloadState: ModelDownloadState {
    if modelRuntime.isModelDownloaded(modelRuntime.selectedModel),
      !modelRuntime.downloadState.isDownloading
    {
      return .downloaded
    }

    return modelRuntime.downloadState
  }

  private var modelActionTitle: String {
    modelRuntime.modelState == .ready ? "Unload" : "Load"
  }

  private var modelActionSystemImage: String {
    modelRuntime.modelState == .ready ? "eject" : "play.fill"
  }

  private var isModelActionDisabled: Bool {
    modelRuntime.modelState == .loading
      || modelRuntime.downloadState.isDownloading
      || (modelRuntime.modelState != .ready
        && !modelRuntime.isModelDownloaded(modelRuntime.selectedModel))
  }
}
