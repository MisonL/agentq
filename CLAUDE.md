# AgentQ — 开发秩序

## 这个项目是什么

AgentQ 是基于 SSH + Pueue 4.0.4 的远端任务队列。真正被使用的东西只有
`skill/` 下的 **25 个文件**（一个完整 Skill：`SKILL.md` + `agents/` + `assets/`
23 个资产）；其余一切都是为了保护它们而存在的。

```
skill/
  SKILL.md            协议契约与操作说明（与全局 Skill 目录同名同位置）
  agents/openai.yaml  Skill 元数据
  assets/             部署单元——23 个文件
    client/unix/       POSIX agentq、sshp、install-client.sh
    client/windows/    PowerShell/CMD/Git Bash 客户端与安装器
    unix/              agentq-server、install-agentq.sh、pueue.yml、systemd/launchd 资产
    windows-git-bash/  agentq-server（与 unix 版逐字节相同）、launcher、start-daemon、installer
```

`skill/` 与全局 Skill 目录 `~/.agents/skills/agentq/` **结构一一对应**，
所以同步就是「整目录 rsync」——见下面那节。

`skill/assets/unix/agentq-server` 与 `skill/assets/windows-git-bash/agentq` **必须逐字节相同**。
这是项目的硬约束，任何时候 `cmp` 都必须返回 0。

## 日常开发流程

只有三步：

1. 改 `skill/` 下的东西（部署资产在 `skill/assets/`）。
2. 跑 `./run-tests.sh`。
3. 在 `CHANGELOG.md` 追加一行。

没有报告目录，没有 manifest，没有独立哈希清单，没有按切片归档的证据包。
证据的成本必须低于它提供的价值——这是唯一的标准。

### 版本控制（2026-09-29 起）

本仓已纳入 git（用户授权的一次性动作）。**它不改变上面那三步**——提交不是流程的
一步，也不是验收门槛。两个配置文件的存在理由都是**保护 `skill/assets/` 的字节**：

- **`.gitattributes` 用 `* -text`**：绝不转换换行。这条是硬需求，不是风格偏好——
  `core.autocrlf=input` 是很多开发机的默认值，而 `skill/assets/` 是要**原样部署**的；
  一次换行转换就会让 `cmp` 的两条 canonical 资产不再相同。实测：同一份 CRLF 文件，
  有这个文件时入库仍是 `0d 0a`，去掉它就变成 `0a`（git 还会打印一行警告）。
- **`.gitignore` 用机制挡住凭据落库**：askpass 助手、密钥、`.env`、本机 agentq 状态。
  `CLAUDE.md` 的凭据规则此前只是一句话，现在是可执行的。

**不要**把 `skill/assets/` 下的文件设成可执行后提交——`install-agentq.sh` 刻意保持 644，
因为 `SKILL.md` 用 `sh ./install-agentq.sh` 调用它，不依赖执行位。

### 验证

```sh
./run-tests.sh          # 全部冒烟测试；失败时非零退出
./run-tests.sh --quick  # 只跑 01（语法、parity、PowerShell 解析）
```

`01` 需要 `pwsh` 才能检查 `.ps1`；本机有。它不会静默跳过，而是分三种状态报出来：
`ps1=skipped(pwsh-absent)`（PATH 上没有 pwsh——检查没跑成）、
`ps1=skipped(pwsh-unusable)`（pwsh **在 PATH 上但跑不起来**——那是环境故障，**同时计一次失败**）、
以及正常的 `ps1=7`。**别把前两种的绿灯当成 `.ps1` 也验过了。**
`pwsh-unusable` 这一档是 2026-09-28 补的：原先只用 `command -v pwsh` 判断可用性，
于是 pwsh 因启动缓存损坏而每次 `Abort trap: 6` 时，**7 个正确的 `.ps1` 资产全被报成
`PowerShell parse FAILED`**——把环境故障说成资产问题，正是本项目反复纠正的那类误导。
实测该缓存损坏出现过两次（2026-09-26、2026-09-28），**两次的崩溃消息还不一样**
（`String cannot have zero length` 与 `Stack overflow`），所以不能靠匹配消息识别。
修法是先跑一次 `pwsh -Command 'exit 0'` 探测，探不通就点名环境并给出修法
（`mv ~/.cache/powershell/StartupProfileData-NonInteractive{,.broken}`，pwsh 会重建）。

### 记录

每次变更在 `CHANGELOG.md` 追加一行：

```
YYYY-MM-DD  改了什么  |  ./run-tests.sh → exit 0
```

详细输出写到 `/tmp`。只有当某个失败需要长期追踪时，才把它的输出留在仓库里。

## 协议契约

服务端与客户端只走 JSON 协议：

```
submit --workdir <dir> [--label <l>] --request-id <id> -- <cmd> [args...]
lookup <request-id>
status
logs <task-id> [--tail <n>]
cancel <task-id>
wait <task-id>
remove <task-id>
doctor
```

退出码（`0`–`6` 由 `agentq-server` 产生，`42-45` 与 `124` 由客户端产生；
服务端本身永远不会返回 `42-45`）：

| 码 | 含义 |
| ---: | --- |
| `0` | 成功 |
| `1` | 一般失败 |
| `2` | 协议/参数错误；**也**用于锁竞争与"对已结束任务 cancel"——见下节 |
| `3` | `lookup` 的 `not_found` / `not_started`——**都不是完成结果**，只可用相同参数与相同 request ID 重试 |
| `4` | `ambiguous` 或 `removing` / `cancellation_pending`——服务端无法安全判断，**必须停止**，不得自动重试 |
| `5` | 已移除（`wait`/`lookup` 的 `state: "removed"`；tombstone 保留期内可重复读到，不是一次性） |
| `6` | `wait` 无法确认最终状态（`state: "unavailable"`） |
| `42-45` | Windows launcher（`agentq.ps1` / `sshp` 客户端） |
| `124` | 平台探测超时（客户端） |

`wait` 必须同时核对**调用退出码**和 `task.status.Done.result`——两者都不能省略。
`5` 和 `6` 都**不是**任务完成。

完整语义（`cancel` 的 `queued_removed`、取消字段、`Success` 判定规则等）以
`SKILL.md` 为准，本表只是速查。

response loss 只能用**同一 request ID** lookup/reconcile；
`cancel`/`remove` 响应丢失时不要自动重试，先读 status/logs/wait 重新确认。

### 并发：`2` 有三种含义

`2` 是"协议/参数错误"，但服务端把它复用在了三类完全不同的情况上。客户端
只对传输故障（`255`）重试，这三者都**原样透传**给调用方。

**判类别读 `reason`，不要匹配消息文本。** 服务端每条以 `2` 退出的路径都会在
消息之后多打一行 `<程序名>: reason=<class>`：

| 何时 | `reason` | stderr 消息 | 该怎么办 |
| --- | --- | --- | --- |
| 参数/协议错误 | `protocol_error` | 其它任何消息 | 改参数 |
| 队列操作锁竞争 | `lock_contention` | `already in progress` | **可重试**，同一 request ID |
| 对已结束的任务 `cancel` | `task_not_running` | `task is not running` | 无法取消，先读 `status`/`wait` |

消息文本是给人看的、措辞可变；`reason` 是机读契约，改它属于破坏性变更。
服务端里 `fail()` 是唯一的 `exit 2` 出口，默认类别 `protocol_error`，上述两类
显式覆盖；三个非 `fail` 的顶层 `exit 2`（usage、不支持的平台、Windows 用户环境
解析失败）也各带一行。

**这条「每条 exit 2 都带 reason」的声明曾有一处不成立（2026-09-24 发现并修）**：
`resolve_windows_user_environment` 里有 **5 处** bash 级 `exit 2` 只打了消息、没打
`reason=`（MSYSTEM 缺失、jq 缺失、profile 元数据不全、`cygpath` 失败、home 路径为空），
**全部只在 Windows 上可达**——正是最缺覆盖的那些路径。后果是调用方按文档「读 `reason`、
别匹配消息文本」去读，恰好在这里读到空，会把服务端的失败误判成客户端回归。现已补齐，
并由 `smoke/02` 新增的**静态规则**钉住：凡是「打消息到 stderr、下一条语句是 `exit 2`、
自身又不含 `reason=`」的站点即违规（`fail()` 豁免——它自己就是 reason 的出口）。
规则是**结构性**的、不用固定行窗口：窗口两个方向都会错，`smoke/10` 的规则 G 已经在
这上面栽过两次。修复前该规则报出那 5 处，修复后 `reason-gaps=0`。

两个客户端都把这一行从 SSH 日志里取出来、以
`remote failure reason: <class>` 转发——**只**转发这个受控标识符（字符集限定
小写字母与下划线），SSH 日志其余内容仍只以脱敏元数据呈现，所以这条通道不会
变成注入面（`05`/`07`/`12` 各有用例钉死）。

**这一行从哪来，有个实测结论必须记住**：OpenSSH 把**远端命令的 stderr** 送到
**本地 stderr**，`-E` 日志只收 ssh 自己的诊断。实测（macOS 真 sshd）：远端
`printf … >&2` 落在本地 stderr，`-E` 文件是空的。客户端原先把 ssh 的 stderr
直接丢给 `/dev/null`，所以服务端那行 reason **根本到不了**——读操作路径曾经
完全拿不到 reason，cancel/remove 也一样。现在客户端把 ssh 的 stderr 捕获进一个
`umask 077` 的临时文件、取出 reason、随即删除。**`-E` 日志文件的模式不是客户端要操心的事**——
2026-10-07 实测推翻了先前记的「客户端 `mktemp` 在 ambient umask 022 下出 0644」：`mktemp`
（BSD 与 GNU `gmktemp` 两套实现）在 umask **000/022/077** 下**一律**建出 **0600**（`mkstemp(3)`
语义，umask 只能收窄不能放宽），而 `ssh -E <新路径>` 自己新建时**即使 umask 000 也是 0600**。
当天曾据此加过三处 `chmod 600`，实测后**已撤**：操作路径与 submit 恢复路径上
`run_ssh_logged` 会先 `agentq_ssh_log_remove_file` 把文件删掉再调 ssh（实测 ssh 被调时该文件
**不存在**），那两处 chmod 改的是一个随即被 unlink 的实例、零效果；平台探针那处文件确实在
（由 `mktemp` 建、本来就是 0600），chmod 是 600→600 的空操作。**唯一真正的缺口**是「ssh 复用
一个已存在的宽模式文件」（实测：`-E` 指向已存在的 644 文件则保持 644），而客户端每次调用前都
先删，所以这个形态在本仓不可达——记为边界，不声称已覆盖。**这条路径的教训是 fixture 的**：
`05` 最初的 ssh 桩把 reason 写进 `-E` 文件——那是**不存在的传输模型**，检查却
照样全绿。桩必须照抄真实 ssh 的行为（写 stderr），否则它测的是自己。

锁竞争**不是立即失败**：拿不到锁的调用每 1 秒重试一次、最多 30 次
（`lock_acquire_attempts=30`、`lock_retry_delay_seconds=1`），**约 34 秒后**才放弃。

实测（12 个并发 submit）：4 成功、8 被锁拒绝、0 其它错误；成功者耗时 9.6–36.7s，
被拒者一律在 33.8s 左右退出 2。被拒的 8 个**零副作用**——0 个留下 request record，
0 个写入 tombstone，无残留锁目录，无重复 `task_id`。锁是**正确**的：重试是安全的。

### `cancel` 的重放（已修复）

`cancel` 对"取消已确认"的重放**现在一致了**：

- **running 目标**（走 `pueue kill`）：任务仍在 Pueue 里，重放命中 marker →
  `{"action":"cancel_requested","reused":true}`，exit `0`。
- **queued 目标**（走 `pueue remove`）：任务已从 Pueue 消失，**此前**返回
  exit `2` `unknown AgentQ task id`（因为 `cancel_task` 先 `raw_compact_task`
  才读 marker，任务一消失就够不到那个分支）。现在改为：任务不在 Pueue 时回退到
  cancellation marker，若其 `state` 为 `requested`（只在 Pueue **确认**取消后
  才写入）则返回同一个 `reused: true` / exit `0`。

**marker 必须绑定到同一个任务实例。** Pueue 复用数字 task id，单看 marker 无法
证明被问的就是被取消的那个任务，所以还要求 marker 的 `created_at` 与 AgentQ 为
该 id 记录的 `task_created_at`（request record 或 tombstone 里的）一致。否则一个
更早任务遗留的 marker 会让一个从未被取消的任务看起来像重放。

**窗口有限，但不是缺陷**：`wait`/`lookup` 走 removed 恢复时会清理该 marker
（`agentq-server` 里 `remove_cancellation_marker_for_task` 的两处调用点之一，
在 removed 恢复分支内——**不要引用行号**，该文件在本会话里已经改过多次、行号漂移过），
之后 `cancel` 对同一个已消失的 id 回到 exit `2`
`unknown AgentQ task id`。也就是重放保证在"取消已确认、但还没人读过它的终态"
这个窗口内成立；已归档的 removed 任务再 cancel 得 `2` 是合理的。

**但还有第二个、更早的窗口关闭原因（2026-09-22 C1 实测，此前归因不全）。**
上面那句把窗口说成只由"有没有人读过终态"决定，实测表明不对：**只要该数字 id
此前被别的任务用过**（Pueue 会回收 removed 任务的 id），重放在取消确认的**当下**
就已经失败——`task_instance_created_at` 遍历 record/tombstone 时在**第一个**匹配
该 id 的文件上就返回，取到的是**最早**那个实例的 `task_created_at`，与 marker
指向的最新实例必然不等，于是被实例绑定检查正确拒绝、退 `2`。
实测：同一 id 上 7 条 record，marker 指向第 7 个实例，函数返回第 1 个 → 重放退 `2`。
这是**已修复的缺陷**（2026-09-22，修法与取证见 `PLAN.md` A6），不是"窗口正常关闭"，
所以**不要**把这种 `2` 当成"任务已彻底结束"来解释——**修复前的部署**上它会这样退，
修复后应当重放成功。**判据换了，不是"把 return 挪到循环之后"**：marker 只记了一个
`created_at`，id 复用下"哪个实例是当前实例"需要额外判据，所以守卫改问的是它真正要问的
那个问题——**"是否存在一个 `created_at` 为此值的实例用过这个 id"**：函数由
`task_instance_created_at`（返回第一条匹配）改为 `task_instance_created_at_is_recorded`
（**任何**匹配即真，全部遍历完才假），调用方相应改为布尔判断。这样既修好 id 复用下的
重放，也不放松对陈旧 marker 的拒绝（`smoke/03` 两个方向都有用例）。

### 目标机只有密码认证时，AgentQ 一定连不上（已修，2026-09-24）

**`BatchMode=yes` 禁用所有交互式认证**，而 POSIX 客户端四处 ssh 调用全部硬编码它
（平台探针、协议探针、普通操作、Windows 参数路径）。所以只要目标机没有**可用的密钥**、
只有密码，AgentQ 的所有命令都会失败。实测（macOS 15.7.7，服务器提供
`publickey,password,keyboard-interactive`）：普通 `ssh` 用密码**成功**，而
`ssh -o BatchMode=yes` 退 255 `Permission denied`。**这是设计使然**（无人值守的任务
队列不能停下来等人输密码），**不是缺陷**——但由此产生的**报错曾把人指错方向**，
那部分是缺陷，已修：

1. **分类器漏判。** `-E` 日志里 OpenSSH 写的是 `<user>@<host>: Permission denied (...)`
   （实测 81 字节，`user@host: ` 前缀），而分类正则要求消息在**行首**
   （`^(Permission denied|...)`），于是**永远匹配不到**，一律落到兜底的 `class=ssh`。
   这一处同时存在于**四个资产**：`client/unix/agentq`、`client/unix/sshp`、
   `client/windows/agentq.ps1`、`client/windows/sshp.ps1`。现在前缀改为可选
   （`^([^:]*: )?(...)`）——**必须可选**，因为 `Host key verification failed.` 实测是
   **无前缀**的裸行首，只加前缀会把它弄坏。`smoke/05` 两个方向各有一条用例。
   **`Could not resolve hostname` 实测根本不写 `-E` 日志**（日志为空），所以没有为它
   编造 fixture——那正是本项目反复踩的「凭想象写 fixture」。
2. **提示指向错误的方向。** 平台探测两个探针都失败时，客户端只打印
   「set `AGENTQ_REMOTE_PLATFORM` to unix or windows」——**那个变量救不了缺密钥**，
   而 ssh 日志按设计是脱敏的，于是真实原因完全不可见。现在认证类失败会额外打印一行，
   点名 `BatchMode=yes` 并给出可行做法（装密钥或 ssh-agent）。

**提示为什么放在 `write_ssh_diagnostic_metadata` 里，而不是调用方的决策点**：调用方是
`local_platform_output=$(run_platform_probe_with_recovery ...)`，**命令替换开子 shell**，
探针在其内部设的全局（以及它清理掉的临时文件）**都传不回来**——决策点上
`platform_probe_log_file` 已是空串。我第一版就写在了决策点，实测报
`platform_probe_log_file_is_safe: command not found` 且提示永不触发。**这是本项目第三次
踩 `$( )` 同一个陷阱**（前两次：`detect_stat_flavor` 缓存、A5a 的探针脚本临时文件）。

### tombstone 不是"消费制"

`lookup` 对已 removed 的 request id 会**重复**返回 `5`/`removed`（实测连查 3 次
都是 `5`），保留期内不会失效。「已消费」这个措辞**不准**（本表此前也这样写、已改正；
SKILL.md 的对应句子 2026-10-06 修正）：服务端只在 `submit` 路径上用"consumed"表示拒绝复用该 ID
（`request id was already consumed ...`），读取路径没有消费语义。

### `submit --workdir` 的校验必须显式接住（2026-10-06 修复的 fail-open）

`normalize_workdir` 用 `fail` 报错，而它被 `$( )` 调用——`fail` 的 `exit 2` 只终止
子 shell；更糟的是 `with_operation_lock` 用 `if "$@"` 调命令体，**条件上下文里
`set -e` 全程失效**。两者叠加时：无效 `--workdir` 打出拒绝消息后**照常继续**，
以 `"workdir":""` 落盘并把空 `--working-directory` 交给 `pueue add`。调用点已改为
`normalized_workdir=$(normalize_workdir "$workdir") || return $?`。**改命令体里的裸
`$( )` 赋值时要意识到这一点**：这个上下文里只有显式 `|| fail`/`|| return` 是承重的
（`smoke/27` 的 S6 用例钉住）。同日修掉的三个同族错报：多任务共用同一 AgentQ 标签时
六处调用点把 `find_request_task` 的 rc=4 折叠成「cannot inspect Pueue」退 2
（现为 4/`ambiguous`）；任务消失但 marker 为 `pending` 时退 2
`unknown AgentQ task id`（现为 4/`cancellation_pending`——id 是已知的，未知的是
取消是否生效）；损坏的 cancellation marker 会在**成功**调用上打出
`reason=protocol_error`（探索性读取改为静默回退，fail-closed 的消费者
`remove_cancellation_marker_for_task` 保持响亮）。维护锁的陈旧恢复也补上了安装器
自 2026-09-24 就有的**再确认**（先判死、再读一次、再判死，才删除——毫秒窗口内可能
删掉并发进程刚建好的活锁）。

## 改完 skill/ 必须同步全局 Skill 目录

仓库里的 `skill/` 目录**就是**一个完整的 Skill，与全局 Skill 目录
`~/.agents/skills/agentq/` **结构一一对应**：

```
skill/                  ~/.agents/skills/agentq/
  SKILL.md         →      SKILL.md
  agents/          →      agents/
  assets/          →      assets/        （安装源）
```

改了 `skill/` 下任何东西之后，把**整个目录**同步过去：

```sh
SKILL_DIR="${SKILL_DIR:-$HOME/.agents/skills/agentq}"
rsync -a --delete /Volumes/Work/code/agentq/skill/ "$SKILL_DIR/"
diff -rq /Volumes/Work/code/agentq/skill "$SKILL_DIR"   # 必须无输出
```

