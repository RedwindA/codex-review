---
name: codex-review
description: 在代码任务完成后、向用户汇报之前，调用 Codex CLI（gpt-6-astra，xhigh 思考强度）对本次改动做独立 review；逐条核验意见，拒绝无意义的防御性编程，修复有效问题后再次提交 review，循环直到通过。当你修改了代码并准备汇报"已完成"时使用，或用户说"让 codex review""codex 审一下"时使用。
user-invocable: true
argument-hint: "[--base <branch> | --commit <sha>] [额外关注点]"
---

# Codex Review 循环

**用户参数：** $ARGUMENTS

在你认为任务完成、**向用户汇报之前**执行。目标是让一个独立的强模型挑错，但由你负责判断哪些意见值得采纳。Codex 是审阅者，不是决策者。

以下情况跳过：本次没有改动代码（纯问答、纯调研）、改动只有文档/注释/格式化，或用户明确说不需要 review。

## 1. 准备

1. 确定 review 范围：
   - 默认：工作区内所有未提交改动（staged + unstaged + untracked）。
   - `--base <branch>`：当前分支相对该分支的改动。
   - `--commit <sha>`：该提交引入的改动。
   - 如果工作区里混有**不属于本次任务**的改动（对照会话开始时的 git status），在 prompt 里列出本次任务涉及的文件，让 codex 只看这些文件。
2. 在 scratchpad 目录（没有就用 `mktemp -d`）下建一个工作目录 `$DIR`，每轮使用 `$DIR/round-N-prompt.md` 和 `$DIR/round-N-review.md`。
3. 维护一份**处理记录**（ledger），每轮都要带给 codex：
   - 已修复：`[轮次] 标题 — 怎么修的`
   - 已拒绝：`[轮次] 标题 — 拒绝理由（具体说明为什么不成立或不必要）`

## 2. 写 review prompt

`codex exec review` 的 `--uncommitted/--base/--commit` 不能和自定义 prompt 同时使用，所以范围写在 prompt 里。模板：

```markdown
You are reviewing code changes made by another engineer. Do not modify any files.

## Scope
<例：Review all uncommitted changes: inspect `git status`, `git diff HEAD`, and untracked files.>
<或：Review `git diff <base>...HEAD`。/ Review commit <sha> (`git show <sha>`)。>
<如有需要：Only these files belong to this change: ...>

## Intent of the change
<2-6 句：用户要什么、你做了什么、关键的设计取舍>

## Review guidance
- Report only issues that are real and actionable: bugs, behavioral regressions, broken edge cases that can actually occur, security problems, concurrency/resource issues, clear violations of this repo's conventions (AGENTS.md / CLAUDE.md), and missing tests for new behavior.
- Do NOT suggest defensive programming for states the types, callers, or invariants already rule out (redundant null/empty checks, try/catch that just swallows or logs, fallback values for impossible cases, re-validating trusted internal inputs). If you think an invariant does not hold, show the concrete path that violates it.
- Do NOT report pure style preferences or speculative refactors.
- For each finding, give file:line, a concrete triggering scenario, and the fix.
- If there are no actionable issues, say explicitly: "No actionable issues found."

## Previous rounds
<第一轮写 "None."；之后粘贴处理记录。>
Fixed items: verify the fixes are correct and did not introduce new problems.
Rejected items: do not re-raise them unless you have a NEW concrete argument (a reproducible scenario or evidence the rejection reasoning is wrong). If you still disagree, state it once under "Disputed" with that evidence.
```

用户在参数里给出的额外关注点，加到 Review guidance 里。

## 3. 运行

```bash
"${CLAUDE_SKILL_DIR}/scripts/run_review.sh" "$DIR/round-N-prompt.md" "$DIR/round-N-review.md"
```

（`${CLAUDE_SKILL_DIR}` 指本 SKILL.md 所在目录。如果它没有被替换成实际路径，就用本文件旁边的 `scripts/run_review.sh` 的绝对路径。）

- 脚本会 cd 到 git 仓库根目录，以 `-m gpt-6-astra -c model_reasoning_effort="xhigh"`、只读沙箱和 `--ephemeral` 运行，打印 codex 的最终结论。完整过程日志保存在 `$DIR/round-N-review.log`。
- 脚本自带硬超时（默认 1800 秒，可用 `CODEX_REVIEW_TIMEOUT` 覆盖），保证进程一定会退出，从而一定会触发完成通知。

### 等待方式：后台运行 + 完成通知，不要轮询

xhigh 对中等规模的改动可能要跑 10–30 分钟，已经超过前台 Bash 最长 10 分钟的上限。因此：

