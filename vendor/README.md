# Third-party and formerly external code

These directories used to be git submodules and are now part of this repository. They were imported at the commits listed below; changes are made here directly.

| Path | Origin | Imported commit |
|------|--------|-----------------|
| `Applications/SyntaxMate/resources/SyntaxMate.tmBundle` | https://github.com/shpakovski/syntaxmate.tmbundle.git | `a609c5cb7184` |
| `PlugIns/dialog` | https://github.com/textmate/dialog.git | `fa2f59e3a8df` |
| `vendor/Onigmo/vendor` | https://github.com/textmate/Onigmo.git | `05da5931eb10` |
| `vendor/kvdb/vendor` | https://github.com/textmate/kvdb.git | `13e30cf55baa` |
| `vendor/md4c/vendor` | https://github.com/mity/md4c | release 0.5.2 |

`PlugIns/dialog-1.x` (https://github.com/textmate/dialog-1.x.git) was removed. Its command line options are handled by `PlugIns/dialog/Commands/nib/dialog1.mm`.

The document icons from https://github.com/textmate/document-icons.git were removed. macOS now generates document icons from the app icon.

## Bundles

The bundles in `Applications/OakMate/support/Bundles` were downloaded from the TextMate bundle server, which builds them from the repositories below. The version is the server’s build number for that bundle. The bundles have since been changed in this repository: they run with ruby 2.6 or later instead of ruby 1.8, the compiled ruby extensions for property lists and the keychain are replaced by ruby code, CocoaDialog is replaced by AppleScript, and binaries that only ran on Intel or PowerPC are removed. Unless a bundle says otherwise, its files are licensed as: “Permission to copy, use, modify, sell and distribute this software is granted. This software is provided “as is” without express or implied warranty, and with no claim as to its suitability for any purpose.”

| Bundle | Origin | Version (date) |
|--------|--------|----------------|
| `Apache.tmbundle` | https://github.com/textmate/apache.tmbundle | 709 (2016-01-03) |
| `AppleScript.tmbundle` | https://github.com/textmate/applescript.tmbundle | 1087 (2019-09-03) |
| `Bundle Development.tmbundle` | https://github.com/textmate/bundle-development.tmbundle | 982 (2017-07-12) |
| `Bundle Support.tmbundle` | https://github.com/textmate/bundle-support.tmbundle | 1116 (2021-03-09) |
| `C.tmbundle` | https://github.com/textmate/c.tmbundle | 1110 (2021-01-09) |
| `CSS.tmbundle` | https://github.com/textmate/css.tmbundle | 965 (2017-04-22) |
| `Diff.tmbundle` | https://github.com/textmate/diff.tmbundle | 942 (2017-01-09) |
| `Git.tmbundle` | https://github.com/textmate/git.tmbundle | 1069 (2018-12-13) |
| `HTML.tmbundle` | https://github.com/textmate/html.tmbundle | 1070 (2019-01-28) |
| `Hyperlink Helper.tmbundle` | https://github.com/textmate/hyperlink-helper.tmbundle | 1035 (2018-07-14) |
| `JavaScript.tmbundle` | https://github.com/textmate/javascript.tmbundle | 1125 (2022-05-20) |
| `JSON.tmbundle` | https://github.com/textmate/json.tmbundle | 777 (2016-08-08) |
| `Mail.tmbundle` | https://github.com/textmate/mail.tmbundle | 334 (2014-06-18) |
| `Make.tmbundle` | https://github.com/textmate/make.tmbundle | 1081 (2019-07-16) |
| `Markdown.tmbundle` | https://github.com/textmate/markdown.tmbundle | 1101 (2020-07-14) |
| `Math.tmbundle` | https://github.com/textmate/math.tmbundle | 1053 (2018-08-05) |
| `Mercurial.tmbundle` | https://github.com/textmate/mercurial.tmbundle | 1019 (2018-02-21) |
| `Objective-C.tmbundle` | https://github.com/textmate/objective-c.tmbundle | 1095 (2020-05-05) |
| `PHP.tmbundle` | https://github.com/textmate/php.tmbundle | 1055 (2018-03-27) |
| `Property List.tmbundle` | https://github.com/textmate/property-list.tmbundle | 1106 (2020-07-14) |
| `Python.tmbundle` | https://github.com/textmate/python.tmbundle | 1111 (2021-01-09) |
| `Ruby.tmbundle` | https://github.com/textmate/ruby.tmbundle | 1083 (2019-08-03) |
| `SCM Diff Gutter.tmbundle` | https://github.com/textmate/scm-diff-gutter.tmbundle | 1066 (2018-11-19) |
| `SCM.tmbundle` | https://github.com/textmate/scm.tmbundle | 446 (2014-08-15) |
| `Shell Script.tmbundle` | https://github.com/textmate/shellscript.tmbundle | 1123 (2021-05-14) |
| `Source.tmbundle` | https://github.com/textmate/source.tmbundle | 1078 (2019-07-01) |
| `SQL.tmbundle` | https://github.com/textmate/sql.tmbundle | 694 (2016-01-10) |
| `Subversion.tmbundle` | https://github.com/textmate/subversion.tmbundle | 896 (2016-08-31) |
| `Text.tmbundle` | https://github.com/textmate/text.tmbundle | 1084 (2019-08-07) |
| `Textile.tmbundle` | https://github.com/textmate/textile.tmbundle | 409 (2014-06-18) |
| `TextMate.tmbundle` | https://github.com/textmate/textmate.tmbundle | 916 (2016-09-25) |
| `Themes.tmbundle` | https://github.com/textmate/themes.tmbundle | 1067 (2018-11-22) |
| `TODO.tmbundle` | https://github.com/textmate/todo.tmbundle | 487 (2014-10-07) |
| `XML.tmbundle` | https://github.com/textmate/xml.tmbundle | 1039 (2018-07-04) |
