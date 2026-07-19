# Release Process

Sumika releases are created from `master` through Release Please and the
existing macOS packaging tasks. Successful releases also publish a Sparkle
appcast to `https://updates.sumika.chat/appcast.xml`.

## Prerequisites

- Use conventional commits on `master`, for example `feat: ...` or `fix: ...`.
- Local release builds require `create-dmg`.
- GitHub release secrets must be configured and can be checked with the
  `macOS Release Secrets Check` workflow.
- `SPARKLE_ED_PRIVATE_KEY` must contain the private Ed25519 key matching the
  `SUPublicEDKey` embedded in the app.
- GitHub Pages must use GitHub Actions as its source, with
  `updates.sumika.chat` configured as its custom domain and HTTPS enforced.
- The release workflow uses `GITHUB_TOKEN` to upload and inspect release assets.

## Create a Release

1. Merge normal feature and fix commits into `master`.
2. The `Release` workflow runs Release Please.
3. Review and merge the Release Please PR. It updates:
   - `CHANGELOG.md`
   - `version.txt`
   - `.release-please-manifest.json`
4. After the Release Please PR is merged, the `Release` workflow creates the tag
   and GitHub Release, for example `v1.3.0`.
5. If a release was created, the workflow builds the notarized macOS DMG with:

   ```sh
   just release-notarized "Sumika-${TAG_NAME}-macos.dmg"
   ```

6. The workflow uploads the DMG to the GitHub Release.
7. Sparkle's `generate_appcast` signs the update archive and creates a
   single-release appcast with embedded release notes. The workflow verifies
   its version, minimum macOS version, download URL, size, and Ed25519
   signature by invoking the same `just generate-sparkle-appcast` task that is
   available for local checks.
8. A dependent job publishes the verified `appcast.xml` to GitHub Pages.

The DMG is uploaded before the appcast is generated, and the appcast is
published last. If appcast generation or Pages deployment fails, the GitHub
Release remains available but installed apps are not offered the new update.

The release task creates an Xcode archive and exports a Developer ID-signed app
with `xcodebuild -exportArchive`. The exported app is then packaged in the DMG;
the app bundle is not modified after export.

`just release-signed` runs `script/verify_release_app.sh` against that exported
app. The check requires the embedded Sparkle framework, updater resources,
`Autoupdate`, updater app, downloader and installer XPC services, a runtime
link to Sparkle, valid nested signatures from the configured team, and nonempty
`SUFeedURL` and `SUPublicEDKey` values.

After changing Sparkle dependency or embedding wiring, also install the
notarized DMG on a clean macOS account, launch Sumika, and invoke
**Check for Updates…** once. That final interactive smoke test is deliberately
separate from the archive-structure verification.

## Versioning

Release Please owns the public release version in `version.txt`.

During the release build, the workflow derives Xcode build settings:

```sh
RELEASE_VERSION="1.3.0"
MARKETING_VERSION="1.3.0"
CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)"
SUMIKA_RELEASE_VERSION="$RELEASE_VERSION"
```

The app bundle uses:

- `CFBundleShortVersionString`: `MARKETING_VERSION`
- `CFBundleVersion`: `CURRENT_PROJECT_VERSION`
- `SumikaReleaseVersion`: full release version shown in About
- `SumikaGitCommit`: release commit SHA

The first stable release uses the temporary Release Please setting
`release-as: 1.3.0`. Remove that setting in the generated `1.3.0` Release
Please PR before merging it. Later versions are then derived from conventional
commits again.

Sparkle uses the numeric `CFBundleVersion` as `sparkle:version` for update
ordering and `CFBundleShortVersionString` as the displayed version.

## Sparkle Publishing

The release job reads the private Ed25519 key only from
`SPARKLE_ED_PRIVATE_KEY` and passes it to `generate_appcast` through standard
input. The key must not be written to the repository, build settings, app
bundle, or workflow logs.

`just generate-sparkle-appcast` is a thin wrapper around
`script/generate_sparkle_appcast.sh`. After `just release-package`, its local
defaults use the exported app, `build/artifacts/Sumika-macos-release.dmg`,
`CHANGELOG.md`, and a non-public example download URL. The expected build and
short versions are read from the exported app. Sparkle reads the local private
key from the login Keychain, so the local check is simply:

```sh
just generate-sparkle-appcast
```

The release workflow overrides `APP_PATH`, `ASSET_PATH`,
`DOWNLOAD_URL_PREFIX`, `EXPECTED_BUILD_VERSION`, `EXPECTED_SHORT_VERSION`, and
`RELEASE_NOTES_PATH`. It also requires `SPARKLE_ED_PRIVATE_KEY` and passes it to
Sparkle through standard input. Set `VERIFY_DOWNLOAD_URL=1` only after the
referenced asset has been uploaded. Without it, the same generation and
signature checks can run locally without publishing anything.

The appcast contains only the current full DMG. Release notes come from the
GitHub Release and are embedded in the XML. Delta updates, release history,
channels, and mandatory signed-feed validation are intentionally deferred.
The DMG enclosure always uses its immutable tag-specific GitHub Release URL.

`SUVerifyUpdateBeforeExtraction` is enabled in the app. `SURequireSignedFeed`
will be enabled separately after the appcast pipeline has completed a
successful production release.

## Notes

- Nightly builds stay separate from releases.
- Xcode Archive/Export performs Developer ID signing. Notarization, stapling,
  and DMG creation remain in the `just` release tasks.
- The public appcast URL is stable even if its hosting provider changes later.