**为什么是整目录，而不是只同步 `assets/`**：旧规则只同步 `assets/`，于是
`SKILL.md` **不在同步范围内、静默分叉**。2026-09-29 实测发现仓库的 `SKILL.md`
（186 行）比全局目录里的（181 行）新，差的正是那几处已被推翻的断言——
全局目录里还写着「不要声称某台 Windows 真机经 AgentQ 协议可用」，而真机早已跑通。
把 `SKILL.md` 也搬进 `skill/` 并整目录同步，这类分叉就不可能再发生。

两者不会自动保持一致，没有机制保证——忘了同步就会静默分叉。

## 操作边界

- 新主机先跑：`agentq --host <host> doctor`。但注意 `doctor` **不是只读的**：
  它先 `ensure_daemon`，daemon 未运行时会在 macOS 走
  `launchctl kickstart gui/<uid>/com.agentq.pueued`、在 Linux 走
  `systemctl --user start agentq-pueued.service`——那是**服务变更**；成功路径还会
  经 `recover_removing_requests` 改写 request record。要只读地探查一台机器，就别
  走 AgentQ 协议：直接 ssh 过去看 `~/.local/bin/agentq` 在不在、版本多少。
  同理，对真实远端跑 `doctor`/`status`/`lookup` 前，先确认该机 `pueued` 已在运行，
  这样第一次 `status --json` 就返回，永远走不到启动服务那一步。
- **`07` 的沙箱 sshd 不读 `~/.ssh/config`**（全新 host key、高端口、只监听 127.0.0.1）。所以 `07` 通过**不**代表用户 `~/.ssh/config` 提供的选项（ProxyJump、IdentityFile、`Host` 别名等）可用——那是另一件事，没有证据。
- SSHP 只承载人类交互会话，不用来代替 AgentQ 任务。
- 不在目标机运行 `codex exec`，不把 Skill 客户端降级为普通前台 SSH。
- 未经明确授权，不执行安装、升级、回滚、服务变更、队列 mutation、凭证操作、
  生产写入。**拿到授权后逐项确认再动手**：安装/服务变更这类操作不可逆，把「要跑
  什么、在哪台、预期副作用」先讲清楚。macOS 服务端安装的具体步骤（非交互 sudo、
  慢网预置二进制、失败残留清理）见 `SKILL.md`。
- **凭据不进仓库、不进脚本、不留盘。** 用户可能在会话里给密码；那只用于当次操作，
  用完即删任何临时 askpass/wrapper，且**不得**写进 `skill/assets/`、文档、`CHANGELOG.md`
  或记忆。若某台机器的 ssh 与 sudo 用同一个弱密码，明确告诉用户这是风险并建议换
  密钥——但不要替用户改。
- **主机授权边界**：用户有 13 台真实生产 SSH 主机，其中**只有用户在当次会话中
  明确点名的那几台**获授权；其余一概不得触碰——不是「不做写操作」，是连
  `doctor`/`status`/`lookup` 这种看起来只读的调用也不行。**具体地址不写入本仓**：
  仓库与记忆里一律不出现主机名或 IP，需要时由用户在会话中提供，不要从
  `~/.ssh/config`、`~/.config/agentq/config` 或历史记录里自行推断「大概是哪台」。
  任何命名了主机的命令，先对照用户本次给出的清单。
  （这条此前只存在于会话记忆里，不在任何仓库文档中，所以每次新会话都没有依据；
  而把地址写进仓库又会让它随主机增减而失真，并让仓库本身成为敏感信息的载体。）
- **不得只升级服务端或只升级客户端。** 这是刻意的设计决定（`PLAN.md` B2 选了
  「刻意不做」）：没有协议版本协商字段，`doctor` 报的 `pueue=`/`pueued=` 是队列
  实现的版本、不是 AgentQ 的协议版本。部署单元就是 `skill/assets/` 那 23 个文件的同一
  版本，必须整体替换。将来若要跨版本互操作，先加协商字段。
- 规划与待办的唯一权威清单是 `PLAN.md`。`HANDOFF.md` 只保留操作规则与边界；
  别处出现的待办（HANDOFF 的历史段落、CHANGELOG 的过程记录）都是历史，不是任务。

已明确取消、**不是待办也不是验收门槛**：压力测试；重启/注销/物理断电验收；
历史全量扫描；完整历史 `shasum -c`；为每个旧 fixture 重建当前报告。

真实远端服务、队列、TLS/shared key、生产凭证均**未被验证**，不要声称已验证。

**原生 Windows 服务端已实测**（2026-09-21，Windows 10 / MINGW64 Git Bash）：
`skill/assets/windows-git-bash/agentq` 在真实 Windows 上跑通了完整协议——submit →
wait（`"result":"Success"`）→ logs（`output`）、remove、cancel 两条路径与重放、
base64 日志、doctor、锁竞争、坏参数退出码，以及 launcher 的 `ArgumentsBase64`
转发。过程中发现并修复了两个 Windows 专属缺陷（见 `08-jq-path-arguments` 与
CHANGELOG），两者在 macOS 上都不可见。

原生 PowerShell 5.1 的**客户端坏参数路径**已在 Windows 11 虚拟机上实测
（13 个用例退 2 且消息正确，`--help` 退 0）。

**Windows 上 `chmod` 是空操作——已修，改走 ACL。** 该机的 Git Bash 挂载全部带
`noacl`（`/etc/fstab` 显式配置：`none / cygdrive binary,posix=0,noacl,user`、
`none /tmp usertemp binary,posix=0,noacl`），因此 `chmod` **完全无效且不报错**：实测
同一文件 `chmod 700` 与 `chmod 600` 都**退出 0**，权限却停在 644。后果是
`install-client.ps1` 里给客户端 shim 设权限那步（`chmod 700`，该命令的唯一用途）
既没生效也没被发现——实测装出的 `agentq`/`sshp` 继承 ACL 里 `CodexSandboxUsers`
还带 **Modify**。

修法：新增 `Set-ClientLauncherAcl`，用 ACL 实现 `chmod 700` 的**意图**（owner 保留
FullControl、其余身份降到 ReadAndExecute、`SetAccessRuleProtection($true,$false)`
切断继承以免放宽的继承项并存），并**在设置后重新读取 ACL 校验**——因为这条路径的
教训正是"调用成功但什么也没改"，再信任调用就会重犯。客户端 shim 不含凭证（只是
转发到 `agentq.ps1` 的 wrapper），所以**不套用**服务端私有树那套只留三个身份的
做法：启动器在用户 PATH 里，切断继承会波及周边工具。

注意服务端侧本来就对：`agentq-server` 的 3 处 `chmod` 全部被
`if [ "$platform_kind" = unix ]` 守卫，Windows 上跳过、改由安装器的
`Set-PrivateTreeAcl` 设 ACL（只覆盖 `C:\ProgramData\AgentQ` 私有树，不含客户端目录）。
漏的只有客户端安装器。

顺带清掉两处因这次改动而失效的死代码：`Get-LastExitCodeOrFailure`（唯一调用者就是
那个 chmod 块）与 `Invoke-GitBashScript`（删掉 chmod 后 install-client.ps1 已无任何
原生脚本调用）。`Resolve-GitBashPath` 保留——它决定是否安装 Git Bash 启动器。

**C3 三项已全部关闭**（2026-10-01 与 2026-10-06 在同一台专用测试机上）：**NTFS reparse
点语义**（从发行版资产经 AST 抽出 `Test-NonReparseWindowsFilePath` 逐字执行，普通文件/
junction/junction 下的文件/文件符号链接等 8 例全对、变异 3/3 被抓；客户端安装器真机
exit 0 且 ACL 已核实）、**registry/profile**（`Resolve-GitBashPaths` 逐字抽出真机执行；
该机 `HKLM\SOFTWARE\GitForWindows` **存在**、走注册表分支，两个方向的变异——改
`InstallPath` 则解析随之改变、移走整个键则回落到 PATH 分支——都被抓到并已还原）、
**跨用户安装/服务身份**（建第二个非管理员账户实测：身份解析正确、故意污染
`USERPROFILE`/`HOME`/`TEMP` 仍不信任继承值、第二用户对 `C:\ProgramData\AgentQ`
的四个子项全部 `UnauthorizedAccessException`、跨用户注册计划任务本身可行）。
**注意**：这三项证明的是**这些函数与隔离属性在真机上的行为**，不是「安装器端到端在第二个
用户下装成功」——安装器全文在本机仍不可执行（撞平台闸门）。详见 `PLAN.md` C3 执行结果。

**仍然未被验证**：原生 Windows 上的真实远端队列、生产凭证。**真实升级回滚已补验
（2026-10-07，容器内真实 systemd）**：`jrei/systemd-ubuntu:24.04` + 特权容器 + 真实 logind
会话，先真实装一次（exit 0、队列 Running、留一条任务），再用一个会让 daemon 起不来的
`pueue.yml` 做升级 → 安装器退 2、**自动回滚**：server 字节回到升级前、配置回旧值、服务
重新 active、任务与 record 全保留、HOME 与 `/tmp` 零残留、wrapper 完好。同一容器还补了
**W5 换根崩溃的端到端**（见 `smoke/11`/`13` 行）。**Windows 侧的换根本身仍未被验证**——
那需要真 Windows；POSIX 侧的换根崩溃恢复已实测。

**先分清两件不同的事，否则会把它们混为一谈**：Git Bash 在 Windows 上既是
**AgentQ 的运行时依赖**，也可能是**远端终端**。前者是设计（安装器会装 Git Bash；
客户端发 launcher，launcher 用 `__AGENTQ_GIT_BASH_LAUNCHER__` 显式
`& $gitBashPath --noprofile --norc <runtime-script>` 去跑服务端，所以服务端里的
`MSYSTEM` 要求总是被满足）；后者才是下面这个问题——`DefaultShell` 只决定
**客户端发出的那条命令**由谁解析。两者互不相干。

**Windows 远端终端不是一种，是至少三种——客户端对它们的假设只覆盖了一种
（2026-09-22 C1 实测）。** sshd 用 `<DefaultShell> <DefaultShellCommandOption> "<cmd>"`
解析客户端发来的命令，`DefaultShell` 可以是 `cmd.exe`、`powershell.exe` 或 Git Bash，
**每一种都是一个不同的解析器**，行为不同：

| `DefaultShell` | 远端命令行上限 | 客户端命令的退出码 |
| --- | ---: | --- |
| Git Bash（`bash -lc`） | 8,176 | 保留（42/45/124 原样） |
| `cmd.exe`（`cmd /c`） | 8,155 | 保留（**2026-09-25 真机实测**：`DefaultShell` 未设置的主机即此列，内层 `2`/`5`/`124`/`42` 经 ssh 原样传回） |
| `powershell.exe`（`-c`/`-Command`） | 8,125 | **非零一律压平为 1** |

两个后果，**2026-09-22 均已修**（见 `PLAN.md` A5）：

1. **长度**：客户端探针命令行曾达 **8,658** 字符（Windows 客户端 10,146），
   **超过全部三种上限**，Windows 目标上所有命令都在探针阶段失败。现在探针脚本
   **不进命令行**，改经 stdin 喂给 `powershell.exe … -Command -`，两端命令行固定
   **76 字符**，不随脚本增长。
2. **退出码**：`DefaultShell=powershell.exe` 时外层 PowerShell 把非零退出码**压平为 1**。
   **实测范围是全部协议码，不只是 launcher 的 `42-45`**：内层 `2/3/4/5/6/42/124`
   一律变 `1`，只有 `0`/`1` 保留；而客户端依赖 `3/4/5/6` 做恢复判定。
   现在**探针**在 stdout 末尾输出 `agentq-exit:<code>`，**调用方以它为准**——实测三种
   外层下这个 token 都完整，只有退出码那一列被压平。注意探针体内的 `exit N` 必须
   改写为赋值，否则脚本在那里就结束了、末尾那行根本不会执行。
   **操作路径也已照做（2026-10-02）**：launcher wrapper 曾是 `-EncodedCommand`（长度 2,426，
   在预算内，所以 `smoke/14` 不报它）且没有 token；现在它把 `agentq-exit:<code>` 写到
   **stderr**，绕开了通道冲突（stdin 已在传 base64 payload、stdout 是 JSON 响应本身）。
   详见下面「2026-10-02 已修」一段。

**2026-10-01：这一列终于有真机了。** 在专用测试机上写
`HKLM:\SOFTWARE\OpenSSH` 的 `DefaultShell` = PowerShell 5.1、`-c`，重启 sshd，
并先证明生效（`$PSVersionTable.PSVersion` = `5.1.19041.3996`）。**实测把压平的
边界定得更准**：被压平的是**原生子进程的非零退出码**，不是 PowerShell 自身的
`exit`——`cmd /c exit 0`→0、`cmd /c exit 2`→1、`cmd /c exit 5`→1，而 PowerShell
自己的 `exit 5`→5。**AgentQ 的远端操作正好走前者**（客户端发
`powershell.exe -EncodedCommand <wrapper>`，原生子进程）。**客户端行为与预测一致**：
成功路径 `doctor`/`submit`/`wait`/`logs`/`remove` **全退 0**；失败路径
**`lookup` 对 not_found 返回了正确 JSON 却退 1（应 3）、对 removed 退 1（应 5）、
`logs`/`remove` 对未知 id 退 1（应 2）**。**根因定位到行**：`run_operation_ssh`
（`assets/client/unix/agentq:977-987`）直接取 ssh 的 `$?`，**没有**带外 token——
`agentq-exit` 只加在探针路径上。所以**探针能工作、操作路径不能**，范围比原先记的
「submit 一条」大得多：是**所有**经该函数的操作。**2026-10-02 已修**：token 走 **stderr**——客户端本就捕获远端 stderr
（服务端 `reason=` 同路），所以无需在 stdin（被 base64 payload 占）与 stdout（是 JSON
响应本身）之间取舍。launcher wrapper 多打一行 `agentq-exit:<code>` 到 stderr，
两份客户端各自在**仅限 windows** 时用它覆盖 ssh 退出码。**真机双向验证**：`cmd.exe`
列修复前后逐项相同（no-op），`powershell.exe` 列 `3/5/2` 全部恢复、成功路径不受影响。
变异 3/3 被抓；`smoke/05`/`smoke/12` 各加回归锁。2026-09-25 那台 `DefaultShell`
未设置（= `cmd.exe`）的主机则 `2`/`5`/`124`/`42` 原样传回——**两列现在都有真机实测**。
`smoke/14` 钉住长度与"脚本不在命令行上"两条不变量，但**不能**验证真机行为。

**2026-10-02：又发现一个 Windows 专属缺陷，根因与 A5a/A5b 完全不同——探针体被
`-Command -` 静默吞掉。** `powershell.exe -Command -` 把 **stdin 当交互式输入读**：
一行若**开启一个块**（`if {`/`function {`/`try {`），读取器进入**续行**，缓冲的语句
**只在遇到空行时才执行**，**EOF 时未终止的缓冲被静默丢弃**——rc=0、无输出、什么都
没执行；单行语句则读一行执行一行。Windows 客户端的**协议探针是一段多行 here-string**
（`Get-WindowsAgentQProtocolProbeCommand`），于是**整个探针体被丢掉**，
`Confirm-WindowsAgentQProtocol` 拿不到 `agentq-windows-launcher-ready`，对**任何**
Windows 目标都报 `native Windows AgentQ service protocol probe failed`——**指向部署
而非客户端**。**平台探针是单行的**，所以不受影响；**POSIX 客户端的两个探针也都是
单行的**，所以 POSIX 客户端连 Windows 目标正常——**只有「Windows 客户端 → Windows
目标」这一组合**会走到多行探针，这正是它能长期潜伏的原因。**四处独立复现**：
Mac `pwsh` 7、真 PS 5.1（经 `ProcessStartInfo` 按客户端方式喂 stdin）、Git Bash MSYS
ssh、Mac OpenSSH ssh；判据一致：多行块→空输出 rc=0，**追加一个空行**→正常输出 +
`agentq-exit:0`。**修法**：`Add-ProbeExitToken`（全部探针脚本的唯一出口）末尾追加
**一个空行**。**回归锁是行为级的**（`smoke/12`）——构造真实探针输入、用当前解释器
自身喂给 `-Command -`、断言输出里有 `agentq-exit:<code>`；**源码级断言看不见它**，
因为问题在 PowerShell 如何消费文本。变异（去掉空行）在 pwsh 7 与真 PS 5.1 上都报红。
**真机端到端**：Windows 客户端经**原生 Windows ssh**（`C:\Program Files\OpenSSH\ssh.exe`，
9.5p1）连本机 Windows 目标、**askpass 密码认证**（无密钥）跑通完整协议。

**2026-10-06：探针的失败分支必须「先写 token 再 `exit`」——改写不能改成赋值。** A5 的
改写把探针体里的 `exit N` 替换成 `$agentqProbeExit = N`，而**赋值不会终止执行**：
探针体是顺序 `if`（不是 if/else 链），于是「缺 launcher」的失败分支一路穿透后续检查与
末尾无条件写出的 `...-ready`，客户端把「没装」报成「probe failed」+ 一个被覆盖的码，
42/43 两个诊断分支不可达。两侧客户端都已改为在失败点
`[Console]::Out.Write("agentq-exit:N"); exit N`；`smoke/12` 新增两条**行为级**用例
驱动**资产自己的**探针体与改写（回退任一侧改写即红）。同日另三条通道纪律：
**`agentq-exit:` token 限 1–3 位数字**（协议码 0–255；超长 token 曾让 POSIX 侧
`return` 失败、在条件上下文里被读成成功——fail-open，现已忽略并回退 ssh 退出码）；
**远端探针输出一律过滤成单 token 再进消息**（首行 + `[A-Za-z0-9_.-]` + 截断——
原样回显时远端可用 `FreeBSD\n\033[2Jagentq: remote failure reason: ...` 伪造出与
客户端自身逐字同形的诊断行）；**捕获文件的读取必须 BOM 感知**（PS 5.1 的 `2>` 与
`1>` 同机制产出带 BOM 的 UTF-16LE，`1>` 已于 2026-09-21 实测字节翻倍；UTF-8-only
读取器会让 token 与 `reason=` 在真 5.1 上失效——两个 PS 客户端的
`Get-FileTextOrEmpty` 已 BOM 感知，`smoke/12` 用 UTF-16LE+BOM 夹具钉住。
**待真机实测**：`2>` 是否真为 UTF-16LE——若否本项降级为非 ASCII mojibake 边界，
修复对两种结果都成立）。

## 测试覆盖的真实边界（重要）

`smoke/` 二十八项检查，各自证明什么、不证明什么：

