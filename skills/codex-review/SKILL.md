---
name: codex-review
description: 在代码任务完成时，调用 Codex CLI 在冻结的工作区快照上对本次改动做独立 review，后台运行、不阻塞汇报和后续工作：首轮按改动的风险分档（quick 用 gpt-6.1-sol，standard 用 gpt-6-astra high，deep 用 gpt-6-astra xhigh，skip 不审）全面审查，之后只用 gpt-6.1-sol high 核验必要的修复；逐条核验意见，拒绝无意义的防御性编程，修复有效问题后再提交核验，循环直到通过。当你修改了代码并准备汇报"已完成"时使用，用户说"让 codex review""codex 审一下"时使用，或用户让你处理夜间 review 报告时使用。
user-invocable: true
argument-hint: "[--base <branch> | --commit <sha>] [--tier quick|standard|deep] [额外关注点]"
---

# Codex Review 循环

**用户参数：** $ARGUMENTS

在你认为任务完成时启动。codex 在冻结的快照上后台运行，启动后你就可以先向用户汇报（注明 review 仍在进行），review 结果出来后再处理。目标是让一个独立的强模型挑错，但由你负责判断哪些意见值得采纳。Codex 是审阅者，不是决策者。

以下情况跳过：本次没有改动代码（纯问答、纯调研），定档结果是 `skip`（见第 1 节第 4 步），或用户明确说不需要 review。

## 1. 准备

1. **先跑确定性检查，全绿再启动 codex。** 按仓库规范（AGENTS.md / CLAUDE.md / CI 配置）跑格式化、lint、类型检查和相关测试，有失败就先修好。不要把 linter 和测试能抓到的问题留给 codex 花几分钟去找；也不要在 codex 运行期间才发现测试挂了，那样修复后 codex 审的就是旧代码。
2. 在 scratchpad 目录（没有就用 `mktemp -d`）下建一个工作目录 `$DIR`，每轮使用 `$DIR/round-N-prompt.md` 和 `$DIR/round-N-review.md`。
3. **确定范围，记下两个快照**：基线写进 `$DIR/base`，第 1 轮快照写进 `$DIR/round-1.tree`。本次 review 的范围始终是 `git diff <base> <round-1.tree>`。

   | 范围 | `$DIR/base` | `$DIR/round-1.tree` |
   |---|---|---|
   | 默认：所有未提交改动 | `git rev-parse 'HEAD^{tree}'` | `"${CLAUDE_SKILL_DIR}/scripts/snapshot.sh"` |
   | `--base <branch>` | `git merge-base <branch> HEAD` | 同上（包含未提交改动） |
   | `--commit <sha>` | `git rev-parse <sha>^`（根提交没有父提交，用空树 `git hash-object -t tree /dev/null`） | `git rev-parse '<sha>^{tree}'` |

   - `snapshot.sh` 输出一个 git tree id，包含已跟踪的改动和未跟踪的文件，不会动真正的 index、HEAD 或 stash。
   - 之后每一轮（N≥2）启动前也记一次快照 `$DIR/round-N.tree`。第 N 轮要核验的修复，就是 `git diff <round-(N-1).tree> <round-N.tree>`。
   - `--commit` 指的不是 HEAD 时，之后各轮的快照还包含这个提交之后的改动，核验轮的 diff 末尾要用 `-- <修复涉及的文件>` 限定。
   - 上一个任务的 review 还没结束你就开始了本任务时（见第 3 节"等待方式"），基线用本任务开始改代码前记下的快照，而不是 HEAD。
   - 工作区里混有**不属于本次任务**的改动（对照会话开始时的 git status）时，记下本次任务涉及的文件，定档和 prompt 里的 diff 都在末尾加 `-- <文件...>`。
