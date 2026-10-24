#!/usr/bin/env bash
# Usage: nightly.sh <repo>...
# For cron. Reviews, at deep effort, the commits that landed on each repo's current branch since
# the previous nightly run (the first run covers the last 24 hours), in a frozen worktree of HEAD,
# so it never touches the working tree. Reports go to
# ${CODEX_REVIEW_NIGHTLY_DIR:-~/.codex-review/nightly}/<absolute repo path>/<date>-<sha>.md.
# A repo is marked as reviewed up to HEAD only when its review succeeds, so a failed run is
# retried with the same commits next time (a failed first run records its baseline for that). Changes that classify.sh rates `skip` are marked
# without a review. Exits non-zero if any repo failed.
set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
nightly_dir=${CODEX_REVIEW_NIGHTLY_DIR:-$HOME/.codex-review/nightly}
# A day of commits can be large; give it longer than an interactive deep round.
export CODEX_REVIEW_TIMEOUT=${CODEX_REVIEW_TIMEOUT:-3600}
empty_tree=$(git hash-object -t tree /dev/null)

review_repo() {
  local repo=$1
  cd "$repo" || return 1
  cd "$(git rev-parse --show-toplevel)" || return 1

  local head branch marker last base
  head=$(git rev-parse HEAD) || return 1
  branch=$(git rev-parse --abbrev-ref HEAD)
  marker="$(git rev-parse --path-format=absolute --git-common-dir)/codex-review/nightly-last"

  # The marker holds the commit reviewed up to, or the empty tree when everything is pending.
  local had_marker=0
  base=""
  if [ -f "$marker" ]; then
    last=$(cat "$marker")
    if [ "$last" = "$empty_tree" ]; then
      base=$empty_tree
      had_marker=1
    elif last=$(git rev-parse -q --verify "$last^{commit}"); then
      # After a branch switch or rebase, start from where the histories meet.
      base=$(git merge-base "$last" "$head" || true)
      had_marker=1
    fi
  fi
  if [ -z "$base" ]; then
    base=$(git rev-list -1 --before="24 hours ago" "$head")
    # The whole history is younger than a day.
    [ -n "$base" ] || base=$empty_tree
  fi
  if [ "$base" = "$head" ]; then
    echo "$repo: no new commits"
    return 0
  fi

  local commits
  if [ "$base" = "$empty_tree" ]; then
    commits=$(git log --format='- %h %s' "$head")
  else
    commits=$(git log --format='- %h %s' "$base..$head")
  fi

  local classification tier notes
  classification=$("$script_dir/classify.sh" "$base" "$head") || return 1
  tier=$(sed -n 's/^tier=//p' <<<"$classification")
  notes=$(sed -n 's/^notes=//p' <<<"$classification")
  if [ "$tier" = "skip" ]; then
    echo "$repo: only skippable changes since ${base:0:12}, marking reviewed"
    mkdir -p "$(dirname "$marker")" && echo "$head" >"$marker"
    return 0
  fi

  local out_dir stem prompt out
  out_dir="$nightly_dir$PWD"
  mkdir -p "$out_dir"
  stem="$out_dir/$(date +%Y-%m-%d)-$(git rev-parse --short "$head")"
  prompt="$stem.prompt.md"
  out="$stem.md"

  {
    cat <<EOF
You are reviewing the commits that landed on branch \`$branch\` since the last nightly review. Do not modify any files.

## Scope
Review the change \`git diff $base $head\`.
The current directory is a read-only checkout of $head. Ignored files (dependencies, build outputs, local config) and submodules are not checked out; do not report their absence.

## Commits
$commits

The commit messages describe the intent of each change.
EOF
    if [ -n "$notes" ]; then
      printf '\n## Repo review notes\n'
      # Drop the YAML frontmatter, keep the body.
      awk 'NR == 1 && /^---\r?$/ { fm = 1; next } fm && /^---\r?$/ { fm = 0; next } !fm' "$notes"
      printf '\nFollow these notes: they record what this repo does and does not want reported, and why.\n'
    fi
    cat <<'EOF'

## Review guidance
- Report only issues that are real and actionable: bugs, behavioral regressions, broken edge cases that can actually occur, security problems, concurrency/resource issues, clear violations of this repo's conventions (AGENTS.md / CLAUDE.md), and missing tests for new behavior.
- Do NOT suggest defensive programming for states the types, callers, or invariants already rule out (redundant null/empty checks, try/catch that just swallows or logs, fallback values for impossible cases, re-validating trusted internal inputs). If you think an invariant does not hold, show the concrete path that violates it. This does not cover external input (user input, network, files, environment variables, config, data from other processes or versions): check how the change behaves at its boundary values (zero, negative, empty, missing) and report concrete failures.
- Do NOT report pure style preferences or speculative refactors.
- For each finding, give file:line, the commit that introduced it, a concrete triggering scenario, and the fix.
- For race-condition and security findings, state the preconditions the scenario needs (which interleaving, which attacker capability) and the concrete damage.
- Start each finding's title with exactly one tag: [Important] (a real bug, regression, security or data problem these commits introduce), [Nit] (a minor real issue: a misleading name, a small missing test, an unclear error message), or [Pre-existing] (a real problem in code these commits did not introduce).
- Add a line "Class: <bug class>" to each finding (e.g. "unescaped shell interpolation", "missing await on async call"), and list every place in the change with the same class of bug, not just the first one you saw.
- If there are no actionable issues, say explicitly: "No actionable issues found."
EOF
  } >"$prompt"

  echo "$repo: reviewing ${base:0:12}..${head:0:12} ($(sed -n 's/^reason=//p' <<<"$classification"))"
  if ! "$script_dir/run_review.sh" "$prompt" "$out" deep "$head" >/dev/null; then
    # Without a marker the next run would recompute a later 24-hour window and drop these commits.
    if [ "$had_marker" -eq 0 ]; then
      mkdir -p "$(dirname "$marker")" && echo "$base" >"$marker"
    fi
    return 1
  fi
  mkdir -p "$(dirname "$marker")" && echo "$head" >"$marker"
  echo "$repo: report at $out"
}

if [ "$#" -eq 0 ]; then
  echo "usage: nightly.sh <repo>..." >&2
  exit 2
fi

failed=0
for repo in "$@"; do
  if ! (review_repo "$repo"); then
    echo "$repo: nightly review failed" >&2
    failed=1
  fi
done
exit "$failed"