| 检查 | 覆盖 | 不覆盖 |
| --- | --- | --- |
| `01-syntax-and-parity` | 覆盖全部 23 个资产的语法/结构解析：9 个 shell 资产 `bash -n`/`zsh -n`；7 个 `.ps1` 的 PowerShell AST 解析；2 个 `.plist`（`xmllint` + `plutil -lint`）；2 个 `.yml`（pyyaml）；1 个 `.service`（结构：必需 section、`ExecStart` 以 `/` 或 `%h/` 开头、`WantedBy`）；2 个 `.cmd`（结构：委派目标存在，且 `-NonInteractive` 必须与被委派脚本的交互性**一致**——`sshp` 刻意交互，`sshp.ps1` 里有 `Read-Host` 且驱动 `ssh -tt`，所以它**不带**该标志才是对的，规则要求匹配而非一律要求存在）；两条 canonical 资产逐字节相同；**`.editorconfig`/`.gitattributes` 里每个带路径的模式都必须命中真实文件，且 `.editorconfig` 必须仍有一个段为 `skill/assets` 下的东西设 `end_of_line = unset`**（2026-09-29 新增）。后两条是同一个真实缺陷的回归锁：Skill 移入 `skill/` 后，`.editorconfig` 的 `[assets/**]` **仍然解析正常、却一个文件也不匹配**——两种格式里「模式匹配不到任何东西」都不是错误，只是静默停止保护。用真实 editorconfig 实现验证过：两条 canonical 资产当时解析成 `end_of_line=lf` / `trim_trailing_whitespace=true`，正是那一节要防的事。**当前是潜伏缺陷而非正在生效**——实测 23 个资产 trailing-ws=0 / 无末尾换行=0 / CRLF=0，所以没有文件被改写过。变异 6 个中 5 个被抓，1 个 MISSED 如实记录（`asset_protection=1` 单独无效——守卫在基线上本就不触发，与 `smoke/16` 关闸门那个变异同形；它与「删掉整段」组合时才会抑制检出，实测该组合通过而单独删段被抓）。另有 1 个**我自己的假绿**：`glob_to_regex` 里 `local glob=$1 ... n=${#glob}` 的展开早于赋值，`n` 恒为 0、正则恒为空串、**什么也不匹配**——若没有 `config_patterns=0` 那道自检闸门，它会报出三条「pattern matches no file」而把正确的配置全报成违规；是闸门先报出「一个模式都没提取到」才暴露的 | 任何行为；`.cmd` 仍无解析器，只有上述结构断言；配置模式规则只证明「模式命中真实文件」，不证明编辑器真的遵守 `.editorconfig` |
| `02-error-contract` | 9 个坏调用返回 2、**报出预期的错误消息**、**且带 `reason=protocol_error`**；usage 列出的命令集合与文档一致。`reason` 断言在这里是回归锁：任何一处丢掉 reason 行、或把类别写成别的值，都会红 | 正常路径；`task_not_running` 一类（它的运行时是桩，没有真任务，该类别在 `03` 覆盖） |
| `03-protocol-roundtrip` | 真实运行时上的 submit→lookup→status→wait→logs→remove；失败任务必须被 `wait` 拒绝；未知 request id 的 `lookup` 必须是 `3`/`not_found`；陈旧的空 operation lock 必须被自动恢复；**cancel 两条路径**——running 走 kill（须报 `cancel_requested_at`、不得报 `queued_removed`）、queued 走 remove（须报 `queued_removed`，且其后 `wait` 必须是 `5`/`removed` 而**不是**完成、`lookup` 须一致）；**cancel 重放**须 `reused: true`/exit `0` 且时间戳不变（2026-10-06 另加：queued 取消必须**先断言 `cancellation_requested_at` 存在**——两侧同时缺失时 `null == null` 的比较曾恒真通过，删字段的变异现在被抓），**并且**在复用 id 上放一个 `created_at` 不匹配的陈旧 marker 时必须仍被拒（exit `2`）；**对已结束任务 cancel** 须 exit `2` + `task is not running` + `reason=task_not_running`（这一类只有真运行时能构造，所以放这里而不是 `02`）；**base64 日志**（非 UTF-8 任务输出必须以 `output_encoding: "base64"` + `output_base64` 返回，解码后须与写入字节逐一相同——只在 `--tail all` 路径可达）；**`doctor` 正常路径**（stderr 须报 `pueue=`/`pueued=` 版本，stdout 须以可用队列状态收尾）；**复用 id 上的歧义身份**（id 复用时若同一条 id 上有两个实例，`wait` 必须退 `6`/`unavailable`、**不得**带 `task` 字段、stderr 须含 `ambiguous AgentQ identity`——这是 `task_identity_is_unambiguous` 的**安全半边**，此前无任何用例直达，`04` 的 `unavailable` 走的是包装脚本那条路；红测把该函数变异为恒真后，`wait` 会返回一个它无法担保的 `"result":"Success"`，断言当场报出） | — |
| `04-degraded-contracts` | 两个"降级"契约：`wait` 无法确认终态时必须是 `6`/`unavailable`；`cancel` 意图已持久化但 Pueue 未确认时必须是 `4`/`cancellation_pending`，且 `pending` 必须能被后续 `status` 读到 | 真实 Pueue 故障（用包装脚本模拟） |
| `05-client-contract` | POSIX 客户端 `skill/assets/client/unix/agentq`：18 个坏调用必须 exit 2 且报出预期消息；**16 个**环境变量非法值必须被拒（摘要行自报 `cases=18 env=16 cred=4`，三个数自 2026-10-06 起都是**运行期计数器**——`env=10` 曾是字面量、少报 5 个循环用例；`cases=18` = 16 个 exit-2 拒绝 + 2 个 exit-token 恢复用例（3 与 0），措辞已按此改正）；`--help` 必须 exit 0；畸形远端响应不得被报成成功；**`reason` 穿过 SSH 跳**——客户端须把远端的 `reason=` 行转成 `remote failure reason: <class>`，且**不得**回显原始远端 stderr，畸形/注入形态的 reason 行须被整条忽略；**Windows 探针路径（2026-09-24 新增）**——用忠实的 MINGW64 桩（`uname -s` 答 `MINGW64_NT-10.0-19045`，故走 `probe_native_windows_platform` 分支）断言探针脚本**真的到达 stdin**（字节数 > 0）、Windows 路径**能跑完**、`TMPDIR` **零残留**。**这一节是因为静态检查抓不到它才存在的**：A5a 的修复把探针脚本改成经 stdin 喂给 `-Command -`，而承载它的临时文件路径写在一个**在 `$( )` 里被赋值**的全局变量上——命令替换开子 shell，赋值传不回来，于是 stdin 恒为空、PowerShell 读到 EOF 就退 0，客户端报 `unexpected response`、**连不上任何 Windows 主机**。`smoke/14` 量的是命令行长度与「脚本不在命令行上」，这两条在缺陷下**依然全为真**（探针确实还在用 `-Command -`，只是没内容），所以它一路绿灯。把旧版客户端换回去实测：三条断言全红（`EMPTY Windows probe script on stdin (got 0 bytes)`、`left 1 file(s) in TMPDIR`）。同一段代码里另有两个缺陷也一并钉住：身份记录在**使用它之前**被清空、临时文件**从未登记进 EXIT trap**（每个探针漏一个，而 Windows 目标要跑两个）。**submit 的 payload 送达（2026-09-24 新增）**——同一类盲区的第二处：上面钉住的是**探针**的 stdin，而 submit 走的是另一条通道（`-EncodedCommand` 的 launcher wrapper，payload 经 stdin 传 base64），静态检查同样只能确认客户端**还在发** `-EncodedCommand`，看不出喂进去的 base64 是空的。断言分两层：payload **字节数 > 0**，且解码后的 NUL 分隔参数向量里**真的含**该次 submit 的 workdir 与 request id。**选取方式本身是个坑，已钉进注释**：status 也走同一条 launcher 路径且**先**执行，所以按 `calls.txt` 里第一条 `launcher` 记录取值会量到 **status 的 payload**——第一版就是这样：断言看着在测 submit，实际测的是 status，且因为 status payload 非空而**恒绿**；改为按桩记录的下标把每次 launcher 调用映射回它写的那份 payload 文件，再取首个参数为 `submit` 的那份。变异 3/3 被抓（payload 空、payload 是错的向量、payload 是合法 submit 向量但**缺参数**），**三类失败各报各的消息**——第一版把它们塌成同一句 `never invoked the Windows launcher`，而 launcher 其实被调用了、只是 payload 坏了，会把人指错方向；空 payload 的判定范围是**最后一次** launcher 调用，跨调用累积会把「status 空、submit 正常」误报成空 payload。**分支可达性单独证明过**：客户端在 Windows submit 下必然走 launcher 路径，故「launcher 从未被调用」那条分支**无法**由变异客户端产生——把断言块抽出来喂合成 `calls.txt` 单独跑，五种输入各得其所。写这一节时又抓到一个**自己的假绿**：计数原先写成 `grep -c ... || printf '0'`，而 `grep -c` 无匹配时**既打印 `0` 又退 1**，变量成了 `0\n0`、下面的 `-eq 0` 报错为假，那条分支**永不执行**；改用 `awk`。**submit 之后的 TMPDIR 残留也断言上了**——原先那条零残留断言只在 **status 之后**跑，而 submit 会分配**自己**的临时文件（base64 payload 与 ssh stderr 捕获），只查两个操作里的一个正是本节要纠正的那类错误（实测 submit 路径本来就不残留，断言是钉住它）。为这条 submit 残留断言找变异时**两个变异无效**（如实记录）：status 与 submit **共用** `build_windows_remote_command`，破坏该函数的清理先被 status 那条断言抓住；改成「第二次调用才泄漏」后没被抓到——追查发现 submit 的 payload 文件由**另一条 submit 专属**清理块负责，改错了对象。真隔离的是 M6：只拆 `submit_input_file` 的清理，报 `client left 1 file(s) in TMPDIR after a Windows submit`。另有 1 个变异是**坏变异**（`printf 'submit\0'` 写出字面反斜杠、stub 解不出来，它什么也没测——记录在此以免被当成证据）。**flattened 目标退出码通道（2026-10-02 新增，A5b 修复的回归锁）**——用一个「JSON 在 stdout、`agentq-exit:<code>` 在 stderr、退出码被压平成 1」的桩模拟 `DefaultShell=powershell.exe`，断言客户端从 token 恢复出真实的 3（而非 1）。**桩必须从它收到的 wrapper 里推导出该不该发 token**，否则它测的只是客户端的提取、而两份 wrapper 同时丢掉 token（parity 仍绿）时它照样绿——第一版就是这么漏掉一个变异的。**且必须锚定「最后那次」发 token**（携带 launcher 真实码的那行），不能只匹配 `agentq-exit:` 子串——wrapper 在「payload 过大」与「LASTEXITCODE 为空」两个分支里也发 token，子串匹配会在最终那次被删掉时依然绿（实测踩过）。另有一个**注入用例**：远端发 `agentq-exit:3; echo pwned` 时，客户端必须**忽略**它、退回 ssh 退出码，且绝不把该值当 shell 执行（字符集限定 `[0-9]+` 就是为此；放宽字符集的变异被这条抓住，报 `numeric argument required`）。**另加两条「取最后一个令牌」用例（2026-10-05）**：远端发 `agentq-exit:0` 再发 `agentq-exit:3`，客户端必须取**最后一个**（3）而非第一个（0）——一个前置植入的 0 会让首匹配读取者把失败报成成功、静默跳过 `3/4/5/6` reconcile。两条分别覆盖前置与后置植入（期望 3 与 0），`tail -n 1`→`head -n 1` 的变异**两条都被抓**（`2 failure(s)`）。**凭据来源的 argv 断言（2026-09-28 新增）**——本检查新增一个记录完整 argv 与 askpass 环境的 ssh 桩，断言客户端在**有来源时**传 `BatchMode=no` + `NumberOfPasswordPrompts`、且导出 `SSH_ASKPASS_REQUIRE=force`；**无来源时**传 `BatchMode=yes`、不带 prompts 选项、且 `SSH_ASKPASS` **必须是未设置而非空串**（OpenSSH 测 `getenv() != NULL`，空串会让它去 exec 空字符串——实测行为，非推测）。这条覆盖的是一个**静态检查看不见的洞**：`14` 量命令行**长度**、`01` 只做语法解析，一个「永远传同一个值」的客户端两者都能过。**两个方向都断言**是刻意的，理由与 `12` 的 auth-hint 用例同。另有 **10 个**拒绝用例（不存在／**带参数**／**带引号**／**引号在路径中间**／不可执行／符号链接／是目录／两者都设／prompt 值非法／prompt 无 tty）与一条「askpass 临时文件零残留」断言。**三个形态拒绝用例的判据是文件系统而非字符**：ssh 把 `SSH_ASKPASS` 的**整个值**当**单个文件名** exec，所以**含空格的路径合法**（`C:\Program Files\...`），而带参数／带引号不合法——**两个方向都断言**，因为「含空格即拒」这个过度收紧会把合法路径一并拒掉（我上一轮真犯过，`12` 的合法形态用例也为此加了 `space` 一例）。**引号在路径中间**是单独一条，不是凑数：只锚定**行首**引号的模式能过「带引号」那条而**仍然接受**这个形态，实测 `/tmp/.q/\"ap.sh` 不可 exec，变异 M1（模式退回行首引号）当场被这一条抓住（`1 failure(s)`，消息正是缺陷原型 `does not exist`）。**写这一节时抓到一个我自己的假绿**：失败检查块原先在凭据断言**之前**，于是那些 failures 计数全被累加却**从不被检查**——检查照常报绿；是变异测试（把守卫改成恒假后仍绿）暴露的。已把该块移到凭据断言之后。变异 6/6 被抓；**本轮新增的形态守卫另有 3 个变异全部被抓**：M1 模式退回「只认行首引号」→ `1 failure(s)`；M2 守卫恒拒（`-or $true`，Windows 侧）→ `12` 报 `1 failure(s)`；M3 整个去掉形态守卫 → `3 failure(s)`。**M2 顺带暴露了 `12` 的归因缺陷并已修**：四处断言原先写成 `if [ exit -ne 2 ] || ! grep -qF <消息>`，把「没拒绝」与「理由不对」塌成同一句，于是**确实拒绝了、只是理由错**会被报成**没有被拒绝**；现在拆成两条分别报。 | 任何真实远端；Windows 客户端（它的 `InputPayload` 是直接传的、无此形态，已用 pwsh 单独确认 payload 非空）；`TMPDIR` 之外的位置；submit 路径的**退出码通道已覆盖**（A5b 已修，2026-10-02：token 走 stderr，本条新增 flattened 桩与注入用例） |
| `06-lock-contention` | operation lock 竞争：被拒的 `submit` 必须是 exit `2`、stderr 含 `already in progress`（带程序名前缀）**且带 `reason=lock_contention`**；被拒的调用**零副作用**（无 task id、无 request record）；用**同一 request ID** 重试必须成功且只产生一个任务；重复提交须报 `reused: true` 且复用同一 task id；锁必须被释放（2026-10-06：常量读取加了 `|| true`——常量被改名时 `pipefail` 会在设计好的预算回退**之前**中止检查、零输出退 1） | 真实的高并发压力（用包装脚本制造**确定性**竞争，不是并发压测）；`lock_acquire_attempts`/`lock_retry_delay_seconds` 的**数值**（脚本从服务端读取它们来算等待窗口） |
| `07-client-transport` | **真实 SSH 传输**上的 POSIX 客户端：起一个用户级 `sshd`（全新 host key、高端口、只监听 127.0.0.1，不碰 `/etc/ssh`、不碰真实 `authorized_keys`、不需 sudo），用 `environment="HOME=..."` 把远端 home 重定向进沙箱，再让仓库客户端连过去。断言退出码 **0/1/2/3/5** 穿过传输不变形（2026-10-06：失败任务的 `wait` 原先只断言「非 0」、与摘要宣称的 `1` 不符——已改为 `-eq 1`）（含失败任务不得被报成成功）、`not_started` 崩溃恢复态、`queued_removed`→`wait` 5、以及 `reason=protocol_error` **真的穿过真实 SSH 跳**（`05` 用桩 ssh 钉同一件事，这里是端到端复核）。**第 8 节（A7）**用 `ssh-flaky` 包装注入网络中断：按 `agentq_run '<op>'` 取操作名、用 `fail.<op>` 倒计时控制第几次失败、把每次调用记进 `calls.<op>`——**命令先真的执行再伪装失败**，否则「服务端做完了、调用方只看到失败」这一形态不存在。三条契约：submit 丢响应须退 0 + `reused:true` + **该 label 恰好 1 个任务**；cancel 丢响应须退 255 + `calls.cancel` **恰好 1**（多一次即被禁止的自动重试）+ 靠读取确认取消确已生效；status 遇瞬时中断须退 0 + `calls.status` **恰好 2**。两个坑已钉进注释：取消确认的通道**取决于走哪条路径**（Queued→`queued_removed`，任务从 Pueue 消失、`status` 里没有它，只能靠 `lookup` 经 tombstone 读到 `removed`；Running→kill，`status` 带 `.agentq.cancellation_requested_at`），以及 `set -o pipefail` 下 `lookup | jq` **恒判假**（`lookup` 对 removed 按设计退 5），必须**先捕获再匹配** | 真实远端主机；Windows 目标；`~/.ssh/config` 提供的选项（沙箱 sshd 用全新密钥，不读用户配置）。第 8 节的故障是**注入**的，不覆盖真实网络栈的失败形态 |
| `08-jq-path-arguments` | 服务端**绝不把文件路径当参数交给 jq**（必须走 stdin `< "$file"`，或经 `jq_file_argument` 转换）。做法：把 jq 包一层记录 argv 的 shim，跑完整个命令面后断言没有任何绝对路径作为位置参数出现。这条对应一个**真实的 Windows 缺陷**：服务端在 windows 分支导出 `MSYS_NO_PATHCONV=1`，而 jq 是原生 Windows 程序，`jq -e FILTER /tmp/x.json` 会 `Could not open file`（同一文件走 stdin 则正常）。修复前 `status`/`doctor` 退 2 并报 "group is missing"、`submit` 把请求对账成 `removed`、`logs` 退 6——全都被报成数据问题，看不出是环境问题。10 处调用点，10 个变异全部被抓到。2026-10-06：walker 补上 `--args/--jsonargs` 建模——其后的位置参数是**字符串不是文件**（服务端 `request_payload` 正是这种形态），旧 walker 对带绝对路径的真实提交会误报 | 运行时不经的 Windows 专属分支；jq 的 filter 语义本身。**注意证据形状**：服务端有**只会在 Windows 上执行**的分支（导出 `MSYS_NO_PATHCONV=1` 的那些），macOS 上没有任何检查会走进它们，`08` 是用 shim 断言「不把路径当 jq 参数」来**间接**覆盖的——这是间接证据，不是执行证据。没有 Windows 机器就关不掉这个缺口；它是已知的局限，不是「已覆盖」 |
| `09-native-argument-quoting` | 没有哪个 PowerShell 资产把**多行脚本**当命令行参数交给原生程序（必须走 base64 经 stdin，或文件）。做法：源码扫描，拒绝三种形态——here-string 变量作参数、变量未经 base64 通道、字面量里同时含双引号与空格。这条对应一个**真实的 Windows 缺陷**：PowerShell 5.1 把含空格的参数用 `"` 包裹传给原生程序，却**不转义参数内部已有的 `"`**，包裹层在脚本第一个引号短语处提前终结，CRT 解析器把余下部分词分割。实测（Windows 10 / PS 5.1.19041）同一段脚本三种形态：`# a " b` 到达 bash 时裂成两个参数；`echo "hi there"` 变成 `echo hi` + `there`；无引号则完好。pwsh 7.5 无此问题。缺陷现场：为修 jq 路径参数而加的一行注释 `# reports "Could not open file".  Verified on Windows 10 ...` 让整段 status 命令只剩 `set -e` 加半行注释——bash **静默 exit 0、零输出**，status 文件照写 1.5 MB，jq 从未运行；失败在四层之外以 "Pueue shell smoke task result was empty" 现形，安装器回滚。9 个变异全部被抓到，另有 3 个安全形态确认不被误报（检查里内置了一个 CRT 参数解析模型 `crt_argc`，先用实测的 5 组对照校准：`# a " b`→2、`echo "hi there"`→2、真实缺陷注释→4，而 `"$PATH" --config "x"`→1、`printf "%s" "$MSYSTEM"`→1 均完好——所以它不是「见到引号就报」的启发式）。检查还内置了该模型的**自检**：五组实测对照在每次运行时重算，模型被改动而不符则拒绝给出结论，而不是静默放宽 | PowerShell 5.1 的实际行为**已不再完全不覆盖**（2026-09-25：5 组校准值在一台真 PS 5.1.19041 主机上逐条复现、argv 逐字一致——见下方性能补充四）；本检查本身仍只做源码扫描，只覆盖本仓扫描到的调用形态 |
| `10-installer-invariants` | 两个 Windows 安装器、三个 launcher 协议拷贝、以及两份 POSIX 安装器的**十四条**不变量（A–K，其中 A 与 E 各含两个检查点；**G 覆盖 POSIX 安装器**：每个 `mv` 之后其所在函数内必须有复核，16 个站点实测全部合规，作用域是函数而非行窗口——固定窗口两个方向都错，我在规则 G 里把两个方向都犯了一遍）。逐条对应本会话在真机上发现的安装器缺陷：**A** 每个 `[int]$MaximumBytes` 声明都必须带默认值（逐处检查，不是「至少一处」——3 处声明里只查 1 处，实测会漏掉另两处被剥夺默认值的变异），且至少一个调用点抬高它，且读取器内不得再有内联上限（缺陷现场：硬编码 1 MiB 上限，而该机真实 status 为 1507407 字节，安装器拒绝更新）；**B** 用 `1> $file` 重定向写的 JSON 要求读取端保持 BOM 感知——这条表达的是**耦合**而非禁止：重定向让 PowerShell 经控制台代码页解码子进程 stdout 再编成带 BOM 的 UTF-16LE（字节数翻倍），但读取端已加固为识别 BOM 且实测能正确读回，所以「禁止重定向」会误伤能工作的代码，真正的不变量是「有人丢掉 BOM 处理时这些站点会静默失效」；**C** 客户端安装器不得调用 `chmod`（noacl 挂载上它是静默空操作）；**D** 每个 `Set-Acl` 都必须在**同一函数内**有 `Get-Acl` 读回。D 的作用域是函数而非固定行窗口——窗口两个方向都错：本处的读回在写入之后 6 行（含注释），而宽到能容纳它的窗口也会接受属于**下一个**函数的读回；变异 `d-readback-in-next-fn` 正是验证这一点（把读回挪进下一个函数，仍被拒）。**E** launcher 的 payload 协议在三份拷贝（launcher 自身、Windows 客户端内嵌 wrapper、POSIX 客户端内嵌 wrapper）之间必须一致——上限数值与退出码**就是**协议，而 01 的 parity 只覆盖两条 `agentq-server`；实测单独把 POSIX 侧上限改成 1048577（该客户端会发出、launcher 会拒绝的 payload）全套检查依然全绿，故补此条。比较用 token 序列而非字节（POSIX 是 `;` 连接的单行、Windows 是缩进多行，逐字节比会在正确代码上报红），四类分叉实测全部被抓：改任一侧内嵌上限、改 launcher 自身上限、改 `exit 2`、删分支。**变异计数不再单列**：规则集在 2026-09-24 从 8 条扩到 10 条（新增 F、G），逐条各自记录——A–E 时期为 9 个，F 为 2 个，G 为 3 个；合计 14 个全部被抓到，1 个安全形态（改注释措辞）确认不误报。**F（2026-09-24 真机新增）**：ACL 对象的属性名必须真实存在——服务端安装器读的是 `$acl.AccessRulesProtected`，而 .NET 的真实属性名是 `AreAccessRulesProtected`；**客户端安装器一直是拼对的**，两份拷贝不一致，而只有一份在真机上被跑过。在 `Set-StrictMode -Version Latest` 下读不存在的属性会**抛错**（不是返回 `$null`），于是 ACL 校验那步让每次安装都死在该行——实测主机 A 上安装器回滚干净、部署未受影响。规则 D 抓不到它（`Get-Acl` 读回**存在**），只有真机能执行那一行，所以属性名在源码级钉住：允许集是「本仓实际读到的两个类型的属性」，`AccessRulesProtected` 不在其中。**变异 2/2 被抓**（服务端、客户端各一），基线绿。**H（2026-10-01 真机新增）**：`[AllowNull()][string]` 参数上的守卫必须测**空**、不能测 `$null`——PowerShell 把 `$null` 强转成 `""`，所以 `$null -ne $x` 对空串为**真**，守卫恰好在它要拒的那个值上放行。缺陷现场：`Restore-ScheduledTaskDefinition` 用 `if ($null -ne $Definition)` 守 `Register-ScheduledTask -Xml $Definition`，而首次安装时本就没有前一个计划任务（`Get-ScheduledTaskDefinition` 返回 `$null`），于是走进 `-Xml ""`、抛参数校验错——**把一次干净的首次安装失败说成「rollback is incomplete」并留下 recovery artifacts 残留**。同一文件里隔一个函数的兄弟守卫（`Remove-AgentQInstallerResponseTemporaryFile` 的 `$ExpectedIdentity`）一直用 `[string]::IsNullOrWhiteSpace`，只有这一处漏了。实测 PS 5.1.19041.3996：`$null` 绑到 `[AllowNull()][string]` 后读回 `isNull=False / isNullOrEmpty=True`。**规则作用域刻意只锚定 `[AllowNull()][string]`**——普通 `[string]` 参数根本绑不上 `$null`（绑定器会拒），那里的 `$null` 守卫是冗余而非错误；而匹配所有 `[string]` 参数会在名为 `$item`（持有文件系统对象的局部变量）的 `$null` 比较上误报。AllowNull 属性正是让 `$null` 守卫**看起来必要却无效**的原因。**变异 2/2**：还原守卫为 `$null` 形式 → 抓到（exit 1，精确报行号）；在非 AllowNull 的 `[string]` 参数上加同类 `$null` 守卫 → 保持绿（确认不是「见到 `$null` 就报」）。注释行被排除——修好后的代码里那条注释**引用了坏形态**，算进去会让正确的文件报红。**注意 `AccessControlType` 是合法的**（`AccessRule` 的属性，不是 ACL 对象的），已在允许集里——第一版漏了它，把 4 处正确代码报成违规。**J（2026-10-05 审查新增）**：**维护锁的释放必须不可被跳过**。服务端安装器在顶层 `try` 的 `finally` 里释放维护锁，而 PowerShell 里 `finally` 中的 `throw` 会**替换在途异常并中止该块**——原形态 `:2899`/`:2903` 两个 `throw` 都在 `Release-MaintenanceLock` **之前**，于是清理一失败就既**掩盖真正的安装错误**（报出来的是清理错误）又**把锁留到下次运行**（下次撞陈旧锁直接拒绝），两个症状同时。规则要求该释放语句**位于嵌套 `finally` 之内**（用括号深度判定「在内部」而非「在后面」——放在嵌套 finally 关闭之后是兄弟语句，同样不可靠）。**变异 4/4 被抓**：旧形态（无嵌套 finally）、Release 挪出嵌套 finally、Release 放在嵌套 finally 之后、只剩注释提到——**第一版规则把区域首行 `} finally {` 当成了嵌套 finally，于是什么都没抓到**，是重写成括号深度后才真正承重。**K（同日新增）**：客户端安装器的暂存清理 `finally`（2026-10-07 起为 `Install-CommitSet`——原先的 `Install-AtomicFile` 被成对提交重构吸收）清理失败时若无条件 `throw`，同样会掩盖 try 体真正失败的原因；规则要求它在抛之前先区分「体已失败」（报 stderr 让原错误传播）与「体成功」（清理失败才是错误）。**变异 2/2 被抓**（还原无条件 throw；完全不再抛）。**2026-10-06 扩为 K2**：同一形态在**服务端**安装器里有四处（`Install-PueueConfiguration`/`Install-AgentQLauncher`/`Download-VerifiedPueueBinary`/`Install-StageAsset`），K 的单函数锚点看不见；K2 扫描**两个**安装器的每个 `finally`——凡其中调用 `Remove-*TemporaryFile` 又含无条件 `throw`、且不引用已捕获异常变量者即违规。四处已改成同文件的错误合并写法（`$cleanupError`），变异（还原一处）被抓；maintenance-lock 释放的 finally 刻意不在范围内（规则 J 管它）。两条都是**源码级**不变量——两个安装器在本机都跑不了（`13`/`25` 撞平台闸门），这是本仓对「真机才看得见的失效」既有的唯一自动防线 | 安装器是否真的能装——那仍需真机；每条规则只保证「这个具体失效无法再静默复发」，不等于正确 |**I（2026-10-03 新增）**：**被渲染的模板里的占位符必须真被替换**。三份模板由 `__AGENTQ_*__` 替换渲染——launchd daemon plist（POSIX 安装器，三条 `sed`）、Windows 的 `pueue.yml` 与 `agentq-launcher.ps1`（PowerShell 安装器，`.Replace`）。Windows 渲染器**两个方向都设了防**（模板缺占位符抛错、渲染后仍含占位符抛错），而 **POSIX 那处两个方向都没有**——实测（修复前）把 plist 占位符改名成安装器不认识的名字，`01`/`10`/`11` **全绿**（`plutil -lint` 只验 XML 合法性，`__AGENTQ_X__/pueued` 是合法字符串），把 `sed` 模式改坏同样不可见；后果是 launchd 去 exec 一个字面量 `__AGENTQ_HOME__/pueued`，到服务加载才现形。现已两侧补齐：安装器加**运行时**守卫（替换后泛化扫 `__[A-Z][A-Z0-9_]*__`，命中即 `fail`），`10` 加**静态**规则 I（三对 template↔renderer 的 token 集合必须互相知晓，且渲染器必须带那个运行时守卫标记），`11` 加**行为级**用例（把安装器里那段渲染代码按锚点抽出来、桩掉三个 helper 后真跑：未知占位符必须退 2 且消息正确，**真实模板必须渲染干净**——两个方向都断言）。**变异 6/6 被抓**（三对各自改模板 token、三处各自去掉运行时守卫），`11` 的两条守卫用例另有 **2/2**（去掉守卫 → `guard block was not extracted`；守卫改成恒假 → `expected exit 2, got 0`）。**刻意排除一个文件**：legacy `com.agentq.pueued.plist` **不被渲染**（只 `require_file`，是旧安装路径的遗留），把它纳入同一 token 集会让正确代码报红——这条排除写在规则注释里。 | 安装器是否真的能装——那仍需真机；每条规则只保证「这个具体失效无法再静默复发」，不等于正确 |
| `11-installer-contract` | `skill/assets/unix/install-agentq.sh` 的**失败契约**——**27 个用例**（2026-10-07 加 2 例 W5 崩溃残留拒绝 + 1 例父目录不可列 + 1 例恢复指引须点名重启 daemon + 1 例「daemon 不在时必须说怎么办」），全部必须在安装器写入任何东西之前被拒。这是本仓最大的零行为覆盖资产（**2,946 行**，此前只有 `01` 的 `bash -n` 碰过它），而本会话 7 个缺陷里 6 个是安装器缺陷，正是这个洞的预测结果。做法沿用 `05`：只测契约不测成功路径。该安装器纯环境变量驱动、**顶层不解析 argv**（函数栈判定，非 grep），所以可测面是一张干净的拒绝清单。三条隔离手段缺一不可：HOME 指向沙箱、PATH 换成桩（本机真有 `jq` 和 `brew`，沙箱 HOME **挡不住** `brew install`）、包管理器全部换成「记录并失败」的桩——因此「什么都没装」是断言而非期望。另有 fixture 自检：先证明安装器能走到**依赖解析**这一步，否则全部用例会一起报同一个错消息（这个自检抓到过一次真问题：漏拷 macOS 的 plist 时，全部用例都死在缺资产上）。**变异 11/11 被抓**（2026-09-22 复测：先前文档里记过 7/7 与 10/10 两套互相矛盾的数字；重跑 11 个变异后有 4 个 MISSED，逐个手工构造情形查证，**全部是可达但本检查从未走过的分支**——`~/.agentq` 是普通文件、下载路径的哈希校验、陈旧锁的恢复与再确认。已补 4 个用例：用例数 11 → 15，并为此新增一个产出坏内容的 `curl` 桩和一个「只答一次身份查询」的有状态 `ps` 桩（后者用于钉住 `recover_stale_maintenance_lock` 的 TOCTOU 再确认，单进程 fixture 里否则不可达）。**2026-10-07 新增 5 例（22 → 27，分三次提交：W5 POSIX 3 例、C2 换根恢复指引 1 例、daemon 消息 1 例）**：**W5 崩溃残留必须被拒**（POSIX 侧同一窗口——`mv agentq_home→backup_home` 与 `mv stage_home→agentq_home` 之间崩溃后重跑，`previous_install` 为假、安装器把它当全新安装，旧队列留在 `..agentq.backup.*` 里；实测此前只被不相关的 wrapper 检查偶然挡住、且消息指向 wrapper 而非残留），两个方向各一例（root 缺失 / root 尚在），**且每例都断言残留未被删除**（一个「修复」=删掉操作者唯一队列副本的守卫比缺陷更糟；M5 变异正是删残留，被抓）；外加**父目录 `chmod 000` 必须拒绝**（扫描 fail-closed——M4 变异把它改成 fail-open 后，没有这一例时整个文件依然全绿）与**恢复指引必须点名重启 daemon**（容器实测：崩溃的 run 已停掉 daemon，「把 backup 移回去」这一步不够，照做会在下一道检查被 `daemon is unavailable` 拒；变异去掉该句 → 1 failure 被抓）；**同类的相邻实例一并修**：那条 `daemon is unavailable` 本身原先也只拒绝、不说怎么修（而 W5 恢复路径正把操作者引到这里），两侧消息都补了「start it and re-run …」，`smoke/11` +1 例（Linux 平台桩 + 失败 client 桩直达该分支），变异（删掉动作）→ 1 failure 被抓。**2026-10-06 新增 3 例（17 → 20）：临时路径不再由 `$$` 派生**；**同日再加 2 例（20 → 22）**：**curl 自身失败必须退 2**（原先把 curl 的 7/22/28 原样当安装器退出码、消息也无安装器前缀——已修）与**模板缺占位符必须被拒**（POSIX 渲染器补了 Windows 侧同款的模板侧预检：此前删掉模板里的占位符会渲染"干净"、plutil 通过、装出缺键的 plist；两个新方向的变异都被抓）。安装器曾有 **17 处** `${dest}.new.$$` 形态的临时路径（**不是 6 处**——先前的估计是漏的），全部改成 `mktemp`：**11 处写入目标**用创建形态（O_EXCL、后缀不可预测），**3 处重命名目标 + 3 处目录名**用 `mktemp -u`（随后的 `mv`/`mkdir` 在末段组件上本就原子，缺的只是不可预测的名字）。两个助手（`create_installer_temporary_file`/`create_installer_temporary_name`）里**显式补回目录链守卫**：原守卫经 `installer_path_is_safe` 走遍整条链查符号链接，而 `mktemp` 只守末段，不补会静默丢掉这条属性；助手用 `return 1` 而非 `fail`（它们在 `$( )` 里跑，`fail` 只终止子 shell）。root 目录（macOS 的 `/Library/LaunchDaemons`）经 `installer_directory_needs_elevation` **按目录本身**判断是否提权，不按 `platform_kind`（同平台上包装器目录是用户自己的）。三层断言：**① 行为级**（`mkdir` 桩记录真实 staging 路径与调用方 `$PPID`，断言名字不由 pid 派生）；**② 源码规则**（赋值同时满足「值里插值 `$$`」且「变量名是安装器创建的路径」，两半都必需——只看 `$$` 会误报维护锁的合法 `$$`，只看名字会误报只转发路径的 `discard_*` 助手）；**③ 助手行为级**（把两个助手**连真实守卫**从资产按锚点抽出真跑：创建形态调用后文件确实存在、两次名字不同、名字形态不建文件、两种形态都拒绝符号链接目录）。**变异 5/5 被抓**：M1 staging 名退回 `$$` → ① 与 ② 各报一次；M2 创建形态退回 `mktemp -u` → 只有 ③ 报 `got 4 / not created`；M3 fixture 到不了的 `health_temporary` 退回 `$$` → **只有 ② 报**（它正是为这类站点存在）；M4/M5 各删一个目录链守卫 → `got 8` / `got 9`。**反向用例**：加一个「值是 `$$` 但与路径无关」的变量 → ② 保持绿（证明它不是见到 `$$` 就报的启发式） | **成功路径**（要下载 pueue、写 `~/.agentq`、注册服务，需真机与授权）；`prepare_service_stage` 之后的一切（launchctl/systemctl 行为）；Windows 安装器；哈希用例只证明**拒绝坏二进制**，不证明接受好的；**11 处写入目标里只有 staging 根在离线 fixture 里可达**——② 只证明「名字不再由 `$$` 派生」，**不证明原子性**（那由 ③ 对助手本身证明），其余站点需成功下载、既有安装或回滚才能走到 |
| `12-ps-client-contract` | `skill/assets/client/windows/agentq.ps1` 的本地契约，**在 pwsh 下真正执行**——48 个用例（原 32；2026-10-06 加 3 例——两资产的探针失败回落行为锁 + UTF-16LE+BOM 读取锁，见下方 Windows 段；本轮补一组凭据用例：`Get-CredentialSshOptions` 两个方向各断言一次、数组**拼接是否真的落到 argv**（选项串对了但没进 ssh 等于没做）、以及三个黑盒拒绝用例——`AGENTQ_PASSWORD`／`AGENTQ_PASSWORD_PROMPT` 在 Windows 上必须被拒（该平台 ssh 无控制台时读 `_getwch()` 会**挂死**而非报错），`AGENTQ_ASKPASS` 指向不存在的文件必须被拒。**这三个拒绝用例刻意走进程调用而非 dot-source**：拒绝路径是 `exit`，而点源脚本里的 `exit` **只终止被点源的那一层**——实测（pwsh 7.5.4）外层脚本继续跑下去、`$LASTEXITCODE` 被设为该码，而 `try/catch` **两种写法都看不见它**（`. script` 与 `& script` 都不抛）。所以用点源驱动一个会 `exit` 的拒绝路径，断言会被后面继续执行的代码污染；第一版就是这么写的，报绿而实际什么也没测。变异 4/4 被抓。**本轮又加三条（36 → 39），针对一个真机发现的守卫缺陷**：ssh 把 `SSH_ASKPASS` 的**整个值**当**单个文件名**执行（无 shell、不分词），所以**带参数或带引号的形态永远不可能工作**；而守卫原先**只校验第一个 token**（源自「`cmd.exe /c helper.cmd` 是可行形态」这个**已被真机推翻**的假设），于是**接受**了这两种形态，失败最终以 `class=timeout` 现形——**把配置错误说成连接超时**。两条新用例断言这两种形态被守卫拒绝（真机复核：`rc=2` + 消息点明原因），**第三条断言合法单路径必须仍被接受**——这条是**补出来的**：先做的变异 M2（把守卫改成无条件拒绝）**报 MISSED**，查证后确认是**用例缺口**而非变异无效（此前没有任何用例验证「合法配置能过守卫」，一个拒绝一切的守卫能全绿），补上后 M2 被抓（`1 failure(s)`）。**用例计数从 41 改为 40 是修掉一个真错**：那一轮在合法形态的 `for` 循环**之前**多留了一次 `cases=$((cases + 1))` 与 `status=0`，而循环内两次迭代各自也计数——所以 41 是**重复计数**，实际用例是 40。**同时把四处「未拒绝」断言拆成两条**（退出码一条、消息一条）：原先写成 `if [ exit -ne 2 ] || ! grep -qF <消息>`，两件事塌成一句「was not refused」——M2 变异（守卫恒拒）当场暴露它会把**确实拒绝了、只是理由不对**说成**没有被拒绝**，而消息明明就在 stderr 里。现在分别报「没有拒绝（期望 2，实得 N）」与「拒绝了，但理由不是它」。原 32 中有一组认证提示用例：四个诊断串各跑 `Write-Diagnostics`，断言认证类**必打**提示且**须含目标主机名**、其余 class **必不打**；第二个方向不是凑数——提示若对所有 class 都打就退化成操作者学会跳过的噪音，那正是原提示失去价值的路径。变异 5/5 有效者被抓，1 个无效变异如实记录：把 `-eq "authentication"` 改成 `-eq "Authentication"` 报 MISSED，查证为**变异无效**——PowerShell 的 `-eq` 本身大小写不敏感，实测 `"authentication" -eq "Authentication"` 为真，`-ceq` 才敏感，该改动行为完全不变）（原 29，补了一组 `reason` 通道用例，本轮又补一条 exit-token 用例：8 个分类用例直接调 `Get-RemoteFailureReason`）；**2026-10-02 再补一条 wrapper 退出码 token 用例**：构造 `New-WindowsRemoteInvocation` 并解码它发出的 wrapper，断言其中**确有**携带 launcher 真实码的最终 `agentq-exit:$agentqLauncherExit` 行（不是子串——wrapper 另两个分支也发 token，子串会在最终那次被删时仍绿；实测踩过）。**2026-10-05 再补两条、43→45**：① **操作路径**——用桩 `ssh`（先发 `agentq-exit:0` 再发 `agentq-exit:3`、自身退 1）驱动**真实的** `Invoke-SshLogged`，断言 `ExitCode == 3`——既不是首个 0、也不是 ssh 码 1。② **探针路径**——`Resolve-ProbeExitToken` 同样从取首个改为取最后一个（对齐 POSIX 的 `windows_probe_apply_exit_token`），五例：三条单 token 额外断言与修改前实现**逐字节相同**（证明改动面窄），两条多 token 断言与 POSIX 侧一致。两条都**刻意是行为级**：源码级断言只能看见 `Matches(…)` 的存在，**看不见取了第几个下标**，而缺陷正是在下标上；变异（操作路径改 `[0]`、探针路径改回 `-match`）各自被抓（`1 failure(s)`），且探针那条变异下三条单 token 仍绿。**同日再补两条，其中一条是行为级的、抓到一个真缺陷**：① **askpass 环境**——`New-SshProcessStartInfo` 在配置了凭据来源时必须同时发 `SSH_ASKPASS` **和** `SSH_ASKPASS_REQUIRE=force`，无来源时两者都必须**不存在**（Git Bash 会导出 `SSH_ASKPASS`，客户端必须清除继承来的值；判据是「字典里有没有这个键」，不是值空不空——`EnvironmentVariables` 读缺失键会**抛异常**）。② **探针体必须真的跑起来**——`powershell.exe -Command -` 把 **stdin 当交互式输入读**：一行若**开启块**（`if {`/`function {`/`try {`）就进入续行，缓冲的语句**只在遇到空行时才执行**，**EOF 时未终止的缓冲被静默丢弃**（rc=0、无输出、什么都没执行）。Windows 客户端的**协议探针是多行 here-string**，于是**整个探针体被丢掉**、对任何 Windows 目标都报 `protocol probe failed`（指向部署而非客户端）；平台探针是单行、POSIX 客户端的探针也都是单行，所以**只有「Windows 客户端 → Windows 目标」这一组合**受影响——这正是它能长期潜伏的原因。修法是 `Add-ProbeExitToken` 末尾追加**一个空行**。这一条**刻意是行为级**：它构造**真实探针输入**、用**当前解释器自身**喂给 `-Command -`，断言输出里出现 `agentq-exit:<code>`（只证「体执行了」，不证具体码值）；**源码级断言看不见它**，因为问题在 PowerShell 如何消费文本、不在文本本身。变异（去掉那个空行）在 **pwsh 7 与真 PS 5.1 上都报红**。四处独立复现（Mac pwsh 7、真 PS 5.1、Git Bash MSYS ssh、Mac OpenSSH ssh）。此前该资产只有 `01` 的 AST 解析与 `10` 的两条源码不变量，从未被运行过；它的坏参数契约原先只是 `CLAUDE.md` 里「已在 Windows 11 实测 13 例」的文字记录。**必须重定向 `AGENTQ_CONFIG`**：客户端会从 `~/.config/agentq/config` 读 `AGENTQ_HOST`，而本机**确实存在**该文件，不重定向时「无 host」用例会静默解析出真实 host、走到别的分支——读开发者自己配置的检查不是封闭的，换台机器行为就变。变异 7/7 被抓；**2026-09-25 起可在真 PS 5.1 上跑**（`AGENTQ_SMOKE_PWSH=powershell.exe`）；**2026-10-02 在专用 Windows 测试机上实跑，`cases=43 pwsh=5.1.19041.3996 ps51=covered`**（45 例里的第 44、45 条是 2026-10-05 在 pwsh 上新增的，那台机未重跑这两条；
2026-10-07 按当前字节重算为 **48 例**），含本轮新增的两条行为级用例（askpass 环境、探针体送达），且探针体那条的变异在真 PS 5.1 上也被抓住。**注意这条覆盖是「按需」的**：默认仍跑 `pwsh`，此时摘要报 `ps51=NOT-covered` —— 那是准确的，因为 pwsh 7.5 **不复现**本项目实际踩过的两个 PS 5.1 缺陷（`09` 建模的词分割、`-EncodedCommand` 路径）。要看 PS 5.1 的真实行为必须显式设该变量，并在一台真 Windows 机上跑（PS 5.1 不接受 POSIX 路径作 `-File`，检查已用 `cygpath -w` 处理） |
| `13-ps-installer-contract` | `skill/assets/windows-git-bash/install-agentq.ps1`（**3,072** 行，全仓第二大资产，此前**从未被执行过**——`01` 只做 AST 解析、`10` 只做四条源码不变量）的参数契约与平台闸门——7 个用例：4 个参数错误消息（缺 `-StageDirectory`、缺值、空值、未知参数）+ 平台闸门（非 Windows 上必须失败，且**不得**留下事务目录、**不得**改写交给它的 staged 资产）+ **闸门先于 staging 校验**这条顺序（用**空** stage 目录证明：顺序若被改反，错误会从平台错误变成缺资产错误）+ **W5 崩溃残留守卫（2026-10-07 新增）**：`Find-AgentQCrashLeftovers`/`Assert-NoCrashLeftoverTransactions` 是纯 .NET，按 `22`/`23`/`25` 的 AST 抽取**抽出真跑**七种目录树——干净（无/有 root，必须**通过**，防「一律拒绝」的退化守卫）、缺 root+backup、缺 root+stage、有 root+backup（**两个方向都必须拒**，消息按方向区分）、相似名不误报（无前导点/别的 root 名）、父目录不可列（**fail-closed**）。变异 6/6 被抓；其中 **M4（扫描 fail-open）与 M6（两方向互换）第一版检查没抓到**——fixture 父目录恒存在、且只断言 `refusing to install:` 前缀，现按方向断言消息片段并加不可列一例。变异 3/3 被抓（去掉 `ValidateNotNullOrEmpty`、把 `-StageDirectory` 改成可选、拆掉 `GetCurrent` 闸门） | **这台机器上不可达的一切**：staging / 资产校验 / sha256 / ACL / **换根本身（两次 `Move-Item` 之间的真实崩溃与恢复）**，全都需要真实 Windows。已实测确认不可达而非推测：**任何**参数组合都在第一条语句 `Resolve-GitBashPaths` 上以 `Windows Principal functionality is not supported on this platform` 死掉，且空 stage 目录与填满的 stage 目录报**同一个**错——闸门在 staging 校验之前。所以本检查**不**覆盖安装器的行为，只覆盖参数契约、闸门的前置性与 **W5 的拒绝逻辑**；`10` 的源码不变量仍是该文件仅有的源码级保障之一 |
| `14-remote-command-length` | 两台客户端发出的**远端命令行长度**必须 <= 7,869（三种 `DefaultShell` 实测上限的最小值 8,125 减 256 安全边际）——**7 个站点**：POSIX 协议探针、POSIX 平台探针、POSIX launcher wrapper、Windows 协议探针、**Windows launcher wrapper（2026-09-24 补，此前从未被测量——把它撑到 26,538 字符也全绿）**、**Windows 客户端的 unix 探针脚本（2,707）与 unix 安装脚本（1,267）（2026-10-03 补）**。后两个站点是 A21 修法**自己造出来的**：那两条脚本原先作为裸 argv 发出、命令行上很小，改成 base64 通道后**第一次出现在命令行上**，而 base64(UTF-8) 约为原脚本的 4/3，所以这个修复让这两条命令行**比它替换掉的字节更长**，而本检查存在的全部理由就是 Windows 目标的命令行上限——这正是本检查 2026-09-24 记下的那类盲区（站点不在列表里就永远量不到）。`sshp` 的**会话命令刻意不量**，理由与它不被包装相同（需 tty）。**变异 2/2 被抓**（垫到 10,711 → `OVER`；破坏抽取 → `below the 32 floor` 而非假绿）。**量的是命令行，不是脚本体**：把脚本搬到 stdin 之后「脚本多大」不再是风险，量脚本会把修好的代码报成红的。所以站点 1/4 抽取**客户端实际发出的命令行常量**，并额外断言它**不含 `-EncodedCommand`、含 `-Command -`**；站点 2 断言平台探针**路由**经那两个助手（它不内联命令行，只共享常量）。实测顺序：先红（8,658 / 10,146 两处超限）→ 改代码 → 全绿。**站点 2 一度是假绿**：抽取标记 `encode_windows_powershell "` 在平台探针改用 stdin 后只匹配到 launcher 的调用点，量到的是变量名（25 字符）、报出无意义的 150——绿灯但什么也没量。三个变异（两端各自退回 `-EncodedCommand`、平台探针单独退回）全部被抓 | **真机行为**：命令是否真的能在该终端下跑、退出码是否真的不失真、我们没测过的终端其上限是多少。这条只证明「命令行足够短且脚本不在命令行上」这个静态事实；A5b 的退出码通道（stdout 上的 `agentq-exit:<code>`）是**另一条**不变量，本检查**不覆盖** |
| `15-transient-pueue-failure` | **瞬时 Pueue 读取失败不得被当成「任务不存在」**——P0 缺陷的回归锁（2026-09-24 外部审查发现）。缺陷机制：`find_request_task` 用 `fail`（即 `exit 2`）表达「读不到 Pueue」，而 6 个调用点全是 `if task=$(find_request_task ...)` 形状——**`exit` 在 `$( )` 里只终止子 shell**，调用方拿到空串 + 假条件，判定任务不存在，于是把**活着的** request 归档成 `removed`（删 record、写 tombstone，任务继续跑）。后果永久：`lookup` 永远 `5`、任务丢掉全部 `agentq` 元数据、request id 再也不能复用。做法：自建真实运行时，包装 `pueue` 只在**第 2 次** `status --json`（即 reconcile 那次；第 1 次是 `ensure_daemon` 的探测，失败会让服务端去 `launchctl`）注入一次失败，然后断言五件事——必须报 exit `2` + `reason=protocol_error`、**record 数不变**、**tombstone 为 0**、**不得报 `removed`**、Pueue 恢复后 `lookup` 必须仍能解析到同一 task id 且任务仍 `Running`。修复前（`1bbfd403`）五条全红、消息精确；修复后全绿。**2026-10-07 扩为第 6 节**：`logs`/`cancel`/`remove` 各注入一次同样的瞬时失败（第二次 `status --json`），断言**不得**报 `unknown AgentQ task id`、**必须**报 `cannot inspect Pueue` + `reason=protocol_error` + 退 2，之后任务须存活且 `logs` 恢复；外加 pending-marker 组合（读失败时不得宣告「任务已消失」/`cancellation_pending`，因为 `cancel` 的宣告分支闸在 rc=4 上）。修复前实测 **6 红**，5 个变异（三个调用点各自退回直接 `fail`、去 pending 闸门、分类器恒报 unknown）5/5 被抓 | 除这些注入点外的其它 Pueue 故障形态 |
| `16-no-host-identifiers` | **仓库与记忆里不得出现任何主机标识**——这条**规则早就写在文档里**（`CLAUDE.md` 操作边界「仓库与记忆里一律不出现主机名或 IP」），`CHANGELOG` 也记着 2026-09-22 清过 9 处、验证方式是「全仓正则扫描、排除回环、零命中」。**但没有任何检查重跑那次扫描，于是规则静默失效**：到 2026-09-27，仓库里重新出现 **7 个不同地址、46 行**，另有账号名、两把**他人公钥的注释串**（含真实姓名与两个机器名）、一个 `~/.ssh/config` 别名，以及**由地址派生的私钥文件名**。做法：七条规则扫全仓每个文本文件 + 记忆目录——`R1` 非回环 IPv4、`R2` mDNS 主机名、`R3` `user@fqdn`、`R4` `@含数字的裸词`（抓 `R3` 漏掉的序列号式主机名）、`R5` **被压成标识符的地址**（私钥文件名那个形状，`\b` 在这里失效——第一版就是这么写成「永远不匹配」还报绿的）、**`R6` 内网 TLD 的 FQDN（2026-10-05 新增）**、**`R7` 自动生成的 Windows 计算机名（2026-10-06 新增）**。**R6 补的是一个实测出来的洞**：前五条漏掉**最常见的真实泄漏形态**——`「db01.<内网TLD>」`、`「jump.<内网TLD>」` 这类内网主机名（`R2` 只认 `.local`，`R3`/`R4` 都要 `@` 前缀）。设计上两条约束都是量出来的：① **TLD 必须是末标签**（后面不接 `.`），否则一个「内网 TLD 后面还接着保留 TLD」的占位 FQDN 会命中，而 RFC 2606 保留 `example`/`test`/`invalid` 正是为了让占位 FQDN 可以安全写进文档——**本仓 CHANGELOG 里就真有一个这样的占位 FQDN**；② 排除保留 TLD。实测干净树上 **R6 零误报**（记忆目录同样 0）。**R6 加进去后立刻抓到了它自己的注释**（第 52 行的示例字面量），这正是该文件头警告的情形，按它自己定的规矩**拆分字面量、绝不豁免文件**。**R7 补的是又一个实测出来的洞，而且正是上面那条边界里可关闭的子形状**：2026-10-06 的 C3 写稿把**测试机的计算机名**（大写 + 内嵌 8 位日期 + 尾字母——克隆虚拟机的自动生成名）写进了 `PLAN.md` 与 `CHANGELOG.md`，另有两个账户名（其中原账户名 2026-09-29 就已进仓）、探针账户名、ESXi 的 VM 名——**前六条规则全都要求点号、`@` 或地址形状，裸 token 一条都盖不到**。规则 `[A-Z][A-Z0-9]*-20[0-9]{6}[A-Z][A-Z0-9]*` 的两条边都是量出来的：**尾字母要求**单独就把带日期的发布标签挡在外面（`RELEASE-20260926` 是负样本）；合成 task id（`AQAAA-00000000000001` 是负样本）要**两条边都去掉**才会命中（实测，非推断）；**账号名刻意不建规则**（任意词，无形状可写，只能靠阅读清理），如实记为边界。实测干净树 + 记忆目录 **R7 零误报**（三个候选宽度全部 0 命中，取最窄的）。**修法照 2026-09-27 先例：改字面量、不豁免文件**——计算机名→`<计算机名>`、账户名→`<账户名>`/`<第二账户>`/「第一账户」、VM 名→「专用测试机」，证据（`UserId=…`、`MSFT_TaskLogonTrigger`、`UnauthorizedAccessException`）一条未删。**真实红/绿**：把计算机名放回 `PLAN.md` → 1 处违规（打码输出）+ exit 1，还原 → 0。**变异 5/5 被抓**：永不匹配→自校准 no-longer-fires；去掉尾字母→自校准 false-positive（发布标签）；再去掉日期锚→false-positive ×2（task id + 发布标签）；**永不匹配 + 关闸门 → canary 独立兜住（`6 of 7`）**；**R7 漏出 `scan_file` 的 spec 列表 → canary 也兜住（`6 of 7`）**。**裸主机名（无点）刻意不加规则**：实测「含连字符且含数字的裸词」在干净树上命中 **1882 行**（`aarch64`/`sha256sum`/`v4`/`ps1`/`P0`/`kernel32`/`ed25519`/`TLS1` 全是误报），**无法与「架构名/哈希名/版本号」区分**，所以那个缺口是**实测不可关闭**、如实记为边界（R7 收窄了它——带 8 位日期且大写的子形状现在可关闭——但无日期的与全小写的仍在边界外）。**变异**：R6 三个全被抓——去掉末标签锚（退回会误报 `.example` 的宽松版）→ 自校准报 false-positive；改成永不匹配 → 自校准报 no-longer-fires ×2；**改成永不匹配 + 关掉自校准闸门** → **canary 独立兜住**（报 `canary caught 5 of 6 rules`）。**输出里的匹配一律打码**，只留前两个字符与长度：检查自己的输出会被阅读、粘贴、归档，原样打印等于把检测器变成新的泄漏通道。**先自校准再扫描**：七条规则各自必须在**它存在的形状**上触发、且在**替换它的占位符**上保持沉默，自校准不过就不给结论；另有一条 canary 把已知坏内容喂进**真实扫描路径**，独立于自校准地证明 grep→判定→退出码这条链是通的。**变异 11 个中 10 个被抓**，1 个 MISSED 如实记录：单独关掉自校准闸门（`if false`）**没有任何可观测变化**——闸门本来就没触发过，单看这一个变异是良性的；它与「某条规则被放宽」组合时会被 canary 抓住（实测 `R2`/`R5` 各自 + 关闸门 → 报 `canary caught 4 of 5 rules`），所以**不声称它是缺陷，也不声称它被覆盖**。真实红/绿已验：把清洗前的 `PLAN.md` 放回去 → 27 处违规、五条规则全部触发；换回当前版本 → 0。**2026-10-06 另加「树扫描到 0 个文件即 FAIL」守卫**——把 root 指向空目录的变异此前会报 `files=17 violations=0` 并退 0（17 全来自记忆目录） | 任何**不具这七条形状**的地址写法（记成「角落那台机器」的扫描器看不见，这是刻意的边界而非疏漏）；**无点的裸主机名**（实测不可关闭，见上；R7 只覆盖其中带 8 位日期且大写的子形状）；**账号名**（任意词，无规则可写，只能靠阅读清理）；`find` 会跳过的二进制文件；规则本身只证明「这七条形状不在文本里」，不证明别处没有 |
| `17-askpass-credential` | **POSIX 客户端的密码认证路径，跑在真实 sshd 上**（2026-10-05 起 `cases=8`，新增 `AGENTQ_PASSWORD` 源端到端）。**新增的那节补的是一个真实洞**：此前 `AGENTQ_PASSWORD` 在本检查里**只出现在 `env -u`**、从未被设过值，于是「客户端自建临时 wrapper」这条路径**零覆盖**——而它正是 2026-10-05 审查改动的地方（wrapper 的创建、身份记录、删除、`TMPDIR` 残留全无断言；`AGENTQ_ASKPASS` 源不分配那个文件，`smoke/05` 只看到达 ssh argv/环境的内容、不看 wrapper 在盘上的生命周期）。新用例用同一个口令做 submit→wait 端到端，并**重定向 `TMPDIR`** 断言零残留（重定向让「零残留」是真断言而非指望）。**变异被抓**：把 askpass 临时文件从 `cleanup_client_runtime` 移除 → 报 `AGENTQ_PASSWORD left 2 file(s) in TMPDIR: agentq-askpass.*`。客户端原先 4 处 ssh 调用全部硬编码 `BatchMode=yes`（它禁用全部交互式认证），所以只有密码的目标机连不上。现在配置了凭据来源就改传 `BatchMode=no` + `NumberOfPasswordPrompts`，并经 askpass 取密码；**没配置时逐字节不变**。本检查断言两件事：**有来源时端到端跑通**（真 sshd、真 pueue、submit→wait 的 `result` 必须是 `Success`）、**无来源时 ssh 仍拿 `BatchMode=yes` 且 askpass 一次都不被调用**。两个方向都断言是刻意的——只测一个方向，一个「永远传同一个值」的退化实现也能过（`12` 的 auth-hint 用例已为同类理由写过这个论证）。**凭据来源是三种**：`AGENTQ_ASKPASS`（可执行程序，**排第一**——AgentQ 因此从不接触密码本身，只传程序名）、`AGENTQ_PASSWORD`（环境变量）、`AGENTQ_PASSWORD_PROMPT=1`（人类交互）。**守卫是严格的**：来源配置了但不可用（不存在／不可执行／符号链接／是目录）必须**拒绝运行**（exit 2 + 原因），**不静默回落到密钥认证**——静默回落会让操作者以为在用密码。**为什么用口令私钥而不是账户密码做端到端**：两者走**同一条 `read_passphrase → ssh_askpass` 代码路径**（实测 prompt 文本不同、机制相同），而 macOS 上非 root 的用户级 sshd **无法验证任何真实账户密码**——`getpwnam().pw_passwd` 是 `'********'`、无 `/etc/shadow`、`/usr/sbin/sshd` 无 setuid 位、`UsePAM yes` 明确要求 root。所以账户密码**登录成功**这一环本机测不了，需真机。**实现里三处易错点已钉住**：① 凭据解析必须在**顶层**、早于 `initialize_remote_invocation`——平台探针自己就是一处 ssh 调用，来源若只在操作路径生效，探针会先失败、命令根本走不到操作路径；② `SSH_ASKPASS` 空串**不等于未设置**（OpenSSH 测的是 `getenv() != NULL`），所以只在真有程序时才导出；③ 清理只删**自己建的**临时 wrapper，用户提供的 askpass 程序绝不动（实测把两者混为一谈时清理会去删用户的文件）。变异 6/6（POSIX 参数构造）与 3/3（端到端）全部被抓，其中一个是「清理越界删除用户程序」 | **账户密码登录成功**（macOS 非 root 限制，见左）；**Windows 客户端本身**（那是 `12` 的地盘，本检查只跑 POSIX 客户端）。Windows 上 `AGENTQ_PASSWORD`/`AGENTQ_PASSWORD_PROMPT` **刻意拒绝**（该平台 ssh 无控制台时读 `_getwch()` 会挂死，且没有顶层 trap 可挂清理），只支持 `AGENTQ_ASKPASS`；且 Windows 的 `SSH_ASKPASS` 取值必须是**一个可执行文件的路径**——ssh 把整个值当**单个文件名**执行，无 shell、不分词，**不能带参数、不能加引号，但路径里的空格合法**（判据是「整个值是不是一个存在的可执行文件」而非「有没有空格」；真机实测含空格路径 rc=0 成功。原先的：`cmd.exe /c helper.cmd` 报 `ssh_askpass: exec(...): No such file or directory`；指向带 shebang 的脚本则正常）。**2026-09-29 真机复核**：POSIX 客户端经**真实账户密码**（非口令私钥）在 macOS 主机上跑通完整协议 （`submit`→`wait` 的 `Done.result=Success`→`logs` 回 `Darwin`→`remove`），Linux 目标同样跑通；**这是 A18 标注为「尚未在任何真实主机上验证」的那一项，现已验证**。Windows 客户端已升级到 canonical 并在真机确认守卫与 ACL；**经 Windows 客户端发起的端到端也已验证**（Windows → 那台只有密码的 macOS 主机：`wait` 退 0 + `Done.result=Success`、`logs` 回 `WIN-E2E-OK\nDarwin`、`remove` 回 `removed:true`）。**2026-10-02 在专用 Windows 测试机上补齐了原生 ssh 与「Windows→Windows」两格**：该机 `Get-Command ssh.exe` 解析到 `C:\Program Files\OpenSSH\ssh.exe`（`OpenSSH_for_Windows_9.5p1`，**原生**，非 Git Bash MSYS），Windows 客户端经它连本机 Windows 目标、**askpass 密码认证**（无密钥）跑通完整协议（`submit`/`wait` `Success`/`logs`/`remove` 全 rc=0）。**askpass 的 `SSH_ASKPASS_REQUIRE` 是这里的关键**：本机三种 ssh 各测两列（按客户端的 `ProcessStartInfo`），9.5p1 与 Git Bash MSYS 9.9p1 **无 `REQUIRE` 时都阻塞、askpass 一次都不调**，有 `force` 才 rc=0；`System32` 的 8.1p1 **两列都阻塞**（该构建早于该变量）。客户端此前只发 `SSH_ASKPASS`、头注释还写着「Windows ssh 没有该变量的对应物」（**前提错误**），已修为两条路径都发 `SSH_ASKPASS_REQUIRE=force`、无来源时清除继承值。**仍不覆盖**：`System32` 8.1p1 这一格（客户端默认解析不到它，且它不支持该变量——如实记为边界，不是缺陷） |
| `18-record-metadata-contract` | **`status` 的 request-record 元数据扫描的契约**——27 例，跑在临时目录里自建的合成运行时上（含 `pueue`/`pueued` 桩，桩必须同时答 `status --json` **和** `group --json`，否则 `status` 死于 "group is missing"，看起来像记录问题而其实不是）。**这个检查存在的原因是本仓文档一直写着「smoke 抓不到行为回归」，而本轮用实验坐实了它**：一个跳过 crash-window repair 扫描的变体（约 1.9× 加速）会让合法的 crash-window record **永远无法自愈**，却跑出 `17 ran 0 failed`；另一个去掉 filename↔`request_id` 绑定的变体**静默接受**错配记录，同样全绿。所以先写能红的检查、再改扫描代码。断言：① 8 类坏记录必须 exit `2` + `reason=protocol_error`，且**完整 stderr 与基线逐字节相同**（含 base 因内层 `fail` 落在 `$( )` 里而多打的那条 `missing ... during recovery`——第一版读取器把结果赋给变量而非走 stdout+`$( )`，**丢掉了这条消息**，正是这个检查抓到的）；② 合法 crash-window 状态（`removed` record + 已写 tombstone）必须自愈成 record 0 / tombstone 1；③ `task_id: null` 对 prepared/adding **合法**；④ 好记录的输出逐字节一致。**每个用例都重新播种记录目录**——`status` 会**写**（把 `removed` 归档进 tombstone），两棵树共用一个目录会让先跑的那次消费掉后跑那次要看的输入，报出 IDENTICAL 而实际什么都没测。**变异 3/3 被抓**：跳过 repair → `crashwin: exit code differs (baseline 0, variant 1)` + `did not self-heal`；去掉绑定判据 → `mismatch: expected exit 2, got 1`；把校验的 `error(...)` 换成恒真 → 8 处失败。**1 个 MISSED 如实记录且已查证不是覆盖漏洞**：把**聚合**过滤器换成恒真（`jq -cse .`）报绿——因为 `repair`（pass 1）会先拒掉每一条坏记录，`load_request_records` 那个聚合过滤器（`request_records_filter`，**排除** `removed`）的绑定检查在 `status` 路径上**不可达**；另外**直接**用 `jq -cse --args -f` 单独喂给它错配/匹配两种记录，确认判据本身正确（错配 error、匹配通过）。**注意别把两个聚合过滤器混为一谈**：上面那个不可达的是 `load_request_records` 的；`repair` 自己的聚合过滤器（`request_removed_records_filter`，**接受** `removed`，2026-10-04 加）的绑定检查**是可达的**——把它的 `valid($ids[$i])` 去掉，一条「文件名与 request_id 不符、且 state 为 removed」的记录会被**错误归档**，实测 `status` 把它写进 tombstone（records=1→2 的差异），`smoke/18` 以该变体跑报 12 处红。该结论写在检查的注释里，以免绿灯被过度解读。**2026-10-04 新增第 27 例 `assert_jq_diagnostics`**：每条坏记录的 jq 诊断行**必须恰好 1 条**。这是被一次真实的假绿逼出来的——`compare_case` 在默认运行里 base 与 variant 是**同一份资产**，它只 diff 两侧，**确定性的重复行在两侧相同、它看不见**；而 repair 的快路径第一版把 `jq …` 的 stderr 漏了出去（`var=$(cmd) 2>/dev/null` 在 bash 里**不抑制 `cmd` 的 stderr**——重定向绑在赋值上，不在替换上），于是每条 parse error **打印两遍**，`compare_case` 却全绿。新断言在**默认运行**下就能红（实测把该形态放回资产：6 处 `expected 1 … got 2`）。**也记下我自己的两个假红**（都改了检查、没改代码）：`normalize()` 没剥两棵树各自的绝对路径，对**未改动**的服务端也报 7/21 失败 | **真机行为**——全部跑在 macOS 的合成运行时上，不证明真实 Pueue/远端/Windows；**聚合过滤器的绑定检查在 `status` 路径上不可达**（见左，`repair` 先拦住；这里指的是 `load_request_records` 的 `request_records_filter`，**不是** 2026-10-04 新增的 `request_removed_records_filter`——后者的绑定检查**可达**）；只覆盖 `status`。`lookup`/`wait` 各自的记录读取路径见 `26-record-read-paths`；**`logs` 不是记录读取路径**（它只 `compact_task`、不读 request record），原文把它并列进来是错的，已更正 |
| `19-sshp-contract` | POSIX `sshp`（**1,207** 行）的**本地契约**，19 例，用一个记录 argv 的 `SSHP_SSH` 桩替换 ssh（不接触任何远端）。**该资产此前从未被执行过**——`01` 只做 `sh -n` 语法解析，而它是**人每天都在用的交互会话路径**，不是一次性工具。做法沿用 `05`/`11`：只测契约不测成功路径（真会话要远端有 tmux/screen/Zellij）。覆盖：参数校验（无参、三个参数、空主机、`-` 开头主机、会话名含空格/斜杠/引号/分号 → exit 2）；**会话名被接受**那条（空串回退`ghostty`）；环境变量校验（`SSHP_RECONNECT_DELAY=abc`、不可用的 `SSHP_SSH`）；`--help` **不得调用 ssh**；探测分派（unix ready、`--check` **不得安装** → **恰好 1 次 ssh 调用**、不支持的平台、MINGW 路由）；重连（255 + `-E` 传输行 → 第 2 次 READY → exit 0 且**恰好 2 次调用**）；从记录读 argv（`-E`、`LogLevel=ERROR`、`-T`、`ConnectTimeout=10`、`ServerAlive*`、`TCPKeepAlive=yes`、主机为独立 argv，**无 `BatchMode`**——sshp 刻意支持密码）；TMPDIR **零残留**（2026-10-06：删掉一个从未被调用、且参数会翻倍的死 `run_client`）。**`--check` 的重连必须有界（2026-10-07 新增）**：交互路径保持无界重试（有人看着、可 Ctrl-C），但 `--check` 是非交互只读探针，远端「接受 TCP 后立刻断开」会让 `while :` 永远转下去——加 3 次预算，超限退 255 并报 `--check does not retry forever`；用例让桩**每次**都返回 255+传输行（桩的 `logfile-lines` 按调用序号取行，所以给了 5 行），断言退出 255、消息在、调用数在 2–4 之间（变异关掉预算 → `made 7 ssh call(s)` 且实际挂起，被抓）。**唯一安全相关的用例**：会话名被插进一条**远端 shell 命令**（`exec tmux new-session -A -s '$session'`），唯一挡在它与远端命令注入之间的是 `*[!A-Za-z0-9_.-]*` 守卫，故两个方向都直接断言 | 任何真实远端（桩证明的是 sshp **发出什么**，不是真 sshd 拿它做什么）；交互会话本体（需远端答 READY，随后阻塞在终端——只断言它会用的 argv）；Windows 路径（只断言 MINGW 路由决策）；远端安装路径（会在远端跑包管理器） |
| `20-ps-native-argv-roundtrip` | **两个 PowerShell 客户端交给 ssh 的脚本，必须挺过 PowerShell 5.1 的原生根参数引号处理**——9 例（2026-10-07 加一例：带引号的会话名必须**在调用 ssh 之前**被拒——`sshp.ps1` 原有一处把 `'` 转成 `'""'` 的转义会**插入双引号**，恰是 A21 词分割的触发字节；已删并改为 fail-closed，变异「守卫放行 + 恢复注入转义」→ 2 failure 被抓），在 pwsh 里真跑客户端、捕获真 argv、套用 `09` **同一份、同一组真机校准值**的 CRT 模型。**这条对应 PLAN.md A21**：两个 Windows 客户端都用 **splat 数组**把一段多行 shell 脚本当**单个 argv 元素**交给 ssh（`$sshArguments += @("--", $script:TargetHost, $RemoteCommand)` 然后 `& $script:SshPath @sshArguments`）——`&` 调用操作符会给含空格的参数外包一层 `"`，但**不转义参数内部已有的 `"`**（A5a 已建模的机制），于是脚本在 ssh 看到之前就被按词分割。`09` 的扫描规则只 grep `-c`/`-lc` 与 `Invoke-GitBashScript -Script`，**看不见 splat 数组**，所以 `sites` 从不计入这两个文件。断言：**最后一个 argv 元素**过模型后**恰好 1 个参数**且**字节完全一致**；**且** base64 通道解码回来必须含预期 marker（只断言「命令行完好」会让一个「完好但什么都不做」的命令通过）。含模型自检——自检不过则**拒绝给出结论**。**变异 2/2 被抓**（两个资产各自退回裸脚本）。**另 4 例守一处刻意的例外**：`sshp.ps1` 的 `Get-UnixSessionCommand`（`exec tmux/screen/zellij`）**不**走 base64——该通道是 `printf %s <b64> \| base64 -d \| sh`，`sh` 的 stdin 是**管道**，而多路复用器要求 stdin 是 tty（实测：pty 下 `stdin=tty` 正常起 screen、`stdin=pipe` 一律 `Must be connected to a terminal.`）。它裸着安全**只因一个双引号都没有**，所以这条例外**有条件**、条件本身被这 4 例守住（必须仍裸、仍带 tmux 分发、仍是一个参数、字节不变，**两个方向都断言**），**变异 3/3 被抓** | PowerShell 5.1 的**实际行为**——本机跑的是 pwsh 7.5，它引号处理**正确**，这正是该缺陷在 macOS 上长期不可见的原因；模型按 6 行真机测量校准，但**没有 PS 5.1 在这里执行**，且**这一具体形态（`& $exe @splat`）尚未在任何真 PS 5.1 上直接测量**。也不覆盖真实 ssh／远端；会话命令的裸形态只在「不含双引号」这一条件下成立，该条件被守住但不证明其它脚本也能裸着。**也记录了修检查时我自己的一个假红与一处归因缺陷**：原模型用 `wc -l` 数参数，而一个参数本身可含换行（会话命令就是多行的），把 1 个参数数成 5、冤枉了正确的资产——改为模型**显式输出 argc**（补 `multiline-one` 自校准行，共 6 行） |
| `21-install-client-contract` | `skill/assets/client/unix/install-client.sh`（**280** 行）的**本地契约**，12 例（2026-10-07 加 **W1 成对原子性**，见下）——**它是本仓最后一个此前零行为覆盖的安装器**（另两个各有 `11`/`13`），也是那张「从未被执行过」表里**唯一在 macOS 上完全可跑**的。做法沿用 `11`/`13`（只测契约），但它**解析 argv**（不像 `install-agentq.sh` 纯环境变量驱动），所以可测面是选项解析 + 路径安全 + 漂移检测。覆盖：未知选项／`--bin-dir` 缺值／空值 → exit 2；`--help`/`-h` 退 0 且不碰任何文件；**目标路径链含符号链接**必须被拒（安全相关——防跟随攻击者植入的链接）；目标是普通文件必须被拒；`--check` 对空目录报两个 client missing 且**不写入**；**唯一可测的成功路径**（只把两个文件拷进沙箱目录，无网络/无服务管理器/无包管理器——三个安装器里只有它能这样测）：装出**逐字节等于 canonical** 的两个 client、**mode 700**（这一条刻意断言，因为它的 Windows 对应物 `chmod` 曾是静默空操作）、无 `.agentq.new.*` 暂存残留，再 `--check` 报 match；**`--check` 必须检出漂移**（改一个 client 的字节 → 报 `does not match canonical asset: sshp` 退 1，且**不得**把未漂移的那个也报成漂移——两个方向都断言，否则一个恒报漂移的 `--check` 能过）。**变异 3/3 被抓**（去掉 symlink 守卫、`--check` 恒报 match、装完不 chmod）。**一处实测纠正**：我第一版把「目标是文件」的报错猜成 `not a directory`，实测资产报的是 `cannot create destination directory`——按资产改正，不按推测。**W1（2026-10-07，成对原子性）**：安装改成「先暂存两个、再依次两个 `mv`」，W1 用例把 `sshp` 资产置为 **111**（**`-f`/`-x` 预检都只看模式位——实测 `[ -x ]` 对 `--x--x--x` 为真——只在 `cp` 失败，正是旧顺序的窗口），断言退出非 0、stderr 点名 `cannot stage client: sshp`、**`agentq` 仍是旧字节**、`sshp` 未动、零暂存残留。变异（退回逐件 stage+move）报 `agentq was updated even though the install aborted on sshp` + 残留 1，被抓 | 真实用户 `~/.local/bin` 的安装（全程用 `--bin-dir` 指向沙箱，HOME 也指向沙箱）；**live 目标上的崩溃语义**（暂存文件与 rename 之间崩溃）；它所装 client 的行为（本检查只证明字节等于 canonical） |
| `22-launcher-contract` | `skill/assets/windows-git-bash/agentq-launcher.ps1`（430 行）——**曾是本仓最大的零覆盖资产**——**在 macOS 上可跑的那三块**，**外加 `agentq-start-daemon.ps1` 的两个路径守卫与失败契约**，59 例（2026-10-06 从 49 扩到 57：`Set-AgentQUserEnvironment` 原先只断言 8 个值，现断言全部 **16 个**值 + 3 条关系——删掉任意一个变量此前不可检出，实测补全后「删 USER 项」变异被抓）。它也是**三份 launcher 协议拷贝**之一，而 `10` 的规则 E 只断言三者**源码一致**、从无行为断言。**可跑**（都不碰 Windows API，pwsh 7.5 能执行）：① **payload 解码器** `Read-AgentQArguments`（NUL 分隔 base64 向量）——合法向量解析正确（含空格参数 `/tmp/my dir`、非 ASCII `任务`/`ünïcode` 逐字保留），空串／坏 base64／**缺尾 NUL** 三种坏输入被拒；这是规则 E 比较的三份拷贝的**接收端**，一个让三者字节相同却弄坏解码器的漂移能过规则 E 与所有其它检查。② **路径守卫**`Test-AgentQLauncher{Required,Runtime}FilePath` 与 `Remove-`／`Assert-`：普通文件 True、目录/缺失/空串 False、**符号链接 False**（安全相关：launcher 绝不透过链接写运行时脚本）。③ **环境变量→位置参数回环 bash 脚本**（launcher 写出并交给 Git Bash 的那段）——含空格/双引号/换行的参数**逐字回环且不被词分割**（A21 同类），非数字 `count`（`1;rm -rf /`）与缺失 `count` 都退 2。**变异 4/5 被抓**（去掉 malformed 检查、去掉 ReparsePoint 检查、去掉非数字 count 守卫、`set --` 去掉引号→词分割）。**1 个 MISSED 如实记录且查证为良性**：去掉解码器自己的 `IsNullOrWhiteSpace` 守卫**不被抓**——空 payload 仍被下游 `contains no arguments` 拒绝，「拒绝」这个属性两种写法都成立、只是消息不同；断言确切消息会钉住实现细节而非契约，故不做 | **Windows API 路径**（`Get-CurrentWindowsUserEnvironment` 用 `WindowsIdentity`+HKLM ProfileList，及其下游的一切：真 server 路径的 `Assert-...RequiredFile`、`New-AgentQLauncherRuntimePath`、真正的 `& $gitBashPath` 调用）——需要真 Windows；本检查在摘要行明写 `windows-api=NOT-covered(needs-Windows)`，不暗示整个文件被跑过。**`agentq-start-daemon.ps1` 本身仍未覆盖**——它顶层第一条语句就死于 `WindowsIdentity`，但它的**两个路径守卫与 `Set-AgentQUserEnvironment`** 是纯 .NET、可跑，且与 launcher 的守卫是**近乎逐字的拷贝**（本仓「同一机制抄在多处只修一处」的病灶，A9/A19/规则 E 同类），故一并纳入并**断言两份拷贝行为一致**。**2026-10-03 又补一个纯 .NET 函数**：`Set-AgentQUserEnvironment`（把 16 个变量写进**进程环境**，承载「HOME/USERPROFILE 必须来自进程 SID 解析出的 profile、不信任被 Git Bash/OpenSSH/runas 污染的继承值」这条安全属性）也被抽出来真跑：用合成的 user-environment 对象驱动、读回进程环境，断言 16 个值全部来自该对象、`TEMP`/`TMP` 与 `HOME`/`USERPROFILE` 同源，**且继承来的 HOME 必须被覆盖**（这一条正是「函数退化成 no-op」的检测器）。变异 4/4 被抓（HOME 取自环境变量、TMP 取错字段、丢 USERPROFILE、整个函数 no-op），每个都报出精确的 `expected [...] got [...]`。**2026-10-07 又加两例**：start-daemon 的三处拒绝站点原是 `Write-Error` + `exit 2`，而脚本顶部 `$ErrorActionPreference = "Stop"` 让 `Write-Error` **抛异常**、进程退 1，`exit 2` 是死代码（实测：EAP=Stop + `Write-Error` 的脚本退 1、永不执行下一句）——已改 `[Console]::Error` + `exit 2`，用例用**真实子 pwsh** 驱动真函数（缺文件 → 恰好 2 + 消息；正常路径 → 0，防「永远退 2」的退化实现），变异（还原 `Write-Error`）→ `expected 2, got 1` 被抓。**变异 M6（只改 start-daemon 一份拷贝）被抓**；**M7 暴露了我自己的一个覆盖洞并已关掉**：第一版 fixture 的 `dirlink/sub` 不存在，`Get-Item -ErrorAction Stop` 在叶子就抛错返回 False，父链检查从未被走到——补上真实存在的子目录后 M7 被抓（`sd.profile.underLinkedDir` 期望 False 得 True） |
| `23-durable-move-contract` | `skill/assets/windows-git-bash/agentq-durable-move.ps1`（118 行）的**参数契约**（4 例）+ **源码级 access-mask 不变量**（3 例）。该资产此前只有 `01` 的 AST 解析。**它是本项目第一个原生 Windows 缺陷的现场**——`FlushFileBuffers` 需要 `GENERIC_WRITE`，而 handle 只开了 `GenericRead`，于是 ERROR_ACCESS_DENIED(5)，安装时 `install_temporary_file` 失败 → `write_lock_metadata` 失败 → **操作锁永远拿不到**，每个命令重试 30 次后以误导性的 `AgentQ operation is already in progress` 现形。**可跑**：参数契约（三个参数都必填非空，4 条实测消息）。**源码级钉住**：`OpenForFlush` 的 `uint access` 必须**同时**含 `GenericRead` 与 `GenericWrite`（这一行常量就是整个修复，只有真机能注意到它回归，故照 `10` 钉 ACL 属性名的方式钉确切断言）、flush 路径必须经 `OpenForFlush`、`MoveFileEx` 必须带 `MoveFileWriteThrough`。**变异 3/3 被抓**（access 退回只读=缺陷原型、去掉 WriteThrough、去掉 `ValidateNotNullOrEmpty`）。2026-10-06：掩码行读取加 `|| true`——行被改名时那条设计好的诊断此前不可达（`pipefail` 先中止、零输出退 1）。**注意证据形状**：access-mask 是**源码断言**，不是执行证据 | **move/flush 的实际行为**——本机每次合法调用都死在 kernel32 P/Invoke 上（`MoveAndFlush`→`CreateFile` 对 kernel32.dll），需要真 Windows；摘要行明写 `behaviour=NOT-covered(needs-Windows)` |
| `24-git-bash-launcher-contract` | 两个 Git Bash 启动器 `client/windows/agentq.bash`、`sshp.bash`（合计 38 行）的**本地契约**，18 例——它们此前只有 `01` 的 `bash -n`，**从未被执行过**。**不是死文件**：`install-client.ps1` 在检测到 Git Bash 时（`Resolve-GitBashPath` 非空）把每个 `.bash` 拷成 `.local\bin` 下的**无扩展名** `agentq`/`sshp`，那才是 Git Bash 用户实际调用的入口。做法：在真 bash 下执行启动器，`cygpath` 与 `powershell.exe` 都换成桩，断言**PowerShell 子进程真正收到什么**（argv + `MSYS_*`/`AGENTQ_*` 环境），而不是读启动器文本。覆盖：委派 argv（`-File` 指向同目录 `.ps1` 的 Windows 形态路径、参数逐字透传）；**`MSYS_NO_PATHCONV=1` 与 `MSYS2_ARG_CONV_EXCL='*'` 必须设**（这是 SKILL.md 写明的「不被本机 Git Bash 篡改」属性）；**交互性**——`agentq` 必须传 `-NonInteractive` 而 `sshp` **必须不传**（它驱动交互会话，与 `01` 的 `.cmd` 规则同一条理由）；**条件路径转换**（绝对路径经 `cygpath` 转 Windows 形态、相对路径**原样保留**、未设则保持未设——**两个方向都断言**，只测一个方向会让「一律转换」的实现通过并破坏相对值）；**子进程退出码必须传回调用方**（`.cmd` 的 `exit /b %ERRORLEVEL%` 同形）。**变异 8/8 被抓**（去掉 `MSYS_NO_PATHCONV`、`sshp` 误加 `-NonInteractive`、两处把相对路径也转换、去掉 `MSYS2_ARG_CONV_EXCL`、委派到错的 `.ps1`、两种吞掉退出码的写法）。**3 个「无效变异」如实记录且查证**：去掉 `exec`、去掉 `exec` 后追加一条命令、把子进程接进 `cat` 管道——三者**行为等价**（`set -euo pipefail` 下 `pipefail` 与 `set -e` 各自就保住了失败子进程的状态），故断言**是属性而非机制**，消息不写「exec 必须替换 shell」 | 真实 Git Bash、真实 `cygpath`、真实 `powershell.exe`——桩模拟的是**接口**不是实现，证明不了 Windows 会接受这些 argv 或这些环境值 |
| `25-ps-client-installer-contract` | `skill/assets/client/windows/install-client.ps1`（**563** 行）的**参数契约**与**平台闸门**，9 例（2026-10-07 加 W4 成对原子性用例，见下）——**该资产此前从未被执行过**（`01` 做 AST 解析、`10` 断言四条源码不变量，两者都不运行它）。这是给**它的姊妹** `install-agentq.ps1` 在 `13` 里做过的那件事，同一类缺口。**可跑**：参数契约（缺值／未知参数／`-Check` 下的未知参数，3 条实测消息）+ `-?`（PowerShell 自带的帮助开关，打印 synopsis 退 0——**唯一可达的零退出路径**，断言 synopsis 列出三个真实参数且不写文件）。**平台闸门**：合法调用在非 Windows 上必须失败且失败信息是 `This installer must run on Windows`（不是缺资产错误、不是静默成功）；**闸门必须先于任何写入**（用文件系统证明——gated 运行后目标目录必须仍为空）；`-Check`（只读模式）**也必须撞闸门**（一个在非 Windows 上短路成成功的 `-Check` 是静默通过的空操作）。**变异 5/5 被抓**（软化闸门消息、删掉闸门、`-Check` 提前短路成 exit 0、闸门前写入残留文件、重命名 `-DestinationDirectory` 使 synopsis 漂移）。**W4（2026-10-07，成对原子性）**：安装器重构为 `Install-CommitSet`（全部暂存→统一提交，`finally` 沿用规则 K 的错误合并写法）；本检查用 AST 把 `Install-CommitSet` 连同 `New/Remove-InstallerTemporaryFile` 与 reparse 守卫**抽出真跑**（平台闸门之外的函数是纯 .NET；照 smoke/22/23 手法），断言：第二件暂存失败时**两个目标都原封不动**、失败原因**就是**那条暂存错误（不相关的 throw 也会让目标不变——第一版没钉原因，被 happy-path 反向抓出过一次假绿）、happy path 两件都提交、零残留。**变异 1/1 被抓**（退回逐件「暂存+替换」→ `first client was replaced despite the second failing`）。**不覆盖**：提交阶段中途崩溃（两次 `[File]` 之间）——无事务文件系统上不可原子，残留靠 `--check` 检出、重跑自愈 | **staging／ACL／原子移动的其余部分与 PATH 更新**——`Install-CommitSet` 之外的一切在 macOS 上不可达（实测：合法调用在闸门处即退 1、目标目录 0 残留），需要真 Windows；摘要行明写 `pair-atomic=covered staging=NOT-covered(needs-Windows)` |
| `26-record-read-paths` | **`lookup` 与 `wait` 的请求记录读取路径的契约**，38 例（2026-10-06 加 W6：两个可见任务共用同一 AgentQ 标签时必须退 4/`ambiguous`，不得把「检查成功但结果不唯一」说成「无法检查 Pueue」退 2——六处折叠 rc=4 的调用点已修，变异验证被抓），跑在合成运行时上（`pueue`/`pueued` 桩必须同时答 `status --json` **和** `group --json`）。填补 `18` 留下的缺口（`18` 只覆盖 `status` 的记录扫描）。**实测确认 `logs` 不是记录读取路径**——它只 `compact_task`——所以刻意不在本检查内。覆盖：**lookup**——畸形记录退 2 + `reason=protocol_error`；`state=removed`+墓碑退 5 且记录被归档（0/1）；无记录无墓碑退 3 `not_found`；只有墓碑退 5 `removed`；`prepared`（任务未入队列）退 3 `not_started`；`accepted`（任务已从 Pueue 消失）退 5 `removed`；非法 request-id 退 2。**wait**——`unknown AgentQ task id` 退 2；匹配墓碑退 5 `was already removed before wait`；匹配 `accepted` 记录退 5 `was removed before wait` 且记录被归档（0/1）。**两条安全属性**：① **W4**——**两条记录都声称同一 task id 时必须退 2 拒绝**（`multiple AgentQ request records match task id`），不得默默挑一条；② **W5**——匹配的**活跃记录优先于墓碑**（走记录分支、归档记录、保留墓碑，counts=0/2）。先测真实行为再写断言（全部结果来自实测，非构造）。**变异 6 个被抓**：W4 守卫改「first-match-wins」（3 处红）、`lookup` 的 `not_found` 改退 0（1 处）、`fail()` 去掉 `reason=` 行（4 处）、跳过 `wait` 的归档（1 处）、去掉墓碑扫描的 `[ -z "$matched_record" ]` 前置守卫（4 处）。**3 个 MISSED 如实记录且逐一查证**：跳过 `lookup` 自己的 `archive_removed_request` **无观测差异**——`acquire_operation_lock` 会先跑 `ensure_request_record_layout → migrate_removed_request_records → repair_removed_request_records`，那是**每条命令**的必经之路、它自己就把 `removed` 记录归档了，所以 `lookup` 那次调用是**冗余的**（同一机制抄在两处，A9/A19/规则 E 同类）；同理 `wait` 扫描里对 `removed`/`removing` 记录的分支**不可达**（`removed` 被锁的 repair 先归档、`removing` 被 `ensure_daemon → recover_removing_requests` 先归档，两者都早于 `wait_reconcile_missing_task` 的扫描），所以那两个变异无观测差异。**1 个无效变异**：交换记录/墓碑的 `if/elif` 顺序**是 no-op**——墓碑扫描被上游的 `if [ -z "$matched_record" ]` 挡住，记录一匹配就不再扫墓碑。**1 个我自己的假绿**：W5 初版用「树里放一条 `removed` 记录 + wait 无关 id」来测「跳过 removed」，实测该记录**在本检查扫描前就已被 repair 归档**，用例什么也没测；改为「`accepted` 记录 + 墓碑并存」这一**真正可达**的分支后才有效。 | **真机行为**——全部跑在 macOS 合成运行时上，不证明真实 Pueue/远端/Windows；**`wait` 扫描的 `removed`/`removing` 分支在本检查里不可达**（见左，被更早的归档 pass 遮住），故**不声称覆盖它**；只覆盖 `lookup`/`wait`；`submit`/`cancel`/`remove` 各自的记录读取路径见 `27-record-write-paths` |
| `27-record-write-paths` | **`submit`/`cancel`/`remove` 的请求记录读取路径的契约**，41 例（2026-10-06 加 S6/C4：无效 `--workdir` 必须在**任何写入之前**拒绝（缺陷原形：拒绝消息打出后照样以 `workdir:""` 落盘并入队——`normalize_workdir` 的 `fail` 在 `$( )` 里只终止子 shell，而 `with_operation_lock` 的 `if "$@"` 上下文又关掉了整个命令体的 errexit，调用点已改为显式 `|| return $?`）；任务消失但 marker 为 `pending` 时必须退 4/`cancellation_pending` 而非 `unknown AgentQ task id`），合成运行时（与 `26` 同一骨架）。填补 `26` 行「不覆盖」列最后那一半。覆盖：**submit**——已存在记录但 payload 不同必须退 2（`request id was already used with different submit arguments`）；只剩墓碑必须退 2（`already consumed ... has been removed`）；记录 `state=adding` 且 payload 匹配时必须退 4 `ambiguous` 且**不得重新入队**（`refusing to enqueue it again`）；`pueue add` 返回一个 Pueue 渲染不出的 id 退 4；`pueue add` 返回可渲染的 id 则成功（`reused:false`、记录归档为 `accepted` + 该 task id）。**cancel**——首次取消 running 任务走 kill、写 `requested` 标记、退 0；**重放**须 `reused:true` 且 `cancellation_requested_at` 逐字不变；未知 id 退 2。**remove**——匹配的 `accepted` 记录被归档成墓碑且任务移除（退 0、counts 0/1）；**任务可见但记录缺失必须退 2**（`missing AgentQ request record while removing task`）而非静默丢弃元数据；未知 id 退 2。**变异 6/6 被抓**：submit 的 payload 比对恒真（3 处红）、submit 的 `adding` 分支不再退 4（3 处）、cancel 重放分支删掉（1 处）、cancel 的 unknown-id 改退 0（3 处）、remove 缺记录守卫改静默（消息红）、remove 成功路径不写墓碑（2 处）。**两个实测坑（都改变了第一版用例、非猜测）**：① `normalize_workdir` 把 `/tmp` 解析成 `/private/tmp`，所以「匹配 payload」的记录必须写**解析后**的 workdir，否则每个 submit 用例都落在 payload-mismatch 分支上、测不到目标分支；② 若桩在 `pueue add` **之前**就报告该 task 可见，submit 走的是**恢复**路径（`reused:true`）而非 add 路径——S5 因此改用**有状态桩**（`add` 后才可见）。**可达性边界（实测，如实记录）**：submit 的 `removing` 分支在本检查里**不可达**——`ensure_daemon → recover_removing_requests` 会先把该记录归档（与 `26` 记录的同一遮罩）；cancel 的 **queued** 分支（队列移除 + `queued_removed`）需真实排队任务，由 `smoke/03` 端到端覆盖，**本检查不声称覆盖**。 | **真机行为**——全部跑在 macOS 合成运行时上，不证明真实 Pueue/远端/Windows；**submit 的 `removing` 分支不可达**（被更早的归档遮住）；**cancel 的 queued 路径**不在此检查（见 `03`）；只覆盖这三条命令的记录读取决策，不覆盖 `status`/`doctor` |
| `28-client-interrupt` | **POSIX 客户端的中断路径**——信号必须既**停住**操作、又**清理干净**，且对每个信号都成立。4 例（TERM/INT/HUP 各一 + 一个无信号对照），**不需要 sshd 或 pueue**：用桩 `ssh` 在客户端**发起 SSH 调用期间**给客户端自身发信号（信号发给**父进程**是关键——证明 handler 在一次未完成的 SSH 调用中运行；从外部对客户端进程组发信号分不出两种形态，因为前台进程组的子进程也会收到）。断言两件事：退出码必须是 **130**（`sshp`/`install-client.sh` 的既有约定），且**重定向的 `TMPDIR` 零残留**（重定向让「零残留」是真断言而非指望）。**它存在的理由是一个真实缺陷**：客户端在 `:313` 设 `trap cleanup_config_snapshot EXIT HUP INT TERM`、在 `:1201` 又设 `trap cleanup_client_runtime EXIT`——第二次只换掉 EXIT 槽，HUP/INT/TERM 仍指向早已被清空的 `cleanup_config_snapshot`（空操作）；而 bash 里信号 handler **返回后 shell 继续执行**（实测），于是 Ctrl-C 既不停 `wait`、也不跑运行时清理，若随后被 SIGKILL 则残留一个 0700 的 askpass wrapper。修复即 `trap 'cleanup_client_runtime; exit 130' HUP INT TERM`。**这条检查是「先写能红的检查」的产物**：写它之前我先按读码判定 `ssh_stderr_capture` 只是「窗口小、影响轻」，写完一跑，它**立刻报出** `agentq-ssh-stderr.*` 在三个信号下各泄漏一个——那是另一条我尚未修的缺陷（`run_ssh_logged` 的 4 个早退绕过唯一删除点、且该文件不在 `cleanup_client_runtime` 清单里），随后一并修掉。**变异 2/2 被抓**（去掉信号 trap → 三信号均报 `did not stop the client (exit 255)`；把 `ssh_stderr_capture` 从 cleanup 清单移除 → 报残留）。对照用例是刻意的：没有它，一个「永远退 130」或「根本不分配临时文件」的客户端能过全部信号用例。**不覆盖**：真实远端/sshd/协议（桩 ssh 只负责发信号），以及 **SIGKILL**（不可捕获，任何 trap 都盖不住；残留断言只针对可捕获信号） | 真实远端与协议行为；SIGKILL；Windows 客户端 |

