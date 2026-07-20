import AppKit
import SumikaCore
import SwiftUI

struct ModelContextDebugHost: View {
  let controller: ChatSessionController
  let context: WorkspaceChatContext
  let sessionID: ChatSession.ID?
  let onClose: () -> Void

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = Self._printChanges()
    #endif

    let debugState = controller.modelContextDebugState
    ModelContextDebugPane(
      debugState: debugState,
      requestID: ModelContextDebugRequestID(
        controllerID: ObjectIdentifier(controller),
        workspaceID: context.id,
        sessionID: sessionID,
        documentRevision: debugState.documentRevision
      ),
      makeDocument: {
        try controller.modelContextDebugDocument(
          workspace: context.workspace(containing: sessionID ?? controller.sessionID),
          sessionID: sessionID
        )
      },
      onClose: onClose
    )
  }
}

struct ModelContextDebugPane: View {
  let debugState: ModelContextDebugState
  let requestID: ModelContextDebugRequestID
  let makeDocument: @MainActor () throws -> ModelContextDebugDocument
  let onClose: () -> Void
  @State private var documentResult: Result<ModelContextDebugDocument, Error>?
  @State private var didCopy = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      switch documentResult {
      case .success(let document):
        header(for: document)
        RuntimeCacheDebugSection(snapshot: debugState.runtimeCacheDebugSnapshot)
        Divider()
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            ModelContextDebugEntryView(entry: document.systemPrompt)
            ForEach(document.entries) { entry in
              ModelContextDebugEntryView(entry: entry)
            }
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      case .failure(let error):
        ContentUnavailableView(
          "Model Context Unavailable",
          systemImage: "exclamationmark.triangle",
          description: Text(error.localizedDescription)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case nil:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(width: 380)
    .frame(maxHeight: .infinity)
    .background(.regularMaterial)
    .overlay(alignment: .leading) {
      Divider()
    }
    .accessibilityIdentifier("modelContextDebug.pane")
    .task(id: requestID) {
      refreshDocument()
    }
  }

  @MainActor
  private func refreshDocument() {
    documentResult = Result {
      try makeDocument()
    }
  }

  private func header(for document: ModelContextDebugDocument) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Projected Model Context")
            .font(.headline)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)

          Text(document.signature)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(document.signature)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        HStack(spacing: 8) {
          Button {
            copy(document.renderedContext)
          } label: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
          }
          .help(didCopy ? "Copied" : "Copy full context")
          .accessibilityLabel("Copy full model context")

          Button(action: onClose) {
            Image(systemName: "xmark")
          }
          .help("Hide model context debug")
          .accessibilityLabel("Hide model context debug")
        }
      }

      HStack(spacing: 12) {
        ModelContextDebugMetric(
          title: "Chars",
          value: document.totalCharacters.formatted(.number)
        )
        ModelContextDebugMetric(
          title: "Est. tokens",
          value: document.totalEstimatedTokens.formatted(.number)
        )
        ModelContextDebugMetric(
          title: "Entries",
          value: document.entries.count.formatted(.number)
        )
      }
    }
    .padding(16)
  }

  private func copy(_ context: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(context, forType: .string)
    didCopy = true

    Task {
      try? await Task.sleep(for: .seconds(1.2))
      didCopy = false
    }
  }
}

struct ModelContextDebugRequestID: Equatable {
  let controllerID: ObjectIdentifier
  let workspaceID: Workspace.ID
  let sessionID: ChatSession.ID?
  let documentRevision: Int

  static func == (lhs: ModelContextDebugRequestID, rhs: ModelContextDebugRequestID) -> Bool {
    lhs.controllerID == rhs.controllerID
      && lhs.workspaceID == rhs.workspaceID
      && lhs.sessionID == rhs.sessionID
      && lhs.documentRevision == rhs.documentRevision
  }
}

private struct ModelContextDebugMetric: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .trailing, spacing: 2) {
      Text(title)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.caption.monospacedDigit())
    }
  }
}

private struct RuntimeCacheDebugSection: View {
  let snapshot: RuntimeCacheDebugSnapshot?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("KV Cache")
        .font(.subheadline.weight(.semibold))

      if let snapshot {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Label(statusTitle(for: snapshot), systemImage: statusImage(for: snapshot))
              .font(.caption.weight(.semibold))
            Spacer()
            Text(snapshot.recordedAt, style: .time)
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }

