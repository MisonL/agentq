# AgentQ — 开发秩序

<!-- toc -->
- 这个项目是什么
- 日常开发流程
- 协议契约
- 改完 skill/ 必须同步全局 Skill 目录
- 操作边界
- 实测证据与测试覆盖
<!-- /toc -->



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
    windows-git-bash/  agentq（服务端，与 unix 版逐字节相同）、durable-move、launcher、start-daemon、installer
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
实测该缓存损坏出现过四次（2026-09-26、2026-09-28 ×2、2026-09-29），**四种形态
各不相同**（`String cannot have zero length` ×2、`Stack overflow`、
`System.IO.FileLoadException`），所以不能靠匹配消息识别。
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
（`agentq-server` 里 `remove_cancellation_marker_for_task` 的调用点之一，
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
这是**已修复的缺陷**（2026-09-22，修法与取证见 `docs/PLAN.md` A6），不是"窗口正常关闭"，
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
- **`~/.local/bin/agentq` 在服务端主机上是 wrapper，不是客户端。** 服务端安装器把它写成
  60 字节的 exec wrapper，客户端安装器的默认目标又是同一个路径——所以在同时跑服务端的
  主机上装客户端会**冲突**。两个安装器现在都拒绝制造或加固这个状态（客户端装到该路径
  会退 `2`；服务端升级发现该路径上是客户端也退 `2`），冲突时用
  `install-client.sh --bin-dir <其他目录>`。实测 2026-10-09（WSL 主机）：此前是**静默
  覆盖**、退 `0`，wrapper 消失、客户端就位，随后远端 `agentq_run` 执行到客户端自身，
  所有协议调用以 `2` 与空输出失败。
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
- **不得只升级服务端或只升级客户端。** 这是刻意的设计决定（`docs/PLAN.md` B2 选了
  「刻意不做」）：没有协议版本协商字段，`doctor` 的 `agentq=`（2026-10-08 加）只是
  **信息行**——报告这台机上部署的是哪个 AgentQ 版本，用于发现「只升了一侧」的部署漂移，
  **不参与任何协商**；`pueue=`/`pueued=` 是队列
  实现的版本、不是 AgentQ 的协议版本。部署单元就是 `skill/assets/` 那 23 个文件的同一
  版本，必须整体替换。将来若要跨版本互操作，先加协商字段。
- 规划与待办的唯一权威清单是 `docs/PLAN.md`。`docs/HANDOFF.md` 只保留操作规则与边界；
  别处出现的待办（HANDOFF 的历史段落、CHANGELOG 的过程记录）都是历史，不是任务。

已明确取消、**不是待办也不是验收门槛**：压力测试；重启/注销/物理断电验收；
历史全量扫描；完整历史 `shasum -c`；为每个旧 fixture 重建当前报告。

真实远端服务、队列、TLS/shared key、生产凭证均**未被验证**，不要声称已验证。


## 实测证据与测试覆盖

以下内容已拆分为独立文件（2026-10-08，用户指示「文档太长、可读性差、拆分」），
正文逐字未变：

- [`docs/verification-status.md`](docs/verification-status.md) —— 哪些结论已
  实测、哪些没有，以及 **`smoke/` 二十九项检查各自证明什么 / 不证明什么** 的覆盖表、
  `run-tests.sh` 的防假绿机制与沙箱跑法。**改 `skill/assets/` 或声称任何覆盖前必读。**
- [`docs/performance.md`](docs/performance.md) —— `status` 的子进程与耗时事实、历次实测，
  改热点路径前先读。