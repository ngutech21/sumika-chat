import Foundation
import Observation
import SumikaCore

struct MCPServerTestFeedback: Equatable {
  var message: String
}

struct SettingsLoadOutcome: Equatable {
  var hasAuthoritativeMCPServers: Bool
}

enum MCPServersSaveOutcome: Equatable, Sendable {
  case saved
  case failed(message: String)

  var didSave: Bool {
    if case .saved = self {
      return true
    }
    return false
  }

  var errorMessage: String? {
    if case .failed(let message) = self {
      return message
    }
    return nil
  }
}

private enum SettingsPersistenceDomain: CaseIterable, Hashable {
  case webAccess
  case appBehavior
  case mcpServers
}

@MainActor
@Observable
final class SettingsFeatureState {
  var webAccessSettings = WebAccessSettings.disabled
  var appBehaviorSettings = AppBehaviorSettings()
  var mcpServers: [MCPServerConfig] = []
  private(set) var pendingMCPServers: [MCPServerConfig]?
  private(set) var hasAuthoritativeMCPServers = false
  /// Updated by the Agent feature after configuration changes or reconnects so
  /// the settings UI can render connection state without reaching into Core.
  var mcpServerStatuses: [MCPServerStatus] = []
  var mcpServerTestFeedback: MCPServerTestFeedback?
  var errorMessage: String? {
    get {
      let messages = SettingsPersistenceDomain.allCases.compactMap { persistenceErrors[$0] }
      return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
    set {
      if newValue == nil {
        persistenceErrors.removeAll()
      }
    }
  }

  @ObservationIgnored private let webAccessSettingsStore: any WebAccessSettingsStoring
  @ObservationIgnored private let appBehaviorSettingsStore: any AppBehaviorSettingsStoring
  @ObservationIgnored private let mcpServersStore: any MCPServersStoring
  @ObservationIgnored private var saveWebAccessSettingsTask: Task<Void, Never>?
  @ObservationIgnored private var saveAppBehaviorSettingsTask: Task<Void, Never>?
  private var persistenceErrors: [SettingsPersistenceDomain: String] = [:]

  init(
    webAccessSettingsStore: any WebAccessSettingsStoring = WebAccessSettingsStore(),
    appBehaviorSettingsStore: any AppBehaviorSettingsStoring = AppBehaviorSettingsStore(),
    mcpServersStore: any MCPServersStoring = MCPServersStore()
  ) {
    self.webAccessSettingsStore = webAccessSettingsStore
    self.appBehaviorSettingsStore = appBehaviorSettingsStore
    self.mcpServersStore = mcpServersStore
  }

  var editableMCPServers: [MCPServerConfig] {
    pendingMCPServers ?? mcpServers
  }

  func load() async -> SettingsLoadOutcome {
    do {
      webAccessSettings = try await webAccessSettingsStore.load()
      setPersistenceError(nil, for: .webAccess)
    } catch {
      webAccessSettings = .disabled
      setPersistenceError(error.localizedDescription, for: .webAccess)
    }

    do {
      appBehaviorSettings = try await appBehaviorSettingsStore.load()
      setPersistenceError(nil, for: .appBehavior)
    } catch {
      appBehaviorSettings = AppBehaviorSettings()
      setPersistenceError(error.localizedDescription, for: .appBehavior)
    }

    do {
      mcpServers = try await mcpServersStore.load()
      pendingMCPServers = nil
      hasAuthoritativeMCPServers = true
      setPersistenceError(nil, for: .mcpServers)
      return SettingsLoadOutcome(hasAuthoritativeMCPServers: true)
    } catch {
      pendingMCPServers = nil
      hasAuthoritativeMCPServers = false
      setPersistenceError(error.localizedDescription, for: .mcpServers)
      return SettingsLoadOutcome(hasAuthoritativeMCPServers: false)
    }
  }

  func updateWebAccessSettings(_ settings: WebAccessSettings) {
    webAccessSettings = settings
    let previousSaveTask = saveWebAccessSettingsTask
    saveWebAccessSettingsTask = Task { [webAccessSettingsStore, weak self] in
      await previousSaveTask?.value
      do {
        try await webAccessSettingsStore.save(settings: settings)
        await MainActor.run {
          self?.setPersistenceError(nil, for: .webAccess)
        }
      } catch {
        await MainActor.run {
          self?.setPersistenceError(error.localizedDescription, for: .webAccess)
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
          self?.setPersistenceError(nil, for: .appBehavior)
        }
      } catch {
        await MainActor.run {
          self?.setPersistenceError(error.localizedDescription, for: .appBehavior)
        }
      }
    }
  }

  func flushPendingSaves() async {
    let webAccessSettingsTask = saveWebAccessSettingsTask
    let appBehaviorSettingsTask = saveAppBehaviorSettingsTask
    await webAccessSettingsTask?.value
    await appBehaviorSettingsTask?.value
  }

  func stageMCPServersUpdate(_ servers: [MCPServerConfig]) {
    pendingMCPServers = servers
  }

  func persistMCPServers(_ servers: [MCPServerConfig]) async -> MCPServersSaveOutcome {
    do {
      try await mcpServersStore.save(servers: servers)
      return .saved
    } catch {
      return .failed(message: error.localizedDescription)
    }
  }

  func settleMCPServersUpdate(
    authoritativeServers: [MCPServerConfig]?,
    saveOutcome: MCPServersSaveOutcome
  ) {
    if let authoritativeServers {
      mcpServers = authoritativeServers
      hasAuthoritativeMCPServers = true
    }
    pendingMCPServers = nil
    setPersistenceError(saveOutcome.errorMessage, for: .mcpServers)
  }

  private func setPersistenceError(
    _ message: String?,
    for domain: SettingsPersistenceDomain
  ) {
    persistenceErrors[domain] = message
  }
}
