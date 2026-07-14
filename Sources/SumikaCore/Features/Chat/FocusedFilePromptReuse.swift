import Foundation

struct FocusedFilePromptReusePolicy: Equatable, Sendable {
  let maxCompactUsesPerAnchor: Int
  let maxInterveningProviderBytes: Int

  static let conservative = FocusedFilePromptReusePolicy(
    maxCompactUsesPerAnchor: 1,
    maxInterveningProviderBytes: 8_000
  )
  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  static let disabled = FocusedFilePromptReusePolicy(
    maxCompactUsesPerAnchor: 0,
    maxInterveningProviderBytes: 0
  )

  var isEnabled: Bool {
    maxCompactUsesPerAnchor > 0 && maxInterveningProviderBytes >= 0
  }
}

enum FocusedFilePromptReusePlanner {
  static func apply(
    to fullProjection: ModelPromptProjection,
    policy: FocusedFilePromptReusePolicy,
    anchorResetBeforeEntryIDs: Set<ModelContextEntry.ID> = []
  ) -> ModelPromptProjection {
    guard policy.isEnabled else {
      return fullProjection
    }
    guard containsPotentialReusePair(in: fullProjection) else {
      return fullProjection
    }

    let providerProjection = ProviderPromptProjection.normalized(from: fullProjection)
    var entries = fullProjection.entries
    var anchor: Anchor?

    for index in fullProjection.entries.indices {
      let entry = fullProjection.entries[index]

      if anchorResetBeforeEntryIDs.contains(entry.id) {
        anchor = nil
      }

      if invalidatesReuseAnchor(entry) {
        anchor = nil
        continue
      }

      guard case .userPrompt(let userPrompt) = entry.body,
        let currentPromptContext = userPrompt.currentPromptContext,
        let focusedFile = focusedFileCandidate(in: currentPromptContext)
      else {
        continue
      }

      guard let fingerprint = Fingerprint(focusedFile) else {
        anchor = nil
        continue
      }

      guard var existingAnchor = anchor,
        existingAnchor.fingerprint == fingerprint,
        existingAnchor.compactUseCount < policy.maxCompactUsesPerAnchor,
        let interveningBytes = providerProjection.byteLedger.interveningByteCount(
          afterSourceEntryID: existingAnchor.sourceEntryID,
          beforeSourceEntryID: entry.id
        ),
        interveningBytes <= policy.maxInterveningProviderBytes
      else {
        anchor = Anchor(sourceEntryID: entry.id, fingerprint: fingerprint)
        continue
      }

      entries[index] = compactEntry(
        from: entry,
        userPrompt: userPrompt,
        currentPromptContext: currentPromptContext
      )
      existingAnchor.compactUseCount += 1
      anchor = existingAnchor
    }

    return ModelPromptProjection(entries: entries)
  }

  private static func containsPotentialReusePair(
    in projection: ModelPromptProjection
  ) -> Bool {
    var fingerprints: [Fingerprint] = []
    for entry in projection.entries {
      guard case .userPrompt(let userPrompt) = entry.body,
        let context = userPrompt.currentPromptContext,
        let candidate = focusedFileCandidate(in: context),
        let fingerprint = Fingerprint(candidate)
      else {
        continue
      }
      if fingerprints.contains(fingerprint) {
        return true
      }
      fingerprints.append(fingerprint)
    }
    return false
  }

  private static func focusedFileCandidate(
    in context: CurrentPromptContext
  ) -> FocusedFileCandidate? {
    guard case .selected(let selection) = context else {
      return nil
    }
    let supportingBlocks = selection.blocks.values.filter { block in
      if case .workspaceInstructions = block {
        return false
      }
      return true
    }
    guard supportingBlocks.count == 1,
      case .focusedFile(let focusedFile) = supportingBlocks[0]
    else {
      return nil
    }
    return FocusedFileCandidate(
      context: focusedFile,
      truncation: selection.truncation
    )
  }