`02` 会在临时目录里自建一个最小运行时（目录结构 + `pueue`/`pueued` 桩），
否则服务端在解析参数**之前**就因缺少可执行文件退出 2——那样即使参数校验
完全损坏，检查也照样通过。每个用例同时断言 stderr 内容，所以失败可归因。

**这套检查无法发现行为回归。** `skill/assets/unix/agentq-server` 是 5,332 行无类型
shell，没有编译器、没有类型系统。**2026-09-29 起已纳入 git**（用户明确授权的一次性动作；此前本仓刻意不做版本控制，`.gitattributes` 用 `* -text` 钉住字节一致性，`.gitignore` 用机制挡住凭据落库）。smoke 证明的是：能解析、两条
canonical 资产一致、坏参数被正确拒绝、命令集合没漂移。它不证明任何分支的
行为正确。

改 `skill/assets/` 时把这一点计入风险，尤其是当你动的是 `agentq-server` 或客户端的
非主链路分支时。降低风险的办法只有两个：针对你正在改的具体函数新写针对性
测试，或对改动做真实的手工验证再记录结果。

`run-tests.sh` 自身有五道防假绿：**先 `bash -n` 每个检查，不通过就 FAIL**
（脚本在末行出现语法错误时仍可能以自身的 `exit 0` 收尾，退出码看不出问题——
2026-09-20 实测：`exit 0` 后跟一个未闭合的 `if`，bash 打印
`syntax error: unexpected end of file` 却仍退出 `0`）；`exit 0` 但无输出的检查记为
FAIL；一个检查都没跑记为 FAIL；**跑过的检查数必须等于发现的检查数**，否则 FAIL
（这条是补出来的：检查列表原先放在 stdin 上，而 `07` 会起真实 `sshd` 并用 `ssh`
驱动它——ssh 读 fd 0 把剩余列表抽干，于是后面的检查从未执行却仍报 PASS；列表
现放在 fd 3，heredoc 与进程替换都仍走 stdin，救不了）；有 SKIP 时总结行之后紧跟
一行 `NOT A FULL PASS: N check(s) skipped and therefore not verified.`——**SKIP 不是
PASS**，而原先把提示放在总结行下方容易被滚过去，`PASS 10 ran, 3 skipped, 0 failed`
读起来就是全绿。

