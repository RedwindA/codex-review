# codex-review

An [Agent Skill](https://agentskills.io) for Claude Code: before reporting a finished coding task, have the Codex CLI review the change with a model and reasoning effort matched to its risk (`gpt-6-astra` for ordinary changes, at `xhigh` only for large or sensitive ones; the cheaper `gpt-6.1-sol` for small ones), verify each finding, reject pointless defensive programming, fix the real issues, then have `gpt-6.1-sol` check only those fixes until it passes.

在 Claude Code 完成代码任务、向用户汇报之前，调用 Codex CLI 做独立 review：首轮按改动风险分档全面审查（小改动用更便宜的 `gpt-6.1-sol`，普通改动用 `gpt-6-astra`，只有大改动或敏感路径才用 xhigh），逐条核验意见，拒绝无意义的防御性编程，修复有效问题后，之后每轮只用 `gpt-6.1-sol` 核验修复，直到通过。

## Install

Install for Claude Code only (user-level, no `.agents/` copy):

```bash
mkdir -p ~/.claude/skills && curl -fsSL https://github.com/RedwindA/codex-review/archive/main.tar.gz | tar -xz -C ~/.claude/skills --strip-components=2 codex-review-main/skills/codex-review
```

Re-run the same command to update.

## Requirements

- [Codex CLI](https://github.com/openai/codex) installed and logged in (`codex login`)
- Access to `gpt-6-astra` and `gpt-6.1-sol`. Per mode defaults and overrides:

  | Mode | Model (`CODEX_REVIEW_<MODE>_MODEL`) | Effort |
  |---|---|---|
  | `quick` | `gpt-6.1-sol` | `high` (`CODEX_REVIEW_QUICK_EFFORT`) |
  | `standard` | `gpt-6-astra` | `high` (`CODEX_REVIEW_EFFORT`) |
  | `deep` | `gpt-6-astra` | `xhigh` (`CODEX_REVIEW_DEEP_EFFORT`) |
  | `verify` | `gpt-6.1-sol` | `high` (`CODEX_REVIEW_VERIFY_EFFORT`) |

  `CODEX_REVIEW_MODEL` replaces the default model of every mode.
- `git` and GNU `timeout` (coreutils); on macOS, install coreutils

## How it works

1. Scope the review (uncommitted changes by default; `--base <branch>` or `--commit <sha>` supported), then pick a tier from the change itself with `scripts/classify.sh`:

   | Tier | Default rule | First round |
   |---|---|---|
   | `skip` | only docs, licenses, lockfiles, snapshots, images | no Codex; green checks suffice |
   | `quick` | ≤ 50 lines, no sensitive path | `gpt-6.1-sol` `high`, no verify rounds |
   | `standard` | everything else | `gpt-6-astra` `high` |
   | `deep` | > 400 lines, or touches auth, secrets, billing, migrations, CI, deploy/release/install paths | `gpt-6-astra` `xhigh` |

   PRs to repos you don't maintain get at least `deep`. Override with `--tier`, or per repo in the YAML frontmatter of `REVIEW.md` (format in the header of `scripts/classify.sh`).
2. Once lint, type checks and tests are green, run `codex exec review` in a read-only sandbox, with the change's intent and a ledger of previously fixed/rejected findings.
3. Verify every finding (Codex tags each as `[Important]`, `[Nit]` or `[Pre-existing]` and names its bug class): fix real bugs, and every other instance of the same class in the change; reject false positives and defensive checks for states the types or callers already rule out; surface out-of-scope issues, design trade-offs, and real but very unlikely issues whose fix would add significant complexity to the user.
4. Fix, re-run tests, then run a verify round: Codex reviews only the fix delta between two working-tree snapshots (`git diff <prev-tree> <cur-tree>`, taken by `scripts/snapshot.sh` without touching the index), with `gpt-6.1-sol` at `high`, instead of re-reviewing the whole change. Verify rounds run only when a non-trivial fix of an `[Important]` finding needs checking; Nit-only, test-only or mechanical fixes stop at green tests. Stops when Codex has no new actionable findings, or after 3 rounds, at which point the approach itself is put back to the user.

Reviews don't block. Each round checks out its working-tree snapshot into a temporary detached worktree (no hooks, no LFS downloads) and runs Codex there as a Claude Code background task, so Claude can report the task right away, keep working, or start your next task while Codex reviews the frozen code; it resumes on the completion notification instead of polling, and the review summary follows as a separate message. A hard timeout (`CODEX_REVIEW_TIMEOUT`, default 1800s for `deep`, 900s otherwise) guarantees the task exits.

## Per-repo review notes

Each repo can keep review notes that every round sends to Codex: project conventions, and the kinds of findings it should not report, with the reason. Recurring rejections thus stop coming back in later sessions. The skill looks for:

1. `REVIEW.md` at the repo root (for repos you maintain), or
2. `<git-common-dir>/codex-review/REVIEW.md` (kept out of commits; for repos you contribute to).

The body is free text. Optional YAML frontmatter overrides the tiering rules (`deep`, `skip`, `quick_max_lines`, `deep_min_lines`). When a rejection reason generalizes, Claude proposes a note in its report and writes it only after you agree.

## Nightly review

`scripts/nightly.sh <repo>...` reviews, at `deep`, the commits that landed on each repo's current branch since its previous run (the first run covers the last 24 hours), in a frozen worktree of `HEAD`. Reports go to `~/.codex-review/nightly/<absolute repo path>/<date>-<sha>.md` (override the root with `CODEX_REVIEW_NIGHTLY_DIR`). A repo is marked reviewed only when its review succeeds, so a failed night is retried with the same commits, including on the first run. This is a safety net for the `quick` changes reviewed lightly during the day; ask Claude to "处理夜间 review 报告" to triage and fix the findings.

Run it from cron. cron starts with a minimal `PATH`, so put the directories of `codex` and `node` on it:

```bash
mkdir -p ~/.codex-review   # cron opens the log before nightly.sh runs
crontab -e
# every day at 03:00
0 3 * * * PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin $HOME/.claude/skills/codex-review/scripts/nightly.sh $HOME/proj-a $HOME/proj-b >> $HOME/.codex-review/nightly.log 2>&1
```

On WSL, cron only runs while the distro is running, and is not started by default: enable systemd (`[boot] systemd=true` in `/etc/wsl.conf`) or run `sudo service cron start` after boot. A missed night is covered by the next run.

## Stats

Each codex run appends a `round` record (mode, model, effort, seconds, exit status, input / cached / output tokens) to `~/.codex-review/stats.jsonl`, and Claude adds a `session` record when a review ends (tier, rounds, result, fixed, rejected, nits, pre-existing). `scripts/stats.sh` summarizes them: time and tokens per mode and model, cost per day, and per tier the average rounds, first-round pass rate and rejection rate. A week or two of data tells you whether the thresholds, models and efforts are paying off, e.g. whether `deep` finds enough more than `standard` to justify `xhigh`. Set `CODEX_REVIEW_STATS` to another path, or to `/dev/null` to turn this off.

Token usage comes from the review thread's Codex session file (`codex exec review --json` reports zeros), so reviews are no longer `--ephemeral` and stay in `~/.codex/sessions`. For costs, put your prices in `~/.codex-review/prices.tsv` (or `CODEX_REVIEW_PRICES`), USD per million tokens:

```
# model       input  cached-input  output
gpt-6-astra   <in>   <cached>      <out>
gpt-6.1-sol   <in>   <cached>      <out>
```

When a bug the review should have caught turns up later, record it so the misses are counted too, and keep the commit around as a regression case for prompt or effort changes:

```bash
~/.claude/skills/codex-review/scripts/record_stats.sh kind=miss repo="$PWD" commit=<sha> note="<what was missed>"
```

## Layout

```
.
├── LICENSE
├── README.md
└── skills/
    └── codex-review/
        ├── SKILL.md
        └── scripts/
            ├── classify.sh
            ├── nightly.sh
            ├── record_stats.sh
            ├── run_review.sh
            ├── snapshot.sh
            └── stats.sh
```

## License

[MIT](./LICENSE)