1. **每轮都用 Bash 的 `run_in_background: true` 启动脚本。** 进程退出后，Claude Code 会自动重新唤醒你，这个通知就是唯一的等待信号。
2. 启动后，**禁止**做以下任何事：
   - 用 `sleep`、`while` 循环、Monitor 或 ScheduleWakeup 去检查进度；
   - 反复 `tail`/`cat` 日志或输出文件，或用 `ps`/`pgrep` 查 codex 是否还在跑；
   - 在结束前读取 `round-N-review.md`（codex 结束时才写入，中途读到的要么不存在，要么是旧内容）。
3. 等待期间可以做和 review 结论无关、且不修改被审代码的工作，比如跑还没跑的测试或 lint、整理处理记录、起草汇报的其余部分。**不要改动被审文件**，否则 codex 看到的代码和你之后修复的代码会不一致。
4. 没有其他事可做时，直接结束本轮回复，告诉用户"codex review 第 N 轮正在后台运行（通常需要 X 分钟），完成后自动继续"。不要为了等待而保持回合开着。
5. 收到完成通知后，读取通知里的输出（即脚本打印的最终结论），退出码非 0 时再看日志尾部，然后进入第 4 步。
6. 如果用户中途问进度，只回答"仍在运行"。只有用户明确要求时，才看一次日志尾部。

- 如果失败（认证、网络、模型不可用、超时退出码 124），先看日志尾部。可以用环境变量 `CODEX_REVIEW_MODEL` / `CODEX_REVIEW_EFFORT` 覆盖模型和思考强度，但**只在用户同意后**才降级；否则停止循环，并在汇报里说明 review 没有完成。
- 输出格式通常是 `- [P0..P3] 标题 — 文件:行` 加一段说明。

## 4. 逐条核验（关键步骤）

不要照单全收。对每条意见，先读相关代码，必要时实际复现（写一个小测试或脚本、跑已有测试、追调用方），然后归入下面一类：

| 判定 | 标准 | 处理 |
|---|---|---|
| **有效** | 能指出具体的触发路径或复现，确实是 bug、回归、安全问题、违反仓库规范，或新行为缺少测试 | 修复 |
| **误报** | 对代码理解有误，所说的路径实际不可达，或已经被处理 | 拒绝，给出证据（如"调用方 X 在 foo.rs:42 已保证非空"） |
| **无意义防御性编程** | 见下方清单 | 拒绝，说明是哪条不变量或类型保证排除了该情况 |
| **超出范围** | 问题早已存在、不是本次改动引入的，且不影响本次任务 | 不修，汇报时作为"顺带发现"告诉用户 |
| **有争议的设计取舍** | 两种做法都说得通，涉及产品或架构判断 | 不擅自改，汇报时交给用户决定 |

**应当拒绝的防御性编程**：
- 对类型系统、构造函数或唯一调用方已经保证的值再做 null/None/空值/越界检查。
- 用 try/catch、`.ok()`、`unwrap_or_default()` 吞掉本应暴露的错误，或"以防万一"只记一条日志的兜底。
- 为不可能出现的枚举分支或状态加 fallback（能用穷尽 match 或让编译器检查的，就不要加运行时兜底）。
- 对内部可信数据重复校验，或加入没有真实故障场景支撑的重试、超时、锁。
- 为了"更健壮"引入新的配置项、参数或抽象层。

**不属于**无意义防御的（这些要认真对待）：外部输入（用户输入、网络、文件、环境变量、跨进程或跨版本数据）的校验；codex 能给出具体违反路径的"不变量"；资源泄漏；并发竞态；数据丢失；安全边界。

拿不准时，以能否构造出具体触发场景为准：构造得出来就修，构造不出来就拒绝并写明理由。

## 5. 修复并复审

1. 修复所有"有效"项，按仓库规范跑相关的格式化和测试（例如 AGENTS.md 要求的 `just fmt`、`just test -p ...`）。
2. 更新处理记录，然后进入下一轮（回到第 2 步，轮次 +1）。
3. **通过条件**，满足任一即可：
   - codex 明确表示没有可操作的问题；
   - codex 剩下的意见全是此前已拒绝的项，且没有提出新的具体证据；
   - 剩下的只有"超出范围"或"有争议的设计取舍"项。
4. **上限 5 轮**。到了上限仍未收敛，停止循环，把分歧原样交给用户，不要为了"通过"而做你认为错误的修改。
5. 如果 codex 在 Disputed 里给出了新证据，要重新核验，不能因为之前拒绝过就坚持原判。

## 6. 汇报

在给用户的最终汇报末尾附上简短的 review 摘要：

```
Codex review（gpt-6-astra xhigh）：N 轮后通过
- 已修复：<条目 — 一句话说明>
- 已拒绝：<条目 — 理由>
- 需要你决定：<有争议的设计取舍，没有就省略>
- 顺带发现：<超出范围的既有问题，没有就省略>
```

如果 review 没有完成（CLI 出错、达到轮次上限），直接说明，不要写成"已通过"。
