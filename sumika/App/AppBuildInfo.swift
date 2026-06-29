import Foundation

struct AppBuildInfo: Equatable {
  let version: String?
  let releaseVersion: String?
  let build: String?
  let gitCommit: String?

  init(infoDictionary: [String: Any], gitCommitResource: String? = nil) {
    self.version = Self.normalizedString(
      infoDictionary["CFBundleShortVersionString"] as? String
    )
    self.releaseVersion = Self.normalizedString(
      infoDictionary["SumikaReleaseVersion"] as? String
    )
    self.build = Self.normalizedString(infoDictionary["CFBundleVersion"] as? String)
    self.gitCommit =
      Self.normalizedString(infoDictionary["SumikaGitCommit"] as? String)
      ?? Self.normalizedString(gitCommitResource)
  }

  static var current: AppBuildInfo {
    let bundle = Bundle.main
    return AppBuildInfo(
      infoDictionary: bundle.infoDictionary ?? [:],
      gitCommitResource: gitCommitResource(in: bundle)
    )
  }

  var aboutApplicationVersion: String {
    releaseVersion ?? version ?? "Unknown"
  }

  var aboutBuildVersion: String? {
    if let shortGitCommit {
      return "commit SHA \(shortGitCommit)"
    }

    return build
  }

  var shortGitCommit: String? {
    guard let gitCommit else {
      return nil
    }
    return String(gitCommit.prefix(12))
  }

  private static func normalizedString(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func gitCommitResource(in bundle: Bundle) -> String? {
    guard let url = bundle.url(forResource: "SumikaGitCommit", withExtension: "txt") else {
      return nil
    }

    return try? String(contentsOf: url, encoding: .utf8)
  }
}
