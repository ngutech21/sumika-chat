import Testing

@testable import Sumika

@Suite
struct AppBuildInfoTests {
  @Test
  func readsVersionBuildAndCommitFromInfoDictionary() {
    let buildInfo = AppBuildInfo(
      infoDictionary: [
        "CFBundleShortVersionString": "1.2.3",
        "CFBundleVersion": "45",
        "SumikaGitCommit": "124880582175726b709015a632c5ba9f3069a319",
      ]
    )

    #expect(buildInfo.aboutApplicationVersion == "1.2.3")
    #expect(buildInfo.aboutBuildVersion == "commit SHA 124880582175")
    #expect(buildInfo.shortGitCommit == "124880582175")
  }

  @Test
  func ignoresBlankCommitValue() {
    let buildInfo = AppBuildInfo(
      infoDictionary: [
        "CFBundleShortVersionString": "1.2.3",
        "CFBundleVersion": "45",
        "SumikaGitCommit": "  ",
      ]
    )

    #expect(buildInfo.gitCommit == nil)
    #expect(buildInfo.aboutApplicationVersion == "1.2.3")
    #expect(buildInfo.aboutBuildVersion == "45")
  }

  @Test
  func usesGitCommitResourceWhenInfoDictionaryValueIsBlank() {
    let buildInfo = AppBuildInfo(
      infoDictionary: [
        "CFBundleShortVersionString": "1.2.3",
        "CFBundleVersion": "45",
        "SumikaGitCommit": "",
      ],
      gitCommitResource: "abcdef1234567890\n"
    )

    #expect(buildInfo.gitCommit == "abcdef1234567890")
    #expect(buildInfo.aboutBuildVersion == "commit SHA abcdef123456")
  }
}
