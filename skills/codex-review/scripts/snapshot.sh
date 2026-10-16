#!/usr/bin/env bash
# Usage: snapshot.sh
# Prints a git tree id for the current working tree (tracked changes plus untracked, non-ignored
# files) without touching the real index, HEAD or stash. `git diff <old-tree> <new-tree>` then
# shows exactly what changed between two snapshots.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Start from a copy of the real index so unchanged files keep their cached stat info.
index=$(git rev-parse --git-path index)
if [ -f "$index" ]; then
  # -p keeps the mtime git uses to spot racily clean entries (files changed in the same
  # second the index was written); a fresh mtime would make them look unchanged.
  cp -p "$index" "$tmp/index"
fi
GIT_INDEX_FILE="$tmp/index" git add -A
GIT_INDEX_FILE="$tmp/index" git write-tree
