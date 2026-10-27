# Releasing

Releases are built, signed, notarized, and published by the [release workflow](.github/workflows/release.yml) when a version tag is pushed.

1. Give the newest entry in `Applications/OakMate/about/Changes.md` its release date, e.g. `## 2026-11-01 (v2.1.0)`. The version of the application is taken from this entry, and its text becomes the release notes.
2. Commit, then tag and push: `git tag v2.1.0 && git push origin main v2.1.0`.

The workflow publishes `OakMate-«version».zip` (used by the updater), a disk image, and their SHA-256 checksums. An update is only installed if it is signed by the same team as the running copy of OakMate.

## Repository Secrets

The workflow runs in the `release` environment and needs these secrets (_Settings_ → _Secrets and variables_ → _Actions_):

| Secret | Value |
|--------|-------|
| `DEVELOPER_ID_CERTIFICATE_P12` | The “Developer ID Application” certificate with its private key, exported from Keychain Access as `.p12` and base64 encoded (`base64 -i cert.p12 \| pbcopy`) |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password chosen when exporting the `.p12` |
| `NOTARIZATION_APPLE_ID` | Apple ID of the developer account |
| `NOTARIZATION_PASSWORD` | An app-specific password for that Apple ID, created at [appleid.apple.com](https://appleid.apple.com) |
| `NOTARIZATION_TEAM_ID` | Team ID, shown at [developer.apple.com/account](https://developer.apple.com/account) |
