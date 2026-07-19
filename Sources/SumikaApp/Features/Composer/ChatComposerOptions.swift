import Foundation
import SumikaCore
import SwiftUI

struct ChatComposerOptions: View {
  struct Configuration {
    let interactionMode: WorkspaceInteractionMode
    let reasoningEnabled: Bool
    let toolApprovalPolicy: ToolApprovalPolicy
    let canChangeReasoning: Bool
    let canEnableAutomaticToolApproval: Bool
    let servers: [MCPServerConfig]
    let statuses: [MCPServerStatus]
    let selectedServerIDs: [UUID]
    let canChangeMCPSelection: Bool
    let onSetReasoningEnabled: (Bool) -> Void
    let onEnableAutomaticToolApproval: () -> Void
    let onDisableAutomaticToolApproval: () -> Void
    let onSelectServerIDs: ([UUID]) -> Void
  }

  let configuration: Configuration

  @State private var isPresented = false
  @State private var showAutoApproveConfirmation = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "slider.horizontal.3")
          .font(.system(size: 10, weight: .semibold))
        Text("Options")
          .font(.caption2.weight(.medium))
          .lineLimit(1)
        if showsAutomaticApprovalWarning {
          Image(systemName: "shield.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.orange)
        }
      }
      .foregroundStyle(Color.secondary)
      .padding(.horizontal, 7)
      .frame(width: 86, height: 24)
      .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
      .overlay {
        RoundedRectangle(cornerRadius: 5)
          .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
      }
    }
    .buttonStyle(.plain)
    .help("Session options")
    .accessibilityLabel("Session options")
    .accessibilityValue(accessibilityValue)
    .accessibilityIdentifier("chat.sessionOptions")
    .popover(isPresented: $isPresented) {
      optionsContent
    }
    .alert("Enable Auto-approve?", isPresented: $showAutoApproveConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Enable Auto-approve", role: .destructive) {
        configuration.onEnableAutomaticToolApproval()
      }
    } message: {
      Text(
        """
        Agent will execute file changes, web and MCP actions, and arbitrary shell commands without asking again. Shell commands run with your user permissions and can access files outside this workspace and the network.
        """
      )
    }
  }

  private var optionsContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Session options")
          .font(.headline)
        Text("Only for this chat")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)

      Divider()

      reasoningRow
        .padding(8)

      if configuration.interactionMode == .agent {
        Divider()
          .padding(.horizontal, 8)

        agentOptions
          .padding(8)
      }
    }
    .frame(width: 320)
  }

  private var reasoningRow: some View {
    Toggle(
      isOn: Binding(
        get: { configuration.reasoningEnabled },
        set: { isEnabled in
          configuration.onSetReasoningEnabled(isEnabled)
        }
      )
    ) {
      optionLabel(
        title: "Reasoning",
        description: "Enable the model’s reasoning process.",
        systemImage: "lightbulb"
      )
    }
    .toggleStyle(.switch)
    .controlSize(.small)
    .disabled(!configuration.canChangeReasoning)
    .accessibilityLabel("Reasoning")
    .accessibilityValue(configuration.reasoningEnabled ? "On" : "Off")
    .accessibilityIdentifier("chat.reasoningToggle")
  }

  private var agentOptions: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Agent")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)

      autoApproveRow

      Divider()
        .padding(.vertical, 2)

      mcpServerSection
    }
  }

  private var autoApproveRow: some View {
    let isAutomatic = configuration.toolApprovalPolicy == .automatic

    return Toggle(
      isOn: Binding(
        get: { isAutomatic },
        set: { shouldEnable in
          if shouldEnable {
            showAutoApproveConfirmation = true
          } else {
            configuration.onDisableAutomaticToolApproval()
          }
        }
      )
    ) {
      optionLabel(
        title: "Auto-approve",
        description: "Skip approval prompts for allowed Agent tools.",
        systemImage: isAutomatic ? "shield.fill" : "shield"
      )
    }
    .toggleStyle(.switch)
    .controlSize(.small)
    .tint(isAutomatic ? .orange : .accentColor)
    .disabled(!isAutomatic && !configuration.canEnableAutomaticToolApproval)
    .accessibilityLabel("Auto-approve")
    .accessibilityValue(isAutomatic ? "Enabled" : "Disabled")
    .accessibilityIdentifier("chat.autoApproveToggle")
  }

  private var mcpServerSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        VStack(alignment: .leading, spacing: 1) {
          Text("MCP servers")
            .font(.subheadline.weight(.medium))
          Text("Connect tools from selected servers.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if !configuration.selectedServerIDs.isEmpty {
          Button("Clear") {
            configuration.onSelectServerIDs([])
          }
          .buttonStyle(.borderless)
          .controlSize(.small)
          .disabled(!configuration.canChangeMCPSelection)
          .accessibilityIdentifier("chat.mcpServerClear")
        }
      }
      .padding(.horizontal, 4)

      if configuration.servers.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("No MCP servers configured.")
            .foregroundStyle(.secondary)
          SettingsLink {
            Label("Configure in Settings…", systemImage: "gear")
          }
          .controlSize(.small)
        }
        .padding(4)
      } else {
        VStack(alignment: .leading, spacing: 1) {
          ForEach(configuration.servers) { server in
            serverRow(server)
          }
        }
      }
    }
  }

  private func optionLabel(
    title: String,
    description: String,
    systemImage: String
  ) -> some View {
    HStack(spacing: 8) {
      Image(systemName: systemImage)
        .frame(width: 16)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
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
    .disabled(!configuration.canChangeMCPSelection)
    .accessibilityLabel(server.name)
    .accessibilityValue(
      isSelected ? "Selected, \(statusText(for: server))" : statusText(for: server)
    )
    .accessibilityIdentifier("chat.mcpServer.\(server.id.uuidString)")
  }

  private var showsAutomaticApprovalWarning: Bool {
    configuration.interactionMode == .agent
      && configuration.toolApprovalPolicy == .automatic
  }

  private var accessibilityValue: String {
    let reasoning = configuration.reasoningEnabled ? "Reasoning on" : "Reasoning off"
    guard configuration.interactionMode == .agent else {
      return reasoning
    }

    let approval =
      configuration.toolApprovalPolicy == .automatic
      ? "Auto-approve on" : "Auto-approve off"
    let count = configuration.selectedServerIDs.count
    let servers = count == 1 ? "1 MCP server selected" : "\(count) MCP servers selected"
    return "\(reasoning), \(approval), \(servers)"
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
