#!/usr/bin/env bash
# Sync `main` with upstream and rebuild `dev` = main + dev-tooling + every
# branch in scripts/dev-branches.txt. `dev` is disposable: it is recreated
# from scratch each run, so fixes drop out once upstream merges them.
#
# Usage: scripts/rebuild-dev.sh [--push]
#   --push  also push `main` and force-push `dev` to origin.
#
# Runs in a throwaway worktree, so your current checkout is never touched.
# Repeated conflicts are resolved automatically once you have resolved them
# once by hand (git rerere).
set -euo pipefail

push=false
[[ "${1:-}" == "--push" ]] && push=true

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

git config rerere.enabled true
git config rerere.autoupdate true

echo "Fetching upstream and origin..."
git fetch -q upstream
git fetch -q origin

# main mirrors upstream; never commit to it.
git branch -f main upstream/main 2>/dev/null || {
    # main is checked out somewhere: fast-forward it in place instead.
    git -C "$(git worktree list --porcelain | awk '/^worktree /{w=$2} /^branch refs\/heads\/main$/{print w}')" \
        merge --ff-only -q upstream/main
}

branches=(dev-tooling)
while IFS= read -r line; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -n "$line" ]] && branches+=("$line")
done < <(git show dev-tooling:scripts/dev-branches.txt)

tmp="$(mktemp -d)"
cleanup() { git worktree remove --force "$tmp" 2>/dev/null || true; }
trap cleanup EXIT

git worktree add -q --detach "$tmp" main
cd "$tmp"

for b in "${branches[@]}"; do
    echo "Merging $b"
    if ! git merge -q --no-ff --no-edit "$b" -m "Merge $b into dev"; then
        # rerere may have resolved everything already.
        if [[ -z "$(git diff --name-only --diff-filter=U)" ]]; then
            git commit -q --no-edit
        else
            echo "Conflict merging $b. Resolve it in a normal checkout of dev," >&2
            echo "then rerun; rerere will remember the fix." >&2
            git diff --name-only --diff-filter=U >&2
            exit 1
        fi
    fi
done

git branch -f dev HEAD 2>/dev/null || {
    echo "dev is checked out in another worktree; switch it away and rerun." >&2
    exit 1
}
echo "dev rebuilt: $(git log --oneline -1 dev)"

if $push; then
    cd "$repo"
    git push -q origin main
    git push -q --force-with-lease origin dev
    echo "Pushed main and dev to origin."
fi