### 怎么让 `03`/`04`/`06`/`07` 真的跑起来

本机没有安装运行时，所以 `03` 默认跳过。要真跑，需要一个带 `pueue` 的运行时
（`04`/`06` 只需要 `AGENTQ_SMOKE_HOME` 指向一个含真实 `pueue` 的目录，它们各自
在 `/tmp` 下自建运行时；`03` 则要求该目录本身就是一个**可用运行时**——有
`config/pueue.yml`、`data/`、`runtime/` 和一个**已在运行**的 `pueued`）：

沙箱有脚本，先试它：

```sh
./sandbox.sh up      # 建沙箱、校验哈希、起 pueued，打印 AGENTQ_SMOKE_HOME
AGENTQ_SMOKE_HOME=/tmp/aqsb/home/.agentq ./run-tests.sh
./sandbox.sh down    # 停 pueued 并删除沙箱
```

`up` 幂等（已在跑就直接打印路径）；二进制缓存在 `/tmp/aqsb-cache`，重复运行不重新
下载。它从 `install-agentq.sh` **抽取**哈希而不是复制一份，所以两边不会分叉。
脚本在仓库根目录、**不在 `smoke/`**——`run-tests.sh` 用 `find smoke -name '*.sh'`
发现检查，放进去会被当成检查执行。只动 `/tmp`，不碰真实 `~/.agentq` 与 launchd 域；
`down` 只删带 marker 的目录（无 marker 则拒绝删除）。

