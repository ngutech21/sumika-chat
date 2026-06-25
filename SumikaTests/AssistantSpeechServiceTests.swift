import AVFoundation
import Testing

@testable import Sumika

@MainActor
struct AssistantSpeechServiceTests {
  @Test
  func voiceResolutionUsesSavedVoiceThenLanguageThenDefaultLanguage() {
    let germanVoice = AssistantSpeechVoiceDescriptor(
      identifier: "voice.de",
      name: "Anna",
      languageCode: "de-DE",
      quality: .default
    )
    let englishVoice = AssistantSpeechVoiceDescriptor(
      identifier: "voice.en",
      name: "Alex",
      languageCode: "en-US",
      quality: .enhanced
    )
    let voices = [germanVoice, englishVoice]

    #expect(
      AssistantSpeechVoiceCatalog.resolvedVoice(
        settings: AppBehaviorSettings(
          assistantSpeechLanguageCode: "de-DE",
          assistantSpeechVoiceIdentifier: "voice.en"
        ),
        voices: voices,
        defaultLanguageCode: "en-US"
      ) == englishVoice
    )
    #expect(
      AssistantSpeechVoiceCatalog.resolvedVoice(
        settings: AppBehaviorSettings(
          assistantSpeechLanguageCode: "de-DE",
          assistantSpeechVoiceIdentifier: "missing"
        ),
        voices: voices,
        defaultLanguageCode: "en-US"
      ) == germanVoice
    )
    #expect(
      AssistantSpeechVoiceCatalog.resolvedVoice(
        settings: AppBehaviorSettings(assistantSpeechVoiceIdentifier: "missing"),
        voices: voices,
        defaultLanguageCode: "en-US"
      ) == englishVoice
    )
  }

  @Test
  func startingAnotherRowStopsPreviousRowAndMarksNewActiveRow() {
    let synthesizer = TestAssistantSpeechSynthesizer()
    let service = AssistantSpeechService(synthesizer: synthesizer)
    let settings = AppBehaviorSettings(assistantSpeechEnabled: true)

    service.speak(rowID: "row-a", text: "First response", settings: settings)
    service.speak(rowID: "row-b", text: "Second response", settings: settings)

    #expect(synthesizer.stopCount == 2)
    #expect(
      synthesizer.spokenUtterances.map(\.speechString) == ["First response", "Second response"])
    #expect(service.activeRowID == "row-b")
  }

  @Test
  func speakUsesConfiguredRate() throws {
    let synthesizer = TestAssistantSpeechSynthesizer()
    let service = AssistantSpeechService(synthesizer: synthesizer)
    let settings = AppBehaviorSettings(
      assistantSpeechEnabled: true,
      assistantSpeechRate: 0.63
    )

    service.speak(rowID: "row-a", text: "First response", settings: settings)

    let utterance = try #require(synthesizer.spokenUtterances.last)
    #expect(utterance.rate == 0.63)
  }

  @Test
  func appBehaviorSettingsClampSpeechRate() {
    #expect(
      AppBehaviorSettings(assistantSpeechRate: AssistantSpeechRate.minimum - 0.1)
        .assistantSpeechRate == AssistantSpeechRate.minimum
    )
    #expect(
      AppBehaviorSettings(assistantSpeechRate: AssistantSpeechRate.maximum + 0.1)
        .assistantSpeechRate == AssistantSpeechRate.maximum
    )
  }

  @Test
  func stopClearsActiveRow() {
    let synthesizer = TestAssistantSpeechSynthesizer()
    let service = AssistantSpeechService(synthesizer: synthesizer)

    service.speak(
      rowID: "row-a",
      text: "First response",
      settings: AppBehaviorSettings(assistantSpeechEnabled: true)
    )
    service.stop()

    #expect(synthesizer.stopCount == 2)
    #expect(service.activeRowID == nil)
  }

  @Test
  func completionClearsOnlyMatchingActiveUtterance() throws {
    let synthesizer = TestAssistantSpeechSynthesizer()
    let service = AssistantSpeechService(synthesizer: synthesizer)
    let settings = AppBehaviorSettings(assistantSpeechEnabled: true)

    service.speak(rowID: "row-a", text: "First response", settings: settings)
    let firstUtterance = try #require(synthesizer.spokenUtterances.last)
    service.speak(rowID: "row-b", text: "Second response", settings: settings)
    let secondUtterance = try #require(synthesizer.spokenUtterances.last)

    synthesizer.delegate?.speechSynthesizerDidCancel(
      ObjectIdentifier(firstUtterance)
    )
    #expect(service.activeRowID == "row-b")

    synthesizer.delegate?.speechSynthesizerDidFinish(
      ObjectIdentifier(secondUtterance)
    )
    #expect(service.activeRowID == nil)
  }
}

@MainActor
private final class TestAssistantSpeechSynthesizer: AssistantSpeechSynthesizing {
  weak var delegate: (any AssistantSpeechSynthesizingDelegate)?
  private(set) var spokenUtterances: [AVSpeechUtterance] = []
  private(set) var stopCount = 0

  func speak(_ utterance: AVSpeechUtterance) {
    spokenUtterances.append(utterance)
  }

  func stopSpeaking(at _: AVSpeechBoundary) {
    stopCount += 1
  }
}
