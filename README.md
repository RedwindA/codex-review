# codex-review

An [Agent Skill](https://agentskills.io) for Claude Code: before reporting a finished coding task, have the Codex CLI (`gpt-6-astra`, `xhigh` reasoning) review the change, verify each finding, reject pointless defensive programming, fix the real issues, and re-review until it passes.

在 Claude Code 完成代码任务、向用户汇报之前，调用 Codex CLI（`gpt-6-astra`，xhigh 思考强度）做独立 review：逐条核验意见，拒绝无意义的防御性编程，修复有效问题后再次 review，直到通过。

## Install

Install for Claude Code only (user-level, no `.agents/` copy):

```bash
mkdir -p ~/.claude/skills && curl -fsSL https://github.com/RedwindA/codex-review/archive/main.tar.gz | tar -xz -C ~/.claude/skills --strip-components=2 codex-review-main/skills/codex-review
```

Re-run the same command to update.

## Requirements

- [Codex CLI](https://github.com/openai/codex) installed and logged in (`codex login`)
- Access to the `gpt-6-astra` model, or override it with `CODEX_REVIEW_MODEL` / `CODEX_REVIEW_EFFORT`
- `git` and GNU `timeout` (coreutils); on macOS, install coreutils

## How it works

1. Scope the review (uncommitted changes by default; `--base <branch>` or `--commit <sha>` supported).
2. Run `codex exec review` in a read-only sandbox, with the change's intent and a ledger of previously fixed/rejected findings.
3. Verify every finding: fix real bugs; reject false positives and defensive checks for states the types or callers already rule out; surface out-of-scope issues and design trade-offs to the user.
4. Fix, re-run tests, re-review. Stops when Codex has no new actionable findings, or after 5 rounds.

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
            └── run_review.sh
```

## License

[MIT](./LICENSE)
