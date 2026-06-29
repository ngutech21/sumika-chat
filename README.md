# Sumika

A local-first macOS app for private, inspectable AI coding workflows on your own
machine.

[![CI](https://github.com/ngutech21/sumika-chat/actions/workflows/ci.yml/badge.svg)](https://github.com/ngutech21/sumika-chat/actions/workflows/ci.yml)
[![MacOS Nightly](https://github.com/ngutech21/sumika-chat/actions/workflows/macos-nightly.yml/badge.svg)](https://github.com/ngutech21/sumika-chat/actions/workflows/macos-nightly.yml)
[![Actions Lint](https://github.com/ngutech21/sumika-chat/actions/workflows/actions-lint.yml/badge.svg)](https://github.com/ngutech21/sumika-chat/actions/workflows/actions-lint.yml)
[![Spelling](https://github.com/ngutech21/sumika-chat/actions/workflows/spelling.yml/badge.svg)](https://github.com/ngutech21/sumika-chat/actions/workflows/spelling.yml)

Sumika helps you explore, change, and run local projects without handing
your workspace to a cloud agent. You choose the context, review each action, and
keep the conversation on your Mac.

## Highlights

- 🏠 **Local by default**: run LLMs through MLX and keep model execution,
  workspace context, and speech workflows on your Mac.
- 🧭 **Explicit context**: attach files, focus workspace context, and inspect
  what the model sees before the workflow grows opaque.
- 🛠 **Agent with brakes**: let Sumika read files, write code, run commands, and
  inspect diffs through typed tools with review states.
- ✅ **Review before action**: writes, edits, shell commands, and web access pass
  through approval instead of running as hidden automation.
- 🌐 **Bring your own search**: connect a self-hosted SearXNG instance or use the
  built-in DuckDuckGo search provider.
- 🧰 **Terminal and browser built in**: run approved workspace commands and
  inspect local previews without leaving the app.
- 🖥 **Build and preview locally**: create small apps, prototypes, and HTML
  experiments, then inspect them beside the chat.
- 🗣 **Speak and dictate**: listen to assistant responses with Apple system voices
  and dictate prompts with local English or multilingual speech models.
- 🧾 **Inspectable transcript**: keep prompts, assistant responses, tool calls,
  approvals, and command output visible in the chat.

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

## What You Can Do

- Ask questions about a workspace and keep the model-facing context explicit.
- Build small apps, scripts, games, and UI prototypes in short, reviewable
  steps.
- Let the agent read, list, search, and summarize local workspace files.
- Review generated file writes, file edits, shell commands, and workspace diffs
  before they run.
- Search and fetch the public web through policy-gated tools, using either a
  self-hosted SearXNG instance or the built-in DuckDuckGo provider.
- Use the integrated terminal and browser preview while working through an agent
  task.
- Open local HTML previews and inspect browser state while iterating.
- Dictate prompts instead of typing them.
- Listen to assistant responses with installed Apple voices.
- Follow prompts, assistant responses, tool calls, approvals, and command output
  in one visible transcript.

## Interaction Modes

Sumika keeps tool access explicit. The composer has a manual mode per chat
session:

- **Chat**: normal conversation with public web tools only. No workspace tools,
  shell commands, local file access, or writes.
- **Agent**: coding workflow with workspace tools, write/edit tools, shell
  execution, browser preview tools, and approval flow.

Mode is product state, not prompt magic. Sumika does not infer local tool access
from wording alone.

## No Cloud Account Required

Sumika is built for local-first work, not a hosted assistant subscription.

- No subscription or hosted workspace account is required to use the app.
- No telemetry, prompts, transcripts, commands, or workspace contents are
  exported by the app.
- Model execution, chat history, speech output, and dictation stay on your Mac.
- Network access is explicit: web search and fetch tools only run when available
  in the selected mode and approved by policy.
- You can use the built-in DuckDuckGo search provider or point Sumika at your
  own SearXNG instance.

## Voice And Dictation

Sumika includes two local voice surfaces:

- **Assistant speech** adds play controls to completed text responses. It uses
  Apple system voices installed on the Mac, supports language and voice
  selection, and lets you tune speech rate.
- **Composer dictation** records prompts locally. The default model is a small,
  fast English model; a larger multilingual Parakeet model is available for
  German and other European languages.

## Why Local First

Many agent products assume cloud models, opaque context selection, and broad
implicit access to your data or tools. Sumika explores a different
direction:

- Local-first model execution on macOS
- User-controlled workspace context
- Reviewable agent steps instead of hidden automation
- Approval-gated tool and shell execution
- Visible transcripts and tool states for review
- Native macOS workflows instead of a browser-first interface

## The Name

`sumika` means "dwelling" or "place to live" in Japanese. `sumika.chat` is meant
as a local home for AI agents: close to your files, explicit about what context
they see, and reviewable before they act.

## Project Status

Sumika is an unreleased prototype. It is useful for experimentation and
local coding workflows, but APIs, persisted data, and workflows are still
changing.

## Architecture

The project is split into a headless SwiftPM core library and a macOS app
target. Reusable agent, runtime, persistence, and workflow logic lives in
`SumikaCore`; the app target owns SwiftUI/AppKit views, launch wiring, platform
services, and MLX-backed implementations.

- [Tool Runtime](docs/tool-runtime.md): core flow for adding type-safe tools,
  permissions, registries, and model-facing tool calls.
- [Chat Runtime](docs/chat-runtime.md): chat turn lifecycle, cancellation,
  transcript state, and model-context filtering.

## Development

Install the local task runner, linter, and formatter:

```sh
brew install just swiftlint swift-format
```

Build the app locally:

```sh
just build
open "build/DerivedData/Build/Products/Debug/Sumika.app"
```

Build an unsigned release app:

```sh
just release-unsigned
open "build/DerivedData/Build/Products/Release/Sumika.app"
```

You can also build from Xcode by opening `Sumika.xcodeproj` and running the
`Sumika` scheme for macOS.

Common development tasks:

```sh
just test
just lint
just format
just final-check
```

`just build`, `just release-unsigned`, and `just test` run the `Sumika` Xcode
scheme with a stable DerivedData path under `build/DerivedData`. `just lint`
runs SwiftLint using `.swiftlint.yml`. `just format` formats Swift sources with
`swift-format`. `just final-check` runs the broader local verification suite
before review.

## License

Licensed under the [Apache License 2.0](LICENSE).
