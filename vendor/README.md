# Third-party and formerly external code

These directories used to be git submodules and are now part of this repository. They were imported at the commits listed below; changes are made here directly.

| Path | Origin | Imported commit |
|------|--------|-----------------|
| `Applications/SyntaxMate/resources/SyntaxMate.tmBundle` | https://github.com/shpakovski/syntaxmate.tmbundle.git | `a609c5cb7184` |
| `Applications/TextMate/icons` | https://github.com/textmate/document-icons.git | `80ee65a59c90` |
| `PlugIns/dialog` | https://github.com/textmate/dialog.git | `fa2f59e3a8df` |
| `vendor/Onigmo/vendor` | https://github.com/textmate/Onigmo.git | `05da5931eb10` |
| `vendor/kvdb/vendor` | https://github.com/textmate/kvdb.git | `13e30cf55baa` |
| `vendor/md4c/vendor` | https://github.com/mity/md4c | release 0.5.2 |

`PlugIns/dialog-1.x` (https://github.com/textmate/dialog-1.x.git) was removed. Its command line options are handled by `PlugIns/dialog/Commands/nib/dialog1.mm`.
