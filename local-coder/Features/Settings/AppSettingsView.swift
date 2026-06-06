import LocalCoderCore
import SwiftUI

struct AppSettingsView: View {
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
  AppSettingsView(webAccessSettings: .constant(WebAccessSettings()))
}
