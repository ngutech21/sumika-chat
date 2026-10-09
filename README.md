
[![CI](https://github.com/ngutech21/sumika-chat/actions/workflows/ci.yml/badge.svg)](https://github.com/ngutech21/sumika-chat/actions/workflows/ci.yml)
[![MacOS Nightly](https://github.com/ngutech21/sumika-chat/actions/workflows/macos-nightly.yml/badge.svg)](https://github.com/ngutech21/sumika-chat/actions/workflows/macos-nightly.yml)
[![Actions Lint](https://github.com/ngutech21/sumika-chat/actions/workflows/actions-lint.yml/badge.svg)](https://github.com/ngutech21/sumika-chat/actions/workflows/actions-lint.yml)
[![Spelling](https://github.com/ngutech21/sumika-chat/actions/workflows/spelling.yml/badge.svg)](https://github.com/ngutech21/sumika-chat/actions/workflows/spelling.yml)

# Sumika

A self-contained, private AI assistant for your Mac. Sumika runs local models
directly through MLX — no Ollama, LM Studio, external model server, API key, or
separate runtime required.

Install the app, choose and download a model, and start chatting right away.

Use Chat mode to write, translate, summarize, or research. Switch to Agent
mode when you want Sumika to write code, work with your files, use
approval-aware tools, or connect to local apps. Your conversations and model
execution stay on your Mac, and you choose how tools and network access are
approved.

## Highlights

- 💬 **Everyday AI assistance**: write, brainstorm, translate, summarize,
  research, and ask questions without needing a technical background.
- 🌟 **No recurring subscription**: use local models without paying for a
  hosted AI assistant plan.
- 🧭 **Explicit context**: attach files, focus workspace context, and inspect
  what the model sees before the workflow grows opaque.
- 🛠 **Approval-aware agent workflows**: keep manual approval prompts or opt in
  to Auto-approve from an Agent session's options.
- 🧩 **Connect local apps**: extend Agent mode through Model Context
  Protocol (MCP) servers and choose the integrations available to each session.
- 🌐 **Web research when you need it**: enable search and page fetching with
  built-in providers or your own services.
- 🖥 **Build and preview locally**: create small apps, prototypes, and HTML
  experiments with the integrated terminal and browser preview beside the chat.
- 🗣 **Speak and dictate**: listen to assistant responses with Apple system voices
  and turn speech into prompts with local English or multilingual transcription
  models.
- 🔄 **Update checks built in**: automatically check for signed releases and
  install them through the native Sparkle update flow.
- 🧾 **Inspectable transcript**: keep prompts, assistant responses, tool calls,
  approvals, and command output visible in the chat.

## Install Sumika

Sumika requires an Apple silicon Mac running macOS 15 or later.

1. Download the latest `Sumika-*-macos.dmg` from the
   [GitHub Releases page](https://github.com/ngutech21/sumika-chat/releases/latest).
2. Open the downloaded DMG and drag **Sumika** into **Applications**.
3. Start Sumika from the Applications folder and download a local model from
   the Models screen.
4. Open a conversation and choose Chat or Agent mode.

Release downloads are signed and notarized for macOS. Once installed, Sumika
checks automatically for new versions. When an update is available, the app
guides you through installing it, so you do not need to download another DMG.
You can also check manually from **Sumika > Check for Updates…**.

## Supported Models

All listed models run locally and support Chat mode and Agent tool calling. The
model browser groups them by use case, highlights recommended choices, and
marks whether a model accepts images or text only.

Download sizes are estimates of storage space, not the memory required to run a
model. Larger models need more memory, and memory usage also grows with the length
of the conversation. Start with a smaller model if your Mac has limited memory.

| Model | Input | Download size |
| --- | --- | ---: |
| [Gemma 4 E4B QAT 4-bit](https://huggingface.co/mlx-community/gemma-4-e4b-it-qat-4bit) | Images | 6.8 GB |
| [Gemma 4 12B QAT 4-bit](https://huggingface.co/mlx-community/gemma-4-12B-it-qat-4bit) | Images | 11.0 GB |
| [Gemma 4 26B A4B QAT 4-bit](https://huggingface.co/mlx-community/gemma-4-26B-A4B-it-qat-4bit) | Images | 15.6 GB |
| [Gemma 4 31B QAT 4-bit](https://huggingface.co/mlx-community/gemma-4-31B-it-qat-4bit) | Images | 28.8 GB |
| [Qwen 3.6 35B A3B 4-bit](https://huggingface.co/mlx-community/Qwen3.6-35B-A3B-4bit) | Images | 20.4 GB |
| [Qwen 3.6 35B A3B OptiQ 4-bit](https://huggingface.co/mlx-community/Qwen3.6-35B-A3B-OptiQ-4bit) | Images | 24.7 GB |
| [Qwen 3.6 35B A3B 8-bit](https://huggingface.co/mlx-community/Qwen3.6-35B-A3B-8bit) | Images | 37.7 GB |
| [Qwen 3.6 27B 4-bit](https://huggingface.co/mlx-community/Qwen3.6-27B-4bit) | Images | 16.1 GB |
| [Qwen 3.6 27B OptiQ 4-bit](https://huggingface.co/mlx-community/Qwen3.6-27B-OptiQ-4bit) | Images | 20.0 GB |
| [Qwen 3.6 27B 8-bit](https://huggingface.co/mlx-community/Qwen3.6-27B-8bit) | Images | 29.5 GB |
| [Qwen 3.8 27B OptiQ 4-bit](https://huggingface.co/mlx-community/Qwen3.8-27B-OptiQ-4bit) | Images | 20.0 GB |
| [Swift-1.5 4-bit](https://huggingface.co/ukisai/Swift-1.5-4bit-MLX) | Images | 15.8 GB |
| [Qwen 3.6 40B uncensored 8-bit](https://huggingface.co/mlx-community/Qwen3.6-40B-Claude-4.6-Opus-Deckard-Heretic-Uncensored-Thinking-8bit) | Text only | 41.5 GB |

## Screenshots

### Agent workflow

![Agent workflow creating a local Python snake game](screenshots/snake.webp)

Sumika can work in agent mode, write files through approval-aware tools, and
keep the transcript inspectable while it works.

### Local preview

![Local HTML pomodoro timer preview](screenshots/pomodoro.webp)

Build small local HTML, CSS, and JavaScript prototypes, then inspect them in the
native preview pane.

### Local models

![Local model management in Sumika](screenshots/models.webp)

Download, load, and inspect local models from the macOS app without turning the
chat into a cloud workflow.

## Document Attachments

Attach Word, PDF, PowerPoint, Excel (including legacy XLS), OpenDocument, RTF,
or EPUB files to ask about their complete extracted text. Conversion runs locally.
CSV and other supported text files are read as UTF-8.

You can attach up to eight files. Documents and text attachments can contain
**32,000 extracted characters in total per message**; document source files can
be up to **64 MiB each**. Accepted attachment text is supplied in full. These
attachment limits do not cap conversation history or reduce the selected response
length. Scanned PDFs require text recognition first; Sumika does not perform OCR.

## Interaction Modes

Choose how much Sumika can do in each conversation:

- **Chat**: talk, write, translate, summarize, and research the public web. Chat
  can use files you attach, but cannot browse your workspace, run commands, or
  change files.
- **Agent**: let Sumika work with a selected folder, connected tools, commands,
  and browser previews. Manual approval is the default. Enable or disable
  Auto-approve in the composer's **Options** for the current session, or set the
  default for new sessions in Settings.

You select the mode yourself. Sumika never grants itself access because of how
a prompt is worded.

## Project Instructions And Skills

Agent mode uses project guidance from the selected workspace:

- **Workspace instructions**: when an `AGENTS.md` file exists at the workspace
  root, Sumika reads it before each Agent turn and includes its instructions in
  the model context.
- **Skills**: Sumika uses the first valid `<name>/SKILL.md` it finds in
  `<workspace>/.agents/skills`, `<workspace>/.claude/skills`,
  `<workspace>/.cursor/skills`, `~/.agents/skills`, `~/.claude/skills`, then
  `~/.cursor/skills`, in that order. Later copies with the same name are ignored;
  an invalid earlier copy reports a diagnostic but does not block a valid
  fallback. Type `$myskill` in the composer to activate a skill for the message
  you are sending; typing `$` also opens the available skill suggestions.

## No Cloud Account Required

Sumika is designed as a private alternative to subscription-based cloud
assistants.

- No recurring AI subscription or hosted workspace account is required.
- No built-in telemetry or hosted model service receives your prompts,
  transcripts, commands, or workspace contents.
- Model execution, chat history, speech output, and dictation stay on your Mac.
- Network access is explicit. Model downloads and update checks connect to their
  configured sources; enabled web and MCP tools can send queries, URLs, and tool
  arguments to the service you selected.

## Web Access

Web access is off by default in both Chat and Agent. For public web research,
enable it in **Settings > Web Access** and choose **Ask each time** or **Allow**.

Search uses DuckDuckGo by default, or you can connect your own SearXNG instance.
Page fetching uses the built-in extractor by default and can optionally use a
self-hosted Firecrawl instance without storing an API key.

## Voice And Dictation

Sumika includes two local voice surfaces:

- **Assistant speech** adds play controls to completed text responses. It uses
  Apple system voices installed on the Mac, supports language and voice
  selection, and lets you tune speech rate.
- **Speech-to-text and composer dictation** record and transcribe prompts on the
  Mac. Choose the small, fast English model for English prompts or the larger
  multilingual Parakeet model to capture prompts in German and other supported
  European languages.

## MCP Servers

The Model Context Protocol (MCP) lets AI assistants use tools provided by other
apps and services. Configure MCP servers globally in Settings using stdio or
Streamable HTTP, then choose the servers available to each Agent session from
the composer. MCP tools stay out of Chat mode and enter the approval flow before
every call. Manual mode shows an approval prompt; Auto-approve can execute
allowed calls without prompting.

For Python MCP servers, configure `uvx` or `uv` as the command. Sumika includes
uv and automatically downloads Python and server dependencies when first needed;
you do not need to install Python, uv, or Homebrew. Selecting a server or using
**Test Connection** starts setup, which may need an internet connection. Downloads
are reused on later starts. Tests can be cancelled in Settings.

Runtime files live under `~/Library/Application Support/Sumika/MCP/`, with the uv
cache under `~/Library/Caches/Sumika/MCP/uv/`. Explicit executable paths use your
chosen installation; other commands, including `python`, `python3`, and `npx`,
keep their normal behavior. Server environment settings remain explicit overrides;
for example, `UV_OFFLINE=1` prevents downloads and requires cached dependencies.

## The Name

`sumika` means "dwelling" or "place to live" in Japanese. `sumika.chat` is meant
as a local home for AI agents: close to your files, explicit about what context
they see, and reviewable before they act.

## Project Status

Sumika is an evolving prototype. It is useful for local conversations, everyday
AI assistance, and agent workflows, but APIs, persisted data, and workflows are
still changing.

## Architecture

The project uses one Swift package with three production modules and a thin
native Xcode app target:

- `SumikaCore` owns provider-neutral domain models, agent/workflow logic,
  persistence, tools, and runtime interfaces.
- `SumikaRuntimeMLX` implements the local MLX/Hugging Face runtime behind the
  core interfaces.
- `SumikaApp` owns SwiftUI/AppKit, launch composition, and macOS integrations
  such as Sparkle.
- `sumika/` contains only the native app launcher, resources, entitlements, and
  bundle metadata.

Dependencies point one-way: `SumikaApp` -> `SumikaRuntimeMLX` ->
`SumikaCore`; `SumikaApp` may also use `SumikaCore` directly. All external
product dependencies are declared in the root `Package.swift`; the isolated
SwiftLint tool package lives under `script/swiftlint`. The Xcode app target
links only the local `SumikaApp` product.

- [Tool Runtime](docs/tool-runtime.md): core flow for adding type-safe tools,
  permissions, registries, and model-facing tool calls.
- [Chat Runtime](docs/chat-runtime.md): chat turn lifecycle, cancellation,
  transcript state, and model-context filtering.
- [Contributing](CONTRIBUTING.md): contribution and pull request expectations.
- [Development](docs/development.md): requirements, architecture, and dependencies.
- [Testing](docs/testing.md): verification, sanitizer limitations, and benchmarks.
- [Security](SECURITY.md): supported versions and private vulnerability
  reporting.
- [Changelog](CHANGELOG.md): release history and notable changes.
- [Release Process](docs/release.md): signing, packaging, notarization, and
  update-feed publication.

## Development

Development requires the Apple toolchain recorded in
[versions.env](.github/actions/setup-apple-toolchain/versions.env), a macOS version
supported by that Xcode release, and Homebrew. The same file defines the macOS CI
runner label. Install `just` and `typos`, then use the project recipe for the
remaining tools:

```sh
brew version-install just@1.58.0
brew version-install typos-cli@1.50.0
just deps
```

See [Development](docs/development.md) for the complete setup and build workflow,
and [Testing](docs/testing.md) for verification requirements.

Build the app locally:

```sh
just build
open "build/DerivedData/Build/Products/Debug/Sumika.app"
```

The first Xcode build may ask you to enable the pinned `MLXHuggingFaceMacros`
package macro. Review and approve it in Xcode. Hosted CI cannot approve package
plugins or macros interactively and uses the explicit validation-skip flags in
the project task runner.

Build an unsigned release app:

```sh
just release-unsigned
open "build/DerivedData/Build/Products/Release/Sumika.app"
```

Build and export a Developer ID-signed release archive:

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: …" just release-signed
```

The signed release command verifies the exported app, including the embedded
Sparkle framework, updater, XPC helpers, update feed configuration, nested
signatures, signing team, hardened runtime, and release entitlements.

You can also build from Xcode by opening `Sumika.xcodeproj` and running the
`Sumika` scheme for macOS.

Common development tasks:

```sh
just test
just lint
just format
just final-check
```

`just build` and `just release-unsigned` run the `Sumika` Xcode scheme with a
stable DerivedData path under `build/DerivedData`. `just test` runs every unit
and integration test target through SwiftPM; Xcode remains responsible for the
app launcher/resources and UI tests. `just lint` runs SwiftLint using
`.swiftlint.yml` and the exact SwiftPM-pinned version from
`script/swiftlint/Package.swift`. `just format` checks Swift sources with the
`swift-format` provided by the selected Xcode toolchain.
`just final-check` runs the broader local verification suite before review.

`just resolve-packages` resolves both the root SwiftPM graph and the Xcode app
graph, then synchronizes the Xcode pin states with the root resolution. Commit
both `Package.resolved` files after dependency changes. The root lockfile is the
canonical pin selection; the Xcode lockfile retains its workspace-specific
metadata.
`just check-package-locks` disables automatic dependency updates and verifies
that both committed lockfiles still satisfy their graph and resolve identical
package pins. The files represent different resolver roots and are not expected
to be byte-identical; metadata such as `originHash` and normalized repository
URLs may differ.
SwiftLint is intentionally outside the product graphs. Its independent
`script/swiftlint/Package.resolved` lockfile is validated whenever
`just prepare-swiftlint`, `just lint`, or `just lint-analyze` runs.
If a Dependabot PR changes the root graph and this check reports a stale Xcode
lockfile, run `just resolve-packages` and commit the regenerated Xcode
`Package.resolved` file to the PR.

## License

Licensed under the [Apache License 2.0](LICENSE).
