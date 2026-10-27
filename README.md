# OakMate

OakMate is a fast, native text editor for macOS. It is a continuation of [TextMate 2][TextMate] and keeps working with TextMate bundles, themes, and `.tm_properties` files. The name pays tribute to the Oak frameworks that TextMate is built from.

OakMate is not affiliated with or endorsed by MacroMates.

## Download

Download the newest version from [GitHub Releases][Releases]. OakMate checks for new releases once a day and offers to install them. To check manually, use _OakMate_ → _Check for Updates…_. To turn off the daily check:

```sh
defaults write com.isztld.oakmate disableSoftwareUpdate -bool YES
```

## Bundles

OakMate uses TextMate bundles. The `TM_*` environment variables, the `txmt://` URL scheme, `mate`, and `rmate` work as they do in TextMate.

The default bundles are part of this repository (`Applications/OakMate/support/Bundles`, see `vendor/README.md` for their origins) and ship inside the application. OakMate does not download or update bundles. To add another bundle, double-click a `.tmbundle` or place it in `~/Library/Application Support/OakMate/Bundles`.

# Building

## Setup

OakMate builds on Apple silicon Macs running macOS 14 or later. You need:

 * [Xcode][]            — the compiler and macOS SDK
 * [ninja][]            — build system similar to `make`

Every other dependency is part of this repository. Ninja can be installed with [Homebrew][] or [MacPorts][]:

```sh
brew install ninja         # Homebrew
sudo port install ninja    # MacPorts
```

Then clone the repository and run `./configure` followed by `ninja`, for example:

```sh
git clone https://github.com/OakMate/OakMate.git
cd OakMate
./configure && ninja OakMate/run
```

The `./configure` script checks that the tools can be found and then calls `bin/rave` to bootstrap a `build.ninja` file with default config set to `release` and default target set to `OakMate`.

Machine-specific settings (extra compiler flags, code signing identity, etc.) can be placed in an optional `local.rave` file, which is not under version control.

## Building from within OakMate

You should install the [Ninja][NinjaBundle] bundle, e.g. by cloning it into `~/Library/Application Support/OakMate/Bundles`.

After this you can press ⌘B to build from within OakMate. In case you haven't already you also need to set up the `PATH` variable either in _Preferences_ → _Variables_ or `~/.tm_properties` so it can find `ninja` and related tools; an example could be `$PATH:/usr/local/bin`.

The default target (set in `.tm_properties`) is `OakMate/run`. This will relaunch OakMate but when called from within OakMate, a dialog will appear before the current instance is killed. As there is full session restore, it is safe to relaunch even with unsaved changes.

If the current file is a test file then the target to build is changed to build the library to which the test belongs (this is done by setting `TM_NINJA_TARGET` in the `.tm_properties` file found in the root of the source tree).

Similarly, if the current file belongs to an application target (other than `OakMate.app`) then `TM_NINJA_TARGET` is set to build and run this application.

## Build Targets

For the `OakMate.app` application there are two symbolic build targets:

```sh
ninja OakMate       # Build and sign OakMate
ninja OakMate/run   # Build, sign, and (re)launch OakMate
```

To build and run all unit tests:

```sh
ninja test          # All tests
ninja buffer/test   # Tests of a single framework
```

To clean everything run:

```sh
ninja -t clean
```

Or simply delete the build directory, `~/build/«name of the source folder»` by default.

## Code Signing

Builds are ad-hoc signed by default. To sign with your own certificate, set the identity in `local.rave` (not under version control):

```
set CS_IDENTITY "Developer ID Application: «Name» («Team ID»)"
```

When an identity is set, executables shipped inside bundles are signed as well (`bin/sign_nested`), which notarization requires.

## Releasing

Releases are built, signed, notarized, and published by the [release workflow](.github/workflows/release.yml) when a version tag is pushed:

1. Give the newest entry in `Applications/OakMate/about/Changes.md` its release date, e.g. `## 2026-11-01 (v2.1.0)`. The version of the application is taken from this entry, and its text becomes the release notes.
2. Commit, then tag and push: `git tag v2.1.0 && git push origin v2.1.0`.

The workflow publishes `OakMate-«version».zip` (used by the updater), a disk image, and their SHA-256 checksums. An update is only installed if it is signed by the same team as the running copy of OakMate.

The workflow needs these repository secrets:

| Secret | Value |
|--------|-------|
| `DEVELOPER_ID_CERTIFICATE_P12` | The “Developer ID Application” certificate with its private key, exported from Keychain Access as `.p12` and base64 encoded (`base64 -i cert.p12 \| pbcopy`) |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password chosen when exporting the `.p12` |
| `NOTARIZATION_APPLE_ID` | Apple ID of the developer account |
| `NOTARIZATION_PASSWORD` | An app-specific password for that Apple ID, created at [appleid.apple.com](https://appleid.apple.com) |
| `NOTARIZATION_TEAM_ID` | Team ID, shown at [developer.apple.com/account](https://developer.apple.com/account) |

# Legal

OakMate is a modified version of TextMate, copyright MacroMates Ltd. and contributors. Like TextMate, the source is released under the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. See [LICENSE](LICENSE).

TextMate is a trademark of Allan Odgaard. OakMate does not use the TextMate name or artwork other than to describe where it comes from.

## App Icon

The icon is an [Icon Composer][] file, `Applications/OakMate/icon/OakMate.icon`, compiled by `actool` during the build. Its layers are generated by `Applications/OakMate/icon/leaf.py`.

[Xcode]:         https://developer.apple.com/xcode/
[ninja]:         https://ninja-build.org/
[MacPorts]:      http://www.macports.org/
[Homebrew]:      http://brew.sh/
[NinjaBundle]:   https://github.com/textmate/ninja.tmbundle
[TextMate]:      https://github.com/textmate/textmate
[Releases]:      https://github.com/OakMate/OakMate/releases
[Icon Composer]: https://developer.apple.com/icon-composer/
