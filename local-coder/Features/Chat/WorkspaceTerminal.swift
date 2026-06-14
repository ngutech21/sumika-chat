import AppKit
import LocalCoderCore
import SwiftTerm
import SwiftUI

struct WorkspaceTerminalConfiguration: Equatable {
  let workspaceName: String
  let workingDirectoryPath: String
  let shellPath: String
  let shellArguments: [String]
  let environment: [String: String]

  init(
    workspace: Workspace,
    processEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.init(
      workspaceName: workspace.name,
      workingDirectoryPath: workspace.normalizedRootPath,
      processEnvironment: processEnvironment
    )
  }

  init(
    workspaceName: String,
    workingDirectoryPath: String,
    processEnvironment: [String: String]
  ) {
    self.workspaceName = workspaceName
    self.workingDirectoryPath = workingDirectoryPath

    let shell = processEnvironment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    shellPath =
      if let shell, !shell.isEmpty {
        shell
      } else {
        "/bin/zsh"
      }
    shellArguments = ["-il"]

    var resolvedEnvironment = processEnvironment
    resolvedEnvironment["PWD"] = workingDirectoryPath
    resolvedEnvironment["SHELL"] = shellPath
    resolvedEnvironment["TERM"] = "xterm-256color"
    resolvedEnvironment["PATH"] = Self.resolvedPath(from: processEnvironment["PATH"])
    environment = resolvedEnvironment
  }

  var environmentArray: [String] {
    environment
      .map { key, value in "\(key)=\(value)" }
      .sorted()
  }

  var shellDisplayName: String {
    URL(filePath: shellPath).lastPathComponent
  }

  private static func resolvedPath(from existingPath: String?) -> String {
    let fallbackPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    let basePath =
      if let existingPath, !existingPath.isEmpty {
        existingPath
      } else {
        fallbackPath
      }
    let existingComponents =
      basePath
      .split(separator: ":", omittingEmptySubsequences: false)
      .map(String.init)
    let prefixes = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]

    var seen = Set<String>()
    var components: [String] = []
    for component in prefixes + existingComponents
    where !component.isEmpty && !seen.contains(component) {
      seen.insert(component)
      components.append(component)
    }
    return components.joined(separator: ":")
  }
}

struct WorkspaceTerminalPane: View {
  let configuration: WorkspaceTerminalConfiguration
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Label {
          Text(configuration.workspaceName)
            .lineLimit(1)
            .truncationMode(.middle)
        } icon: {
          Image(systemName: "terminal")
        }
        .font(.caption.weight(.semibold))

        Text(configuration.shellDisplayName)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)

        Spacer()

        Button(action: onClose) {
          Image(systemName: "xmark")
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .help("Hide terminal")
        .accessibilityLabel("Hide terminal")
        .accessibilityIdentifier("workspace-terminal-close-button")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

      Divider()

      WorkspaceTerminalView(configuration: configuration)
        .accessibilityIdentifier("workspace-terminal-view")
    }
    .frame(height: 300)
    .background(Color(nsColor: .controlBackgroundColor))
    .overlay(alignment: .top) {
      Divider()
    }
    .accessibilityIdentifier("workspace-terminal-pane")
  }
}

struct WorkspaceTerminalView: NSViewRepresentable {
  let configuration: WorkspaceTerminalConfiguration

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> LocalProcessTerminalView {
    let terminalView = LocalProcessTerminalView(frame: .zero)
    terminalView.processDelegate = context.coordinator
    terminalView.autoresizingMask = [.width, .height]
    context.coordinator.startProcessIfNeeded(in: terminalView, configuration: configuration)
    return terminalView
  }

  func updateNSView(_ terminalView: LocalProcessTerminalView, context: Context) {
    context.coordinator.startProcessIfNeeded(in: terminalView, configuration: configuration)
  }

  static func dismantleNSView(_ terminalView: LocalProcessTerminalView, coordinator: Coordinator) {
    coordinator.terminate(terminalView)
  }

  final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
    private var processState = WorkspaceTerminalProcessState.idle

    func startProcessIfNeeded(
      in terminalView: LocalProcessTerminalView,
      configuration: WorkspaceTerminalConfiguration
    ) {
      if processState.configuration == configuration {
        return
      }

      switch processState {
      case .running:
        terminate(terminalView)
      case .idle, .exited:
        break
      }

      processState = .running(configuration)
      terminalView.startProcess(
        executable: configuration.shellPath,
        args: configuration.shellArguments,
        environment: configuration.environmentArray,
        currentDirectory: configuration.workingDirectoryPath
      )
    }

    func terminate(_ terminalView: LocalProcessTerminalView) {
      terminalView.process.terminate()
      processState = .idle
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
      if case .running(let configuration) = processState {
        processState = .exited(configuration)
      }
    }
  }
}

enum WorkspaceTerminalProcessState: Equatable {
  case idle
  case running(WorkspaceTerminalConfiguration)
  case exited(WorkspaceTerminalConfiguration)

  var configuration: WorkspaceTerminalConfiguration? {
    switch self {
    case .idle:
      nil
    case .running(let configuration), .exited(let configuration):
      configuration
    }
  }
}
