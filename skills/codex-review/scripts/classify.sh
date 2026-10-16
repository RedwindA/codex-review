#!/usr/bin/env bash
# Usage: classify.sh [<git diff args>...]
# Picks a review tier for a change from the change itself (its size and the paths it touches):
#   skip      every changed file matches a skip pattern (docs, licenses, lockfiles, images)
#   deep      a changed file matches a deep pattern (auth, secrets, billing, migrations, CI,
#             deploy/release/install scripts), or more than deep_min_lines lines changed
#   quick     at most quick_max_lines lines changed
#   standard  everything else
# Files matching a skip pattern are left out of the line count and the deep check.
# Arguments go to `git diff --numstat` (e.g. `main...HEAD`, `<sha>^ <sha>`, `<tree> <tree>`, or a
# trailing `-- <paths>`); with none, or with only `-- <paths>`, the uncommitted change (tracked
# and untracked) against HEAD is classified.
#
# Patterns and thresholds can be overridden in the YAML frontmatter of the repo's review notes:
# REVIEW.md at the repo root, or <git-common-dir>/codex-review/REVIEW.md for notes kept out of
# the repo. A key that is present replaces its default; `skip: []` disables skipping.
#   ---
#   deep: ["*auth*", "migrations/*"]   # or one "  - pattern" per line
#   skip: ["*.md"]
#   quick_max_lines: 50
#   deep_min_lines: 400
#   ---
# Patterns are bash globs matched against the repo-relative path; `*` also matches `/`.
#
# Prints key=value lines: tier, lines, files, reason, notes (path of the review notes, or empty).
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
cd "$(git rev-parse --show-toplevel)"

deep_patterns=('*auth*' '*login*' '*session*' '*passw*' '*secret*' '*credential*' '*token*'
  '*crypt*' '*permission*' '*security*' '*billing*' '*payment*' '*invoice*' '*migration*'
  '*.sql' '.github/workflows/*' '.gitlab-ci*' 'Dockerfile*' '*deploy*' '*release*' '*install*')
skip_patterns=('*.md' '*.mdx' '*.rst' 'docs/*' 'LICENSE*' 'COPYING*' 'CHANGELOG*' '*.snap'
  '*.lock' '*-lock.json' '*-lock.yaml' 'go.sum' '*.png' '*.jpg' '*.jpeg' '*.gif' '*.svg'
  '*.ico' '*.webp')
quick_max_lines=50
deep_min_lines=400

notes=""
if [ -f REVIEW.md ]; then
  notes="$PWD/REVIEW.md"
else
  private="$(git rev-parse --path-format=absolute --git-common-dir)/codex-review/REVIEW.md"
  if [ -f "$private" ]; then
    notes=$private
  fi
fi

unquote() {
  local v=$1
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  if [[ $v == \"*\" || $v == \'*\' ]]; then
    v=${v:1:${#v}-2}
  fi
  printf '%s' "$v"
}

# Appends one pattern to the list named by the current frontmatter key.
add_pattern() {
  local p
  p=$(unquote "$1")
  [ -n "$p" ] || return 0
  case $key in
    deep) deep_patterns+=("$p") ;;
    skip) skip_patterns+=("$p") ;;
  esac
}

if [ -n "$notes" ]; then
  key=""
  first=1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    if [ "$first" -eq 1 ]; then
      first=0
      [ "$line" = "---" ] && continue
      break
    fi
    [ "$line" = "---" ] && break
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    line=$(sed 's/[[:space:]]#.*$//' <<<"$line")
    if [[ $line =~ ^([a-z_]+):[[:space:]]*(.*)$ ]]; then
      key=${BASH_REMATCH[1]}
      value=${BASH_REMATCH[2]}
      case $key in
        deep) deep_patterns=() ;;
        skip) skip_patterns=() ;;
        quick_max_lines | deep_min_lines)
          if [[ ! $value =~ ^[0-9]+$ ]]; then
            echo "classify.sh: $key in $notes must be a number, got '$value'" >&2
            exit 2
          fi
          printf -v "$key" '%s' "$value"
          continue
          ;;
        *) continue ;;
      esac
      if [[ $value == \[*\] ]]; then
        value=${value:1:${#value}-2}
        IFS=',' read -ra items <<<"$value"
        for item in ${items[@]+"${items[@]}"}; do
          add_pattern "$item"
        done
      fi
    elif [[ $line =~ ^[[:space:]]+-[[:space:]]*(.*)$ ]]; then
      add_pattern "${BASH_REMATCH[1]}"
    fi
  done <"$notes"
fi

matches_any() {
  local path=$1 pattern
  shift
  for pattern in "$@"; do
    # shellcheck disable=SC2053 # the pattern is meant to glob
    [[ $path == $pattern ]] && return 0
  done
  return 1
}

if [ "$#" -eq 0 ] || [ "$1" = "--" ]; then
  head_tree=$(git rev-parse -q --verify 'HEAD^{tree}' || git hash-object -t tree /dev/null)
  work_tree=$("$script_dir/snapshot.sh")
  set -- "$head_tree" "$work_tree" "$@"
fi

# Run the diff on its own so a bad revision fails here instead of reading as an empty change.
numstat=$(mktemp)
trap 'rm -f "$numstat"' EXIT
git diff --numstat -z --no-renames "$@" >"$numstat"

lines=0
files=0
skipped=0
deep_hits=()
while IFS=$'\t' read -r -d '' added deleted path; do
  if [ "${#skip_patterns[@]}" -gt 0 ] && matches_any "$path" "${skip_patterns[@]}"; then
    skipped=$((skipped + 1))
    continue
  fi
  files=$((files + 1))
  # Binary files show "-" for both counts.
  [ "$added" = "-" ] || lines=$((lines + added + deleted))
  if [ "${#deep_patterns[@]}" -gt 0 ] && matches_any "$path" "${deep_patterns[@]}"; then
    deep_hits+=("$path")
  fi
done <"$numstat"

if [ "$files" -eq 0 ] && [ "$skipped" -eq 0 ]; then
  tier=skip
  reason="no changed files"
elif [ "$files" -eq 0 ]; then
  tier=skip
  reason="all $skipped changed files match skip patterns"
elif [ "${#deep_hits[@]}" -gt 0 ]; then
  tier=deep
  reason="touches a deep path: ${deep_hits[0]}"
  [ "${#deep_hits[@]}" -eq 1 ] || reason+=" (+$((${#deep_hits[@]} - 1)) more)"
elif [ "$lines" -gt "$deep_min_lines" ]; then
  tier=deep
  reason="$lines lines changed (> $deep_min_lines)"
elif [ "$lines" -le "$quick_max_lines" ]; then
  tier=quick
  reason="$lines lines changed (<= $quick_max_lines)"
else
  tier=standard
  reason="$lines lines changed"
fi

printf 'tier=%s\nlines=%s\nfiles=%s\nreason=%s\nnotes=%s\n' "$tier" "$lines" "$files" "$reason" "$notes"
