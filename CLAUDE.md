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
`umask 077` 的临时文件、取出 reason、随即删除。**这条路径的教训是 fixture 的**：
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
都是 `5`），保留期内不会失效。CLAUDE.md 速查表与 SKILL.md 里的"已消费"是
**措辞不准**：服务端只在 `submit` 路径上用"consumed"表示拒绝复用该 ID
（`request id was already consumed ...`），读取路径没有消费语义。


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

**仍然未被验证**：NTFS reparse 点语义（只确认了文件系统是 NTFS 与上述 ACL 实测，
未测 reparse 点本身）、原生 Windows 上的真实远端队列、生产凭证。

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
   **submit 路径尚未照做**：launcher wrapper 仍是 `-EncodedCommand`（长度 2,426，在预算内，
   所以 `smoke/14` 不报它）且没有 token。改它要先解决通道冲突（stdin 已在传 base64
   payload，token 只能走 stdout）。

**仍未验证**：`DefaultShell` 真的配置为 `powershell.exe` 的真实主机（那一列是
用外层 `powershell -c` 模拟的，机制是 PowerShell 自身的、结论可靠，但无真机）。
2026-09-25 在一台真实 Windows 主机上确认了**另一列**：该机 `DefaultShell` **未设置**
（= Windows 默认 `cmd.exe`），实测 `2`/`5`/`124`/`42` 经 ssh **原样传回**。所以
**A5b 的压平问题在该机不成立**——它是 `powershell.exe` 那一列独有的，而那列仍无真机。
这是「不做 A5b」的第二个理由：唯一能验证它的配置我们没有。
`smoke/14` 钉住长度与"脚本不在命令行上"两条不变量，但**不能**验证真机行为。

## 测试覆盖的真实边界（重要）

`smoke/` 十八项检查，各自证明什么、不证明什么：

