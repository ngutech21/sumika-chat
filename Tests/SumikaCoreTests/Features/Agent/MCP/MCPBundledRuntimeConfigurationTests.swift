import Foundation
import SumikaTestSupport
import Testing

@testable import SumikaCore

/// Runs the pinned helper's configuration parser without installing or starting any Python tool.
@Suite(TemporaryDirectoryTrait(named: "sumika-bundled-uv-configuration"))
struct MCPBundledRuntimeConfigurationTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["SUMIKA_TEST_BUNDLED_UV"] != nil),
    arguments: ["uv", "uvx"], ["workspace", "user", "system", "explicit"]
  )
  func bundledRuntimeIgnoresExternalConfiguration(command: String, location: String) async throws {
    let executable = try #require(ProcessInfo.processInfo.environment["SUMIKA_TEST_BUNDLED_UV"])
    let root = try scopedTemporaryDirectory()
    let workspace = root.appending(path: "workspace")
    let userConfig = root.appending(path: "user-config")
    let systemConfig = root.appending(path: "system-config")
    let temporaryHome = root.appending(path: "home")
    let configurationFiles = [
      "workspace": workspace.appending(path: "uv.toml"),
      "user": userConfig.appending(path: "uv/uv.toml"),
      "system": systemConfig.appending(path: "uv/uv.toml"),
      "explicit": root.appending(path: "explicit.toml"),
    ]
    try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
    for file in configurationFiles.values {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try "".write(to: file, atomically: true, encoding: .utf8)
    }
    let configurationFile = try #require(configurationFiles[location])
    try """
    [[index]]
    url = "https://sumika-uv-config.invalid/simple"
    default = true
    """.write(to: configurationFile, atomically: true, encoding: .utf8)

    let report = root.appending(path: "settings.txt")
    let helper = root.appending(path: "inspect-uv.sh")
    let script = """
      #!/bin/sh
      "$REAL_UV" --show-settings "$@" > "$REPORT" || exit $?
      """ + "\n" + MCPClientTests.fakeServerScript
    try script.write(to: helper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    var environment = ["REAL_UV": executable, "REPORT": report.path, "UV_NO_CONFIG": "0"]
    if location == "explicit" { environment["UV_CONFIG_FILE"] = configurationFile.path }
    let connection = MCPServerConnection(
      config: MCPServerConfig(
        name: "Configuration probe", command: command,
        arguments: (command == "uv" ? ["run"] : []) + ["sumika-configuration-probe"],
        environment: environment),
      workspaceRootURL: workspace,
      baseEnvironment: [
        "PATH": "/usr/bin:/bin", "HOME": temporaryHome.path,
        "XDG_CONFIG_HOME": userConfig.path, "XDG_CONFIG_DIRS": systemConfig.path,
        "UV_OFFLINE": "1",
      ],
      pathPrefixDirectories: [],
      runtimeConfiguration: MCPRuntimeConfiguration(
        uvExecutableURL: helper, dataDirectoryURL: root.appending(path: "runtime"),
        cacheDirectoryURL: root.appending(path: "cache")),
      initializeTimeout: .seconds(10))
    defer { await connection.shutdown() }

    #expect(try await connection.start().count == 1)
    let settings = try String(contentsOf: report, encoding: .utf8)
    #expect(settings.contains("Offline"))
    #expect(!settings.contains("sumika-uv-config.invalid"))
  }
}
