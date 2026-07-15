# Release Process

Sumika releases are created from `master` through Release Please and the
existing macOS packaging tasks.

## Prerequisites

- Use conventional commits on `master`, for example `feat: ...` or `fix: ...`.
- Local release builds require `create-dmg`.
- GitHub release secrets must be configured and can be checked with the
  `macOS Release Secrets Check` workflow.
- The release workflow uses `GITHUB_TOKEN` for the first beta process.

## Create a Release

1. Merge normal feature and fix commits into `master`.
2. The `Release` workflow runs Release Please.
3. Review and merge the Release Please PR. It updates:
   - `CHANGELOG.md`
   - `version.txt`
   - `.release-please-manifest.json`
4. After the Release Please PR is merged, the `Release` workflow creates the tag
   and GitHub Release, for example `v1.0.0-beta.1`.
5. If a release was created, the workflow builds the notarized macOS DMG with:

   ```sh
   just release-notarized "Sumika-${TAG_NAME}-macos.dmg"
   ```

6. The workflow uploads the DMG to the GitHub Release.

The release task creates an Xcode archive and exports a Developer ID-signed app
with `xcodebuild -exportArchive`. The exported app is then packaged in the DMG;
the app bundle is not modified after export.

## Versioning

Release Please owns the public release version in `version.txt`.

During the release build, the workflow derives Xcode build settings:

```sh
RELEASE_VERSION="1.0.0-beta.1"
MARKETING_VERSION="1.0.0"
CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)"
SUMIKA_RELEASE_VERSION="$RELEASE_VERSION"
```

The app bundle uses:

- `CFBundleShortVersionString`: `MARKETING_VERSION`
- `CFBundleVersion`: `CURRENT_PROJECT_VERSION`
- `SumikaReleaseVersion`: full release version shown in About
- `SumikaGitCommit`: release commit SHA

## Notes

- Nightly builds stay separate from releases.
- Xcode Archive/Export performs Developer ID signing. Notarization, stapling,
  and DMG creation remain in the `just` release tasks.
- Sparkle is not part of this process yet; this release versioning is prepared
  for adding Sparkle later.
