import Foundation
import SumikaCore
import SwiftUI

struct MCPServerPicker: View {
  struct Configuration {
    let servers: [MCPServerConfig]
    let statuses: [MCPServerStatus]
    let selectedServerIDs: [UUID]
    let interactionMode: WorkspaceInteractionMode
    let canChangeSelection: Bool
    let onSelectServerIDs: ([UUID]) -> Void
  }

  let configuration: Configuration

  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "server.rack")
          .font(.system(size: 10, weight: .semibold))
        Text(title)
          .font(.caption2.weight(configuration.selectedServerIDs.isEmpty ? .medium : .semibold))
          .lineLimit(1)
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 8, weight: .semibold))
          .foregroundStyle(.tertiary)
      }
      .foregroundStyle(
        configuration.selectedServerIDs.isEmpty ? Color.secondary : Color.accentColor
      )
      .padding(.horizontal, 7)
      .frame(width: 72, height: 24)
      .background(
        configuration.selectedServerIDs.isEmpty
          ? Color.secondary.opacity(0.08) : Color.accentColor.opacity(0.18),
        in: RoundedRectangle(cornerRadius: 5)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 5)
          .strokeBorder(
            configuration.selectedServerIDs.isEmpty
              ? Color.secondary.opacity(0.16) : Color.accentColor.opacity(0.55),
            lineWidth: configuration.selectedServerIDs.isEmpty ? 1 : 1.2
          )
      }
    }
    .buttonStyle(.plain)
    .disabled(!configuration.canChangeSelection)
    .help(helpText)
    .accessibilityLabel("MCP servers")
    .accessibilityValue(accessibilityValue)
    .accessibilityIdentifier("chat.mcpServerPicker")
    .popover(isPresented: $isPresented) {
      pickerContent
    }
  }

  private var pickerContent: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("MCP Servers")
          .font(.headline)
        Spacer()
        if !configuration.selectedServerIDs.isEmpty {
          Button("Clear") {
            configuration.onSelectServerIDs([])
          }
          .buttonStyle(.borderless)
          .controlSize(.small)
          .accessibilityIdentifier("chat.mcpServerClear")
        }
      }
      .padding(.horizontal, 8)

      if configuration.servers.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("No MCP servers configured.")
            .foregroundStyle(.secondary)
          SettingsLink {
            Label("Configure in Settings…", systemImage: "gear")
          }
          .controlSize(.small)
        }
        .padding(8)
      } else {
        VStack(alignment: .leading, spacing: 1) {
          ForEach(configuration.servers) { server in
            serverRow(server)
          }
        }
      }
    }
    .padding(6)
    .frame(width: 300)
  }

  private func serverRow(_ server: MCPServerConfig) -> some View {
    let isSelected = configuration.selectedServerIDs.contains(server.id)
    return Button {
      var selection = configuration.selectedServerIDs
      if isSelected {
        selection.removeAll { $0 == server.id }
      } else {
        selection.append(server.id)
      }
      configuration.onSelectServerIDs(selection)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
          .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        VStack(alignment: .leading, spacing: 1) {
          Text(server.name)
            .lineLimit(1)
          Text(statusText(for: server))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
      .padding(.horizontal, 8)
      .frame(height: 34)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(server.name)
    .accessibilityValue(
      isSelected ? "Selected, \(statusText(for: server))" : statusText(for: server)
    )
    .accessibilityIdentifier("chat.mcpServer.\(server.id.uuidString)")
  }

  private var title: String {
    configuration.selectedServerIDs.isEmpty
      ? "MCP" : "MCP \(configuration.selectedServerIDs.count)"
  }

  private var helpText: String {
    configuration.interactionMode == .agent
      ? "Choose MCP servers for this session"
      : "MCP servers are available in Agent mode"
  }

  private var accessibilityValue: String {
    guard configuration.interactionMode == .agent else {
      return "Unavailable in Chat mode"
    }
    let count = configuration.selectedServerIDs.count
    return count == 1 ? "1 server selected" : "\(count) servers selected"
  }

  private func statusText(for server: MCPServerConfig) -> String {
    guard server.isEnabled else {
      return "Disabled"
    }
    switch configuration.statuses.first(where: { $0.serverID == server.id })?.state {
    case .connected(let toolCount):
      return toolCount == 1 ? "Connected, 1 tool" : "Connected, \(toolCount) tools"
    case .connecting:
      return "Connecting…"
    case .failed:
      return "Connection failed"
    case .disconnected, .none:
      return "Disconnected"
    }
  }
}
