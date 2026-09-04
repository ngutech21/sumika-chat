# Contributing to Sumika

Thank you for helping improve Sumika. Contributions should stay focused,
reviewable, and compatible with the local-first nature of the project.

For ordinary bugs and feature requests, use the
[issue tracker](https://github.com/ngutech21/sumika-chat/issues). Larger features,
persisted-data changes, and architectural changes should be discussed in an
issue before implementation. Report suspected vulnerabilities privately as
described in [SECURITY.md](SECURITY.md).

## Development Requirements

Sumika is a native macOS project. Development requires:

- macOS 15 or later.
- Xcode 26.6 (build 17F113) with Apple Swift 6.3.3 and the macOS 26.5 SDK.
- [Homebrew](https://brew.sh/).
- `just`, SwiftLint, Periphery, and `typos` for the complete local verification
  workflow. Xcode provides `swift-format`.

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

- [Chat runtime](docs/chat-runtime.md)
- [Tool runtime](docs/tool-runtime.md)
- [Agent loop](docs/agent-loop.md)
- [Data model](docs/model.md)

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

### Persisted Data

Treat `ChatSession.turns` and `ChatTurn.items` as the persisted transcript and
tool-state source of truth. Avoid duplicate persisted collections, caches, or
projections when the same information can be derived reliably.

Persisted-schema changes need focused tests for ownership, ordering, invariants,
and encode/decode round trips. Run `just data-model` and include the regenerated
`docs/data-model.md` when the schema changes. That file is generated and should
not be edited manually; `docs/model.md` is the curated model overview.

### Tools

Tools must use the typed runtime described in
[docs/tool-runtime.md](docs/tool-runtime.md). Registry membership controls
availability, and write, edit, and command tools must enter the approval flow
before execution. Update the runtime documentation when a tool contract changes.

## Tests and Verification

Use the narrowest feedback loop that covers the change:

| Change | Required verification |
| --- | --- |
| One behavior or test suite | `swift test --filter <pattern>` |
| Package logic or integration | `just test` |
| Xcode launcher, resources, embedding, or project wiring | `just build` |
| UI, accessibility, launch-test mode, or UI-facing MLX traces | `just test-ui` |
| Persisted data-model schema | `just data-model` |
| Concurrency or memory safety | `just test-tsan` or `just test-asan` |
| Documentation or comments only | `just typos` |

Before requesting review, run:

```sh
just final-check
```

This checks spelling, formatting, lint, dead code, and SwiftPM tests. It does not
replace `just build` or `just test-ui` when a change affects those areas. UI
tests are local-only, must not download a model, and may skip when their
configured local model is unavailable.

Report the checks you actually ran and their real outcomes in the pull request.
If an unrelated failure or environment restriction blocks a check, identify it
instead of reporting the suite as passing.

## Dependencies and Generated Files

All Swift package dependencies are declared in the root `Package.swift`. After
changing dependencies, run:

```sh
just resolve-packages
just check-package-locks
```

Commit both `Package.resolved` files. The root lockfile is the canonical package
selection, while the Xcode lockfile retains workspace-specific metadata; they
are not expected to be byte-identical.

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

## Releases and License

Maintainers should follow the separate [release process](docs/release.md).
Contributions are made to a project distributed under the terms in [LICENSE](LICENSE).
