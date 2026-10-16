#!/usr/bin/env bash
# Usage: stats.sh [<stats-file>]
# Summarizes the stats file written by record_stats.sh (default: CODEX_REVIEW_STATS, or
# ~/.codex-review/stats.jsonl): time and tokens per mode and model from `round` records, cost per
# day, and outcomes per tier from `session` records. Use it to judge whether the tier thresholds,
# models and efforts are worth it, e.g. whether deep rounds find enough more real issues than
# standard ones for what they cost.
#
# Costs need a price table (CODEX_REVIEW_PRICES, default ~/.codex-review/prices.tsv), one model
# per line, USD per million tokens; `#` starts a comment:
#   gpt-6-astra   <input> <cached input> <output>
# Output tokens include reasoning tokens. Models missing from the table show no cost.
set -euo pipefail

stats_file=${1:-${CODEX_REVIEW_STATS:-$HOME/.codex-review/stats.jsonl}}
prices_file=${CODEX_REVIEW_PRICES:-$HOME/.codex-review/prices.tsv}
if [ ! -s "$stats_file" ]; then
  echo "no stats recorded yet in $stats_file"
  exit 0
fi
[ -f "$prices_file" ] || prices_file=/dev/null

awk -v prices="$prices_file" '
  # Reads a string or integer field from a flat JSON line written by record_stats.sh.
  function get(key,    m) {
    if (match($0, "\"" key "\":(\"([^\"\\\\]|\\\\.)*\"|-?[0-9]+)")) {
      m = substr($0, RSTART + length(key) + 3, RLENGTH - length(key) - 3)
      gsub(/^"|"$/, "", m)
      return m
    }
    return ""
  }
  function usd(x) { return sprintf("$%.2f", x) }
  FILENAME == prices {
    sub(/#.*/, "")
    if (NF >= 4) { p_in[$1] = $2; p_cached[$1] = $3; p_out[$1] = $4 }
    next
  }
  get("kind") == "round" {
    model = get("model")
    key = get("mode") " " model
    keys[key] = 1
    rounds[key]++
    secs[key] += get("seconds")
    if (get("exit") != "0") failed[key]++
    # Rounds recorded before token tracking have no token fields.
    if (get("input_tokens") == "") next
    in_t = get("input_tokens"); cached_t = get("cached_input_tokens"); out_t = get("output_tokens")
    counted[key]++
    tin[key] += in_t; tcached[key] += cached_t; tout[key] += out_t
    if (model in p_in) {
      c = ((in_t - cached_t) * p_in[model] + cached_t * p_cached[model] + out_t * p_out[model]) / 1e6
      cost[key] += c
      day = substr(get("ts"), 1, 10)
      days[day] = 1
      day_cost[day] += c
      day_rounds[day]++
      priced = 1
    }
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
    printf "%-9s %-14s %6s %8s %6s %10s %9s %10s %10s\n", "mode", "model", "rounds", "avg_secs", "failed", "avg_in_k", "cached%", "avg_out_k", "cost"
    for (k in keys) {
      split(k, parts, " ")
      n = counted[k]
      printf "%-9s %-14s %6d %8.0f %6d %10s %9s %10s %10s\n", parts[1], parts[2], rounds[k], secs[k] / rounds[k], failed[k], \
        (n ? sprintf("%.1f", tin[k] / n / 1000) : "-"), \
        (n && tin[k] ? sprintf("%.0f%%", 100 * tcached[k] / tin[k]) : "-"), \
        (n ? sprintf("%.1f", tout[k] / n / 1000) : "-"), \
        ((k in cost) ? usd(cost[k]) : "-")
    }
    if (priced) {
      print ""
      printf "%-10s %6s %10s\n", "day (UTC)", "rounds", "cost"
      ndays = 0
      for (d in days) list[++ndays] = d
      # Sort the days; there are few enough for an insertion sort.
      for (i = 2; i <= ndays; i++) {
        v = list[i]
        for (j = i - 1; j >= 1 && list[j] > v; j--) list[j + 1] = list[j]
        list[j + 1] = v
      }
      for (i = (ndays > 14 ? ndays - 13 : 1); i <= ndays; i++)
        printf "%-10s %6d %10s\n", list[i], day_rounds[list[i]], usd(day_cost[list[i]])
    }
    print ""
    printf "%-9s %8s %10s %9s %6s %6s %8s %11s\n", "tier", "sessions", "avg_rounds", "pass_1st", "capped", "fixed", "rejected", "reject_rate"
    for (t in tiers) {
      total = fixed[t] + rejected[t]
      printf "%-9s %8d %10.2f %8.0f%% %6d %6d %8d %10s\n", t, sessions[t], rsum[t] / sessions[t], 100 * first[t] / sessions[t], capped[t], fixed[t], rejected[t], (total ? sprintf("%.0f%%", 100 * rejected[t] / total) : "-")
    }
    if (misses) printf "\nmissed bugs recorded: %d\n", misses
  }
' "$prices_file" "$stats_file"