4. **定档**：按变更本身（而不是"这是我写的"）决定首轮审查力度：

   ```bash
   "${CLAUDE_SKILL_DIR}/scripts/classify.sh" "$(cat "$DIR/base")" "$(cat "$DIR/round-1.tree")" [-- <文件...>]
   ```

   脚本输出 `tier=`、`lines=`、`files=`、`reason=` 和 `notes=`（仓库审查备注的路径）。

   | 档位 | 默认条件 | 首轮 | 核验轮 |
   |---|---|---|---|
   | `skip` | 改动的文件全是文档、许可证、lockfile、快照、图片 | 不跑 codex，测试和 lint 全绿即可 | 无 |
   | `quick` | 不超过 50 行，且没碰敏感路径 | `gpt-6.1-sol` `high` | 无，修复靠测试把关 |
   | `standard` | 其他普通改动 | `gpt-6-astra` `high` | 按第 5 节规则（`gpt-6.1-sol` `high`） |
   | `deep` | 超过 400 行，或碰了鉴权、密钥、计费、数据迁移、CI、部署/发布/安装脚本等敏感路径 | `gpt-6-astra` `xhigh` | 按第 5 节规则（`gpt-6.1-sol` `high`） |

   - 用户参数里的 `--tier` 优先于脚本结果。
   - 这次改动要作为 PR 提交到**别人维护的仓库**时（例如 `git remote -v` 里有 `upstream`，或 origin 不属于用户），至少用 `deep`：那里消耗的是维护者的时间。
   - 你知道脚本看不出来的风险时（例如改动很小但涉及并发、缓存失效、数据删除），可以往上调档，并在汇报里说明原因；不要往下调。
   - 敏感路径、skip 列表和行数阈值可以在仓库的审查备注里覆盖，格式见 `scripts/classify.sh` 文件头。
5. **读审查备注**：`classify.sh` 输出的 `notes=` 非空时，读这个文件。frontmatter 之后的正文是这个仓库跨会话积累的审查规则（项目约定、"这类问题不要报"及其原因），每一轮都原样放进 prompt 的 `Repo review notes` 一节。
6. 维护一份**处理记录**（ledger），每轮都要带给 codex：
   - 已修复：`[轮次] 标题 — 怎么修的`
   - 已拒绝：`[轮次] 标题 — 拒绝理由（具体说明为什么不成立或不必要）`

## 2. 写 review prompt

`codex exec review` 的 `--uncommitted/--base/--commit` 不能和自定义 prompt 同时使用，所以范围写在 prompt 里。

只有第 1 轮全面审查整个改动。从第 2 轮起，codex 只核验上一轮之后的修复，不再重审没动过的代码。

### 2a. 第 1 轮：全面审查

```markdown
You are reviewing code changes made by another engineer. Do not modify any files.

## Scope
Review the change `git diff <base> <round-1 tree>`<如有需要：` -- <文件...>`，并写明 "Only these files belong to this change.">.
The current directory is a read-only checkout of <round-1 tree>; read files there for context. It is a frozen snapshot, so `git status` and `git diff HEAD` tell you nothing about the change. Ignored files (dependencies, build outputs, local config) and submodules are not checked out; do not report their absence.

## Intent of the change
<2-6 句：用户要什么、你做了什么、关键的设计取舍>

## Repo review notes
<审查备注正文；没有备注就删掉这一节>
Follow these notes: they record what this repo does and does not want reported, and why.

## Review guidance
- Report only issues that are real and actionable: bugs, behavioral regressions, broken edge cases that can actually occur, security problems, concurrency/resource issues, clear violations of this repo's conventions (AGENTS.md / CLAUDE.md), and missing tests for new behavior.
- Do NOT suggest defensive programming for states the types, callers, or invariants already rule out (redundant null/empty checks, try/catch that just swallows or logs, fallback values for impossible cases, re-validating trusted internal inputs). If you think an invariant does not hold, show the concrete path that violates it.
- Do NOT report pure style preferences or speculative refactors.
- For each finding, give file:line, a concrete triggering scenario, and the fix.
- Start each finding's title with exactly one tag: [Important] (a real bug, regression, security or data problem this change introduces), [Nit] (a minor real issue: a misleading name, a small missing test, an unclear error message), or [Pre-existing] (a real problem in code this change did not introduce).
- Add a line "Class: <bug class>" to each finding (e.g. "unescaped shell interpolation", "missing await on async call"), and list every place in the change with the same class of bug, not just the first one you saw.
- If there are no actionable issues, say explicitly: "No actionable issues found."

```

### 2b. 第 2 轮起：只核验修复