          RuntimeCacheDebugRow(title: "Reason", value: snapshot.cacheReason)
          RuntimeCacheDebugRow(title: "Mode", value: snapshot.cacheMode)
          RuntimeCacheDebugRow(title: "Reuse", value: reuseValue(for: snapshot))
          RuntimeCacheDebugRow(title: "Messages", value: messageValue(for: snapshot))
          RuntimeCacheDebugRow(title: "Mismatch", value: mismatchValue(for: snapshot))
          RuntimeCacheDebugRow(
            title: "System prompt",
            value: booleanValue(snapshot.systemPromptChanged)
          )
          RuntimeCacheDebugRow(
            title: "Prompt context",
            value: booleanValue(snapshot.currentPromptContextChanged)
          )
          RuntimeCacheDebugRow(title: "Signature", value: snapshot.contextSignature)
          if let previousContextSignature = snapshot.previousContextSignature {
            RuntimeCacheDebugRow(title: "Previous", value: previousContextSignature)
          }
        }
      } else {
        Text("No KV cache decision recorded yet.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 12)
  }

  private func statusTitle(for snapshot: RuntimeCacheDebugSnapshot) -> String {
    if snapshot.cacheMode == "append_delta" || snapshot.reuseStrategy == "append_delta" {
      return "Append-only delta"
    }
    if snapshot.cacheMode == "reused_session" {
      return "Reused"
    }
    if snapshot.cacheMode == "new_session" {
      return "New session"
    }
    if snapshot.cacheMode == "dirty_rebuild" {
      return "Rebuilt"
    }
    return snapshot.cacheMode
  }

  private func statusImage(for snapshot: RuntimeCacheDebugSnapshot) -> String {
    if snapshot.cacheMode == "reused_session" || snapshot.cacheMode == "append_delta" {
      return "bolt.horizontal.circle"
    }
    if snapshot.cacheMode == "new_session" {
      return "plus.circle"
    }
    if snapshot.cacheMode == "dirty_rebuild" {
      return "exclamationmark.triangle"
    }
    return "memorychip"
  }

  private func reuseValue(for snapshot: RuntimeCacheDebugSnapshot) -> String {
    guard let appendDeltaStartIndex = snapshot.appendDeltaStartIndex else {
      return snapshot.reuseStrategy
    }
    return "\(snapshot.reuseStrategy) @ \(appendDeltaStartIndex)"
  }

  private func messageValue(for snapshot: RuntimeCacheDebugSnapshot) -> String {
    "reused \(snapshot.reusedMessageCount), appended \(snapshot.appendedMessageCount)"
  }

  private func mismatchValue(for snapshot: RuntimeCacheDebugSnapshot) -> String {
    guard let mismatchReason = snapshot.mismatchReason else {
      return "none"
    }
    if let firstMismatchIndex = snapshot.firstMismatchIndex {
      return "\(mismatchReason) @ \(firstMismatchIndex)"
    }
    return mismatchReason
  }

  private func booleanValue(_ value: Bool?) -> String {
    switch value {
    case .some(true):
      "changed"
    case .some(false):
      "unchanged"
    case .none:
      "unknown"
    }
  }
}

private struct RuntimeCacheDebugRow: View {
  let title: String
  let value: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(title)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(width: 76, alignment: .leading)
      Text(value)
        .font(.caption.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .help(value)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct ModelContextDebugEntryView: View {
  let entry: ModelContextDebugEntry
  @State private var isExpanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      ScrollView(.horizontal) {
        Text(entry.content.isEmpty ? " " : entry.content)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 8)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      HStack(spacing: 10) {
        Label(entryTitle, systemImage: entry.role.systemImage)
          .font(.subheadline)
        Spacer()
        Text("\(entry.characterCount.formatted(.number)) chars")
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
        Text("~\(entry.estimatedTokens.formatted(.number)) tokens")
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
    }
    .padding(10)
    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
  }

  private var entryTitle: String {
    if let index = entry.index {
      return "\(index). \(entry.role.title)"
    }
    return entry.role.title
  }
}

extension ModelContextDebugRole {
  fileprivate var title: String {
    switch self {
    case .system:
      "System"
    case .user:
      "User"
    case .assistant:
      "Assistant"
    case .tool:
      "Tool"
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .system:
      "gearshape"
    case .user:
      "person"
    case .assistant:
      "cpu"
    case .tool:
      "wrench.and.screwdriver"
    }
  }
}
