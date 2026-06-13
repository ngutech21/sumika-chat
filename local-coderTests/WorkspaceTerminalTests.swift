import Foundation
import LocalCoderCore
import Testing

@testable import local_coder

struct WorkspaceTerminalTests {
  @Test
  func terminalConfigurationUsesWorkspaceRootAsWorkingDirectoryAndPWD() {
    let workspace = Workspace(
      name: "Project",
      rootURL: URL(filePath: "/tmp/project", directoryHint: .isDirectory)
    )

    let configuration = WorkspaceTerminalConfiguration(
      workspace: workspace,
      processEnvironment: [
        "SHELL": "/bin/bash",
        "PATH": "/usr/bin:/bin",
        "CUSTOM": "value",
      ]
    )

    #expect(configuration.workspaceName == "Project")
    #expect(configuration.workingDirectoryPath == Workspace.normalizedPath(for: workspace.rootURL))
    #expect(configuration.environment["PWD"] == Workspace.normalizedPath(for: workspace.rootURL))
    #expect(configuration.environment["CUSTOM"] == "value")
  }

  @Test
  func terminalConfigurationPrefixesPathWithoutDroppingExistingPath() {
    let configuration = WorkspaceTerminalConfiguration(
      workspaceName: "Project",
      workingDirectoryPath: "/tmp/project",
      processEnvironment: [
        "SHELL": "/bin/zsh",
        "PATH": "/usr/bin:/bin",
      ]
    )

    #expect(
      configuration.environment["PATH"]
        == "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin")
  }

  @Test
  func terminalConfigurationDoesNotDuplicateExistingPathPrefixes() {
    let configuration = WorkspaceTerminalConfiguration(
      workspaceName: "Project",
      workingDirectoryPath: "/tmp/project",
      processEnvironment: [
        "SHELL": "/bin/zsh",
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin",
      ]
    )

    #expect(
      configuration.environment["PATH"]
        == "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin")
  }

  @Test
  func terminalConfigurationFallsBackToZshWhenShellIsMissing() {
    let configuration = WorkspaceTerminalConfiguration(
      workspaceName: "Project",
      workingDirectoryPath: "/tmp/project",
      processEnvironment: [:]
    )

    #expect(configuration.shellPath == "/bin/zsh")
    #expect(configuration.environment["SHELL"] == "/bin/zsh")
    #expect(configuration.environment["TERM"] == "xterm-256color")
    #expect(configuration.shellArguments == ["-il"])
  }
}
