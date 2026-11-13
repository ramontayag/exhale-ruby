# CLI

The command line is the only way CI meets exhale, so a typo there must never pass for a clean run.

## Obligations

- **L1** `exhale` and `exhale dry` run the duplication check. `exhale dry explain A B` scores two units with the same file list and weights the gate uses.
- **L5** `exhale complexity` runs the ratchet with `--base`, `--floor`, `--format` and `--include-tests`. `exhale complexity explain UNIT` prints that unit's score with every point, its line and its reason, and exits 2 when no unit has that identity.
- **L2** An unknown option, an unknown format, or a positional argument that isn't an existing path exits 2.
- **L3** A `--base` that resolves to no commit exits 2, including a value that looks like a git option, and so does `explain` given an unknown format or base.
- **L4** Settings come from the Contract. Flags override them for a local run only.
- **L6** `exhale complexity --require-base` requires a comparison base and exits 2 when it can't resolve one: no git repository, no commit at HEAD, a base that names no commit, no default branch, a base with no common ancestor with HEAD, or a base whose merge base is HEAD. A base that resolves to HEAD falls back to HEAD's first parent when HEAD is a merge commit. The base is the merge base of the ref and HEAD, so a base that moved ahead still compares against the branch point. `exhale complexity explain UNIT --require-base` resolves the base the same way. Without the flag the run keeps its old behaviour: a missing base is a warning and the run exits 0. The dry check has no such option.

```covers
Exhale::CLI
```
