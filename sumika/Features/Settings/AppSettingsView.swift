import AppKit
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
        Text("Speech").tag(SettingsTab.speech)
        Text("Web").tag(SettingsTab.web)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 240)
      .padding(.top, 14)
      .padding(.bottom, 8)

      Group {
        switch selectedTab {
        case .general:
          generalTab
        case .speech:
          speechTab
        case .web:
          webAccessTab
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(width: 540, height: 420)
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
          "Lets Chat and Agent use public web tools. Pick a provider, or point at a self-hosted SearXNG instance."
        )
      }
    }
    .formStyle(.grouped)
  }

  private var speechTab: some View {
    Form {
      Section {
        Toggle("Show play buttons for assistant responses", isOn: assistantSpeechEnabledBinding)

        Picker("Language", selection: assistantSpeechLanguageBinding) {
          ForEach(assistantSpeechLanguageCodes, id: \.self) { languageCode in
            Text(AssistantSpeechVoiceCatalog.languageDisplayName(languageCode)).tag(languageCode)
          }
        }
        .disabled(!settingsState.appBehaviorSettings.assistantSpeechEnabled)

        Picker("Voice", selection: assistantSpeechVoiceBinding) {
          Text("Automatic").tag(Optional<String>.none)
          ForEach(assistantSpeechVoicesForSelectedLanguage) { voice in
            Text(AssistantSpeechVoiceCatalog.voiceDisplayName(voice))
              .tag(Optional(voice.identifier))
          }
        }
        .disabled(!settingsState.appBehaviorSettings.assistantSpeechEnabled)

        HStack {
          Text("Speed")
          Slider(
            value: assistantSpeechRateBinding,
            in: Double(AssistantSpeechRate.minimum)...Double(AssistantSpeechRate.maximum)
          )
          Text(
            AssistantSpeechRate.displayName(
              settingsState.appBehaviorSettings.assistantSpeechRate
            )
          )
          .monospacedDigit()
          .frame(width: 48, alignment: .trailing)
        }
        .disabled(!settingsState.appBehaviorSettings.assistantSpeechEnabled)

        Button {
          SystemSpeechSettingsLink.open()
        } label: {
          Label("Open macOS Voice Settings", systemImage: "gearshape")
        }
      } header: {
        Text("Assistant Speech")
      } footer: {
        Text(
          "Adds play controls to completed text responses. Code blocks and tool output are skipped. Use macOS Voice Settings to install or remove system voices."
        )
      }
    }
    .formStyle(.grouped)
  }

  private var assistantSpeechVoices: [AssistantSpeechVoiceDescriptor] {
    AssistantSpeechVoiceCatalog.availableVoices()
  }

  private var assistantSpeechLanguageCodes: [String] {
    AssistantSpeechVoiceCatalog.languageCodes(in: assistantSpeechVoices)
  }

  private var selectedAssistantSpeechLanguageCode: String {
    settingsState.appBehaviorSettings.assistantSpeechLanguageCode
      ?? AssistantSpeechVoiceCatalog.currentLanguageCode()
  }

  private var assistantSpeechVoicesForSelectedLanguage: [AssistantSpeechVoiceDescriptor] {
    AssistantSpeechVoiceCatalog.voices(
      for: selectedAssistantSpeechLanguageCode,
      in: assistantSpeechVoices
    )
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

  private var assistantSpeechEnabledBinding: Binding<Bool> {
    Binding(
      get: { settingsState.appBehaviorSettings.assistantSpeechEnabled },
      set: { isEnabled in
        var updatedSettings = settingsState.appBehaviorSettings
        updatedSettings.assistantSpeechEnabled = isEnabled
        onUpdateAppBehaviorSettings(updatedSettings)
      }
    )
  }

  private var assistantSpeechLanguageBinding: Binding<String> {
    Binding(
      get: { selectedAssistantSpeechLanguageCode },
      set: { languageCode in
        var updatedSettings = settingsState.appBehaviorSettings
        updatedSettings.assistantSpeechLanguageCode = languageCode
        updatedSettings.assistantSpeechVoiceIdentifier = nil
        onUpdateAppBehaviorSettings(updatedSettings)
      }
    )
  }

  private var assistantSpeechVoiceBinding: Binding<String?> {
    Binding(
      get: {
        let voiceIdentifier = settingsState.appBehaviorSettings.assistantSpeechVoiceIdentifier
        guard let voiceIdentifier,
          assistantSpeechVoicesForSelectedLanguage.contains(where: {
            $0.identifier == voiceIdentifier
          })
        else {
          return nil
        }
        return voiceIdentifier
      },
      set: { voiceIdentifier in
        var updatedSettings = settingsState.appBehaviorSettings
        updatedSettings.assistantSpeechVoiceIdentifier = voiceIdentifier
        onUpdateAppBehaviorSettings(updatedSettings)
      }
    )
  }

  private var assistantSpeechRateBinding: Binding<Double> {
    Binding(
      get: { Double(settingsState.appBehaviorSettings.assistantSpeechRate) },
      set: { rate in
        var updatedSettings = settingsState.appBehaviorSettings
        updatedSettings.assistantSpeechRate = AssistantSpeechRate.clamped(Float(rate))
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
  case speech
  case web
}

private enum SystemSpeechSettingsLink {
  static func open() {
    for url in urls where NSWorkspace.shared.open(url) {
      return
    }
  }

  private static let urls: [URL] = [
    URL(
      string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent"),
    URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?TextToSpeech"),
    URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess"),
    URL(fileURLWithPath: "/System/Applications/System Settings.app"),
  ].compactMap(\.self)
}

#Preview {
  AppSettingsView(
    settingsState: SettingsFeatureState(),
    onUpdateAppBehaviorSettings: { _ in }
  )
}
