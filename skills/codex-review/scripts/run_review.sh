#!/usr/bin/env bash
# Usage: run_review.sh <prompt-file> <output-file>
# Runs a read-only codex review in the current git repo root. The prompt is fed via stdin.
set -euo pipefail

prompt_file=$1
out_file=$2
model=${CODEX_REVIEW_MODEL:-gpt-6-astra}
effort=${CODEX_REVIEW_EFFORT:-xhigh}
# Hard cap so the background task always exits and triggers a completion notification.
timeout_secs=${CODEX_REVIEW_TIMEOUT:-1800}

cd "$(git rev-parse --show-toplevel)"
log_file="${out_file%.*}.log"
rm -f "$out_file"

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