手动搭建的等价步骤：

```sh
# 1. 建沙箱 home，从安装器内置的 URL 取二进制，并用安装器内置的哈希校验
#    （见 install-agentq.sh 的 release_base 与 pueue_sha256）
# 2. config/pueue.yml 必须写【绝对路径】——run_pueue 用 env -i HOME="$HOME"，
#    资产里的 '~/.agentq/...' 会展开到真实 home，把 pueued 指向真实数据目录
# 3. 补齐运行时布局（缺一个都会在运行时报错，而不是被跳过）：
#      <agentq_home>/pueue            可执行（准入条件，缺则整个 03 SKIP）
#      <agentq_home>/agentq-server    可执行（03 直接把它当服务端用）
#      <agentq_home>/config/pueue.yml
#      <agentq_home>/data/agentq-cancellations
#      <agentq_home>/data/agentq-requests/.locks
#      <agentq_home>/data/agentq-requests/.tombstones
#      <agentq_home>/runtime
# 4. 先手动起 pueued，再跑测试：
AGENTQ_SMOKE_HOME=<agentq_home> ./run-tests.sh
```

**`AGENTQ_SMOKE_HOME` 指向 agentq home 本身**（即 `$HOME/.agentq`），不是它的父目录
`$HOME`——检查要的是 `$AGENTQ_SMOKE_HOME/pueue` 与 `$AGENTQ_SMOKE_HOME/agentq-server`。
指错一层不会报错，只会让 `03` 继续 SKIP（因为 `pueue` 找不到），很容易被误读成
"环境不满足"。2026-09-21 实测：本机一次完整的沙箱运行是
`AGENTQ_SMOKE_HOME=/tmp/aqsb/home/.agentq ./run-tests.sh` → **10 ran, 0 skipped, 0 failed**。

