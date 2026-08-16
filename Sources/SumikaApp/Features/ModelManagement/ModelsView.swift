import SumikaCore
import SwiftUI

enum ModelsTab: String, CaseIterable, Hashable {
  case text
  case audio
}

struct ModelsView: View {
  @State private var modelPendingDeletion: ManagedModel?
  @State private var isMoreCodingModelsExpanded = false
  let modelManagementState: ModelManagementFeatureState
  @Bindable var audioModelController: ComposerAudioModelController
  @Binding var selectedTab: ModelsTab
  let errorMessage: String?

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
      revealSelectedCodingModelIfNeeded()
    }
    .onChange(of: modelManagementState.state.selectedModel.id) {
      revealSelectedCodingModelIfNeeded()
    }
    .alert(
      "Delete downloaded model?",
      isPresented: modelDeletionAlertBinding,
      presenting: modelPendingDeletion
    ) { model in
      Button("Cancel", role: .cancel) {
        modelPendingDeletion = nil
      }

      Button("Delete", role: .destructive) {
        modelManagementState.deleteModel(model)
        modelPendingDeletion = nil
      }
    } message: { model in
      Text(
        "This permanently deletes the downloaded files for “\(model.displayName)”. Chats, model selection, and generation settings are preserved."
      )
    }
  }

  private var textModelsForm: some View {
    let state = modelManagementState.state

    return Form {
      Section {
        Text(
          "QAT and OptiQ models are recommended for most uses. Standard Qwen models support images."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      } header: {
        Text("Choose a model")
          .textCase(nil)
      }

      ForEach(ManagedModelGroup.allCases, id: \.self) { group in
        Section {
          modelRows(in: group)
        } header: {
          Text(group.title)
            .textCase(nil)
        }
      }

      Section {
        CurrentModelSummary(
          model: state.selectedModel,
          modelState: state.modelState,
          downloadState: modelManagementState.effectiveDownloadState,
          actionTitle: modelManagementState.primaryAction.title,
          actionSystemImage: modelManagementState.primaryAction.systemImage,
          isActionDisabled: modelManagementState.isPrimaryActionDisabled,
          onAction: modelManagementState.performPrimaryAction
        )

        if case .downloading(let progress) = state.downloadState {
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
            modelState: state.modelState,
            downloadState: modelManagementState.effectiveDownloadState
          )

          ModelAdvancedSettings(
            model: state.selectedModel,
            modeSettings: Binding(
              get: { modelManagementState.modeSettings },
              set: { modeSettings in
                modelManagementState.updateModeSettings(modeSettings)
              }
            ),
            contextTokenLimit: Binding(
              get: { modelManagementState.state.modelContextTokenLimit },
              set: { limit in
                modelManagementState.updateContextTokenLimit(limit)
              }
            ),
            canChangeContextTokenLimit: state.modelState == .notLoaded,
            generationConfigPreset: state.modelGenerationConfigPreset
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

  @ViewBuilder
  private func modelRows(in group: ManagedModelGroup) -> some View {
    let models = modelManagementState.state.availableModels.filter { $0.group == group }

    if group == .coding {
      let recommendedModels =
        models
        .filter(\.isRecommended)
        .sorted { $0.recommendation.listOrder < $1.recommendation.listOrder }

      let additionalModels = models.filter { !$0.isRecommended }

      ForEach(recommendedModels) { model in
        managedModelRow(model)
      }

      if !additionalModels.isEmpty {
        DisclosureGroup(isExpanded: $isMoreCodingModelsExpanded) {
          ForEach(additionalModels) { model in
            managedModelRow(model)
          }
        } label: {
          HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
              Text("More coding models")
                .font(.body.weight(.medium))
              Text("Larger Gemma and standard Qwen variants")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(additionalModels.count) models")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    } else {
      ForEach(models) { model in
        managedModelRow(model)
      }
    }
  }

  private func managedModelRow(_ model: ManagedModel) -> some View {
    let state = modelManagementState.state

    return ManagedModelRow(
      model: model,
      isSelected: state.selectedModel.id == model.id,
      isActive: state.selectedModel.id == model.id
        && state.modelState == .ready,
      isDownloaded: state.isModelDownloaded(model),
      downloadState: state.selectedModel.id == model.id
        ? state.downloadState : .idle,
      canSelect: modelManagementState.canChangeModel,
      canDelete: modelManagementState.canDeleteModel(model),
      isDeleting: state.deletingModelID == model.id,
      onSelect: {
        modelManagementState.selectModel(model)
      },
      onDelete: {
        modelPendingDeletion = model
      }
    )
  }

  private func revealSelectedCodingModelIfNeeded() {
    let selectedModel = modelManagementState.state.selectedModel
    if selectedModel.group == .coding, !selectedModel.isRecommended {
      isMoreCodingModelsExpanded = true
    }
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

  private var modelDeletionAlertBinding: Binding<Bool> {
    Binding(
      get: { modelPendingDeletion != nil },
      set: { isPresented in
        if !isPresented {
          modelPendingDeletion = nil
        }
      }
    )
  }

}

extension ManagedModelGroup {
  var title: String {
    switch self {
    case .everydayChat:
      "Everyday chat and images"
    case .coding:
      "Coding and agent tasks"
    case .specialized:
      "Specialized models"
    }
  }

  var bestRecommendationTitle: String {
    switch self {
    case .everydayChat:
      "Best everyday"
    case .coding:
      "Best for coding"
    case .specialized:
      "Recommended"
    }
  }
}

extension ManagedModelRecommendation {
  fileprivate var listOrder: Int {
    switch self {
    case .bestForGroup:
      0
    case .recommended:
      1
    case .standard:
      2
    }
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