```markdown
You are verifying fixes another engineer made after a previous code review. Do not modify any files.

## Scope
Review only the fix delta since the previous round: `git diff <round-(N-1) tree> <round-N tree>`<如有需要：` -- <修复涉及的文件>`>.
Both ids are git tree snapshots. The current directory is a read-only checkout of <round-N tree>; ignored files and submodules are not checked out.
Read surrounding code only as far as you need to judge the delta. Do not re-review code the delta does not touch.

## Intent of the change
<和第 1 轮相同的 2-6 句>

## Fixes to verify
<上一轮修复的条目：标题、原问题一句话（含触发场景）、怎么修的>

## Repo review notes
<审查备注正文；没有备注就删掉这一节>
Follow these notes: they record what this repo does and does not want reported, and why.

## Review guidance
- For each fix: does it actually resolve the original finding, including its triggering scenario? Is it complete?
- Report new problems only if the delta introduces them: bugs, behavioral regressions, broken edge cases that can actually occur, security problems, and missing tests for the fix.
- Do not report issues in code the delta did not change, unless the delta now relies on that code in a way that breaks.
- Do NOT suggest defensive programming for states the types, callers, or invariants already rule out (redundant null/empty checks, try/catch that just swallows or logs, fallback values for impossible cases, re-validating trusted internal inputs). If you think an invariant does not hold, show the concrete path that violates it.
- Do NOT report pure style preferences or speculative refactors.
- For each finding, give file:line, a concrete triggering scenario, and the fix.
- Start each finding's title with exactly one tag: [Important] (a real bug, regression, security or data problem this change introduces), [Nit] (a minor real issue: a misleading name, a small missing test, an unclear error message), or [Pre-existing] (a real problem in code this change did not introduce).
- Add a line "Class: <bug class>" to each finding (e.g. "unescaped shell interpolation", "missing await on async call"), and list every place in the change with the same class of bug, not just the first one you saw.
- If every fix holds and the delta introduces no actionable issue, say explicitly: "No actionable issues found."

## Rejected items
<所有轮次中已拒绝的条目和理由；没有就写 "None.">
Do not re-raise them unless you have a NEW concrete argument (a reproducible scenario or evidence the rejection reasoning is wrong). If you still disagree, state it once under "Disputed" with that evidence.
```

用户在参数里给出的额外关注点，加到两个模板的 Review guidance 里。

## 3. 运行

```bash
# 第 1 轮：第三个参数是档位 quick | standard | deep，第四个是本轮快照
"${CLAUDE_SKILL_DIR}/scripts/run_review.sh" "$DIR/round-1-prompt.md" "$DIR/round-1-review.md" <tier> "$(cat "$DIR/round-1.tree")"
# 第 2 轮起
"${CLAUDE_SKILL_DIR}/scripts/run_review.sh" "$DIR/round-N-prompt.md" "$DIR/round-N-review.md" verify "$(cat "$DIR/round-N.tree")"
```

（`${CLAUDE_SKILL_DIR}` 指本 SKILL.md 所在目录。如果它没有被替换成实际路径，就用本文件旁边 `scripts/` 下脚本的绝对路径。）

- 脚本把快照检出到临时 worktree（`$DIR/round-N-review.wt`，跳过 hooks 和 LFS 下载），在那里运行 codex，退出时删除 worktree。codex 读的是冻结的快照，所以你在它运行期间改代码不会影响它。如果脚本被强行中止，`git worktree list` 里可能留下这个 worktree，用 `git worktree remove --force <路径>` 清理。
- 仓库很大、检出明显很慢时，可以省略第四个参数，让 codex 直接读真实工作区。这时 prompt 的 Scope 要改成读当前工作区，而且在它结束前**不要改动被审文件**。
- 脚本按档位选模型和思考强度（见第 1 节的档位表），在只读沙箱里运行，打印 codex 的最终结论，最后一行是 `[codex-review] mode=… model=… effort=… seconds=… input_tokens=…`，汇报 review 摘要时用得上。stderr 在 `$DIR/round-N-review.log`，事件流在 `$DIR/round-N-review.events.jsonl`。为了从 codex 的 session 记录里读出 token 用量，脚本不再用 `--ephemeral`，所以 review 线程会留在 `~/.codex/sessions` 里。
- 脚本自带硬超时（`deep` 默认 1800 秒，其他 900 秒，可用 `CODEX_REVIEW_TIMEOUT` 覆盖），保证进程一定会退出，从而一定会触发完成通知。

### 等待方式：后台运行，不阻塞，不要轮询

`deep` 档的 xhigh 通常要 5–10 分钟，改动大时更久，可能超过前台 Bash 最长 10 分钟的上限；其他档位和核验轮也统一按同样方式运行。因此：