**`pueued` 必须在跑，且要确认它真的在跑**：服务端的 `ensure_daemon` 找不到 daemon 时
在 macOS 上会走 `launchctl kickstart`（服务变更）。另外 `pgrep -f <模式>` 在这台机器上
对沙箱 `pueued` 匹配不到（实测），别用它判断——直接看 socket 是否出现、`pueue status
--json` 是否有响应。

**沙箱路径必须短。** `pueued` 在 home 里绑 unix socket，macOS 上路径超过
`SUN_LEN`（约 104 字节）就 `path must be shorter than SUN_LEN` 直接起不来。
macOS 的 `$TMPDIR` 是 `/var/folders/<长哈希>/T/`，**用它会失败**；用 `/tmp`。
`04`、`06`、`07` 都会自建临时运行时，三者都已避开 `TMPDIR` 并对此有显式检查。
`07` 额外要求 `/usr/sbin/sshd` 存在（macOS 自带；没有就 SKIP），并可用
`AGENTQ_SMOKE_CLIENT` 指向另一个客户端二进制（变异测试用）。

`04` 不需要外部沙箱即可自建运行时，但它同样需要 `AGENTQ_SMOKE_HOME` 指向一个
**含真实 `pueue` 二进制**的目录（用来复制进自己的临时运行时）。它把 `pueue`
包一层脚本，通过**文件**（不是环境变量）控制哪个子命令失败——因为
`run_pueue` 走 `env -i`，环境变量传不进去。

