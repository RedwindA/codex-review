#!/usr/bin/env bash
# Usage: record_stats.sh key=value...
# Appends one JSON object built from the key=value pairs, plus a timestamp, to the stats file
# (CODEX_REVIEW_STATS, default ~/.codex-review/stats.jsonl; /dev/null disables it). Integer
# values are written as numbers, everything else as strings. stats.sh summarizes the file.
set -euo pipefail

stats_file=${CODEX_REVIEW_STATS:-$HOME/.codex-review/stats.jsonl}

json_string() {
  local v=$1
  v=${v//\\/\\\\}
  v=${v//\"/\\\"}
  v=${v//$'\n'/\\n}
  v=${v//$'\r'/\\r}
  v=${v//$'\t'/\\t}
  printf '"%s"' "$v"
}

line="{\"ts\":$(json_string "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
for pair in "$@"; do
  if [[ ! $pair =~ ^[a-z_]+= ]]; then
    echo "record_stats.sh: expected key=value, got '$pair'" >&2
    exit 2
  fi
  key=${pair%%=*}
  value=${pair#*=}
  if [[ $value =~ ^-?[0-9]+$ ]]; then
    line+=",\"$key\":$value"
  else
    line+=",\"$key\":$(json_string "$value")"
  fi
done
line+="}"

mkdir -p "$(dirname "$stats_file")"
printf '%s\n' "$line" >>"$stats_file"
