import Foundation
import Observation
import SumikaCore

@MainActor
@Observable
final class SettingsFeatureState {
  var webAccessSettings = WebAccessSettings.disabled
  var appBehaviorSettings = AppBehaviorSettings()
  var mcpServers: [MCPServerConfig] = []
  /// Mirrored from `MCPClientManager` after every configuration change or
  /// reconnect so the settings UI can render connection state without
  /// reaching into the actor.
  var mcpServerStatuses: [MCPServerStatus] = []
  var errorMessage: String?

  @ObservationIgnored private let webAccessSettingsStore: any WebAccessSettingsStoring
  @ObservationIgnored private let appBehaviorSettingsStore: any AppBehaviorSettingsStoring
  @ObservationIgnored private let mcpServersStore: any MCPServersStoring
  @ObservationIgnored private var saveWebAccessSettingsTask: Task<Void, Never>?
  @ObservationIgnored private var saveAppBehaviorSettingsTask: Task<Void, Never>?
  @ObservationIgnored private var saveMCPServersTask: Task<Void, Never>?

  init(
    webAccessSettingsStore: any WebAccessSettingsStoring = WebAccessSettingsStore(),
    appBehaviorSettingsStore: any AppBehaviorSettingsStoring = AppBehaviorSettingsStore(),
    mcpServersStore: any MCPServersStoring = MCPServersStore()
  ) {
    self.webAccessSettingsStore = webAccessSettingsStore
    self.appBehaviorSettingsStore = appBehaviorSettingsStore
    self.mcpServersStore = mcpServersStore
  }

  func load() async {
    webAccessSettings = await webAccessSettingsStore.settings()
    appBehaviorSettings = await appBehaviorSettingsStore.settings()
    mcpServers = await mcpServersStore.servers()
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

  func updateMCPServers(_ servers: [MCPServerConfig]) {
    mcpServers = servers
    let previousSaveTask = saveMCPServersTask
    saveMCPServersTask = Task { [mcpServersStore, weak self] in
      await previousSaveTask?.value
      do {
        try await mcpServersStore.save(servers: servers)
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
