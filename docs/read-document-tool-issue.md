# [FEATURE] Add `read_document` for workspace documents

## Problem

Sumika can convert supported documents to Markdown when they are added as chat
attachments, but the same files cannot be read from the active workspace.
`read_file` is intentionally limited to UTF-8 text, so binary documents such as
PDF, DOCX, and EPUB currently fail as `non-UTF-8 text`.

## Proposed V1

Add an Agent-mode `read_document` tool that converts one workspace document to
Markdown using the same local AnyDoc converter and supported-format list as chat
attachments.

Tool input:

```json
{
  "path": "documents/report.pdf"
}
```

The tool should:

- Accept only a workspace-relative `path` inside the active workspace.
- Support the same document extensions as attachments: `doc`, `docx`, `docm`,
  `odt`, `pdf`, `ppt`, `pps`, `pot`, `pptx`, `pptm`, `ppsx`, `ppsm`, `rtf`,
  `epub`, `xlsx`, `xlsm`, `xlsb`, `xls`, `ods`, and `odp`.
- Reuse the existing `DocumentMarkdownConverting` seam and
  `AnyDocDocumentMarkdownConverter`; do not add another parser or format list.
- Apply the existing 64 MiB source-document and 256 KiB converted-Markdown
  guards.
- Return complete Markdown only when it fits the existing 32,000-character
  attachment-content budget. Otherwise fail with a clear too-large error; do
  not silently truncate.
- Return an actionable failure when conversion requires OCR or fails for
  another reason. The failure must state that no document content was
  extracted and must not encourage guessing from the filename or metadata.
- Be read-only, low-risk, and available only in Agent mode.

`read_file` remains the tool for UTF-8 text and source code. A successful
`read_document` result is derived Markdown, not the literal editable contents of
the workspace file, so it must not offer `edit_file` as a next action or update
focused-file editing snapshots.

## Implementation outline

- Add typed `read_document` input, result, definition, codec, executor, and
  model/transcript projection in `SumikaCore`.
- Inject the existing document converter from `SumikaApp` into the Agent tool
  registry without adding public API.
- Resolve the path and security-scoped workspace access through the existing
  workspace policy before reading bytes.
- Share the attachment document-extension and size policies instead of
  duplicating constants.
- Update Agent guidance so supported workspace documents use `read_document`,
  while chat attachments continue to use their supplied prompt content.
- Update `docs/tool-runtime.md` and the persisted tool data-model documentation.

## Out of scope

- OCR for scanned or mixed PDFs
- RAG, indexing, embeddings, search, chunking, or pagination
- Partial Markdown results
- Editing or writing document formats
- Network services, uploads, shell commands, or external CLI fallbacks
- Reading chat attachments by attachment ID
- Images and ordinary UTF-8 text files

## Acceptance criteria

- [ ] `read_document` converts every document format currently accepted by the
      attachment picker through the same AnyDoc adapter.
- [ ] A supported PDF, DOCX, or EPUB inside the active workspace can be analyzed
      without attaching it and without using `run_command`.
- [ ] Paths outside the active workspace are denied.
- [ ] Unsupported extensions, directories, oversized input/output, conversion
      failures, and OCR-required documents return typed, actionable failures.
- [ ] Failed conversion returns no partial document content.
- [ ] The tool is present in Agent mode and absent from Chat mode.
- [ ] Tool results are persisted and rendered through the typed tool runtime.
- [ ] `read_document` results never enter the `read_file`/`edit_file` focused-file
      workflow.
- [ ] Focused executor, projection, prompt, persistence, and real-converter tests
      cover the new path.
- [ ] `just data-model`, `just prompt-cost`, and `just final-check` pass.
