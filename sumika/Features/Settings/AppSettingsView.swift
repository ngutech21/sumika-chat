import SumikaCore
import SwiftUI

struct AppSettingsView: View {
  let settingsState: SettingsFeatureState
  let onUpdateAppBehaviorSettings: (AppBehaviorSettings) -> Void
  @State private var selectedTab = SettingsTab.general

  var body: some View {
    VStack(spacing: 0) {
      Picker("Settings Section", selection: $selectedTab) {
        Text("General").tag(SettingsTab.general)
        Text("Web").tag(SettingsTab.web)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 160)
      .padding(.top, 14)
      .padding(.bottom, 8)

      Group {
        switch selectedTab {
        case .general:
          generalTab
        case .web:
          webAccessTab
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(width: 520, height: 360)
    .alert(
      "Settings Error",
      isPresented: settingsErrorPresentedBinding,
      actions: {
        Button("OK") {
          settingsState.errorMessage = nil
        }
      },
      message: {
        Text(settingsState.errorMessage ?? "")
      }
    )
  }

  private var generalTab: some View {
    Form {
      Section {
        Toggle("Load last selected model on app start", isOn: autoloadLastModelBinding)
      } header: {
        Text("Startup")
      } footer: {
        Text("When enabled, Sumika Chat loads the active session model after launch.")
      }

      Section {
        Toggle("Enable todo_write planning tool", isOn: todoWriteToolEnabledBinding)
      } header: {
        Text("Agent Tools")
      } footer: {
        Text(
          "Small local models often struggle with this tool; enable it when you want the Agent to maintain an explicit plan."
        )
      }
    }
    .formStyle(.grouped)
  }

  private var webAccessTab: some View {
    Form {
      Section {
        Picker("Access", selection: webPolicyBinding) {
          ForEach(WebAccessPolicy.allCases, id: \.self) { policy in
            Text(policy.displayName).tag(policy)
          }
        }

        Picker("Search Provider", selection: webProviderBinding) {
          ForEach(WebSearchProvider.allCases, id: \.self) { provider in
            Text(provider.displayName).tag(provider)
          }
        }
        .disabled(settingsState.webAccessSettings.policy == .off)

        TextField("SearXNG URL", text: webSearXNGURLBinding)
          .disabled(
            settingsState.webAccessSettings.policy == .off
              || settingsState.webAccessSettings.provider != .searxng
          )
      } header: {
        Text("Web Access")
      } footer: {
        Text(
          "Lets the Agent search the web. Pick a provider, or point at a self-hosted SearXNG instance."
        )
      }
    }
    .formStyle(.grouped)
  }

  private var autoloadLastModelBinding: Binding<Bool> {
    Binding(
      get: { settingsState.appBehaviorSettings.autoloadLastModel },
      set: { isEnabled in
        var updatedSettings = settingsState.appBehaviorSettings
        updatedSettings.autoloadLastModel = isEnabled
        onUpdateAppBehaviorSettings(updatedSettings)
      }
    )
  }

  private var todoWriteToolEnabledBinding: Binding<Bool> {
    Binding(
      get: { settingsState.appBehaviorSettings.todoWriteToolEnabled },
      set: { isEnabled in
        var updatedSettings = settingsState.appBehaviorSettings
        updatedSettings.todoWriteToolEnabled = isEnabled
        onUpdateAppBehaviorSettings(updatedSettings)
      }
    )
  }

  private var webPolicyBinding: Binding<WebAccessPolicy> {
    Binding(
      get: { settingsState.webAccessSettings.policy },
      set: { policy in
        var updatedSettings = settingsState.webAccessSettings
        updatedSettings.policy = policy
        settingsState.updateWebAccessSettings(updatedSettings)
      }
    )
  }

  private var webProviderBinding: Binding<WebSearchProvider> {
    Binding(
      get: { settingsState.webAccessSettings.provider },
      set: { provider in
        var updatedSettings = settingsState.webAccessSettings
        updatedSettings.provider = provider
        settingsState.updateWebAccessSettings(updatedSettings)
      }
    )
  }

  private var webSearXNGURLBinding: Binding<String> {
    Binding(
      get: { settingsState.webAccessSettings.searxngBaseURL },
      set: { searxngBaseURL in
        var updatedSettings = settingsState.webAccessSettings
        updatedSettings.searxngBaseURL = searxngBaseURL
        settingsState.updateWebAccessSettings(updatedSettings)
      }
    )
  }

  private var settingsErrorPresentedBinding: Binding<Bool> {
    Binding(
      get: { settingsState.errorMessage != nil },
      set: { isPresented in
        if !isPresented {
          settingsState.errorMessage = nil
        }
      }
    )
  }
}

private enum SettingsTab: Hashable {
  case general
  case web
}

#Preview {
  AppSettingsView(
    settingsState: SettingsFeatureState(),
    onUpdateAppBehaviorSettings: { _ in }
  )
}
