
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
- 🏠 **Everything you need in one app**: download a model from the built-in
  model browser and start chatting. No Ollama, LM Studio, or separate inference
  backend is required.
- 🌟 **No recurring subscription**: use local models without paying for a
  hosted AI assistant plan.
- 🧭 **Explicit context**: attach files, focus workspace context, and inspect
  what the model sees before the workflow grows opaque.
- 🛠 **Approval-aware agent workflows**: keep manual approval prompts or opt in
  to Auto-approve for new Agent sessions.
- 🧩 **Connect local apps**: extend Agent mode through Model Context
  Protocol (MCP) servers and choose the integrations available to each session.
- ✅ **Choose your approval level**: Manual is the default for Agent tools;
  Auto-approve and web access policies remain explicit user settings.
- 🌐 **Bring your own search**: connect a self-hosted SearXNG instance or use the
  built-in DuckDuckGo search provider.
- 📄 **Bring your own fetcher**: keep the built-in page extractor or point fetch
  at a self-hosted Firecrawl instance.
- 🧰 **Terminal and browser built in**: run approval-aware workspace commands and
  inspect local previews without leaving the app.
- 🖥 **Build and preview locally**: create small apps, prototypes, and HTML
  experiments, then inspect them beside the chat.
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

### Document attachments

Attach Word, PDF, PowerPoint, Excel (including legacy XLS), OpenDocument, RTF,
or EPUB files to ask about their complete extracted text. Conversion runs locally.
CSV and other supported text files are read as UTF-8.

You can attach up to eight files. Documents and text attachments can contain
**32,000 extracted characters in total per message**; document source files can
be up to **64 MiB each**. Accepted attachment text is supplied in full. These
attachment limits do not cap conversation history or reduce the selected response
length. Scanned PDFs require text recognition first; Sumika does not perform OCR.

## What You Can Do

- Write and refine text, brainstorm ideas, translate languages, and summarize
  longer content.
- Ask questions about your own files and choose what the model can see.
- Research topics on the public web through reviewable search and fetch tools.
- Connect local apps and services through configured MCP integrations when you
  want Sumika to take action beyond the chat.
- Let the agent read, organize, search, and update local project files with
  manual approval or an explicitly selected Auto-approve policy.
- Build small apps, scripts, games, and UI prototypes in short, reviewable
  steps.
- Keep manual approval prompts for generated file writes, file edits, and shell
  commands, or opt in to Auto-approve for a session.
- Use the integrated terminal and browser preview while working through an agent
  task.
- Open local HTML previews and inspect browser state while iterating.
- Transcribe speech locally and dictate prompts in English, German, and other
  supported European languages instead of typing them.
- Listen to assistant responses with installed Apple voices.
- Receive automatic update checks and install signed releases from the app.
- Follow prompts, assistant responses, tool calls, approvals, and command output
  in one visible transcript.

## Interaction Modes

Choose how much Sumika can do in each conversation:

- **Chat**: talk, write, translate, summarize, and research the public web. Chat
  mode cannot access local files, run commands, or make changes.
- **Agent**: let Sumika work with a selected folder, connected tools, commands,
  and browser previews. Manual approval is the default; Auto-approve is an
  explicit option for new sessions.

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
- You can use the built-in DuckDuckGo search provider or point Sumika at your
  own SearXNG instance. Fetch uses the built-in extractor by default and can
  optionally use a self-hosted Firecrawl instance without storing an API key.

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

## Why Local First

Most AI assistants send conversations to cloud models and charge a recurring
subscription. Sumika takes a different approach:

- Local-first model execution on macOS
- Everyday assistance without requiring technical knowledge
- No recurring AI subscription
- User-controlled workspace context
- Reviewable agent steps instead of hidden automation
- Configurable Manual or Auto-approve tool execution
- Visible transcripts and tool states for review
- Native macOS workflows instead of a browser-first interface

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
- [Contributing](CONTRIBUTING.md): development requirements, architecture,
  verification, and pull request guidance.
- [Security](SECURITY.md): supported versions and private vulnerability
  reporting.
- [Changelog](CHANGELOG.md): release history and notable changes.
- [Release Process](docs/release.md): signing, packaging, notarization, and
  update-feed publication.

## Development

Development requires macOS 15 or later, Xcode 26.6 (build 17F113) with Apple
Swift 6.3.3 and the macOS 26.5 SDK, and Homebrew. Install `just` and `typos`, then
use the project recipe for the remaining tools:

```sh
brew version-install just@1.58.0
brew version-install typos-cli@1.50.0
just deps
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the complete development and
verification workflow.

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
