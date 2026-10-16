# codex-review

An [Agent Skill](https://agentskills.io) for Claude Code: before reporting a finished coding task, have the Codex CLI (`gpt-6-astra`) review the change at a reasoning effort matched to its risk (`xhigh` only for large or sensitive changes), verify each finding, reject pointless defensive programming, fix the real issues, then have Codex check only those fixes at `high` reasoning until it passes.

在 Claude Code 完成代码任务、向用户汇报之前，调用 Codex CLI（`gpt-6-astra`）做独立 review：首轮按改动风险分档全面审查（只有大改动或敏感路径才用 xhigh），逐条核验意见，拒绝无意义的防御性编程，修复有效问题后，之后每轮只用 high 核验修复，直到通过。

## Install

Install for Claude Code only (user-level, no `.agents/` copy):

```bash
mkdir -p ~/.claude/skills && curl -fsSL https://github.com/RedwindA/codex-review/archive/main.tar.gz | tar -xz -C ~/.claude/skills --strip-components=2 codex-review-main/skills/codex-review
```

Re-run the same command to update.

## Requirements

- [Codex CLI](https://github.com/openai/codex) installed and logged in (`codex login`)
- Access to the `gpt-6-astra` model, or override it with `CODEX_REVIEW_MODEL`; reasoning effort per mode with `CODEX_REVIEW_QUICK_EFFORT` / `CODEX_REVIEW_EFFORT` (standard) / `CODEX_REVIEW_DEEP_EFFORT` / `CODEX_REVIEW_VERIFY_EFFORT` (defaults `high` / `high` / `xhigh` / `high`)
- `git` and GNU `timeout` (coreutils); on macOS, install coreutils

## How it works

1. Scope the review (uncommitted changes by default; `--base <branch>` or `--commit <sha>` supported), then pick a tier from the change itself with `scripts/classify.sh`:

   | Tier | Default rule | First round |
   |---|---|---|
   | `skip` | only docs, licenses, lockfiles, snapshots, images | no Codex; green checks suffice |
   | `quick` | ≤ 50 lines, no sensitive path | `high`, no verify rounds |
   | `standard` | everything else | `high` |
   | `deep` | > 400 lines, or touches auth, secrets, billing, migrations, CI, deploy/release/install paths | `xhigh` |

   PRs to repos you don't maintain get at least `deep`. Override with `--tier`, or per repo in the YAML frontmatter of `REVIEW.md` (format in the header of `scripts/classify.sh`).
2. Once lint, type checks and tests are green, run `codex exec review` in a read-only sandbox, with the change's intent and a ledger of previously fixed/rejected findings.
3. Verify every finding (Codex tags each as `[Important]`, `[Nit]` or `[Pre-existing]` and names its bug class): fix real bugs, and every other instance of the same class in the change; reject false positives and defensive checks for states the types or callers already rule out; surface out-of-scope issues and design trade-offs to the user.
4. Fix, re-run tests, then run a verify round: Codex reviews only the fix delta between two working-tree snapshots (`git diff <prev-tree> <cur-tree>`, taken by `scripts/snapshot.sh` without touching the index), at `high` reasoning, instead of re-reviewing the whole change. Verify rounds run only when a non-trivial fix of an `[Important]` finding needs checking; Nit-only, test-only or mechanical fixes stop at green tests. Stops when Codex has no new actionable findings, or after 3 rounds, at which point the approach itself is put back to the user.

Reviews don't block. Each round checks out its working-tree snapshot into a temporary detached worktree (no hooks, no LFS downloads) and runs Codex there as a Claude Code background task, so Claude can report the task right away, keep working, or start your next task while Codex reviews the frozen code; it resumes on the completion notification instead of polling, and the review summary follows as a separate message. A hard timeout (`CODEX_REVIEW_TIMEOUT`, default 1800s for `deep`, 900s otherwise) guarantees the task exits.

## Per-repo review notes

Each repo can keep review notes that every round sends to Codex: project conventions, and the kinds of findings it should not report, with the reason. Recurring rejections thus stop coming back in later sessions. The skill looks for:

1. `REVIEW.md` at the repo root (for repos you maintain), or
2. `<git-common-dir>/codex-review/REVIEW.md` (kept out of commits; for repos you contribute to).

The body is free text. Optional YAML frontmatter overrides the tiering rules (`deep`, `skip`, `quick_max_lines`, `deep_min_lines`). When a rejection reason generalizes, Claude proposes a note in its report and writes it only after you agree.

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
            ├── run_review.sh
            └── snapshot.sh
```

## License

[MIT](./LICENSE)
