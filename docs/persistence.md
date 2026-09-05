# Configuration Persistence

Sumika versions each durable configuration file independently. Settings files
use a top-level integer `schemaVersion`; a missing key is legacy version `0`.
Workspace manifest and session documents use a required top-level integer
`version`. Loading a supported legacy version migrates it eagerly and replaces
it atomically only after the current representation round-trips.

| File | Owner | Current version | Legacy input |
| --- | --- | ---: | --- |
| `app-behavior-settings.json` | `AppBehaviorSettingsStore` | 1 | Unversioned settings object |
| `web-access-settings.json` | `WebAccessSettingsStore` | 1 | Unversioned `{ "settings": ... }` wrapper |
| `mcp-servers.json` | `MCPServersStore` | 1 | Unversioned `{ "servers": [...] }` wrapper |
| `model-settings.json` | `ModelSettingsStore` | 4 | Unversioned snapshots and versions 2-3 |
| `WorkspaceLibrary/workspaces.json` | `WorkspaceStore` | 1 | Unversioned monolithic workspace library |
| `WorkspaceLibrary/sessions/*.json` | `WorkspaceStore` | 1 | Produced by the workspace v1 migration |

Configuration versions are not an application-wide release number. Bump only
the file whose persisted contract changes. Keep historical decoding in frozen
version-specific data-transfer types and migrate into the current domain model;
do not decode old versions through an evolving current type.

A version bump is required whenever an older Sumika binary could erase or
reinterpret data written by the newer binary. This includes field or case
renames, type changes, changed default semantics, removals, tagged-union changes,
and additive fields that an older encoder would discard.

Unreadable, malformed, and newer-version files fail closed. Sumika may continue
with safe in-memory defaults, but it must not overwrite the unavailable file.
Errors must not contain stored values, including MCP arguments or environment
variables. A missing file is different: it is a valid empty/default
configuration and may be created by the next save.

`selectedModelID` belongs to `model-settings.json` as of version 4. The former
`UserDefaults` key is imported once and removed only after the v4 file has been
written and verified. Pane visibility and collapsed-workspace IDs remain
disposable UI preferences in `UserDefaults`; they are not durable configuration
contracts.

Downloaded model `config.json` and `generation_config.json` files are model
artifacts owned by their publishers, not Sumika configuration schemas. Debug
traces and attachment payloads are operational data and likewise are outside
this versioning contract.

## Workspace deletion and attachment recovery

`WorkspaceStore.saveLibrary` writes changed session documents, then commits the
manifest before removing obsolete session files. A successful return means the
save committed; its typed result may separately contain cleanup warnings. The
store updates its persisted snapshot at commit, even when a later unlink fails.
No schema or directory-layout change and no persisted attachment ownership ledger
are required.

The shared `ChatAttachmentLifecycle` derives committed attachment references from
all retained user and assistant turn items, including cancelled and model-excluded
turns. These references are combined with leases for live conversations, pending
attachments, imports, and queued/in-flight save snapshots. Removing the final
reference reclaims the imported copy. Surviving conversations keep shared files.
The import and conversation transfer rules are documented in
[chat runtime](chat-runtime.md#attachment-ownership-and-cleanup).

A failed write before commit invalidates cached persistence assumptions and
suspends collection while retaining protection. The store must reload the complete
authoritative manifest and every referenced session before reconciling again.
Unreadable, malformed, unsupported, and partially loaded libraries cannot authorize
cleanup; an empty UI fallback is never evidence that stored attachments are unused.
An initially missing library authorizes full cleanup only after its first save.
If its initial write fails, the same store retains the known-empty initial state
so a later save can retry without a manifest. Attachment and session cleanup stay
suspended until that save commits. A newly opened store still rejects an existing
library directory without a manifest.

After a trusted startup load, recovery reload, or initial successful save, Sumika
scans for unreferenced attachment directories and orphaned session documents. This
completes deletion interrupted after manifest commit, as well as abandoned imports.
Ordinary saves clean only newly unreferenced data and previous failures. Cleanup
warnings are distinct from save failures, use the existing error UI and sanitized
logging, and retry on ownership changes, successful saves, startup, or shutdown.
Shutdown keeps its three-second limit, so the next startup can finish pending work.

Deletion targets are restricted to validated app-owned UUID directories under
`Attachments` and recognized UUID session documents under
`WorkspaceLibrary/sessions`. Unknown entries and symlinks are preserved. Attachment
filenames, original source URLs, and workspace roots never determine cleanup
targets. Removing a workspace removes its Sumika records, not its directory.
Debug traces under `debug` are explicitly excluded and retain their existing
independent retention behavior.

The sidebar's collapsed-workspace IDs are pruned against successfully loaded or
committed workspace membership. This covers both workspace-removal entry points;
startup placeholders and failed-load fallbacks do not prune preferences.
