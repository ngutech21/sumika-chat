import LocalCoderCore
import SwiftUI

struct AppSettingsView: View {
  @Binding var appBehaviorSettings: AppBehaviorSettings
  @Binding var webAccessSettings: WebAccessSettings

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Settings")
            .font(.title2.weight(.semibold))
          Text("Configure app-wide behavior for local-first coding workflows.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: 720, alignment: .leading)
        }

        VStack(alignment: .leading, spacing: 14) {
          Text("Startup")
            .font(.headline)

          Toggle("Load last selected model on app start", isOn: autoloadLastModelBinding)

          Text(
            "Off by default. When enabled, Local Coder loads the active session model after launch."
          )
          .foregroundStyle(.secondary)
          .frame(maxWidth: 720, alignment: .leading)
        }

        VStack(alignment: .leading, spacing: 14) {
          Text("Agent Tools")
            .font(.headline)

          Toggle("Enable todo_write planning tool", isOn: todoWriteToolEnabledBinding)

          Text(
            "Off by default. Small local models often struggle with this tool; enable it when you want the Agent to maintain an explicit plan."
          )
          .foregroundStyle(.secondary)
          .frame(maxWidth: 720, alignment: .leading)
        }

        VStack(alignment: .leading, spacing: 14) {
          Text("Web Access")
            .font(.headline)

          Picker("Web Access", selection: webPolicyBinding) {
            ForEach(WebAccessPolicy.allCases, id: \.self) { policy in
              Text(policy.displayName).tag(policy)
            }
          }

          Picker("Search Provider", selection: webProviderBinding) {
            ForEach(WebSearchProvider.allCases, id: \.self) { provider in
              Text(provider.displayName).tag(provider)
            }
          }
          .disabled(webAccessSettings.policy == .off)

          TextField("SearXNG URL", text: webSearXNGURLBinding)
            .textFieldStyle(.roundedBorder)
            .disabled(webAccessSettings.policy == .off || webAccessSettings.provider != .searxng)
        }

        Spacer(minLength: 0)
      }
      .padding(24)
      .frame(maxWidth: 920, alignment: .leading)
    }
  }

  private var autoloadLastModelBinding: Binding<Bool> {
    Binding(
      get: { appBehaviorSettings.autoloadLastModel },
      set: { isEnabled in
        var updatedSettings = appBehaviorSettings
        updatedSettings.autoloadLastModel = isEnabled
        appBehaviorSettings = updatedSettings
      }
    )
  }

  private var todoWriteToolEnabledBinding: Binding<Bool> {
    Binding(
      get: { appBehaviorSettings.todoWriteToolEnabled },
      set: { isEnabled in
        var updatedSettings = appBehaviorSettings
        updatedSettings.todoWriteToolEnabled = isEnabled
        appBehaviorSettings = updatedSettings
      }
    )
  }

  private var webPolicyBinding: Binding<WebAccessPolicy> {
    Binding(
      get: { webAccessSettings.policy },
      set: { webAccessSettings.policy = $0 }
    )
  }

  private var webProviderBinding: Binding<WebSearchProvider> {
    Binding(
      get: { webAccessSettings.provider },
      set: { webAccessSettings.provider = $0 }
    )
  }

  private var webSearXNGURLBinding: Binding<String> {
    Binding(
      get: { webAccessSettings.searxngBaseURL },
      set: { webAccessSettings.searxngBaseURL = $0 }
    )
  }
}

#Preview {
  AppSettingsView(
    appBehaviorSettings: .constant(AppBehaviorSettings()),
    webAccessSettings: .constant(WebAccessSettings())
  )
}