1. **每轮都用 Bash 的 `run_in_background: true` 启动脚本。** 进程退出后，Claude Code 会自动重新唤醒你，这个通知就是唯一的等待信号。
2. 启动后，**禁止**做以下任何事：
   - 用 `sleep`、`while` 循环、Monitor 或 ScheduleWakeup 去检查进度；
   - 反复 `tail`/`cat` 日志或输出文件，或用 `ps`/`pgrep` 查 codex 是否还在跑；
   - 在结束前读取 `round-N-review.md`（codex 结束时才写入，中途读到的要么不存在，要么是旧内容）。
3. **不要干等。** codex 审的是冻结的快照，所以：
   - 第 1 轮启动后，就向用户汇报任务结果，并明确写"codex review（<tier> 档，通常需要 X 分钟）正在后台运行，结果出来后我会处理并补充 review 摘要"。不要写成已经通过 review。然后结束本轮回复，不要为了等待而保持回合开着。
   - 等待期间用户提出新任务，可以直接开始做。开始改代码前，先用 `snapshot.sh` 记下新任务的基线，供新任务 review 时用作 `base`，这样两个任务的 review 范围不会混在一起。
4. 收到完成通知后，读取通知里的输出（即脚本打印的最终结论），退出码非 0 时再看日志尾部，然后进入第 4 节。如果你正在做别的任务，先把手头这一步做完，不要留下改了一半的文件，再处理 review 意见。
5. 意见指向的是快照里的代码，文件路径可能带着临时 worktree 的前缀（`…/round-N-review.wt/`），去掉前缀就是仓库内的相对路径。核验时以当前代码为准：先确认那段代码还在、问题仍然存在，行号可能已经变了。
6. 如果用户中途问进度，只回答"仍在运行"。只有用户明确要求时，才看一次日志尾部。

- 如果失败（认证、网络、模型不可用、超时退出码 124），先看日志尾部。可以用环境变量覆盖模型和思考强度（`CODEX_REVIEW_<MODE>_MODEL`，例如 `CODEX_REVIEW_DEEP_MODEL`；`CODEX_REVIEW_MODEL` 改所有档位的默认模型；思考强度用 `CODEX_REVIEW_DEEP_EFFORT` / `CODEX_REVIEW_EFFORT`（standard）/ `CODEX_REVIEW_QUICK_EFFORT` / `CODEX_REVIEW_VERIFY_EFFORT`），但**只在用户同意后**才降级；否则停止循环，并在汇报里说明 review 没有完成。
- 输出格式通常是 `- [P0..P3] [Important|Nit|Pre-existing] 标题 — 文件:行`，加一段说明和一行 `Class:`。

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

codex 给的标签只是参考，判定以你的核验为准：
- `[Pre-existing]`：核实确实不是本次改动引入的，就按"超出范围"处理。
- `[Nit]`：成立且修起来很便宜就顺手修，否则列进汇报。Nit 的修复不会触发核验轮。
- **按类别修，不要只修一行。** 修复一条有效意见时，按它的 `Class:` 在本次改动涉及的代码里搜索同类问题（grep 相同的调用、模式或写法），一次修完所有实例。否则下一轮 codex 会再报同类问题的另一处，白白多一轮。改动之外的同类既有问题，列为"顺带发现"。

## 5. 修复并复审

1. 修复所有"有效"项，按仓库规范跑相关的格式化和测试（例如 AGENTS.md 要求的 `just fmt`、`just test -p ...`），全绿后再进入下一轮。
2. **判断要不要核验轮。** `quick` 档从不跑核验轮，修复后测试全绿即通过。其他档位，只有本轮修了至少一条 Important，而且修复不是一眼就能确认对错的（例如改了控制流、接口、并发或错误处理，或修复超过约 20 行），才进入核验轮。如果修的只有 Nit、只有测试，或只是几行机械修改（改名、补参数、修常量），测试全绿就视为通过，不再跑 codex。
3. 需要核验轮时：更新处理记录，记录快照，然后用 2b 模板进入下一轮（轮次 +1）。如果两次快照之间还夹着别的任务的改动，diff 末尾用 `-- <修复涉及的文件>` 限定范围，并在 Fixes to verify 里写清楚哪些改动属于修复。核验轮里 codex 对改动之外代码提出的意见，按"超出范围"处理。
4. **通过条件**，满足任一即可：
   - codex 明确表示没有可操作的问题；
   - codex 剩下的意见全是此前已拒绝的项，且没有提出新的具体证据；
   - 剩下的只有"超出范围"或"有争议的设计取舍"项。