  private static func compactEntry(
    from entry: ModelContextEntry,
    userPrompt: UserPromptContext,
    currentPromptContext: CurrentPromptContext
  ) -> ModelContextEntry {
    let workspaceInstructions = CurrentPromptContextRenderer.renderWorkspaceInstructions(
      currentPromptContext
    )
    let systemContext = CurrentPromptContextRenderer.renderSupportingContext(
      currentPromptContext,
      focusedFilePresentation: .compactReuse
    )
    let compactUserPrompt = UserPromptContext(
      prompt: userPrompt.prompt,
      attachmentNames: userPrompt.attachmentNames,
      imageSignatures: userPrompt.imageSignatures,
      workspaceInstructions: workspaceInstructions,
      systemContext: systemContext,
      currentPromptContext: currentPromptContext
    )
    guard
      let compactEntry = try? ModelContextEntry(
        id: entry.id,
        turnID: entry.turnID,
        sourceMessageID: entry.sourceMessageID,
        body: .userPrompt(compactUserPrompt),
        frozenContent: FrozenModelContent(
          role: .user,
          content: ModelFacingPromptRenderer.userContent(
            userPrompt.prompt,
            workspaceInstructions: workspaceInstructions,
            systemContext: systemContext
          )
        )
      )
    else {
      return entry
    }
    return compactEntry
  }

  private static func invalidatesReuseAnchor(_ entry: ModelContextEntry) -> Bool {
    guard case .toolObservation(let context) = entry.body else {
      return false
    }
    if context.toolName == .readFile {
      return !isCompleteReadFileObservation(context)
    }
    return !nonMutatingToolNames.contains(context.toolName)
  }

  private static func isCompleteReadFileObservation(
    _ context: ToolObservationContext
  ) -> Bool {
    guard context.status == .success,
      let receipt = context.toolReceipt,
      receipt.status == .success,
      !receipt.outputTruncated,
      !receipt.outputRedacted,
      let toolCall = context.toolCall,
      toolCall.toolName == .readFile
    else {
      return false
    }
    return !hasConcreteArgument("offset", in: toolCall.rawArguments)
      && !hasConcreteArgument("limit", in: toolCall.rawArguments)
  }

  private static func hasConcreteArgument(
    _ name: String,
    in arguments: ToolCallArguments
  ) -> Bool {
    guard let value = arguments[name] else {
      return false
    }
    if case .null = value {
      return false
    }
    return true
  }

  private static let nonMutatingToolNames: Set<ToolName> = [
    .readFile,
    .showFile,
    .listFiles,
    .globFiles,
    .searchFiles,
    .workspaceDiff,
    .workspaceDiagnostics,
    .todoWrite,
    .askUser,
    .finishTask,
    .browserRefresh,
    .browserInspect,
    .webSearch,
    .webFetch,
  ]

  private struct Anchor {
    let sourceEntryID: UUID
    let fingerprint: Fingerprint
    var compactUseCount = 0
  }

  private struct Fingerprint: Equatable {
    let path: WorkspaceRelativePath
    let source: FocusedPathSource
    let contentHash: String
    let excerpt: PromptContextExcerpt
    let fullContentAvailable: Bool
    let truncation: PromptContextTruncation

    init?(_ candidate: FocusedFileCandidate) {
      let context = candidate.context
      guard context.isReuseEligible,
        candidate.truncation == .none,
        let source = context.source,
        let contentHash = context.contentHash,
        let excerpt = context.excerpt
      else {
        return nil
      }
      path = context.path
      self.source = source
      self.contentHash = contentHash
      self.excerpt = excerpt
      fullContentAvailable = context.fullContentAvailable
      truncation = candidate.truncation
    }

    static func == (lhs: Fingerprint, rhs: Fingerprint) -> Bool {
      lhs.path == rhs.path
        && lhs.source == rhs.source
        && lhs.contentHash == rhs.contentHash
        && lhs.excerpt == rhs.excerpt
        && lhs.fullContentAvailable == rhs.fullContentAvailable
        && lhs.truncation == rhs.truncation
    }
  }

  private struct FocusedFileCandidate {
    let context: FocusedFilePromptContext
    let truncation: PromptContextTruncation
  }
}
