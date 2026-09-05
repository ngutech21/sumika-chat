import Foundation
import Synchronization

/// Reservations are synchronous so UI mutations cannot outrun a queued save.
/// Disk work runs on this actor. The short per-file critical section makes the
/// ownership check and unlink indivisible with respect to new reservations.
package actor ChatAttachmentLifecycle {
  private struct References: Sendable {
    var leases: [UUID: Set<AttachmentID>] = [:]
    var committed: Set<AttachmentID>?
    var imported: Set<AttachmentID> = []
    var candidates: Set<AttachmentID> = []
    var blocked = false

    func protects(_ id: AttachmentID) -> Bool {
      committed?.contains(id) == true || leases.values.contains { $0.contains(id) }
    }
  }

  private let store: ChatAttachmentStore
  nonisolated private let references = Mutex(References())
  private var needsFullScan = false

  package init(store: ChatAttachmentStore = ChatAttachmentStore()) {
    self.store = store
  }

  package nonisolated func protect(_ ids: Set<AttachmentID>) -> ChatAttachmentLease {
    let id = UUID()
    references.withLock { $0.leases[id] = ids }
    return ChatAttachmentLease(id: id, lifecycle: self)
  }

  fileprivate nonisolated func replace(_ leaseID: UUID, with ids: Set<AttachmentID>) {
    references.withLock { state in
      guard let previous = state.leases[leaseID] else { return }
      state.candidates.formUnion(previous.subtracting(ids))
      state.leases[leaseID] = ids
    }
  }

  fileprivate nonisolated func release(_ leaseID: UUID) {
    references.withLock { state in
      state.candidates.formUnion(state.leases.removeValue(forKey: leaseID) ?? [])
    }
  }

  fileprivate nonisolated func transfer(_ source: UUID, into destination: UUID) {
    references.withLock { state in
      guard let ids = state.leases[source],
        let destinationIDs = state.leases[destination]
      else { return }
      state.leases[source] = nil
      state.leases[destination] = destinationIDs.union(ids)
    }
  }

  package nonisolated func recordCommittedReferences(_ ids: Set<AttachmentID>) {
    references.withLock { state in
      state.candidates.formUnion((state.committed ?? []).subtracting(ids))
      state.committed = ids
      state.imported.subtract(ids)
      state.blocked = false
    }
  }

  nonisolated func suspendReconciliation() {
    references.withLock { $0.blocked = true }
  }

  func storeFile(
    data: Data, id: AttachmentID, displayName: String, lease: ChatAttachmentLease
  ) async throws {
    references.withLock { state in
      precondition(state.leases[lease.id] != nil)
      state.leases[lease.id, default: []].insert(id)
      state.imported.insert(id)
    }
    _ = try await store.storeFile(data: data, id: id, displayName: displayName)
  }

  @discardableResult
  package func cleanup(reconcile: Bool = false) -> [FileCleanupIssue] {
    needsFullScan = needsFullScan || reconcile
    guard references.withLock({ !$0.blocked }) else { return [] }
    var issues: [FileCleanupIssue] = []
    if needsFullScan, references.withLock({ $0.committed != nil }) {
      do {
        let ids = try store.storedAttachmentIDs()
        references.withLock { $0.candidates.formUnion(ids) }
        needsFullScan = false
      } catch {
        issues.append(FileCleanupIssue(error))
      }
    }
    let candidates = references.withLock { $0.candidates }
    for id in candidates {
      references.withLock { state in
        guard !state.blocked, !state.protects(id),
          state.committed != nil || state.imported.contains(id)
        else { return }
        do {
          try store.removeStoredAttachment(id: id)
          state.candidates.remove(id)
          state.imported.remove(id)
        } catch {
          issues.append(FileCleanupIssue(error))
        }
      }
    }
    return issues
  }
}

package struct ChatAttachmentLease: Sendable {
  fileprivate let id: UUID
  fileprivate let lifecycle: ChatAttachmentLifecycle

  func replace(with ids: Set<AttachmentID>) {
    lifecycle.replace(id, with: ids)
  }

  package func release() {
    lifecycle.release(id)
  }
}

package struct ChatAttachmentImport: Sendable {
  package let attachments: [ChatAttachment]
  private let lease: ChatAttachmentLease

  init(attachments: [ChatAttachment], lease: ChatAttachmentLease) {
    self.attachments = attachments
    self.lease = lease
  }

  func adopt(into owner: ChatAttachmentLease) {
    precondition(lease.lifecycle === owner.lifecycle)
    lease.lifecycle.transfer(lease.id, into: owner.id)
  }

  @discardableResult
  package func discard() async -> [FileCleanupIssue] {
    lease.release()
    return await lease.lifecycle.cleanup()
  }
}

extension ChatSession {
  var attachmentIDs: Set<AttachmentID> {
    Set(
      turns.flatMap(\.items).flatMap { item -> [AttachmentID] in
        switch item {
        case .userMessage(let message): message.attachments.map(\.id)
        case .assistantMessage(let message): message.attachments.map(\.id)
        case .assistantThinking, .tool: []
        }
      })
  }
}

extension WorkspaceLibrary {
  package var attachmentIDs: Set<AttachmentID> {
    workspaces.flatMap(\.sessions).reduce(into: []) { $0.formUnion($1.attachmentIDs) }
  }
}
