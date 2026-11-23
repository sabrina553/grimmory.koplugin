#!/usr/bin/env bash
# Install a branch's plugin (default: dev) onto the PocketBook over SSH.
# Backs up the reader's current copy first.
#
# Usage: scripts/push-to-reader.sh [ref] [ssh-host]
#   ref       branch or commit to install (default: dev)
#   ssh-host  SSH alias for the reader (default: pocketbook)
set -euo pipefail

ref="${1:-dev}"
host="${2:-pocketbook}"
remote_dir=/mnt/ext1/applications/koreader/plugins
backup="$HOME/.local/share/grimmory-reader-backups/$(date +%F-%H%M%S)"

cd "$(git rev-parse --show-toplevel)"

# Run the same checks as CI when the tools are installed.
command -v busted >/dev/null && busted
command -v luacheck >/dev/null && luacheck . --no-self

# The reader drops Wi-Fi when it sleeps; fail clearly rather than mid-backup.
if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" true; then
    echo "Reader not reachable: wake it, keep it on a page, and retry." >&2
    exit 1
fi

if ssh -o BatchMode=yes "$host" "test -d $remote_dir/grimmory.koplugin"; then
    mkdir -p "$backup"
    ssh -o BatchMode=yes "$host" "cd $remote_dir && tar -cf - grimmory.koplugin" | tar -xf - -C "$backup"
    echo "Backed up reader copy to $backup"
fi

# The release workflow stamps the version into _meta.lua; mark dev builds so
# the reader shows what is installed. Keep it semver-shaped for the OTA check,
# which will then offer the upstream release: ignore it on a dev build.
version="0.0.0-dev.$(git rev-parse --short "$ref")"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
git archive "$ref" grimmory.koplugin | tar -xf - -C "$stage"
sed -i "s/version = \"[^\"]*\"/version = \"$version\"/" "$stage/grimmory.koplugin/_meta.lua"

tar -cf - -C "$stage" grimmory.koplugin | ssh -o BatchMode=yes "$host" "cd $remote_dir && tar -xf -"
echo "Installed $ref ($version). Restart KOReader to load it."
