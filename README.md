# local-coder

## Architecture

- [Tool Runtime](docs/tool-runtime.md): core flow for adding type-safe tools,
  permissions, registries, and model-facing tool calls.
- [Chat Runtime](docs/chat-runtime.md): chat turn lifecycle, cancellation,
  transcript state, and model-context filtering.

## Development

Install the local task runner, linter, and formatter:

```sh
brew install just swiftlint swift-format
```

Common tasks:

```sh
just build
just test
just lint
just format
```

`just build` and `just test` run the `local-coder` Xcode scheme with a stable DerivedData path under `build/DerivedData`. `just lint` runs SwiftLint using `.swiftlint.yml`. `just format` formats Swift sources with `swift-format`.

## License

Licensed under the [Apache License 2.0](LICENSE).