5. **上限 3 轮**（首轮加 2 次核验）。到了上限仍未收敛，往往说明方案本身有问题，而不是还差一处修复：停止循环，不要继续打补丁，把分歧原样交给用户，并说明你是否认为应该换一种实现思路。不要为了"通过"而做你认为错误的修改。
6. 如果 codex 在 Disputed 里给出了新证据，要重新核验，不能因为之前拒绝过就坚持原判。

## 6. 汇报

review 结束后给出简短的 review 摘要。如果第 1 轮启动后你已经先汇报过任务结果，就单独发一条消息，只写 review 摘要和因 review 而做的改动，不要重复整份汇报：

```
Codex review（<tier> 档：<reason>；首轮 <model> <effort>，<秒数>s，<输入 token 数>k in / <输出 token 数>k out）：N 轮后通过
- 已修复：<条目 — 一句话说明>
- 已拒绝：<条目 — 理由>
- 需要你决定：<有争议的设计取舍，没有就省略>
- 顺带发现：<超出范围的既有问题，没有就省略>
- 建议写入审查备注：<可复用的拒绝理由，没有就省略>
```

**沉淀审查备注**：如果某条拒绝理由是这个仓库的通用规律，而不只是这一处代码的事实（例如"内部 RPC 的入参已在网关校验，handler 里不要再校验"或"本项目只支持 Linux"），把它写成一条可以直接放进备注的规则，列在"建议写入审查备注"里，用户同意后再写入：
- 用户自己维护的仓库：写进仓库根目录的 `REVIEW.md`（没有就新建，只写正文；需要覆盖定档规则时才加 frontmatter）。
- 别人维护的仓库（例如开源贡献）：写进 `$(git rev-parse --path-format=absolute --git-common-dir)/codex-review/REVIEW.md`，它不会进入提交和 PR。仓库根目录已有 `REVIEW.md` 时，私有文件不会被读取，先告诉用户。

如果 review 没有完成（CLI 出错、达到轮次上限），直接说明，不要写成"已通过"。

最后记一条会话统计（`run_review.sh` 已经自动记下每轮的耗时；`skip` 档也要记，`rounds=0 result=skipped`）：

```bash
"${CLAUDE_SKILL_DIR}/scripts/record_stats.sh" kind=session session="$DIR" repo="$(git rev-parse --show-toplevel)" \
  tier=<tier> reason="<classify 的 reason>" lines=<lines> rounds=<N> result=<passed|cap|failed|skipped> \
  fixed=<已修复数> rejected=<已拒绝数> nits=<Nit 数> preexisting=<顺带发现数>
```

用户问 review 花了多少时间、档位阈值合不合适时，跑 `"${CLAUDE_SKILL_DIR}/scripts/stats.sh"` 看汇总。

## 7. 处理夜间 review 报告

`scripts/nightly.sh` 由 cron 每晚运行，用 `deep` 档审查各仓库当天合入的提交，报告写在 `<报告根目录><仓库根目录的绝对路径>/<日期>-<sha>.md`（同名的 `.prompt.md` 是当时的 prompt）。报告根目录默认是 `~/.codex-review/nightly`；用户的 crontab 里设置了 `CODEX_REVIEW_NIGHTLY_DIR` 时以它为准（拿不准就 `crontab -l` 看一下）。例如仓库 `/home/me/proj` 的报告在 `~/.codex-review/nightly/home/me/proj/`。用户让你处理夜间报告时：

1. 列出当前仓库对应目录下还没有处理过的报告（文件名不以 `.handled.md` 结尾，也不是 `.prompt.md`）。
2. 按第 4 节逐条核验。报告针对的是当时的提交，代码之后可能又改过：以当前代码为准，先确认问题仍然存在。
3. 把有效项当作一个新任务来修，修完照常走本 skill 的流程（先跑检查，定档，review）。
4. 向用户汇报：已修复、已拒绝（附理由）、需要用户决定的项，以及建议写入审查备注的规则。
5. 把处理完的报告改名为 `<原名>.handled.md`。
