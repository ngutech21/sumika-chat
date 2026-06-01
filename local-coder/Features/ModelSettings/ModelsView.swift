import SwiftUI

struct ModelsView: View {
  @Bindable var controller: ChatSessionController

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Models")
            .font(.title2.weight(.semibold))
          Text(
            "Choose a local Gemma 3 model. Downloads are explicit so you stay in control of storage and network use."
          )
          .foregroundStyle(.secondary)
          .frame(maxWidth: 720, alignment: .leading)
        }

        VStack(spacing: 10) {
          ForEach(controller.availableModels) { model in
            ManagedModelRow(
              model: model,
              isSelected: controller.selectedModelID == model.id,
              isActive: controller.selectedModelID == model.id && controller.modelState == .ready,
              isDownloaded: controller.isModelDownloaded(model),
              downloadState: controller.selectedModelID == model.id
                ? controller.downloadState : .idle,
              canSelect: controller.canChangeModel,
              onSelect: {
                controller.selectModel(model)
              }
            )
          }
        }

        Divider()

        VStack(alignment: .leading, spacing: 14) {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(controller.selectedModel.displayName)
                .font(.headline)
              Text(selectedModelStatusText)
                .foregroundStyle(.secondary)
            }
            Spacer()

            Button {
              controller.downloadSelectedModel()
            } label: {
              Label("Download", systemImage: "square.and.arrow.down")
            }
            .disabled(
              !controller.canChangeModel
                || controller.downloadState.isDownloading
                || controller.isModelDownloaded(controller.selectedModel))

            Button {
              controller.modelState == .ready
                ? controller.unloadModel() : controller.loadSelectedModel()
            } label: {
              Label(modelActionTitle, systemImage: modelActionSystemImage)
            }
            .accessibilityIdentifier(
              controller.modelState == .ready ? "unload-model-button" : "load-model-button"
            )
            .disabled(isModelActionDisabled)
          }

          if case .downloading(let progress) = controller.downloadState {
            DownloadProgressView(progress: progress)
          }

          ModelRuntimeStatus(
            modelState: controller.modelState,
            downloadState: effectiveDownloadState,
            contextUsage: controller.contextUsage,
            processUsage: controller.processUsage
          )

          if let errorMessage = controller.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .font(.callout)
              .foregroundStyle(.red)
              .textSelection(.enabled)
          }
        }

        DisclosureGroup("Details") {
          ModelAdvancedSettings(
            model: controller.selectedModel,
            systemPrompt: $controller.chatSession.systemPrompt,
            generationSettings: $controller.chatSession.generationSettings,
            contextTokenLimit: $controller.modelContextTokenLimit,
            canChangeContextTokenLimit: controller.modelState == .notLoaded
          )
        }
      }
      .padding(24)
      .frame(maxWidth: 920, alignment: .leading)
    }
  }

  private var selectedModelStatusText: String {
    if controller.selectedModel.requiresLargeMemory {
      return "\(controller.selectedModel.estimatedDownloadSize), needs a lot of memory"
    }

    return
      "\(controller.selectedModel.estimatedDownloadSize), \(controller.selectedModel.summary.lowercased())"
  }

  private var effectiveDownloadState: ModelDownloadState {
    if controller.isModelDownloaded(controller.selectedModel),
      !controller.downloadState.isDownloading
    {
      return .downloaded
    }

    return controller.downloadState
  }

  private var modelActionTitle: String {
    controller.modelState == .ready ? "Unload" : "Load"
  }

  private var modelActionSystemImage: String {
    controller.modelState == .ready ? "eject" : "play.fill"
  }

  private var isModelActionDisabled: Bool {
    controller.modelState == .loading
      || controller.downloadState.isDownloading
      || (controller.modelState != .ready
        && !controller.isModelDownloaded(controller.selectedModel))
  }
}
