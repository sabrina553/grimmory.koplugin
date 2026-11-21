# Fork tooling

This folder lives only on the `dev-tooling` branch of this fork, and therefore on
`dev`. It is never part of a PR branch.

## Branches

| Branch | Purpose |
| --- | --- |
| `main` | Mirror of `grimmory-tools/grimmory.koplugin` `main`. Never commit here. |
| `fix/…`, `feat/…` | One change each, branched from `main`, PR'd upstream. |
| `dev-tooling` | These scripts. Never PR'd. |
| `dev` | `main` + `dev-tooling` + every branch in `dev-branches.txt`. Rebuilt, never committed to directly. Install this one. |

## Workflow

1. `git switch -c fix/thing main`, commit, push, open the PR upstream.
2. Add `fix/thing` to `dev-branches.txt` on `dev-tooling`.
3. `scripts/rebuild-dev.sh --push` syncs `main` with upstream and rebuilds `dev`.
4. `scripts/push-to-reader.sh` installs `dev` on the reader.
5. Once upstream merges the PR, delete it from `dev-branches.txt`.

To install, either use `push-to-reader.sh` or download `dev` as a zip from
GitHub and copy its `grimmory.koplugin` folder into KOReader's `plugins`.
