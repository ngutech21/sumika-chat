import Foundation
import Observation
import SumikaCore

@MainActor
@Observable
final class SettingsFeatureState {
  var webAccessSettings = WebAccessSettings.disabled
  var appBehaviorSettings = AppBehaviorSettings()
  var errorMessage: String?

  @ObservationIgnored private let webAccessSettingsStore: any WebAccessSettingsStoring
  @ObservationIgnored private let appBehaviorSettingsStore: any AppBehaviorSettingsStoring
  @ObservationIgnored private var saveWebAccessSettingsTask: Task<Void, Never>?
  @ObservationIgnored private var saveAppBehaviorSettingsTask: Task<Void, Never>?

  init(
    webAccessSettingsStore: any WebAccessSettingsStoring = WebAccessSettingsStore(),
    appBehaviorSettingsStore: any AppBehaviorSettingsStoring = AppBehaviorSettingsStore()
  ) {
    self.webAccessSettingsStore = webAccessSettingsStore
    self.appBehaviorSettingsStore = appBehaviorSettingsStore
  }

  func load() async {
    webAccessSettings = await webAccessSettingsStore.settings()
    appBehaviorSettings = await appBehaviorSettingsStore.settings()
  }

  func updateWebAccessSettings(_ settings: WebAccessSettings) {
    webAccessSettings = settings
    let previousSaveTask = saveWebAccessSettingsTask
    saveWebAccessSettingsTask = Task { [webAccessSettingsStore, weak self] in
      await previousSaveTask?.value
      do {
        try await webAccessSettingsStore.save(settings: settings)
        await MainActor.run {
          self?.errorMessage = nil
        }
      } catch {
        await MainActor.run {
          self?.errorMessage = error.localizedDescription
        }
      }
    }
  }

  func updateAppBehaviorSettings(_ settings: AppBehaviorSettings) {
    appBehaviorSettings = settings
    let previousSaveTask = saveAppBehaviorSettingsTask
    saveAppBehaviorSettingsTask = Task { [appBehaviorSettingsStore, weak self] in
      await previousSaveTask?.value
      do {
        try await appBehaviorSettingsStore.save(settings: settings)
        await MainActor.run {
          self?.errorMessage = nil
        }
      } catch {
        await MainActor.run {
          self?.errorMessage = error.localizedDescription
        }
      }
    }
  }
}
