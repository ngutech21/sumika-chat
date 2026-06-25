import AVFoundation
import Foundation
import Observation

struct AssistantSpeechVoiceDescriptor: Equatable, Identifiable, Sendable {
  let identifier: String
  let name: String
  let languageCode: String
  let quality: Quality

  var id: String {
    identifier
  }

  enum Quality: Int, Equatable, Sendable {
    case `default` = 1
    case enhanced = 2
    case premium = 3
    case unknown = 0
  }

  init(identifier: String, name: String, languageCode: String, quality: Quality) {
    self.identifier = identifier
    self.name = name
    self.languageCode = languageCode
    self.quality = quality
  }

  init(voice: AVSpeechSynthesisVoice) {
    self.init(
      identifier: voice.identifier,
      name: voice.name,
      languageCode: voice.language,
      quality: Quality(rawValue: voice.quality.rawValue) ?? .unknown
    )
  }
}

enum AssistantSpeechVoiceCatalog {
  static func availableVoices() -> [AssistantSpeechVoiceDescriptor] {
    AVSpeechSynthesisVoice.speechVoices()
      .map(AssistantSpeechVoiceDescriptor.init)
      .sorted { lhs, rhs in
        if lhs.languageCode != rhs.languageCode {
          return lhs.languageCode.localizedStandardCompare(rhs.languageCode) == .orderedAscending
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
  }

  static func currentLanguageCode() -> String {
    AVSpeechSynthesisVoice.currentLanguageCode()
  }

  static func languageCodes(
    in voices: [AssistantSpeechVoiceDescriptor],
    defaultLanguageCode: String = currentLanguageCode()
  ) -> [String] {
    let voiceLanguageCodes = Set(voices.map(\.languageCode))
    return Array(voiceLanguageCodes.union([defaultLanguageCode]))
      .sorted {
        languageDisplayName($0).localizedStandardCompare(languageDisplayName($1))
          == .orderedAscending
      }
  }

  static func voices(
    for languageCode: String,
    in voices: [AssistantSpeechVoiceDescriptor]
  ) -> [AssistantSpeechVoiceDescriptor] {
    voices.filter { $0.languageCode == languageCode }
  }

  static func languageDisplayName(_ languageCode: String) -> String {
    Locale.current.localizedString(forIdentifier: languageCode) ?? languageCode
  }

  static func voiceDisplayName(_ voice: AssistantSpeechVoiceDescriptor) -> String {
    switch voice.quality {
    case .enhanced:
      "\(voice.name) (Enhanced)"
    case .premium:
      "\(voice.name) (Premium)"
    case .default, .unknown:
      voice.name
    }
  }

  static func resolvedVoice(
    settings: AppBehaviorSettings,
    voices: [AssistantSpeechVoiceDescriptor],
    defaultLanguageCode: String = currentLanguageCode()
  ) -> AssistantSpeechVoiceDescriptor? {
    if let voiceIdentifier = settings.assistantSpeechVoiceIdentifier,
      let voice = voices.first(where: { $0.identifier == voiceIdentifier })
    {
      return voice
    }

    let languageCode = settings.assistantSpeechLanguageCode ?? defaultLanguageCode
    return voices.first(where: { $0.languageCode == languageCode })
      ?? voices.first(where: { $0.languageCode == defaultLanguageCode })
      ?? voices.first
  }
}

nonisolated enum AssistantSpeechRate {
  static let minimum = AVSpeechUtteranceMinimumSpeechRate
  static let maximum = AVSpeechUtteranceMaximumSpeechRate
  static let defaultValue = AVSpeechUtteranceDefaultSpeechRate

  static func clamped(_ rate: Float) -> Float {
    min(max(rate, minimum), maximum)
  }

  static func displayName(_ rate: Float) -> String {
    let percentage = Int((clamped(rate) / defaultValue * 100).rounded())
    return "\(percentage)%"
  }
}

@MainActor
@Observable
final class AssistantSpeechService: AssistantSpeechSynthesizingDelegate {
  @ObservationIgnored private let synthesizer: any AssistantSpeechSynthesizing
  private var activeUtterance: AssistantSpeechUtteranceToken?

  private(set) var activeRowID: String?

  init(synthesizer: any AssistantSpeechSynthesizing = AssistantSpeechSynthesizerAdapter()) {
    self.synthesizer = synthesizer
    synthesizer.delegate = self
  }

  func toggle(rowID: String, text: String, settings: AppBehaviorSettings) {
    if activeRowID == rowID {
      stop()
      return
    }
    speak(rowID: rowID, text: text, settings: settings)
  }

  func speak(rowID: String, text: String, settings: AppBehaviorSettings) {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard settings.assistantSpeechEnabled, !trimmedText.isEmpty else {
      stop()
      return
    }

    synthesizer.stopSpeaking(at: .immediate)

    let utterance = AVSpeechUtterance(string: trimmedText)
    utterance.voice = resolvedVoice(for: settings)
    utterance.rate = AssistantSpeechRate.clamped(settings.assistantSpeechRate)
    let token = ObjectIdentifier(utterance)

    activeUtterance = token
    activeRowID = rowID
    synthesizer.speak(utterance)
  }

  func stop() {
    synthesizer.stopSpeaking(at: .immediate)
    activeUtterance = nil
    activeRowID = nil
  }

  func speechSynthesizerDidFinish(_ utterance: AssistantSpeechUtteranceToken) {
    clearIfActive(utterance)
  }

  func speechSynthesizerDidCancel(_ utterance: AssistantSpeechUtteranceToken) {
    clearIfActive(utterance)
  }

  private func clearIfActive(_ utterance: AssistantSpeechUtteranceToken) {
    guard activeUtterance == utterance else {
      return
    }
    activeUtterance = nil
    activeRowID = nil
  }

  private func resolvedVoice(for settings: AppBehaviorSettings) -> AVSpeechSynthesisVoice? {
    let descriptors = AssistantSpeechVoiceCatalog.availableVoices()
    if let descriptor = AssistantSpeechVoiceCatalog.resolvedVoice(
      settings: settings,
      voices: descriptors
    ) {
      return AVSpeechSynthesisVoice(identifier: descriptor.identifier)
        ?? AVSpeechSynthesisVoice(language: descriptor.languageCode)
    }

    return AVSpeechSynthesisVoice(
      language: settings.assistantSpeechLanguageCode
        ?? AssistantSpeechVoiceCatalog.currentLanguageCode()
    )
  }
}

@MainActor
protocol AssistantSpeechSynthesizing: AnyObject {
  var delegate: (any AssistantSpeechSynthesizingDelegate)? { get set }

  func speak(_ utterance: AVSpeechUtterance)
  func stopSpeaking(at boundary: AVSpeechBoundary)
}

@MainActor
protocol AssistantSpeechSynthesizingDelegate: AnyObject {
  func speechSynthesizerDidFinish(_ utterance: AssistantSpeechUtteranceToken)
  func speechSynthesizerDidCancel(_ utterance: AssistantSpeechUtteranceToken)
}

typealias AssistantSpeechUtteranceToken = ObjectIdentifier

@MainActor
private final class AssistantSpeechSynthesizerAdapter: NSObject, AssistantSpeechSynthesizing,
  AVSpeechSynthesizerDelegate
{
  weak var delegate: (any AssistantSpeechSynthesizingDelegate)?

  private let synthesizer = AVSpeechSynthesizer()

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  func speak(_ utterance: AVSpeechUtterance) {
    synthesizer.speak(utterance)
  }

  func stopSpeaking(at boundary: AVSpeechBoundary) {
    synthesizer.stopSpeaking(at: boundary)
  }

  nonisolated func speechSynthesizer(
    _: AVSpeechSynthesizer,
    didFinish utterance: AVSpeechUtterance
  ) {
    let token = ObjectIdentifier(utterance)
    Task { @MainActor in
      self.delegate?.speechSynthesizerDidFinish(token)
    }
  }

  nonisolated func speechSynthesizer(
    _: AVSpeechSynthesizer,
    didCancel utterance: AVSpeechUtterance
  ) {
    let token = ObjectIdentifier(utterance)
    Task { @MainActor in
      self.delegate?.speechSynthesizerDidCancel(token)
    }
  }
}
