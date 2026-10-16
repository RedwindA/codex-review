# codex-review

An [Agent Skill](https://agentskills.io) for Claude Code: before reporting a finished coding task, have the Codex CLI (`gpt-6-astra`) review the change at `xhigh` reasoning, verify each finding, reject pointless defensive programming, fix the real issues, then have Codex check only those fixes at `high` reasoning until it passes.

在 Claude Code 完成代码任务、向用户汇报之前，调用 Codex CLI（`gpt-6-astra`）做独立 review：首轮 xhigh 全面审查，逐条核验意见，拒绝无意义的防御性编程，修复有效问题后，之后每轮只用 high 核验修复，直到通过。

## Install

Install for Claude Code only (user-level, no `.agents/` copy):

```bash
mkdir -p ~/.claude/skills && curl -fsSL https://github.com/RedwindA/codex-review/archive/main.tar.gz | tar -xz -C ~/.claude/skills --strip-components=2 codex-review-main/skills/codex-review
```

Re-run the same command to update.

## Requirements

- [Codex CLI](https://github.com/openai/codex) installed and logged in (`codex login`)
- Access to the `gpt-6-astra` model, or override it with `CODEX_REVIEW_MODEL`; reasoning effort with `CODEX_REVIEW_EFFORT` (first round, default `xhigh`) / `CODEX_REVIEW_VERIFY_EFFORT` (verify rounds, default `high`)
- `git` and GNU `timeout` (coreutils); on macOS, install coreutils

## How it works

1. Scope the review (uncommitted changes by default; `--base <branch>` or `--commit <sha>` supported).
2. Run `codex exec review` in a read-only sandbox, with the change's intent and a ledger of previously fixed/rejected findings.
3. Verify every finding: fix real bugs; reject false positives and defensive checks for states the types or callers already rule out; surface out-of-scope issues and design trade-offs to the user.
4. Fix, re-run tests, then run a verify round: Codex reviews only the fix delta between two working-tree snapshots (`git diff <prev-tree> <cur-tree>`, taken by `scripts/snapshot.sh` without touching the index), at `high` reasoning, instead of re-reviewing the whole change. Stops when Codex has no new actionable findings, or after 5 rounds.

Reviews run as Claude Code background tasks and resume on the completion notification instead of polling. A hard timeout (`CODEX_REVIEW_TIMEOUT`, default 1800s) guarantees the task exits.

## Layout

```
.
├── LICENSE
├── README.md
└── skills/
    └── codex-review/
        ├── SKILL.md
        └── scripts/
            ├── run_review.sh
            └── snapshot.sh
```

## License

[MIT](./LICENSE)
