import SumikaCore
import SwiftUI

struct AppSettingsView: View {
  @Binding var appBehaviorSettings: AppBehaviorSettings
  @Binding var webAccessSettings: WebAccessSettings

  var body: some View {
    TabView {
      generalTab
        .tabItem { Label("General", systemImage: "gearshape") }

      webAccessTab
        .tabItem { Label("Web", systemImage: "globe") }
    }
    .frame(width: 520, height: 360)
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
        .disabled(webAccessSettings.policy == .off)

        TextField("SearXNG URL", text: webSearXNGURLBinding)
          .disabled(webAccessSettings.policy == .off || webAccessSettings.provider != .searxng)
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
