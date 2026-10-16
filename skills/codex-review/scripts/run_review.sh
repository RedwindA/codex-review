#!/usr/bin/env bash
# Usage: run_review.sh <prompt-file> <output-file> [quick|standard|deep|verify] [<snapshot>]
# Runs a read-only codex review. The prompt is fed via stdin.
# The mode picks the model and reasoning effort: quick/standard/deep are first-round tiers chosen
# by classify.sh; `verify` checks only the fixes since the previous round. Defaults: quick and
# verify use gpt-6.1-sol at high, standard gpt-6-astra at high, deep gpt-6-astra at xhigh.
# CODEX_REVIEW_<MODE>_MODEL / _EFFORT override one mode; CODEX_REVIEW_MODEL overrides every mode's
# default model.
# With a snapshot (a tree id from snapshot.sh, or a commit), codex runs in a temporary detached
# worktree checked out at that snapshot, so the real working tree can keep changing while it
# reviews; the worktree is removed on exit. Without one, codex runs in the repo root.
# Each run appends a `round` record (mode, model, effort, seconds, exit status, token usage) via
# record_stats.sh; the output file's directory is the session id. Token usage is read from the
# codex session files of the review thread, so the run is not --ephemeral.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)

prompt_file=$1
out_file=$2
mode=${3:-standard}
snapshot=${4:-}
case "$mode" in
  quick)
    model=${CODEX_REVIEW_QUICK_MODEL:-${CODEX_REVIEW_MODEL:-gpt-6.1-sol}}
    effort=${CODEX_REVIEW_QUICK_EFFORT:-high} default_timeout=900
    ;;
  standard)
    model=${CODEX_REVIEW_STANDARD_MODEL:-${CODEX_REVIEW_MODEL:-gpt-6-astra}}
    effort=${CODEX_REVIEW_EFFORT:-high} default_timeout=900
    ;;
  deep)
    model=${CODEX_REVIEW_DEEP_MODEL:-${CODEX_REVIEW_MODEL:-gpt-6-astra}}
    effort=${CODEX_REVIEW_DEEP_EFFORT:-xhigh} default_timeout=1800
    ;;
  verify)
    model=${CODEX_REVIEW_VERIFY_MODEL:-${CODEX_REVIEW_MODEL:-gpt-6.1-sol}}
    effort=${CODEX_REVIEW_VERIFY_EFFORT:-high} default_timeout=900
    ;;
  *) echo "unknown mode: $mode (expected quick, standard, deep or verify)" >&2; exit 2 ;;
esac
# Hard cap so the background task always exits and triggers a completion notification.
timeout_secs=${CODEX_REVIEW_TIMEOUT:-$default_timeout}

prompt_file=$(realpath "$prompt_file")
out_file=$(realpath -m "$out_file")
log_file="${out_file%.*}.log"
events_file="${out_file%.*}.events.jsonl"
rm -f "$out_file"
sessions_dir="${CODEX_HOME:-$HOME/.codex}/sessions"

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
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

# Sums the final token usage of every codex session file belonging to the thread: the review runs
# in a child thread whose session file names the parent, and the --json usage reports zeros.
# Prints "input cached output reasoning".
thread_tokens() {
  local thread=$1 stamp=$2 file usage key in=0 cached=0 out=0 reasoning=0
  [ -d "$sessions_dir" ] || { echo "0 0 0 0"; return; }
  while IFS= read -r file; do
    head -1 "$file" | grep -qE "\"(id|parent_thread_id)\":\"$thread\"" || continue
    usage=$(grep '"type":"token_count"' "$file" | tail -1 | grep -o '"total_token_usage":{[^}]*}') || continue
    for key in input_tokens cached_input_tokens output_tokens reasoning_output_tokens; do
      local n
      n=$(grep -o "\"$key\":[0-9]*" <<<"$usage" | cut -d: -f2)
      case $key in
        input_tokens) in=$((in + ${n:-0})) ;;
        cached_input_tokens) cached=$((cached + ${n:-0})) ;;
        output_tokens) out=$((out + ${n:-0})) ;;
        reasoning_output_tokens) reasoning=$((reasoning + ${n:-0})) ;;
      esac
    done
  done < <(find "$sessions_dir" -name 'rollout-*.jsonl' -newer "$stamp" 2>/dev/null)
  echo "$in $cached $out $reasoning"
}

stamp=$(mktemp)
start=$SECONDS
status=0
timeout --kill-after=30 "$timeout_secs" codex exec review \
  -m "$model" \
  -c "model_reasoning_effort=\"$effort\"" \
  -c 'sandbox_mode="read-only"' \
  --json \
  -o "$out_file" \
  - < "$prompt_file" > "$events_file" 2> "$log_file" || status=$?
seconds=$((SECONDS - start))

thread=$(grep -o -m1 '"thread_id":"[^"]*"' "$events_file" | cut -d'"' -f4 || true)
tokens="0 0 0 0"
if [ -n "$thread" ]; then
  tokens=$(thread_tokens "$thread" "$stamp")
fi
rm -f "$stamp"
read -r in_tokens cached_tokens out_tokens reasoning_tokens <<<"$tokens"

"$script_dir/record_stats.sh" kind=round session="$(dirname "$out_file")" repo="$repo_root" \
  mode="$mode" effort="$effort" model="$model" seconds="$seconds" exit="$status" \
  input_tokens="$in_tokens" cached_input_tokens="$cached_tokens" output_tokens="$out_tokens" \
  reasoning_output_tokens="$reasoning_tokens" ||
  echo "warning: could not record stats" >&2

if [ "$status" -ne 0 ]; then
  if [ "$status" -eq 124 ]; then
    echo "codex review timed out after ${timeout_secs}s" >&2
  fi
  echo "codex review failed (exit $status); last log lines:" >&2
  tail -20 "$log_file" >&2
  tail -20 "$events_file" >&2
  exit "$status"
fi

cat "$out_file"
echo
echo "[codex-review] mode=$mode model=$model effort=$effort seconds=$seconds input_tokens=$in_tokens cached_input_tokens=$cached_tokens output_tokens=$out_tokens"
