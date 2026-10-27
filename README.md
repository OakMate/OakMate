# OakMate

[![Build](https://github.com/OakMate/OakMate/actions/workflows/build.yml/badge.svg)](https://github.com/OakMate/OakMate/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/OakMate/OakMate)][Releases]
[![License: GPL v3](https://img.shields.io/badge/license-GPLv3-blue)](LICENSE)

OakMate is a fast, native text editor for macOS. It continues [TextMate 2][TextMate] and works with TextMate bundles, themes, and `.tm_properties` files, so existing TextMate setups carry over. The name is a tribute to the Oak frameworks TextMate is built from.

OakMate is not affiliated with or endorsed by MacroMates.

## Features

* Bundles for dozens of languages and tools, with commands written in any scripting language
* Multiple carets, column selections, snippets, and macros
* Fuzzy file finder, symbol list, and project-wide find and replace with regular expressions
* File browser with Git, Mercurial, and Subversion status
* Per-folder and per-file-type settings with `.tm_properties`
* The `mate` command-line tool, and `rmate` for editing files on remote servers
* Quick Look previews and thumbnails with syntax highlighting

## Differences from TextMate

* Requires macOS 14 or later on Apple silicon.
* The default bundles ship with the application. Nothing is downloaded from a bundle server.
* Bundle commands run with a modern Ruby (2.6 through 4.0).
* Updates are published as GitHub releases.
* No registration, license keys, or crash reporting.

The full list is in the [release notes](Applications/OakMate/about/Changes.md).

## Install

Download the disk image from the [latest release][Releases], open it, and drag OakMate to Applications.

OakMate checks for new releases once a day and offers to install them. To check manually, choose _OakMate_ → _Check for Updates…_. To turn off the daily check, run:

```sh
defaults write com.isztld.oakmate disableSoftwareUpdate -bool YES
```

## Bundles

The default bundles are included with OakMate. To add another bundle, double-click a `.tmbundle` file or place it in `~/Library/Application Support/OakMate/Bundles`.

TextMate bundles work unchanged: the `TM_*` environment variables, the `txmt://` URL scheme, `mate`, and `rmate` behave as they do in TextMate. Commands written in Ruby run with the system Ruby, with Ruby from Homebrew if the system Ruby is not installed, or with the Ruby set in `TM_RUBY` (_Preferences_ → _Variables_).

## Documentation

Most TextMate documentation also applies to OakMate:

* [TextMate manual](https://macromates.com/textmate/manual/)
* [Frequently asked questions](https://github.com/textmate/textmate/wiki/FAQ)
* [Hidden settings](https://github.com/textmate/textmate/wiki/Hidden-Settings) (write them to `com.isztld.oakmate` instead of `com.macromates.TextMate`)

## Building from Source

You need a Mac with Apple silicon running macOS 14 or later, [Xcode][], and [ninja][] (`brew install ninja`). Every other dependency is part of this repository.

```sh
git clone https://github.com/OakMate/OakMate.git
cd OakMate
./configure && ninja OakMate/run
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for build targets, running the tests, and how to submit changes.

## Reporting Issues

Report bugs and request features in [GitHub Issues][Issues]. Include your macOS version, the OakMate version (_OakMate_ → _About OakMate_), and the steps that reproduce the problem.

## License

OakMate is a modified version of TextMate, copyright MacroMates Ltd. and contributors. Like TextMate, it is free software released under the [GNU General Public License](LICENSE), version 3 or (at your option) any later version.

TextMate is a trademark of Allan Odgaard. OakMate does not use the TextMate name or artwork other than to describe where it comes from.

[TextMate]: https://github.com/textmate/textmate
[Releases]: https://github.com/OakMate/OakMate/releases/latest
[Issues]:   https://github.com/OakMate/OakMate/issues
[Xcode]:    https://developer.apple.com/xcode/
[ninja]:    https://ninja-build.org/
