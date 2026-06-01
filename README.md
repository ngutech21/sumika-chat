# local-coder

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
