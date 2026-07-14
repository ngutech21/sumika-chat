import SumikaCore
import SwiftUI

/// Settings tab for external MCP servers: a user-editable list of server
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
          "Servers use a local stdio process or Streamable HTTP. Remote endpoints require HTTPS; loopback endpoints may use HTTP. Every MCP tool call asks for approval."
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
        Text(server.connectionDescription)
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
  @State private var draft = MCPServerEditorDraft()

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          TextField("Name", text: $draft.name, prompt: Text("GitHub"))
          Picker("Transport", selection: $draft.transport) {
            ForEach(MCPServerEditorTransport.allCases) { transport in
              Text(transport.label).tag(transport)
            }
          }
          .pickerStyle(.segmented)
        }

        switch draft.transport {
        case .stdio:
          stdioFields
        case .streamableHTTP:
          httpFields
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
          if let server = draft.server(replacing: existingServer) {
            onSave(server)
            dismiss()
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!draft.isValid)
      }
      .padding(12)
    }
    .frame(width: 500, height: 460)
    .onAppear(perform: populateFromTarget)
  }

  @ViewBuilder
  private var stdioFields: some View {
    Section {
      TextField("Command", text: $draft.command, prompt: Text("npx"))
    } footer: {
      Text("The command is resolved through PATH, including Homebrew locations.")
    }

    Section {
      TextEditor(text: $draft.argumentsText)
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
      TextEditor(text: $draft.environmentText)
        .font(.body.monospaced())
        .frame(height: 64)
    } header: {
      Text("Environment (KEY=value, one per line)")
    } footer: {
      Text("Values are stored as plain text in mcp-servers.json.")
    }
  }

  @ViewBuilder
  private var httpFields: some View {
    Section {
      TextField(
        "Endpoint",
        text: $draft.endpoint,
        prompt: Text("https://example.com/mcp")
      )
      .textContentType(.URL)

      if let endpointError = draft.endpointError, !draft.endpoint.isEmpty {
        Text(endpointError.localizedDescription)
          .font(.caption)
          .foregroundStyle(.red)
      }
    } footer: {
      Text(
        "Remote servers require HTTPS. HTTP is allowed only for localhost and loopback addresses. Authentication and legacy HTTP+SSE are not supported. Loopback servers may receive the active workspace root; remote servers do not."
      )
    }
  }

  private var isEditing: Bool {
    if case .edit = target {
      return true
    }
    return false
  }

  private var existingServer: MCPServerConfig? {
    if case .edit(let server) = target {
      return server
    }
    return nil
  }

  private func populateFromTarget() {
    if let existingServer {
      draft = MCPServerEditorDraft(server: existingServer)
    }
  }
}

enum MCPServerEditorTransport: String, CaseIterable, Identifiable {
  case stdio
  case streamableHTTP

  var id: Self { self }

  var label: String {
    switch self {
    case .stdio:
      "Local process"
    case .streamableHTTP:
      "Streamable HTTP"
    }
  }
}

struct MCPServerEditorDraft {
  var name = ""
  var transport = MCPServerEditorTransport.stdio
  var command = ""
  var argumentsText = ""
  var environmentText = ""
  var endpoint = ""

  init() {}

  init(server: MCPServerConfig) {
    name = server.name
    switch server.transport {
    case .stdio(let command, let arguments, let environment):
      transport = .stdio
      self.command = command
      argumentsText = arguments.joined(separator: "\n")
      environmentText =
        environment
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: "\n")
    case .streamableHTTP(let endpoint):
      transport = .streamableHTTP
      self.endpoint = endpoint.absoluteString
    }
  }

  var endpointError: (any LocalizedError)? {
    guard transport == .streamableHTTP else { return nil }
    guard let url = parsedEndpoint else { return MCPServerEndpointError.invalidURL }
    do {
      try MCPServerTransportConfiguration.validateStreamableHTTPEndpoint(url)
      return nil
    } catch let error as MCPServerEndpointError {
      return error
    } catch {
      return MCPServerEndpointError.invalidURL
    }
  }

  var isValid: Bool {
    guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
    switch transport {
    case .stdio:
      return !command.trimmingCharacters(in: .whitespaces).isEmpty
    case .streamableHTTP:
      return endpointError == nil
    }
  }

  func server(replacing existing: MCPServerConfig? = nil) -> MCPServerConfig? {
    guard isValid else { return nil }
    let configuration: MCPServerTransportConfiguration
    switch transport {
    case .stdio:
      configuration = .stdio(
        command: command.trimmingCharacters(in: .whitespaces),
        arguments: Self.parsedArguments(argumentsText),
        environment: Self.parsedEnvironment(environmentText)
      )
    case .streamableHTTP:
      guard let endpoint = parsedEndpoint else { return nil }
      configuration = .streamableHTTP(endpoint: endpoint)
    }
    return MCPServerConfig(
      id: existing?.id ?? UUID(),
      name: name.trimmingCharacters(in: .whitespaces),
      transport: configuration,
      isEnabled: existing?.isEnabled ?? true
    )
  }

  private var parsedEndpoint: URL? {
    URL(string: endpoint.trimmingCharacters(in: .whitespaces))
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

extension MCPServerConfig {
  var connectionDescription: String {
    switch transport {
    case .stdio(let command, let arguments, _):
      return ([command] + arguments).joined(separator: " ")
    case .streamableHTTP(let endpoint):
      return endpoint.absoluteString
    }
  }
}
