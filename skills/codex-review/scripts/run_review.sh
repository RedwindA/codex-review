#!/usr/bin/env bash
# Usage: run_review.sh <prompt-file> <output-file> [quick|standard|deep|verify] [<snapshot>]
# Runs a read-only codex review. The prompt is fed via stdin.
# The mode picks the reasoning effort: quick/standard/deep are first-round tiers chosen by
# classify.sh; `verify` checks only the fixes since the previous round.
# With a snapshot (a tree id from snapshot.sh, or a commit), codex runs in a temporary detached
# worktree checked out at that snapshot, so the real working tree can keep changing while it
# reviews; the worktree is removed on exit. Without one, codex runs in the repo root.
set -euo pipefail

prompt_file=$1
out_file=$2
mode=${3:-standard}
snapshot=${4:-}
model=${CODEX_REVIEW_MODEL:-gpt-6-astra}
case "$mode" in
  quick) effort=${CODEX_REVIEW_QUICK_EFFORT:-high} default_timeout=900 ;;
  standard) effort=${CODEX_REVIEW_EFFORT:-high} default_timeout=900 ;;
  deep) effort=${CODEX_REVIEW_DEEP_EFFORT:-xhigh} default_timeout=1800 ;;
  verify) effort=${CODEX_REVIEW_VERIFY_EFFORT:-high} default_timeout=900 ;;
  *) echo "unknown mode: $mode (expected quick, standard, deep or verify)" >&2; exit 2 ;;
esac
# Hard cap so the background task always exits and triggers a completion notification.
timeout_secs=${CODEX_REVIEW_TIMEOUT:-$default_timeout}

prompt_file=$(realpath "$prompt_file")
out_file=$(realpath -m "$out_file")
log_file="${out_file%.*}.log"
rm -f "$out_file"

cd "$(git rev-parse --show-toplevel)"
if [ -n "$snapshot" ]; then
  case "$(git cat-file -t "$snapshot")" in
    commit) commit=$snapshot ;;
    tree)
      parent=()
      if head=$(git rev-parse -q --verify HEAD); then
        parent=(-p "$head")
      fi
      commit=$(GIT_AUTHOR_NAME=codex-review GIT_AUTHOR_EMAIL=codex-review@localhost \
        GIT_COMMITTER_NAME=codex-review GIT_COMMITTER_EMAIL=codex-review@localhost \
        git commit-tree "$snapshot" ${parent[@]+"${parent[@]}"} -m "codex-review snapshot")
      ;;
    *) echo "snapshot $snapshot is not a tree or commit" >&2; exit 2 ;;
  esac
  worktree="${out_file%.*}.wt"
  # Clear a worktree left behind by an aborted run of the same round.
  git worktree remove --force "$worktree" 2>/dev/null || rm -rf "$worktree"
  git worktree prune
  trap 'git worktree remove --force "$worktree" 2>/dev/null || true' EXIT
  # No hooks or LFS downloads: the checkout only needs to be readable.
  GIT_LFS_SKIP_SMUDGE=1 git -c core.hooksPath=/dev/null worktree add --quiet --detach \
    "$worktree" "$commit"
  cd "$worktree"
fi

timeout --kill-after=30 "$timeout_secs" codex exec review \
  -m "$model" \
  -c "model_reasoning_effort=\"$effort\"" \
  -c 'sandbox_mode="read-only"' \
  --ephemeral \
  -o "$out_file" \
  - < "$prompt_file" > "$log_file" 2>&1 || {
    status=$?
    if [ "$status" -eq 124 ]; then
      echo "codex review timed out after ${timeout_secs}s" >&2
    fi
    echo "codex review failed (exit $status); last log lines:" >&2
    tail -40 "$log_file" >&2
    exit "$status"
  }

cat "$out_file"
