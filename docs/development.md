# Development

For contribution and review expectations, see [Contributing](../CONTRIBUTING.md).
Run commands from the repository root. See [Testing](testing.md) for verification,
sanitizer limitations, and benchmarks.

## Development Requirements

Sumika is a native macOS project. Development requires:

- A macOS version supported by the selected Xcode release.
- The Xcode, Swift, and macOS SDK versions recorded in
  [versions.env](../.github/actions/setup-apple-toolchain/versions.env).
- [Homebrew](https://brew.sh/).
- `just`, Periphery, and `typos` for the complete local verification workflow.
  The project resolves its pinned SwiftLint binary through SwiftPM, and Xcode
  provides `swift-format`.

`versions.env` also defines `MACOS_RUNNER`, the GitHub-hosted runner label used
by all Apple toolchain jobs. A reusable configuration workflow reads it through
the GitHub Contents API on Ubuntu, without checking out or executing repository
files, before GitHub schedules the macOS jobs. Release builds read the file from
their release tag; other jobs use their triggering commit. Change the runner and
toolchain versions together, and update the approved hosted runner labels in
`.github/workflows/apple-toolchain.yml` when selecting a new runner. This does
not change the app's macOS 15 minimum deployment target.

Install `just`, then use the project recipe to install its primary development
tools:

```sh
brew version-install just@1.58.0
brew version-install typos-cli@1.50.0
just deps
```

The first Xcode build may ask you to approve the pinned
`MLXHuggingFaceMacros` package macro. Review and approve it in Xcode. Do not
disable package-plugin or macro validation for normal local development.

## Build the Project

Clone the repository and build the app from its root directory:

```sh
git clone https://github.com/ngutech21/sumika-chat.git
cd sumika-chat
just build
open "build/DerivedData/Build/Products/Debug/Sumika.app"
```

You can also open `Sumika.xcodeproj` and run the `Sumika` scheme for macOS.
Run `just --list` to see the currently supported project tasks.

## Architecture

Keep changes within the existing ownership boundaries:

- `Sources/SumikaCore/` owns provider-neutral domain models, workflows,
  persistence, tools, policies, and runtime protocols.
- `Sources/SumikaRuntimeMLX/` owns MLX, Gemma, and Qwen implementations behind
  core protocols.
- `Sources/SumikaApp/` owns SwiftUI, AppKit, presentation adapters, and macOS
  integrations.
- `sumika/` contains the Xcode app launcher, resources, entitlements, and bundle
  metadata.

Dependencies point from `SumikaApp` to `SumikaRuntimeMLX` to `SumikaCore`.
`SumikaApp` may also use `SumikaCore` directly. Core must remain independent of
SwiftUI, AppKit, MLX, and Tree-sitter products.

Views should call controllers or app state. Parsing model output, file access,
command execution, permission decisions, and MLX details belong behind the
appropriate workflow or service boundary.

Before changing chat or tool behavior, read the relevant documentation:

- [Chat runtime](chat-runtime.md)
- [Tool runtime](tool-runtime.md)
- [Agent loop](agent-loop.md)
- [Data model](model.md)

## Implementation Guidelines

- Prefer narrow changes with focused tests. Preserve unrelated worktree changes.
- Use async/await for model calls, file I/O, and command execution. Long-running
  work should be cancellable.
- Prefer typed inputs and results over raw strings or ad hoc dictionaries.
- Keep declarations at the narrowest access level required by current callers.
- Add an abstraction only when it hides meaningful coordination or supports a
  concrete caller, alternate implementation, or test boundary.
- Do not add speculative layers, parallel implementations, or new top-level
  directories.
- Complete refactors by migrating all in-scope callers and removing the replaced
  code, tests, flags, and compatibility paths.
- Keep comments sparse and useful. Source files should remain ASCII unless
  non-ASCII text is required.

For persisted-data invariants and schema changes, see
[the domain model](model.md#persisted-data) and [persistence](persistence.md).
For typed tool registration and approval, see [the tool runtime](tool-runtime.md).

## Dependencies and Generated Files

Xcode builds embed pinned uv through `script/embed_uv.sh`. The first app build
downloads its checksum-verified Apple Silicon archive into `.build/uv/`; subsequent
builds can use that cache offline. Run `bash script/embed_uv.sh --prepare` to warm
the cache, or set `SUMIKA_UV_OFFLINE=1` to fail immediately if it is unavailable.
Developer ID release signing still requires Apple's timestamp service.
The script uses macOS tools and does not require installed Python or uv. SwiftPM
tests inject fake executables and do not download Python or MCP packages.

See [bundled MCP runtime checks](testing.md#bundled-mcp-runtime-checks) for
networked smoke tests and offline configuration checks.

Update `script/uv-release.sh` and the bundled upstream license together when
upgrading uv, then verify embedding, managed MCP startup, and the exported app.

All product Swift package dependencies are declared in the root `Package.swift`.
The isolated SwiftLint tool package lives under `script/swiftlint`. After
changing product dependencies, run:

```sh
just resolve-packages
just check-package-locks
```

Commit both `Package.resolved` files. The root lockfile is the canonical package
selection, while the Xcode lockfile retains workspace-specific metadata; they
are not expected to be byte-identical.

After changing the pinned SwiftLint dependency, run `just resolve-swiftlint`
and commit `script/swiftlint/Package.resolved`.

Do not commit model downloads, DerivedData, `.build` contents, release artifacts,
or unrelated generated files.

## Commits and Pull Requests

Use intentional Conventional Commit messages, for example:

```text
fix: preserve complete command output records
feat: add a workspace interaction mode
docs: clarify local model setup
```

When a commit closes an issue, add `Fixes #<id>` in a separate paragraph.

Keep pull requests limited to one coherent change. The description should cover:

- The problem and user impact.
- The chosen solution and important tradeoffs.
- Tests and manual checks performed.
- Screenshots or recordings for visible UI changes.
- Persistence, migration, permission, or security implications.
- Known limitations or follow-up work.

Review the complete diff before submitting. Do not include build output,
credentials, private conversations, workspace content, or unrelated edits.
Sanitize logs and MLX traces before attaching them to a public issue or pull
request.

Maintainers should follow the separate [release process](release.md).
