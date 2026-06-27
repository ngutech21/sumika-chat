# Chat View TODOs

## Transcript Feature Parity

- Restore full tool detail rendering, including request details, result previews,
  error states, and expanded output.
- Re-check ask-user and approval rows, including approve/deny actions, selected
  options, long option text, and reused row state.
- Complete attachment handling beyond image thumbnails: multiple attachments,
  non-image files, failed image loads, open/reveal actions, and accessible labels.
- Polish code block behavior: per-code-block copy, long-line horizontal scrolling,
  wrapping decisions, large block performance, and streaming code updates.
- Close remaining Markdown gaps that matter for model output: blockquote styling,
  nested list polish, task lists, strikethrough, and readable HTML fallbacks.
- Improve text selection and copy behavior for long assistant responses.
- Audit accessibility output so rows expose concise roles, labels, values, and
  actions instead of long technical descriptions.

## Chat View Architecture

- Keep reducing `WorkspaceChatView` to composition and routing only.
- Introduce a focused transcript controller that owns rendered items, diff
  planning, height cache, pinned-bottom state, copy feedback, expanded tool
  state, attachment preview state, and highlight cache.
- Consider replacing the transcript `NSViewRepresentable` with an
  `NSViewControllerRepresentable` backed by a dedicated AppKit transcript view
  controller.
- Keep preview, terminal, composer, transcript, and debug state local to their
  own host/controller boundaries.

## Performance And Diagnostics

- Verify passive scrolling does not trigger transcript snapshots, assistant
  Markdown reparsing, syntax highlight work, or unrelated SwiftUI body updates.
- Re-sample Release builds after each larger transcript change and compare
  SwiftUI host layout, CoreText drawing, row configuration, and accessibility
  costs.
