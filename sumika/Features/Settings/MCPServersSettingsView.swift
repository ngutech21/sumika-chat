import SumikaCore
import SwiftUI

/// Settings tab for stdio MCP servers: a user-editable list of server
/// configurations plus the live connection state per server. Every mutation
/// flows through `onUpdateServers`, which persists the list and reconciles
/// the running connections.
struct MCPServersSettingsView: View {
  let settingsState: SettingsFeatureState
  let onUpdateServers: ([MCPServerConfig]) -> Void
  let canTestServers: Bool
  let onTestServer: (UUID) -> Void

  @State private var editorTarget: MCPServerEditorTarget?

  var body: some View {
    Form {
      Section {
        if settingsState.mcpServers.isEmpty {
          Text("No MCP servers configured.")
            .foregroundStyle(.secondary)
        }
        ForEach(settingsState.mcpServers) { server in
          MCPServerRow(
            server: server,
            status: status(for: server.id),
            isEnabledBinding: isEnabledBinding(for: server.id),
            canTest: canTestServers,
            onEdit: { editorTarget = .edit(server) },
            onTest: { onTestServer(server.id) },
            onDelete: { removeServer(server.id) }
          )
        }

        Button {
          editorTarget = .add
        } label: {
          Label("Add MCP Server…", systemImage: "plus")
        }
      } header: {
        Text("MCP Servers")
      } footer: {
        Text(
          "Servers are launched as local stdio processes and their tools become available in Agent mode. Every tool call asks for approval. Environment values are stored as plain text."
        )
      }
    }
    .formStyle(.grouped)
    .sheet(item: $editorTarget) { target in
      MCPServerEditorSheet(target: target) { server in
        saveServer(server)
      }
    }
  }

  private func status(for serverID: UUID) -> MCPServerStatus.State? {
    settingsState.mcpServerStatuses.first { $0.serverID == serverID }?.state
  }

  private func isEnabledBinding(for serverID: UUID) -> Binding<Bool> {
    Binding(
      get: {
        settingsState.mcpServers.first { $0.id == serverID }?.isEnabled ?? false
      },
      set: { isEnabled in
        var servers = settingsState.mcpServers
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else {
          return
        }
        servers[index].isEnabled = isEnabled
        onUpdateServers(servers)
      }
    )
  }

  private func saveServer(_ server: MCPServerConfig) {
    var servers = settingsState.mcpServers
    if let index = servers.firstIndex(where: { $0.id == server.id }) {
      servers[index] = server
    } else {
      servers.append(server)
    }
    onUpdateServers(servers)
  }

  private func removeServer(_ serverID: UUID) {
    onUpdateServers(settingsState.mcpServers.filter { $0.id != serverID })
  }
}

private struct MCPServerRow: View {
  let server: MCPServerConfig
  let status: MCPServerStatus.State?
  let isEnabledBinding: Binding<Bool>
  let canTest: Bool
  let onEdit: () -> Void
  let onTest: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
          Text(server.name)
          Text(statusText)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text(commandLine)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Spacer()

      Toggle("Enabled", isOn: isEnabledBinding)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
      Button("Test Connection", systemImage: "stethoscope", action: onTest)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(!server.isEnabled || !canTest)
        .help(canTest ? "Test Connection" : "Open a workspace to test this server")
      Button("Edit", systemImage: "pencil", action: onEdit)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Edit")
      Button("Delete", systemImage: "trash", action: onDelete)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Delete")
    }
  }

  private var commandLine: String {
    ([server.command] + server.arguments).joined(separator: " ")
  }

  private var statusText: String {
    guard server.isEnabled else {
      return "disabled"
    }
    switch status {
    case .connected(let toolCount):
      return toolCount == 1 ? "1 tool" : "\(toolCount) tools"
    case .connecting:
      return "connecting…"
    case .failed(let message):
      return "failed: \(message)"
    case .disconnected, .none:
      return "disconnected"
    }
  }

  private var statusColor: Color {
    guard server.isEnabled else {
      return .gray
    }
    switch status {
    case .connected:
      return .green
    case .connecting:
      return .yellow
    case .failed:
      return .red
    case .disconnected, .none:
      return .gray
    }
  }
}

enum MCPServerEditorTarget: Identifiable {
  case add
  case edit(MCPServerConfig)

  var id: String {
    switch self {
    case .add:
      "add"
    case .edit(let server):
      server.id.uuidString
    }
  }
}

private struct MCPServerEditorSheet: View {
  let target: MCPServerEditorTarget
  let onSave: (MCPServerConfig) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var command = ""
  @State private var argumentsText = ""
  @State private var environmentText = ""

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          TextField("Name", text: $name, prompt: Text("GitHub"))
          TextField("Command", text: $command, prompt: Text("npx"))
        } footer: {
          Text("The command is resolved through PATH, including Homebrew locations.")
        }

        Section {
          TextEditor(text: $argumentsText)
            .font(.body.monospaced())
            .frame(height: 64)
        } header: {
          Text("Arguments (one per line)")
        } footer: {
          Text(
            "Each line is passed to the process exactly as written — no shell, so no quotes or escaping. Put a flag and its value on separate lines."
          )
        }

        Section {
          TextEditor(text: $environmentText)
            .font(.body.monospaced())
            .frame(height: 64)
        } header: {
          Text("Environment (KEY=value, one per line)")
        } footer: {
          Text("Values are stored as plain text in mcp-servers.json.")
        }
      }
      .formStyle(.grouped)

      Divider()
      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button(isEditing ? "Save" : "Add") {
          onSave(editedServer())
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!isValid)
      }
      .padding(12)
    }
    .frame(width: 460, height: 420)
    .onAppear(perform: populateFromTarget)
  }

  private var isEditing: Bool {
    if case .edit = target {
      return true
    }
    return false
  }

  private var isValid: Bool {
    !name.trimmingCharacters(in: .whitespaces).isEmpty
      && !command.trimmingCharacters(in: .whitespaces).isEmpty
  }

  private func populateFromTarget() {
    guard case .edit(let server) = target else {
      return
    }
    name = server.name
    command = server.command
    argumentsText = server.arguments.joined(separator: "\n")
    environmentText = server.environment
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: "\n")
  }

  private func editedServer() -> MCPServerConfig {
    let existing: MCPServerConfig? =
      if case .edit(let server) = target {
        server
      } else {
        nil
      }
    return MCPServerConfig(
      id: existing?.id ?? UUID(),
      name: name.trimmingCharacters(in: .whitespaces),
      command: command.trimmingCharacters(in: .whitespaces),
      arguments: Self.parsedArguments(argumentsText),
      environment: Self.parsedEnvironment(environmentText),
      isEnabled: existing?.isEnabled ?? true
    )
  }

  static func parsedArguments(_ text: String) -> [String] {
    text
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  static func parsedEnvironment(_ text: String) -> [String: String] {
    var environment: [String: String] = [:]
    for line in text.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard
        !trimmed.isEmpty,
        let separatorIndex = trimmed.firstIndex(of: "="),
        separatorIndex != trimmed.startIndex
      else {
        continue
      }
      let key = String(trimmed[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
      let value = String(trimmed[trimmed.index(after: separatorIndex)...])
      environment[key] = value
    }
    return environment
  }
}
