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