**先手动起 `pueued` 是必须的**：服务端的 `ensure_daemon` 在 macOS 上找不到
daemon 时会走 `launchctl kickstart gui/<uid>/com.agentq.pueued`——那是服务变更，
且指向真实的 launchd domain。daemon 已在运行时第一次 `status --json` 就返回，
永远不会走到那一步。（2026-09-20 实测确认：沙箱里 daemon 没起来时，这条路径
确实被走到并执行了 `launchctl kickstart`；因该服务不存在而失败，没有产生副作用。）

### 改这个服务端要知道的性能事实

本机一次 fork+exec 约 15ms，而 `status` 要调几十个子进程——**执行时间基本由
子进程数量决定**，不是由计算量决定。改热点路径前先数子进程：

```sh
# 用 shim 记录所有子进程调用
mkdir -p /tmp/shim && for c in stat jq mktemp perl find grep awk tail tr base64 date ps; do
  printf '#!/bin/sh\necho "%s" >> /tmp/shim/log\nexec "%s" "$@"\n' "$c" "$(command -v $c)" > /tmp/shim/$c
  chmod +x /tmp/shim/$c
done
: > /tmp/shim/log
PATH="/tmp/shim:$PATH" /path/to/agentq-server status >/dev/null
sort /tmp/shim/log | uniq -c | sort -rn
```

一个真实例子：身份读取原先每次都先试 GNU `stat -c`（BSD 上必然失败）再退回
`stat -f`，一次 `status` 里 48 次 stat 有 24 次是白费的。改成进程内探测一次
flavor 后，子进程 65→43，`status` 约 2100ms→1760ms。

注意：`detect_stat_flavor` 这类缓存**必须在父 shell 里调用**。`$(...)` 开子
shell，在命令替换内部设置的全局变量传不回来——缓存会静默失效。

**实测补充（2026-09-21，真实 Windows 主机）：jq 调用数随累积的元数据文件线性增长。**
该机 Pueue 保留全部历史，`data/agentq-requests/` 有 272 个 record、`.tombstones/` 29 个、
`data/agentq-cancellations/` 3 个，`pueue status --json` 为 1523282 字节。用 shim 计数
（shim 指向 chocolatey 的真 jq `lib/jq/tools/jq.exe`，不是那层 .NET 壳）：

| 命令 | jq 调用 | 耗时 |
| --- | ---: | ---: |
| `status` | 1930 | 114s |
| `doctor` | 1930 | 114s |
| `lookup` | 1397 | 87s |
| `logs` | 1673 | 109s |

代码路径（读代码得出，未逐项单独测量）：`prepare_request_metadata_files` →
`load_request_records` / `load_cancellation_markers` 各自遍历目录下**每个** `*.json`，
每个文件经 `request_record_is_valid` 调 jq（另有 `validate_task_id_precision_in_file`
一次）。这些校验是完整性防御，不是可省的冗余——**所以这里不要为了提速而顺手改**：
`agentq-server` 是无类型 shell，本仓的 smoke 抓不到行为回归，而这条路径正好是安全
相关的。要优化就得先把行为钉死（针对该函数写针对性测试或真机验证），再动。

**这条路径现在有针对性检查了：`smoke/18-record-metadata-contract`（27 例）。**
它是在**改之前**先写的，并且先证明了自己能红——跳过 crash-window repair 的变体、
去掉 filename↔`request_id` 绑定的变体都被它抓住。**2026-09-30 已按这条纪律完成
一次优化**：折叠三处逐条重复的 jq，每 record 的 jq 调用 **4.05 → 1.05**
（N=40 时 169 → 49），墙钟 −37%，`status`/`doctor` 输出逐字节不变。

**2026-10-04 折叠了最后一处逐条 jq：`repair_removed_request_records`。**
它**每条命令都跑**（`acquire_operation_lock → ensure_request_record_layout →
migrate_removed_request_records → repair`），此前对**每个** `*.json` 调一次
`read_request_record_state_and_body`（内部一次 jq），而它**只需要找出
`state == removed` 的记录**去归档——其余状态一概不看。现在改成**一次**聚合 jq
（`request_removed_records_filter`），**逐条套用 `request_record_filter`**（它
**接受** `removed`，见下面 A23 那段——不能复用 `load_request_records` 的过滤器，
那会把 crash-window 状态从「归档」变成致命 `exit 2`），只输出 `removed` 记录的
`id`+正文。**任何失败都回退到原来的逐文件循环**：聚合 jq 丢掉了 per-file 的
`:1` 行号与路径归属，**无法逐字节复现** jq 自己的 parse error，而 `smoke/18` 的
`compare_case` 逐字节 diff stderr——所以回退是**保真的唯一手段**，不是可选优化。

**子进程计数（shim 实测，`status`）**：

| records | base jq / 总 | folded jq / 总 |
| ---: | ---: | ---: |
| 0 | 5 / 42 | 5 / 42 |
| 40 | 63 / 152 | 24 / 113 |
| 80 | 119 / 260 | 40 / 181 |

**每 record 恰好省 1 次 jq、1 个子进程，N=0 时零成本**。按本机单价（fork+exec
约 18ms）折合每 record 约 −20ms；生产规模（该机 272 条 record）单这一处约 −5 秒。

**这次折叠踩到一个 bash 语义陷阱，已写进检查**：`output=$(…) 2>/dev/null`
**不抑制**命令替换里命令的 stderr——重定向绑在**赋值**上、不在替换上。第一版就是
这么写的，于是快路径的聚合 jq 把 parse error 漏到 stderr，每条坏记录打印**两遍**。
而 `smoke/18` 的 `compare_case` 在默认运行里 base 与 variant 是**同一份资产**、
只 diff 两侧，**确定性的重复行两侧相同、它看不见**——我最初「以
`AGENTQ_SMOKE_SERVER=<folded>` 跑 `smoke/18` 全绿」因此是**假绿**，真正抓住它的是
**把 base 换成 pre-fold 版本**做对照（那一刻报 6 处 `stderr differs`）。修法是给
快路径的整个子 shell 加花括号 `{ …; } 2>/dev/null`。并新增第 27 例
`assert_jq_diagnostics`（每条坏记录的 jq 诊断**恰好 1 条**），它在**默认运行**下
就能红。**教训**：`AGENTQ_SMOKE_SERVER=<改后的同一份资产>` 与默认运行等价，
证明不了任何东西；变体模式的意义在于 base 与 variant **不同**。

改这条路径时先跑 `smoke/18`，它比整套 smoke 更贴近这里的行为。

**2026-10-04 又折叠了三处同类热点：`wait` 恢复与 `cancel` 重放的逐条 jq。**
折叠 `repair` 后用 jq-shim 把**全部命令**在 N=272 上重新计数，发现它们虽不在
`status` 热路径上，却在**阻塞式**的 `wait`（任务已从 Pueue 消失）与**取消重放**
（`cancel`）上每次仍对每个文件各起一个 jq：

| 路径（N=272 rec + 58 tomb） | 折叠前 jq | 折叠后 jq |
| --- | ---: | ---: |
| `status` / `doctor` | 251 | 8 |
| `wait`（任务消失） | 892 | 9 |
| `cancel` 重放（无匹配，最坏） | 339 | 10 |
| `lookup` / `logs` / `remove` / `wait`（普通） | — | 各 1 |

**至此 N=272 上全部命令的 jq 调用都是 O(1)**，不再随记录数增长。三处都用 A25 的
**快路径 + 保真回退**模式（新增 `request_records_states_filter`、
`request_tombstones_states_filter`、`request_instance_probe_filter` 三个聚合过滤器）。

**第三处（`task_instance_created_at_is_recorded`）的语义与前两处不同，是它必须单独
设计的原因**：原循环**吞掉**畸形文件（`2>/dev/null || continue`）继续扫描、**不是
fail-closed**，也不做逐文件路径守卫。所以它的聚合过滤器**必须容忍**畸形文件
（整次 slurp 失败即回退，由回退里的 `|| continue` 复现 skip 行为）——**不能**套用
fail-closed 的记录过滤器，那会把「跳过畸形文件」变成「拒绝整个重放」。且原循环
**先扫记录再扫墓碑**（记录命中即 `return 0`、从不读墓碑），故快路径把两个列表分开扫。

**验证**：三处各自与 pre-fold HEAD 做**逐字节**对照（stderr + stdout + 退出码），
覆盖命中记录/命中墓碑/无匹配/畸形文件回退/文件名与 id 不符/多墓碑取首个匹配，
全部 IDENTICAL。变异 `MR1`/`MR2`/`MR3`（三处快路径各弄坏一处）被 `smoke/26` 抓住
（7/3/7 处红），`M3a`/`M3b`（实例探测恒真/恒假）被 `smoke/03` 抓住。

**折叠后 jq 不再是热点，但别被首次运行的总子进程数吓到（2026-10-04 实测）。**
在 N=272 rec + 58 tomb 上量 `status` 的**全**子进程数：**首次运行 522**（278 stat /
120 jq / **58 perl**），**稳态 44**（2 perl / 8 jq）。差的是 **28 条 `removed` 记录
被归档进墓碑**——每条 2 次 `durable_sync_file`（perl，本机每次约 50ms）+ 若干 stat，
是**一次性**成本；第二次、第三次跑都是 44。所以「`status` 变慢了」的排查要**先跑第二遍**
再计时，否则量到的是 crash-window 归档的成本，不是常态。剩下 26 次 `stat -f %d:%i`
是 `make_temporary_file`/`install_temporary_file` 的 inode 身份/TOCTOU 守卫——
**不要为提速删掉**（省 4 个子进程、换掉一条安全属性，上面已记过两次）。

同一台机器上 `logs`/`status` 达到分钟级是这个规模因子的结果，不是卡死——排查时先数
元数据文件，再怀疑死锁。

**实测补充二（2026-09-24，同一台 Windows 主机）：取锁在昂贵准备工作之**前**，
锁把扫描串行化了。** 调用链是 `status_with_operation_lock` → `with_operation_lock status`
→ **先** `acquire_operation_lock`，**拿到锁之后**才执行 `status()`，而
`compact_status` 里的 `prepare_request_metadata_files`（遍历 273 条 record、
每条多次 jq）在**锁内**。所以 N 个并发 `status` **不是**「各自先扫描再排队」，
而是**在锁内串行做 N 次全量扫描**——后果同样是分钟级，但**锁是有效**的，
是它把扫描排成了队。（我一度把顺序写反并据此怀疑锁没起作用，已更正；
`doctor` 同形。）

**实测补充三（2026-09-24，同上）：Windows 上每次嵌套 `powershell.exe` 约 12 秒，
而锁恢复路径每次重试都要起一个。** `process_identity_state` 的 windows 分支
**每次调用都 spawn 一个嵌套 `powershell.exe`** 去查进程身份；`acquire_operation_lock`
在**每一次**重试里都经 `process_is_confirmed_dead` 调它。该机实测裸
`powershell.exe -NoProfile -NonInteractive -Command 'exit 0'` **12.9s**，而
`uname -s` 只要 **3.2s**——**成本在 PowerShell 自身启动，不在脚本**（脚本经 stdin
13.1s、作参数 11.2s，差别在噪声内）。所以 `lock_acquire_attempts=30` 在最坏情况下
仅锁循环就是**数分钟**。**这是设计上的乘数，不是缺陷**：30 次 × 12s ≈ 6 分钟，
再加上元数据扫描。排查该机的"卡住"时先量这个，再怀疑死锁。

**实测补充四（2026-09-25，同上主机）：`status` 从 114s 变成 5m47s，原因是 jq 走了 chocolatey 的 .NET 壳，不是代码变慢。**
对照实验（**同一命令、同样 1930 次 jq 调用**，只换 PATH 上的 jq）：

| jq 实现 | 端到端 | 单次调用 |
| --- | ---: | ---: |
| 真 jq（`chocolatey/lib/jq/tools/jq.exe`，985KB） | **1m51s** | 23ms |
| chocolatey 壳（`chocolatey/bin/jq`，392KB .NET wrapper） | **5m47s** | 167ms |

**3.1 倍端到端、7.1 倍单次**，全部来自那层 .NET 包装。`CLAUDE.md` 上面记的 114s 是**准确**的——那次用 shim 指向真 jq；默认 PATH 上解析到的是壳，所以按默认环境实测会得到 5:47。**排查该机「变慢了」时先看 `command -v jq` 解析到哪个**，再看元数据规模。修法是让真 jq 在 PATH 上先于壳（升级后实测 1m17s）。

**实测补充五（2026-09-29，本机沙箱 macOS 15.7.7 / bash 3.2.57）：jq 整数精度探测曾按子 shell 重复执行，
每条 record 多付一次。** `jq_preserves_integer_digits()` 用 shell 变量缓存探测结果，但服务端**从子 shell 里调用它**
（`load_request_records` 的 `{ …; } | jq` 管道左侧、以及多处 `$( )`），而子 shell 里赋的变量**传不回父 shell**——
这是本仓记过三次的 `$( )` 陷阱的**第四次**（管道形式）。修法是在 `ensure_runtime_dependencies()` 里、
**任何子 shell 存在之前**顶层调用一次（子 shell 继承父变量）。**实测**（各 3 次中位数）：

| records | 改前 | 改后 | 提升 |
| ---: | ---: | ---: | ---: |
| 0 | 1836ms | 1545ms | 16% |
| 10 | 3872ms | 2734ms | 29% |
| 20 | 5744ms | 4181ms | 27% |
| 40 | 9714ms | **6685ms** | **31%** |

jq 调用数（3 records）**28 → 19**，其中精度探测 **10 → 1**。**每条 record 的边际成本约 195ms，优化后约 130ms。**
**本机原语单价**（20 次中位数，改热点前先看这个）：裸 fork+exec **17.9ms**、`stat` 20.0ms、
`mktemp` 18.6ms、`jq -c` 22.1ms、**perl fsync（`durable_sync_file`）50.1ms**。
空库 `status` 的 43 个子进程 ≈ 1.2s，**执行时间基本就是子进程数量 × 18ms**，不是计算量。

**同一次测量里两处「看起来该改但其实不该改」的地方**（记录以免下次重复劳动）：
① **34 行相邻重复的校验调用**（`require_runtime_temporary_file` 连续 2–4 次等）是 bash **内建**、不产生子进程——
实测删掉 25 行后计时**无可测差异**（1822ms vs 1913ms，噪声内）、输出逐字节相同，**不必动**。
② **`load_request_records` 对同一条 record 校验两遍**（逐条 `jq -ce` + 聚合 `jq -cse`），确实是每 record 2 次 jq，
但两处规则**不等价**——逐条版多接受 `state == "removed"`，聚合版会拒绝它。删任何一个都**改变行为**，
而这是安全路径，**不要为提速顺手改**。

**探针超时 `AGENTQ_PLATFORM_PROBE_TIMEOUT`（默认 30s）在这类机器上偏紧**：同一次
`status` 期间若主机被别的负载压住（实测我自己的孤儿把该机推到 **load=42**），
探针会被拖过 30s 预算并报 `remote platform/protocol probe timed out`，看起来像
客户端缺陷。**机器空闲时同一探针只要 2 秒**（实测，两种探针各两轮）。所以见到这个
超时时先看目标机负载，再怀疑探针。