| 检查 | 覆盖 | 不覆盖 |
| --- | --- | --- |
| `01-syntax-and-parity` | 覆盖全部 23 个资产的语法/结构解析：9 个 shell 资产 `bash -n`/`zsh -n`；7 个 `.ps1` 的 PowerShell AST 解析；2 个 `.plist`（`xmllint` + `plutil -lint`）；2 个 `.yml`（pyyaml）；1 个 `.service`（结构：必需 section、`ExecStart` 以 `/` 或 `%h/` 开头、`WantedBy`）；2 个 `.cmd`（结构：委派目标存在，且 `-NonInteractive` 必须与被委派脚本的交互性**一致**——`sshp` 刻意交互，`sshp.ps1` 里有 `Read-Host` 且驱动 `ssh -tt`，所以它**不带**该标志才是对的，规则要求匹配而非一律要求存在）；两条 canonical 资产逐字节相同；**`.editorconfig`/`.gitattributes` 里每个带路径的模式都必须命中真实文件，且 `.editorconfig` 必须仍有一个段为 `skill/assets` 下的东西设 `end_of_line = unset`**（2026-09-29 新增）。后两条是同一个真实缺陷的回归锁：Skill 移入 `skill/` 后，`.editorconfig` 的 `[assets/**]` **仍然解析正常、却一个文件也不匹配**——两种格式里「模式匹配不到任何东西」都不是错误，只是静默停止保护。用真实 editorconfig 实现验证过：两条 canonical 资产当时解析成 `end_of_line=lf` / `trim_trailing_whitespace=true`，正是那一节要防的事。**当前是潜伏缺陷而非正在生效**——实测 23 个资产 trailing-ws=0 / 无末尾换行=0 / CRLF=0，所以没有文件被改写过。变异 6 个中 5 个被抓，1 个 MISSED 如实记录（`asset_protection=1` 单独无效——守卫在基线上本就不触发，与 `smoke/16` 关闸门那个变异同形；它与「删掉整段」组合时才会抑制检出，实测该组合通过而单独删段被抓）。另有 1 个**我自己的假绿**：`glob_to_regex` 里 `local glob=$1 ... n=${#glob}` 的展开早于赋值，`n` 恒为 0、正则恒为空串、**什么也不匹配**——若没有 `config_patterns=0` 那道自检闸门，它会报出三条「pattern matches no file」而把正确的配置全报成违规；是闸门先报出「一个模式都没提取到」才暴露的 | 任何行为；`.cmd` 仍无解析器，只有上述结构断言；配置模式规则只证明「模式命中真实文件」，不证明编辑器真的遵守 `.editorconfig` |
| `02-error-contract` | 9 个坏调用返回 2、**报出预期的错误消息**、**且带 `reason=protocol_error`**；usage 列出的命令集合与文档一致。`reason` 断言在这里是回归锁：任何一处丢掉 reason 行、或把类别写成别的值，都会红 | 正常路径；`task_not_running` 一类（它的运行时是桩，没有真任务，该类别在 `03` 覆盖） |
| `03-protocol-roundtrip` | 真实运行时上的 submit→lookup→status→wait→logs→remove；失败任务必须被 `wait` 拒绝；未知 request id 的 `lookup` 必须是 `3`/`not_found`；陈旧的空 operation lock 必须被自动恢复；**cancel 两条路径**——running 走 kill（须报 `cancel_requested_at`、不得报 `queued_removed`）、queued 走 remove（须报 `queued_removed`，且其后 `wait` 必须是 `5`/`removed` 而**不是**完成、`lookup` 须一致）；**cancel 重放**须 `reused: true`/exit `0` 且时间戳不变，**并且**在复用 id 上放一个 `created_at` 不匹配的陈旧 marker 时必须仍被拒（exit `2`）；**对已结束任务 cancel** 须 exit `2` + `task is not running` + `reason=task_not_running`（这一类只有真运行时能构造，所以放这里而不是 `02`）；**base64 日志**（非 UTF-8 任务输出必须以 `output_encoding: "base64"` + `output_base64` 返回，解码后须与写入字节逐一相同——只在 `--tail all` 路径可达）；**`doctor` 正常路径**（stderr 须报 `pueue=`/`pueued=` 版本，stdout 须以可用队列状态收尾）；**复用 id 上的歧义身份**（id 复用时若同一条 id 上有两个实例，`wait` 必须退 `6`/`unavailable`、**不得**带 `task` 字段、stderr 须含 `ambiguous AgentQ identity`——这是 `task_identity_is_unambiguous` 的**安全半边**，此前无任何用例直达，`04` 的 `unavailable` 走的是包装脚本那条路；红测把该函数变异为恒真后，`wait` 会返回一个它无法担保的 `"result":"Success"`，断言当场报出） | — |
| `04-degraded-contracts` | 两个"降级"契约：`wait` 无法确认终态时必须是 `6`/`unavailable`；`cancel` 意图已持久化但 Pueue 未确认时必须是 `4`/`cancellation_pending`，且 `pending` 必须能被后续 `status` 读到 | 真实 Pueue 故障（用包装脚本模拟） |
| `05-client-contract` | POSIX 客户端 `skill/assets/client/unix/agentq`：16 个坏调用必须 exit 2 且报出预期消息；**10 个**环境变量非法值必须被拒（摘要行自报 `cases=16 env=10 cred=4`——`env=5` 是**少报**，本轮修正：原先只数了 5 个环境变量拒绝，没把凭据那几条算进去）；`--help` 必须 exit 0；畸形远端响应不得被报成成功；**`reason` 穿过 SSH 跳**——客户端须把远端的 `reason=` 行转成 `remote failure reason: <class>`，且**不得**回显原始远端 stderr，畸形/注入形态的 reason 行须被整条忽略；**Windows 探针路径（2026-09-24 新增）**——用忠实的 MINGW64 桩（`uname -s` 答 `MINGW64_NT-10.0-19045`，故走 `probe_native_windows_platform` 分支）断言探针脚本**真的到达 stdin**（字节数 > 0）、Windows 路径**能跑完**、`TMPDIR` **零残留**。**这一节是因为静态检查抓不到它才存在的**：A5a 的修复把探针脚本改成经 stdin 喂给 `-Command -`，而承载它的临时文件路径写在一个**在 `$( )` 里被赋值**的全局变量上——命令替换开子 shell，赋值传不回来，于是 stdin 恒为空、PowerShell 读到 EOF 就退 0，客户端报 `unexpected response`、**连不上任何 Windows 主机**。`smoke/14` 量的是命令行长度与「脚本不在命令行上」，这两条在缺陷下**依然全为真**（探针确实还在用 `-Command -`，只是没内容），所以它一路绿灯。把旧版客户端换回去实测：三条断言全红（`EMPTY Windows probe script on stdin (got 0 bytes)`、`left 1 file(s) in TMPDIR`）。同一段代码里另有两个缺陷也一并钉住：身份记录在**使用它之前**被清空、临时文件**从未登记进 EXIT trap**（每个探针漏一个，而 Windows 目标要跑两个）。**submit 的 payload 送达（2026-09-24 新增）**——同一类盲区的第二处：上面钉住的是**探针**的 stdin，而 submit 走的是另一条通道（`-EncodedCommand` 的 launcher wrapper，payload 经 stdin 传 base64），静态检查同样只能确认客户端**还在发** `-EncodedCommand`，看不出喂进去的 base64 是空的。断言分两层：payload **字节数 > 0**，且解码后的 NUL 分隔参数向量里**真的含**该次 submit 的 workdir 与 request id。**选取方式本身是个坑，已钉进注释**：status 也走同一条 launcher 路径且**先**执行，所以按 `calls.txt` 里第一条 `launcher` 记录取值会量到 **status 的 payload**——第一版就是这样：断言看着在测 submit，实际测的是 status，且因为 status payload 非空而**恒绿**；改为按桩记录的下标把每次 launcher 调用映射回它写的那份 payload 文件，再取首个参数为 `submit` 的那份。变异 3/3 被抓（payload 空、payload 是错的向量、payload 是合法 submit 向量但**缺参数**），**三类失败各报各的消息**——第一版把它们塌成同一句 `never invoked the Windows launcher`，而 launcher 其实被调用了、只是 payload 坏了，会把人指错方向；空 payload 的判定范围是**最后一次** launcher 调用，跨调用累积会把「status 空、submit 正常」误报成空 payload。**分支可达性单独证明过**：客户端在 Windows submit 下必然走 launcher 路径，故「launcher 从未被调用」那条分支**无法**由变异客户端产生——把断言块抽出来喂合成 `calls.txt` 单独跑，五种输入各得其所。写这一节时又抓到一个**自己的假绿**：计数原先写成 `grep -c ... || printf '0'`，而 `grep -c` 无匹配时**既打印 `0` 又退 1**，变量成了 `0\n0`、下面的 `-eq 0` 报错为假，那条分支**永不执行**；改用 `awk`。**submit 之后的 TMPDIR 残留也断言上了**——原先那条零残留断言只在 **status 之后**跑，而 submit 会分配**自己**的临时文件（base64 payload 与 ssh stderr 捕获），只查两个操作里的一个正是本节要纠正的那类错误（实测 submit 路径本来就不残留，断言是钉住它）。为这条 submit 残留断言找变异时**两个变异无效**（如实记录）：status 与 submit **共用** `build_windows_remote_command`，破坏该函数的清理先被 status 那条断言抓住；改成「第二次调用才泄漏」后没被抓到——追查发现 submit 的 payload 文件由**另一条 submit 专属**清理块负责，改错了对象。真隔离的是 M6：只拆 `submit_input_file` 的清理，报 `client left 1 file(s) in TMPDIR after a Windows submit`。另有 1 个变异是**坏变异**（`printf 'submit\0'` 写出字面反斜杠、stub 解不出来，它什么也没测——记录在此以免被当成证据）。**凭据来源的 argv 断言（2026-09-28 新增）**——本检查新增一个记录完整 argv 与 askpass 环境的 ssh 桩，断言客户端在**有来源时**传 `BatchMode=no` + `NumberOfPasswordPrompts`、且导出 `SSH_ASKPASS_REQUIRE=force`；**无来源时**传 `BatchMode=yes`、不带 prompts 选项、且 `SSH_ASKPASS` **必须是未设置而非空串**（OpenSSH 测 `getenv() != NULL`，空串会让它去 exec 空字符串——实测行为，非推测）。这条覆盖的是一个**静态检查看不见的洞**：`14` 量命令行**长度**、`01` 只做语法解析，一个「永远传同一个值」的客户端两者都能过。**两个方向都断言**是刻意的，理由与 `12` 的 auth-hint 用例同。另有 **10 个**拒绝用例（不存在／**带参数**／**带引号**／**引号在路径中间**／不可执行／符号链接／是目录／两者都设／prompt 值非法／prompt 无 tty）与一条「askpass 临时文件零残留」断言。**三个形态拒绝用例的判据是文件系统而非字符**：ssh 把 `SSH_ASKPASS` 的**整个值**当**单个文件名** exec，所以**含空格的路径合法**（`C:\Program Files\...`），而带参数／带引号不合法——**两个方向都断言**，因为「含空格即拒」这个过度收紧会把合法路径一并拒掉（我上一轮真犯过，`12` 的合法形态用例也为此加了 `space` 一例）。**引号在路径中间**是单独一条，不是凑数：只锚定**行首**引号的模式能过「带引号」那条而**仍然接受**这个形态，实测 `/tmp/.q/\"ap.sh` 不可 exec，变异 M1（模式退回行首引号）当场被这一条抓住（`1 failure(s)`，消息正是缺陷原型 `does not exist`）。**写这一节时抓到一个我自己的假绿**：失败检查块原先在凭据断言**之前**，于是那些 failures 计数全被累加却**从不被检查**——检查照常报绿；是变异测试（把守卫改成恒假后仍绿）暴露的。已把该块移到凭据断言之后。变异 6/6 被抓；**本轮新增的形态守卫另有 3 个变异全部被抓**：M1 模式退回「只认行首引号」→ `1 failure(s)`；M2 守卫恒拒（`-or $true`，Windows 侧）→ `12` 报 `1 failure(s)`；M3 整个去掉形态守卫 → `3 failure(s)`。**M2 顺带暴露了 `12` 的归因缺陷并已修**：四处断言原先写成 `if [ exit -ne 2 ] || ! grep -qF <消息>`，把「没拒绝」与「理由不对」塌成同一句，于是**确实拒绝了、只是理由错**会被报成**没有被拒绝**；现在拆成两条分别报。 | 任何真实远端；Windows 客户端（它的 `InputPayload` 是直接传的、无此形态，已用 pwsh 单独确认 payload 非空）；`TMPDIR` 之外的位置；submit 路径的**退出码通道**（A5b 仍未做，`DefaultShell=powershell.exe` 时非零仍被压平为 1，本条只证明 payload 送达、不证明退出码不失真） |
| `06-lock-contention` | operation lock 竞争：被拒的 `submit` 必须是 exit `2`、stderr 含 `already in progress`（带程序名前缀）**且带 `reason=lock_contention`**；被拒的调用**零副作用**（无 task id、无 request record）；用**同一 request ID** 重试必须成功且只产生一个任务；重复提交须报 `reused: true` 且复用同一 task id；锁必须被释放 | 真实的高并发压力（用包装脚本制造**确定性**竞争，不是并发压测）；`lock_acquire_attempts`/`lock_retry_delay_seconds` 的**数值**（脚本从服务端读取它们来算等待窗口） |
| `07-client-transport` | **真实 SSH 传输**上的 POSIX 客户端：起一个用户级 `sshd`（全新 host key、高端口、只监听 127.0.0.1，不碰 `/etc/ssh`、不碰真实 `authorized_keys`、不需 sudo），用 `environment="HOME=..."` 把远端 home 重定向进沙箱，再让仓库客户端连过去。断言退出码 **0/1/2/3/5** 穿过传输不变形（含失败任务不得被报成成功）、`not_started` 崩溃恢复态、`queued_removed`→`wait` 5、以及 `reason=protocol_error` **真的穿过真实 SSH 跳**（`05` 用桩 ssh 钉同一件事，这里是端到端复核）。**第 8 节（A7）**用 `ssh-flaky` 包装注入网络中断：按 `agentq_run '<op>'` 取操作名、用 `fail.<op>` 倒计时控制第几次失败、把每次调用记进 `calls.<op>`——**命令先真的执行再伪装失败**，否则「服务端做完了、调用方只看到失败」这一形态不存在。三条契约：submit 丢响应须退 0 + `reused:true` + **该 label 恰好 1 个任务**；cancel 丢响应须退 255 + `calls.cancel` **恰好 1**（多一次即被禁止的自动重试）+ 靠读取确认取消确已生效；status 遇瞬时中断须退 0 + `calls.status` **恰好 2**。两个坑已钉进注释：取消确认的通道**取决于走哪条路径**（Queued→`queued_removed`，任务从 Pueue 消失、`status` 里没有它，只能靠 `lookup` 经 tombstone 读到 `removed`；Running→kill，`status` 带 `.agentq.cancellation_requested_at`），以及 `set -o pipefail` 下 `lookup | jq` **恒判假**（`lookup` 对 removed 按设计退 5），必须**先捕获再匹配** | 真实远端主机；Windows 目标；`~/.ssh/config` 提供的选项（沙箱 sshd 用全新密钥，不读用户配置）。第 8 节的故障是**注入**的，不覆盖真实网络栈的失败形态 |
| `08-jq-path-arguments` | 服务端**绝不把文件路径当参数交给 jq**（必须走 stdin `< "$file"`，或经 `jq_file_argument` 转换）。做法：把 jq 包一层记录 argv 的 shim，跑完整个命令面后断言没有任何绝对路径作为位置参数出现。这条对应一个**真实的 Windows 缺陷**：服务端在 windows 分支导出 `MSYS_NO_PATHCONV=1`，而 jq 是原生 Windows 程序，`jq -e FILTER /tmp/x.json` 会 `Could not open file`（同一文件走 stdin 则正常）。修复前 `status`/`doctor` 退 2 并报 "group is missing"、`submit` 把请求对账成 `removed`、`logs` 退 6——全都被报成数据问题，看不出是环境问题。10 处调用点，10 个变异全部被抓到 | 运行时不经的 Windows 专属分支；jq 的 filter 语义本身。**注意证据形状**：服务端有**只会在 Windows 上执行**的分支（导出 `MSYS_NO_PATHCONV=1` 的那些），macOS 上没有任何检查会走进它们，`08` 是用 shim 断言「不把路径当 jq 参数」来**间接**覆盖的——这是间接证据，不是执行证据。没有 Windows 机器就关不掉这个缺口；它是已知的局限，不是「已覆盖」 |
| `09-native-argument-quoting` | 没有哪个 PowerShell 资产把**多行脚本**当命令行参数交给原生程序（必须走 base64 经 stdin，或文件）。做法：源码扫描，拒绝三种形态——here-string 变量作参数、变量未经 base64 通道、字面量里同时含双引号与空格。这条对应一个**真实的 Windows 缺陷**：PowerShell 5.1 把含空格的参数用 `"` 包裹传给原生程序，却**不转义参数内部已有的 `"`**，包裹层在脚本第一个引号短语处提前终结，CRT 解析器把余下部分词分割。实测（Windows 10 / PS 5.1.19041）同一段脚本三种形态：`# a " b` 到达 bash 时裂成两个参数；`echo "hi there"` 变成 `echo hi` + `there`；无引号则完好。pwsh 7.5 无此问题。缺陷现场：为修 jq 路径参数而加的一行注释 `# reports "Could not open file".  Verified on Windows 10 ...` 让整段 status 命令只剩 `set -e` 加半行注释——bash **静默 exit 0、零输出**，status 文件照写 1.5 MB，jq 从未运行；失败在四层之外以 "Pueue shell smoke task result was empty" 现形，安装器回滚。9 个变异全部被抓到，另有 3 个安全形态确认不被误报（检查里内置了一个 CRT 参数解析模型 `crt_argc`，先用实测的 5 组对照校准：`# a " b`→2、`echo "hi there"`→2、真实缺陷注释→4，而 `"$PATH" --config "x"`→1、`printf "%s" "$MSYSTEM"`→1 均完好——所以它不是「见到引号就报」的启发式）。检查还内置了该模型的**自检**：五组实测对照在每次运行时重算，模型被改动而不符则拒绝给出结论，而不是静默放宽 | PowerShell 5.1 的实际行为**已不再完全不覆盖**（2026-09-25：5 组校准值在一台真 PS 5.1.19041 主机上逐条复现、argv 逐字一致——见下方性能补充四）；本检查本身仍只做源码扫描，只覆盖本仓扫描到的调用形态 |
| `10-installer-invariants` | 两个 Windows 安装器、三个 launcher 协议拷贝、以及两份 POSIX 安装器的**十条**不变量（A–G，其中 A 与 E 各含两个检查点；**G 覆盖 POSIX 安装器**：每个 `mv` 之后其所在函数内必须有复核，16 个站点实测全部合规，作用域是函数而非行窗口——固定窗口两个方向都错，我在规则 G 里把两个方向都犯了一遍）。逐条对应本会话在真机上发现的安装器缺陷：**A** 每个 `[int]$MaximumBytes` 声明都必须带默认值（逐处检查，不是「至少一处」——3 处声明里只查 1 处，实测会漏掉另两处被剥夺默认值的变异），且至少一个调用点抬高它，且读取器内不得再有内联上限（缺陷现场：硬编码 1 MiB 上限，而该机真实 status 为 1507407 字节，安装器拒绝更新）；**B** 用 `1> $file` 重定向写的 JSON 要求读取端保持 BOM 感知——这条表达的是**耦合**而非禁止：重定向让 PowerShell 经控制台代码页解码子进程 stdout 再编成带 BOM 的 UTF-16LE（字节数翻倍），但读取端已加固为识别 BOM 且实测能正确读回，所以「禁止重定向」会误伤能工作的代码，真正的不变量是「有人丢掉 BOM 处理时这些站点会静默失效」；**C** 客户端安装器不得调用 `chmod`（noacl 挂载上它是静默空操作）；**D** 每个 `Set-Acl` 都必须在**同一函数内**有 `Get-Acl` 读回。D 的作用域是函数而非固定行窗口——窗口两个方向都错：本处的读回在写入之后 6 行（含注释），而宽到能容纳它的窗口也会接受属于**下一个**函数的读回；变异 `d-readback-in-next-fn` 正是验证这一点（把读回挪进下一个函数，仍被拒）。**E** launcher 的 payload 协议在三份拷贝（launcher 自身、Windows 客户端内嵌 wrapper、POSIX 客户端内嵌 wrapper）之间必须一致——上限数值与退出码**就是**协议，而 01 的 parity 只覆盖两条 `agentq-server`；实测单独把 POSIX 侧上限改成 1048577（该客户端会发出、launcher 会拒绝的 payload）全套检查依然全绿，故补此条。比较用 token 序列而非字节（POSIX 是 `;` 连接的单行、Windows 是缩进多行，逐字节比会在正确代码上报红），四类分叉实测全部被抓：改任一侧内嵌上限、改 launcher 自身上限、改 `exit 2`、删分支。**变异计数不再单列**：规则集在 2026-09-24 从 8 条扩到 10 条（新增 F、G），逐条各自记录——A–E 时期为 9 个，F 为 2 个，G 为 3 个；合计 14 个全部被抓到，1 个安全形态（改注释措辞）确认不误报。**F（2026-09-24 真机新增）**：ACL 对象的属性名必须真实存在——服务端安装器读的是 `$acl.AccessRulesProtected`，而 .NET 的真实属性名是 `AreAccessRulesProtected`；**客户端安装器一直是拼对的**，两份拷贝不一致，而只有一份在真机上被跑过。在 `Set-StrictMode -Version Latest` 下读不存在的属性会**抛错**（不是返回 `$null`），于是 ACL 校验那步让每次安装都死在该行——实测主机 A 上安装器回滚干净、部署未受影响。规则 D 抓不到它（`Get-Acl` 读回**存在**），只有真机能执行那一行，所以属性名在源码级钉住：允许集是「本仓实际读到的两个类型的属性」，`AccessRulesProtected` 不在其中。**变异 2/2 被抓**（服务端、客户端各一），基线绿。**注意 `AccessControlType` 是合法的**（`AccessRule` 的属性，不是 ACL 对象的），已在允许集里——第一版漏了它，把 4 处正确代码报成违规 | 安装器是否真的能装——那仍需真机；每条规则只保证「这个具体失效无法再静默复发」，不等于正确 |
| `11-installer-contract` | `skill/assets/unix/install-agentq.sh` 的**失败契约**——15 个用例，全部必须在安装器写入任何东西之前被拒。这是本仓最大的零行为覆盖资产（2,755 行，此前只有 `01` 的 `bash -n` 碰过它），而本会话 7 个缺陷里 6 个是安装器缺陷，正是这个洞的预测结果。做法沿用 `05`：只测契约不测成功路径。该安装器纯环境变量驱动、**顶层不解析 argv**（函数栈判定，非 grep），所以可测面是一张干净的拒绝清单。三条隔离手段缺一不可：HOME 指向沙箱、PATH 换成桩（本机真有 `jq` 和 `brew`，沙箱 HOME **挡不住** `brew install`）、包管理器全部换成「记录并失败」的桩——因此「什么都没装」是断言而非期望。另有 fixture 自检：先证明安装器能走到**依赖解析**这一步，否则全部用例会一起报同一个错消息（这个自检抓到过一次真问题：漏拷 macOS 的 plist 时，全部用例都死在缺资产上）。**变异 11/11 被抓**（2026-09-22 复测：先前文档里记过 7/7 与 10/10 两套互相矛盾的数字；重跑 11 个变异后有 4 个 MISSED，逐个手工构造情形查证，**全部是可达但本检查从未走过的分支**——`~/.agentq` 是普通文件、下载路径的哈希校验、陈旧锁的恢复与再确认。已补 4 个用例：用例数 11 → 15，并为此新增一个产出坏内容的 `curl` 桩和一个「只答一次身份查询」的有状态 `ps` 桩（后者用于钉住 `recover_stale_maintenance_lock` 的 TOCTOU 再确认，单进程 fixture 里否则不可达） | **成功路径**（要下载 pueue、写 `~/.agentq`、注册服务，需真机与授权）；`prepare_service_stage` 之后的一切（launchctl/systemctl 行为）；Windows 安装器；哈希用例只证明**拒绝坏二进制**，不证明接受好的 |
| `12-ps-client-contract` | `skill/assets/client/windows/agentq.ps1` 的本地契约，**在 pwsh 下真正执行**——40 个用例（原 32，本轮补一组凭据用例：`Get-CredentialSshOptions` 两个方向各断言一次、数组**拼接是否真的落到 argv**（选项串对了但没进 ssh 等于没做）、以及三个黑盒拒绝用例——`AGENTQ_PASSWORD`／`AGENTQ_PASSWORD_PROMPT` 在 Windows 上必须被拒（该平台 ssh 无控制台时读 `_getwch()` 会**挂死**而非报错），`AGENTQ_ASKPASS` 指向不存在的文件必须被拒。**这三个拒绝用例刻意走进程调用而非 dot-source**：拒绝路径是 `exit`，而 dot-source 脚本里的 `exit` 会终止整个脚本、`try/catch` 看不见它——第一版就是这么写的，报绿而实际什么也没测。变异 4/4 被抓。**本轮又加三条（36 → 39），针对一个真机发现的守卫缺陷**：ssh 把 `SSH_ASKPASS` 的**整个值**当**单个文件名**执行（无 shell、不分词），所以**带参数或带引号的形态永远不可能工作**；而守卫原先**只校验第一个 token**（源自「`cmd.exe /c helper.cmd` 是可行形态」这个**已被真机推翻**的假设），于是**接受**了这两种形态，失败最终以 `class=timeout` 现形——**把配置错误说成连接超时**。两条新用例断言这两种形态被守卫拒绝（真机复核：`rc=2` + 消息点明原因），**第三条断言合法单路径必须仍被接受**——这条是**补出来的**：先做的变异 M2（把守卫改成无条件拒绝）**报 MISSED**，查证后确认是**用例缺口**而非变异无效（此前没有任何用例验证「合法配置能过守卫」，一个拒绝一切的守卫能全绿），补上后 M2 被抓（`1 failure(s)`）。**用例计数从 41 改为 40 是修掉一个真错**：那一轮在合法形态的 `for` 循环**之前**多留了一次 `cases=$((cases + 1))` 与 `status=0`，而循环内两次迭代各自也计数——所以 41 是**重复计数**，实际用例是 40。**同时把四处「未拒绝」断言拆成两条**（退出码一条、消息一条）：原先写成 `if [ exit -ne 2 ] || ! grep -qF <消息>`，两件事塌成一句「was not refused」——M2 变异（守卫恒拒）当场暴露它会把**确实拒绝了、只是理由不对**说成**没有被拒绝**，而消息明明就在 stderr 里。现在分别报「没有拒绝（期望 2，实得 N）」与「拒绝了，但理由不是它」。原 32 中有一组认证提示用例：四个诊断串各跑 `Write-Diagnostics`，断言认证类**必打**提示且**须含目标主机名**、其余 class **必不打**；第二个方向不是凑数——提示若对所有 class 都打就退化成操作者学会跳过的噪音，那正是原提示失去价值的路径。变异 5/5 有效者被抓，1 个无效变异如实记录：把 `-eq "authentication"` 改成 `-eq "Authentication"` 报 MISSED，查证为**变异无效**——PowerShell 的 `-eq` 本身大小写不敏感，实测 `"authentication" -eq "Authentication"` 为真，`-ceq` 才敏感，该改动行为完全不变）（原 29，补了一组 `reason` 通道用例，本轮又补一条 exit-token 用例：8 个分类用例直接调 `Get-RemoteFailureReason`）。此前该资产只有 `01` 的 AST 解析与 `10` 的两条源码不变量，从未被运行过；它的坏参数契约原先只是 `CLAUDE.md` 里「已在 Windows 11 实测 13 例」的文字记录。**必须重定向 `AGENTQ_CONFIG`**：客户端会从 `~/.config/agentq/config` 读 `AGENTQ_HOST`，而本机**确实存在**该文件，不重定向时「无 host」用例会静默解析出真实 host、走到别的分支——读开发者自己配置的检查不是封闭的，换台机器行为就变。变异 7/7 被抓；**2026-09-25 起可在真 PS 5.1 上跑**（`AGENTQ_SMOKE_PWSH=powershell.exe`，实测 `cases=31 pwsh=5.1.19041.3996 ps51=covered`）。**注意这条覆盖是「按需」的**：默认仍跑 `pwsh`，此时摘要报 `ps51=NOT-covered` —— 那是准确的，因为 pwsh 7.5 **不复现**本项目实际踩过的两个 PS 5.1 缺陷（`09` 建模的词分割、`-EncodedCommand` 路径）。要看 PS 5.1 的真实行为必须显式设该变量，并在一台真 Windows 机上跑（PS 5.1 不接受 POSIX 路径作 `-File`，检查已用 `cygpath -w` 处理） |
| `13-ps-installer-contract` | `skill/assets/windows-git-bash/install-agentq.ps1`（2,881 行，全仓第二大资产，此前**从未被执行过**——`01` 只做 AST 解析、`10` 只做四条源码不变量）的参数契约与平台闸门——6 个用例：4 个参数错误消息（缺 `-StageDirectory`、缺值、空值、未知参数）+ 平台闸门（非 Windows 上必须失败，且**不得**留下事务目录、**不得**改写交给它的 staged 资产）+ **闸门先于 staging 校验**这条顺序（用**空** stage 目录证明：顺序若被改反，错误会从平台错误变成缺资产错误）。变异 3/3 被抓（去掉 `ValidateNotNullOrEmpty`、把 `-StageDirectory` 改成可选、拆掉 `GetCurrent` 闸门） | **这台机器上不可达的一切**：staging / 资产校验 / sha256 / ACL / 事务与回滚，全都需要真实 Windows。已实测确认不可达而非推测：**任何**参数组合都在第一条语句 `Resolve-GitBashPaths` 上以 `Windows Principal functionality is not supported on this platform` 死掉，且空 stage 目录与填满的 stage 目录报**同一个**错——闸门在 staging 校验之前。所以本检查**不**覆盖安装器的行为，只覆盖参数契约与闸门的前置性；`10` 的四条不变量仍是该文件仅有的源码级保障 |
| `14-remote-command-length` | 两台客户端发出的**远端命令行长度**必须 <= 7,869（三种 `DefaultShell` 实测上限的最小值 8,125 减 256 安全边际）——5 个站点：POSIX 协议探针、POSIX 平台探针、POSIX launcher wrapper、Windows 协议探针、**Windows launcher wrapper（本轮补，此前从未被测量——把它撑到 26,538 字符也全绿）**。**量的是命令行，不是脚本体**：把脚本搬到 stdin 之后「脚本多大」不再是风险，量脚本会把修好的代码报成红的。所以站点 1/4 抽取**客户端实际发出的命令行常量**，并额外断言它**不含 `-EncodedCommand`、含 `-Command -`**；站点 2 断言平台探针**路由**经那两个助手（它不内联命令行，只共享常量）。实测顺序：先红（8,658 / 10,146 两处超限）→ 改代码 → 全绿。**站点 2 一度是假绿**：抽取标记 `encode_windows_powershell "` 在平台探针改用 stdin 后只匹配到 launcher 的调用点，量到的是变量名（25 字符）、报出无意义的 150——绿灯但什么也没量。三个变异（两端各自退回 `-EncodedCommand`、平台探针单独退回）全部被抓 | **真机行为**：命令是否真的能在该终端下跑、退出码是否真的不失真、我们没测过的终端其上限是多少。这条只证明「命令行足够短且脚本不在命令行上」这个静态事实；A5b 的退出码通道（stdout 上的 `agentq-exit:<code>`）是**另一条**不变量，本检查**不覆盖** |
| `15-transient-pueue-failure` | **瞬时 Pueue 读取失败不得被当成「任务不存在」**——P0 缺陷的回归锁（2026-09-24 外部审查发现）。缺陷机制：`find_request_task` 用 `fail`（即 `exit 2`）表达「读不到 Pueue」，而 6 个调用点全是 `if task=$(find_request_task ...)` 形状——**`exit` 在 `$( )` 里只终止子 shell**，调用方拿到空串 + 假条件，判定任务不存在，于是把**活着的** request 归档成 `removed`（删 record、写 tombstone，任务继续跑）。后果永久：`lookup` 永远 `5`、任务丢掉全部 `agentq` 元数据、request id 再也不能复用。做法：自建真实运行时，包装 `pueue` 只在**第 2 次** `status --json`（即 reconcile 那次；第 1 次是 `ensure_daemon` 的探测，失败会让服务端去 `launchctl`）注入一次失败，然后断言五件事——必须报 exit `2` + `reason=protocol_error`、**record 数不变**、**tombstone 为 0**、**不得报 `removed`**、Pueue 恢复后 `lookup` 必须仍能解析到同一 task id 且任务仍 `Running`。修复前（`1bbfd403`）五条全红、消息精确；修复后全绿 | 除这一处注入外的其它 Pueue 故障形态；`cancel`/`logs`/`remove` 路径上同一根因的**消息误导**（它们 exit `2` 传播正确，只是把「读不出来」说成「id 不存在」）|
| `16-no-host-identifiers` | **仓库与记忆里不得出现任何主机标识**——这条**规则早就写在文档里**（`CLAUDE.md` 操作边界「仓库与记忆里一律不出现主机名或 IP」），`CHANGELOG` 也记着 2026-09-22 清过 9 处、验证方式是「全仓正则扫描、排除回环、零命中」。**但没有任何检查重跑那次扫描，于是规则静默失效**：到 2026-09-27，仓库里重新出现 **7 个不同地址、46 行**，另有账号名、两把**他人公钥的注释串**（含真实姓名与两个机器名）、一个 `~/.ssh/config` 别名，以及**由地址派生的私钥文件名**。做法：五条规则扫全仓每个文本文件 + 记忆目录——`R1` 非回环 IPv4、`R2` mDNS 主机名、`R3` `user@fqdn`、`R4` `@含数字的裸词`（抓 `R3` 漏掉的序列号式主机名）、`R5` **被压成标识符的地址**（私钥文件名那个形状，`\b` 在这里失效——第一版就是这么写成「永远不匹配」还报绿的）。**输出里的匹配一律打码**，只留前两个字符与长度：检查自己的输出会被阅读、粘贴、归档，原样打印等于把检测器变成新的泄漏通道。**先自校准再扫描**：五条规则各自必须在**它存在的形状**上触发、且在**替换它的占位符**上保持沉默，自校准不过就不给结论；另有一条 canary 把已知坏内容喂进**真实扫描路径**，独立于自校准地证明 grep→判定→退出码这条链是通的。**变异 11 个中 10 个被抓**，1 个 MISSED 如实记录：单独关掉自校准闸门（`if false`）**没有任何可观测变化**——闸门本来就没触发过，单看这一个变异是良性的；它与「某条规则被放宽」组合时会被 canary 抓住（实测 `R2`/`R5` 各自 + 关闸门 → 报 `canary caught 4 of 5 rules`），所以**不声称它是缺陷，也不声称它被覆盖**。真实红/绿已验：把清洗前的 `PLAN.md` 放回去 → 27 处违规、五条规则全部触发；换回当前版本 → 0 | 任何**不具这五种形状**的地址写法（记成「角落那台机器」的扫描器看不见，这是刻意的边界而非疏漏）；`find` 会跳过的二进制文件；规则本身只证明「这五种形状不在文本里」，不证明别处没有 |
| `17-askpass-credential` | **POSIX 客户端的密码认证路径，跑在真实 sshd 上**。客户端原先 4 处 ssh 调用全部硬编码 `BatchMode=yes`（它禁用全部交互式认证），所以只有密码的目标机连不上。现在配置了凭据来源就改传 `BatchMode=no` + `NumberOfPasswordPrompts`，并经 askpass 取密码；**没配置时逐字节不变**。本检查断言两件事：**有来源时端到端跑通**（真 sshd、真 pueue、submit→wait 的 `result` 必须是 `Success`）、**无来源时 ssh 仍拿 `BatchMode=yes` 且 askpass 一次都不被调用**。两个方向都断言是刻意的——只测一个方向，一个「永远传同一个值」的退化实现也能过（`12` 的 auth-hint 用例已为同类理由写过这个论证）。**凭据来源是三种**：`AGENTQ_ASKPASS`（可执行程序，**排第一**——AgentQ 因此从不接触密码本身，只传程序名）、`AGENTQ_PASSWORD`（环境变量）、`AGENTQ_PASSWORD_PROMPT=1`（人类交互）。**守卫是严格的**：来源配置了但不可用（不存在／不可执行／符号链接／是目录）必须**拒绝运行**（exit 2 + 原因），**不静默回落到密钥认证**——静默回落会让操作者以为在用密码。**为什么用口令私钥而不是账户密码做端到端**：两者走**同一条 `read_passphrase → ssh_askpass` 代码路径**（实测 prompt 文本不同、机制相同），而 macOS 上非 root 的用户级 sshd **无法验证任何真实账户密码**——`getpwnam().pw_passwd` 是 `'********'`、无 `/etc/shadow`、`/usr/sbin/sshd` 无 setuid 位、`UsePAM yes` 明确要求 root。所以账户密码**登录成功**这一环本机测不了，需真机。**实现里三处易错点已钉住**：① 凭据解析必须在**顶层**、早于 `initialize_remote_invocation`——平台探针自己就是一处 ssh 调用，来源若只在操作路径生效，探针会先失败、命令根本走不到操作路径；② `SSH_ASKPASS` 空串**不等于未设置**（OpenSSH 测的是 `getenv() != NULL`），所以只在真有程序时才导出；③ 清理只删**自己建的**临时 wrapper，用户提供的 askpass 程序绝不动（实测把两者混为一谈时清理会去删用户的文件）。变异 6/6（POSIX 参数构造）与 3/3（端到端）全部被抓，其中一个是「清理越界删除用户程序」 | **账户密码登录成功**（macOS 非 root 限制，见左）；**Windows 侧全部**——`agentq.ps1` 的实现已就位并在 pwsh 下断言了选项构造（`12` 的 4 个新用例），但真机行为未验。Windows 上 `AGENTQ_PASSWORD`/`AGENTQ_PASSWORD_PROMPT` **刻意拒绝**（该平台 ssh 无控制台时读 `_getwch()` 会挂死，且没有顶层 trap 可挂清理），只支持 `AGENTQ_ASKPASS`；且 Windows 的 `SSH_ASKPASS` 取值必须是**一个可执行文件的路径**——ssh 把整个值当**单个文件名**执行，无 shell、不分词，**不能带参数、不能加引号，但路径里的空格合法**（判据是「整个值是不是一个存在的可执行文件」而非「有没有空格」；真机实测含空格路径 rc=0 成功。原先的：`cmd.exe /c helper.cmd` 报 `ssh_askpass: exec(...): No such file or directory`；指向带 shebang 的脚本则正常）。**2026-09-29 真机复核**：POSIX 客户端经**真实账户密码**（非口令私钥）在 macOS 主机上跑通完整协议 （`submit`→`wait` 的 `Done.result=Success`→`logs` 回 `Darwin`→`remove`），Linux 目标同样跑通；**这是 A18 标注为「尚未在任何真实主机上验证」的那一项，现已验证**。Windows 客户端已升级到 canonical 并在真机确认守卫与 ACL；**经 Windows 客户端发起的端到端也已验证**（Windows → 那台只有密码的 macOS 主机：`wait` 退 0 + `Done.result=Success`、`logs` 回 `WIN-E2E-OK\nDarwin`、`remove` 回 `removed:true`）。**仍未测的是原生 Windows ssh**（`System32\OpenSSH\ssh.exe`）下的行为——该机 PATH 上解析到的是 **Git Bash 的 MSYS ssh**，两者不是同一实现，所以「原生 ssh 下能否用带参数形态」在这台机器上测不到 |
| `18-record-metadata-contract` | **`status` 的 request-record 元数据扫描的契约**——21 例，跑在临时目录里自建的合成运行时上（含 `pueue`/`pueued` 桩，桩必须同时答 `status --json` **和** `group --json`，否则 `status` 死于 "group is missing"，看起来像记录问题而其实不是）。**这个检查存在的原因是本仓文档一直写着「smoke 抓不到行为回归」，而本轮用实验坐实了它**：一个跳过 crash-window repair 扫描的变体（约 1.9× 加速）会让合法的 crash-window record **永远无法自愈**，却跑出 `17 ran 0 failed`；另一个去掉 filename↔`request_id` 绑定的变体**静默接受**错配记录，同样全绿。所以先写能红的检查、再改扫描代码。断言：① 8 类坏记录必须 exit `2` + `reason=protocol_error`，且**完整 stderr 与基线逐字节相同**（含 base 因内层 `fail` 落在 `$( )` 里而多打的那条 `missing ... during recovery`——第一版读取器把结果赋给变量而非走 stdout+`$( )`，**丢掉了这条消息**，正是这个检查抓到的）；② 合法 crash-window 状态（`removed` record + 已写 tombstone）必须自愈成 record 0 / tombstone 1；③ `task_id: null` 对 prepared/adding **合法**；④ 好记录的输出逐字节一致。**每个用例都重新播种记录目录**——`status` 会**写**（把 `removed` 归档进 tombstone），两棵树共用一个目录会让先跑的那次消费掉后跑那次要看的输入，报出 IDENTICAL 而实际什么都没测。**变异 3/3 被抓**：跳过 repair → `crashwin: exit code differs (baseline 0, variant 1)` + `did not self-heal`；去掉绑定判据 → `mismatch: expected exit 2, got 1`；把校验的 `error(...)` 换成恒真 → 8 处失败。**1 个 MISSED 如实记录且已查证不是覆盖漏洞**：把**聚合**过滤器换成恒真（`jq -cse .`）报绿——因为 `repair`（pass 1）会先拒掉每一条坏记录，聚合那层的绑定检查在 `status` 路径上**不可达**；另外**直接**用 `jq -cse --args -f` 单独喂给它错配/匹配两种记录，确认判据本身正确（错配 error、匹配通过）。该结论写在检查的注释里，以免绿灯被过度解读。**也记下我自己的两个假红**（都改了检查、没改代码）：`normalize()` 没剥两棵树各自的绝对路径，对**未改动**的服务端也报 7/21 失败 | **真机行为**——全部跑在 macOS 的合成运行时上，不证明真实 Pueue/远端/Windows；**聚合过滤器的绑定检查在 `status` 路径上不可达**（见左，`repair` 先拦住）；只覆盖 `status`，不覆盖 `lookup`/`wait`/`logs`/`submit` 各自的记录读取路径 |

`02` 会在临时目录里自建一个最小运行时（目录结构 + `pueue`/`pueued` 桩），
否则服务端在解析参数**之前**就因缺少可执行文件退出 2——那样即使参数校验
完全损坏，检查也照样通过。每个用例同时断言 stderr 内容，所以失败可归因。

**这套检查无法发现行为回归。** `skill/assets/unix/agentq-server` 是 4,937 行无类型
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

**这条路径现在有针对性检查了：`smoke/18-record-metadata-contract`（21 例）。**
它是在**改之前**先写的，并且先证明了自己能红——跳过 crash-window repair 的变体、
去掉 filename↔`request_id` 绑定的变体都被它抓住。**2026-09-30 已按这条纪律完成
一次优化**：折叠三处逐条重复的 jq，每 record 的 jq 调用 **4.05 → 1.05**
（N=40 时 169 → 49），墙钟 −37%，`status`/`doctor` 输出逐字节不变。改这条路径时
先跑 `smoke/18`，它比整套 smoke 更贴近这里的行为。

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
