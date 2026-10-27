# TextMate

## Download

You can [download TextMate from here](https://macromates.com/download).

## Feedback

You can use [the TextMate mailing list](https://lists.macromates.com/listinfo/textmate) or [#textmate][] IRC channel on [freenode.net][] for questions, comments, and bug reports.

You can also [contact MacroMates](https://macromates.com/support).

Before you submit a bug report please read the [writing bug reports](https://github.com/textmate/textmate/wiki/writing-bug-reports) instructions.

## Screenshot

![textmate](https://raw.github.com/textmate/textmate/gh-pages/images/screenshot.png)

# Building

## Setup

TextMate builds on Apple silicon Macs running macOS 14 or later. You need:

 * [Xcode][]            — the compiler and macOS SDK
 * [ninja][]            — build system similar to `make`

Every other dependency is part of this repository. Ninja can be installed with [Homebrew][] or [MacPorts][]:

```sh
brew install ninja         # Homebrew
sudo port install ninja    # MacPorts
```

Then clone the repository and run `./configure` followed by `ninja`, for example:

```sh
git clone https://github.com/textmate/textmate.git
cd textmate
./configure && ninja TextMate/run
```

The `./configure` script checks that the tools can be found and then calls `bin/rave` to bootstrap a `build.ninja` file with default config set to `release` and default target set to `TextMate`.

Machine-specific settings (extra compiler flags, code signing identity, etc.) can be placed in an optional `local.rave` file, which is not under version control.

## Building from within TextMate

You should install the [Ninja][NinjaBundle] bundle which can be installed via _Preferences_ → _Bundles_.

After this you can press ⌘B to build from within TextMate. In case you haven't already you also need to set up the `PATH` variable either in _Preferences_ → _Variables_ or `~/.tm_properties` so it can find `ninja` and related tools; an example could be `$PATH:/usr/local/bin`.

The default target (set in `.tm_properties`) is `TextMate/run`. This will relaunch TextMate but when called from within TextMate, a dialog will appear before the current instance is killed. As there is full session restore, it is safe to relaunch even with unsaved changes.

If the current file is a test file then the target to build is changed to build the library to which the test belongs (this is done by setting `TM_NINJA_TARGET` in the `.tm_properties` file found in the root of the source tree).

Similarly, if the current file belongs to an application target (other than `TextMate.app`) then `TM_NINJA_TARGET` is set to build and run this application.

## Build Targets

For the `TextMate.app` application there are two symbolic build targets:

```sh
ninja TextMate      # Build and sign TextMate
ninja TextMate/run  # Build, sign, and (re)launch TextMate
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

Or simply delete `~/build/TextMate`.

# Legal

The source for TextMate is released under the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

TextMate is a trademark of Allan Odgaard.

[Xcode]:         https://developer.apple.com/xcode/
[ninja]:         https://ninja-build.org/
[MacPorts]:      http://www.macports.org/
[Homebrew]:      http://brew.sh/
[NinjaBundle]:   https://github.com/textmate/ninja.tmbundle
[#textmate]:     irc://irc.freenode.net/#textmate
[freenode.net]:  http://freenode.net/
