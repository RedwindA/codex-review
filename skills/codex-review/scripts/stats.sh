#!/usr/bin/env bash
# Usage: stats.sh [<stats-file>]
# Summarizes the stats file written by record_stats.sh (default: CODEX_REVIEW_STATS, or
# ~/.codex-review/stats.jsonl): codex time per mode from `round` records, and outcomes per tier
# from `session` records. Use it to judge whether the tier thresholds and efforts are worth it,
# e.g. whether deep rounds find more real issues than standard ones for the time they take.
set -euo pipefail

stats_file=${1:-${CODEX_REVIEW_STATS:-$HOME/.codex-review/stats.jsonl}}
if [ ! -s "$stats_file" ]; then
  echo "no stats recorded yet in $stats_file"
  exit 0
fi

awk '
  # Reads a string or integer field from a flat JSON line written by record_stats.sh.
  function get(key,    m) {
    if (match($0, "\"" key "\":(\"([^\"\\\\]|\\\\.)*\"|-?[0-9]+)")) {
      m = substr($0, RSTART + length(key) + 3, RLENGTH - length(key) - 3)
      gsub(/^"|"$/, "", m)
      return m
    }
    return ""
  }
  get("kind") == "round" {
    mode = get("mode")
    rounds[mode]++
    secs[mode] += get("seconds")
    if (get("exit") != "0") failed[mode]++
    modes[mode] = 1
  }
  get("kind") == "session" {
    tier = get("tier")
    tiers[tier] = 1
    sessions[tier]++
    rsum[tier] += get("rounds")
    if (get("result") == "passed" && get("rounds") <= 1) first[tier]++
    if (get("result") == "cap") capped[tier]++
    fixed[tier] += get("fixed")
    rejected[tier] += get("rejected")
  }
  get("kind") == "miss" { misses++ }
  END {
    printf "%-9s %7s %9s %7s\n", "mode", "rounds", "avg_secs", "failed"
    for (m in modes)
      printf "%-9s %7d %9.0f %7d\n", m, rounds[m], secs[m] / rounds[m], failed[m]
    print ""
    printf "%-9s %8s %10s %9s %6s %6s %8s %11s\n", "tier", "sessions", "avg_rounds", "pass_1st", "capped", "fixed", "rejected", "reject_rate"
    for (t in tiers) {
      total = fixed[t] + rejected[t]
      printf "%-9s %8d %10.2f %8.0f%% %6d %6d %8d %10s\n", t, sessions[t], rsum[t] / sessions[t], 100 * first[t] / sessions[t], capped[t], fixed[t], rejected[t], (total ? sprintf("%.0f%%", 100 * rejected[t] / total) : "-")
    }
    if (misses) printf "\nmissed bugs recorded: %d\n", misses
  }
' "$stats_file"
