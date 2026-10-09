# Contributing to Sumika

Keep contributions focused, reviewable, and compatible with Sumika's local-first
nature.

Use the [issue tracker](https://github.com/ngutech21/sumika-chat/issues) for bugs
and feature requests. Discuss larger features, persisted-data changes, and
architectural changes in an issue before implementation. Report suspected
vulnerabilities privately through [SECURITY.md](SECURITY.md).

## Before submitting a pull request

- Keep the PR limited to one coherent change.
- Describe the problem, solution, and checks actually run, including failures
  or skipped checks. Include screenshots or recordings for visible UI changes.
- Use Conventional Commits; add `Fixes #<id>` in a separate paragraph when closing
  an issue.
- Complete `just final-check` for code changes, or `just typos` for documentation
  and comments only. See [Testing](docs/testing.md) for required checks by change.
- Review the complete diff and sanitize public logs and traces. Exclude
  credentials, private conversations, workspace content, and build output.

## Further reading

- [Development](docs/development.md): setup, architecture, dependencies, and PR guidance.
- [Testing](docs/testing.md): verification, sanitizer limitations, and benchmarks.
- [Release process](docs/release.md): maintainer release workflow.

Contributions are made under the terms in [LICENSE](LICENSE).
