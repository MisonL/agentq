---
name: agentq
description: 将任意授权命令提交到已配置的远程主机并持久化跟踪进度、日志、结果、失败或取消。用户要求远程执行、后台执行、SSH 断线后继续、获取目标机任务进度或结果时使用；用户需要人类交互 SSH 会话保活和重连时使用随 Skill 提供的 sshp。本地调用端覆盖 Windows CMD、PowerShell、Git Bash 与 POSIX sh、bash、zsh；目标机支持 Windows、WSL、Linux、macOS；不在目标机运行 Codex。
version: 0.1.30
---

# AgentQ Remote Queue

使用 `agentq` 通过 SSH 调用目标主机上的兼容 AgentQ 服务端。任务由远端队列托管；本机终端关闭或短暂断线后，已经提交的任务继续运行。

`sshp` 是另一条人类交互链路：它连接远端 `tmux`、`screen` 或 Zellij 会话，并在确认 OpenSSH 传输断开时重连。不要用 `sshp` 承载 AgentQ 任务，也不要用 AgentQ 模拟交互终端。首次缺少依赖的安装确认必须在本地交互终端中完成；无 TTY 时会明确拒绝，不会静默安装。

## 执行工作流

1. 先执行 `doctor`，确认指定主机可用（注意：doctor **不是只读的**，见下方硬性规则与 [`references/doctor.md`](references/doctor.md)；队列概览请用 `status --summary`，它没有这个副作用）。
2. 用短标签提交用户明确授权的命令（多行脚本直接走 `--stdin-script`，不要手工拼引号）：

   ```bash
   agentq --host build-host submit \
     --workdir /absolute/project/path \
     --label test \
     -- npm test

   cat deploy.sh | agentq --host build-host submit \
     --workdir /absolute/project/path \
     --label deploy --stdin-script
   ```

3. 从 `submit` 返回 JSON 取出任务 ID 和请求 ID。耗时任务轮询 `status --summary`（全队列）或 `status --task N`（单任务）与 `logs N --tail 200`；队列可串行或有限并发，不能假设任务立刻开始。`wait N --timeout 120` 给等待一个预算，避免无限阻塞。
4. 完成后执行 `wait N`。仅当退出码为 0 且结果为 `"Success"` 时报告成功；退出码 `1` 表示任务终态为 Failed（wait 已成功送达）；若结果非成功且 `task.agentq.cancellation_requested_at` 存在，报告取消；否则读取 `logs N` 并报告失败。`wait` 以 `6` 退出且 stderr 带 `wait budget ... elapsed` 时是**预算耗尽**，任务可能仍在跑——改用 `status --task N` 继续观察。
5. 用户明确要求停止时才调用 `cancel N`。任务已结束、日志也不再需要时调用 `remove N`；要清理同一标签的全部任务时用 `remove --label <l> --confirm`（输出数组如实标注每一项）。

## 命令面

```bash
agentq [--host <ssh-host>] submit --workdir <remote-directory> [--label <label>] [--request-id <id>] -- <command> [arguments...]
agentq [--host <ssh-host>] submit --workdir <remote-directory> [--label <label>] [--request-id <id>] --stdin-script < script
agentq [--host <ssh-host>] lookup <request-id>
agentq [--host <ssh-host>] status [--summary | --task <task-id>]
agentq [--host <ssh-host>] logs <task-id> [--tail <line-count|all>]
agentq [--host <ssh-host>] wait <task-id> [--timeout <seconds>]
agentq [--host <ssh-host>] cancel <task-id>
agentq [--host <ssh-host>] remove <task-id> | remove --label <label> --confirm
agentq [--host <ssh-host>] doctor [--full]
```

## 退出码

| 码 | 含义 | 能当作完成吗 |
| ---: | --- | --- |
| `0` | 成功 | 是（`wait` 还要看 `task.status.Done.result`） |
| `1` | 一般失败；`wait` 的**任务终态为 Failed** 也退 `1`（`wait` 本身已成功送达），另有「`pueue wait` 提前退出、任务未完成」这一种来源 | 否 |
| `2` | 参数/协议错误；**也**用于操作锁竞争（可重试）、对已结束任务 `cancel`、安装器维护锁、部署状态不对——**读 `reason=` 判类别，不要匹配消息文本** | 否 |
| `3` | `lookup` 的 `not_found` / `not_started` | 否，只用**相同 request ID** 重试 |
| `4` | `ambiguous`、`removing`、`cancellation_pending`：服务端无法安全判断 | 否，**必须停止**，不得自动重试 |
| `5` | 已移除（`removed`）；tombstone 保留期内可重复读到 | 否 |
| `6` | 无法给出可信答案：`unavailable`（`wait` 的终态不可确认、**预算耗尽**；`logs` 的身份歧义或日志不可用；`status --task` 的身份歧义） | 否 |
| `42-45` / `124` | Windows launcher / 平台探测超时 | 否 |

**`5` 和 `6` 都不是任务完成。** 退出码 `2` 的四类 `reason`（`protocol_error`、`lock_contention`、
`task_not_running`、`deployment_state`）、每种的处置方式，以及每个命令的 JSON 形状，见
[`references/contract.md`](references/contract.md)。

## 硬性规则

- **`doctor` 不是只读的**：它先确保 Pueue 守护进程在运行，未启动时会尝试启动（macOS
  `launchctl kickstart`、Linux `systemctl --user start agentq-pueued.service`）——那是服务变更；
  成功路径还会改写 request record。要只读地探查一台机器，别走 AgentQ 协议：直接 ssh 过去看
  `~/.local/bin/agentq` 在不在、版本多少。队列概览用 `status --summary`，它没有这个副作用。
- **不得只升级服务端或只升级客户端。** 部署单元是 `assets/` 下 23 个文件的同一版本，
  必须整体替换；`doctor` 的 `agentq=` 只是信息行，报告部署的是哪个版本（用来发现只升了一侧），
  **不参与任何协议协商**——本项目刻意不做跨版本互操作。
- **`wait` 必须同时核对退出码与 `task.status.Done.result`**，两者都不能省略。
- **`cancel` / `remove` 的响应丢失不得自动重试**：副作用无法与失败安全区分，先读 `status` /
  `logs` / `wait` 重新确认。只有确认的传输故障（`255`）才用**同一 request ID** `lookup` 对账——绝不换新 ID 重提同一命令。
- **多行脚本走 `submit --stdin-script`**，不要手工拼引号：stdin 内容被 base64 成单个 argv，
  远端按 `printf %s <b64> | base64 -d | sh` 解码；脚本必须是 POSIX sh 文本（Debian/Ubuntu 上远端是 dash）。
  unix 目标上限 100000 个 base64 字符；**Windows 目标上限 7800**（Pueue 执行时 8191 字符存储命令上限，
  cmd 与 Git Bash 目标同样适用），超过时客户端在本地退 `2`——超出上限的脚本先 scp 成文件，再提交读取它的短命令。
- **Windows 目标上运行原生命令**时写成 `-- cmd /c <command>` 或 `-- powershell.exe -NoProfile -Command <command>`，
  不要把 CMD 或 PowerShell 引号拼进一个未经验证的大字符串。三种 sshd `DefaultShell` 的差异见
  [`references/clients.md`](references/clients.md) 与 [`references/install.md`](references/install.md)。
- **凭据不得写进仓库、脚本或日志**；主机指纹策略（不覆盖 `StrictHostKeyChecking`）与密码认证的
  三种来源见 [`references/clients.md`](references/clients.md)。
- **用户标签不得为空、也不得以 `agentq:` 开头**；`remove --label` 按**用户标签**匹配，
  而 `status --summary` / `doctor` 的摘要只给得出 Pueue 裸标签 `agentq:<request-id>`。

## 运行语义

- AgentQ 防护的是调用端 SSH/终端中断，不承诺目标主机或队列服务发生生命周期变化时任务继续执行。Windows 服务由当前用户的交互式计划任务启动；Linux 使用 systemd 用户服务并启用 linger；macOS 使用由 root 注册、由目标用户运行的系统 LaunchDaemon。不要将调用端重连能力等同于目标任务在服务生命周期变化后的继续执行。
- Windows 服务资产位于受保护的 `C:\ProgramData\AgentQ`，不应从共享用户目录调用或修改。Linux/macOS 服务资产位于 `~/.agentq`，通过权限为 `0700` 的 Unix socket 通信；不需要也不应暴露队列网络端口。**该「0700 socket」的说法只对 Unix 成立**：Windows 上 Pueue 回落 TCP + TLS（`use_unix_socket` 是 Unix-only 字段），监听回环，其保护来自 `Set-PrivateTreeAcl` 给 `C:\ProgramData\AgentQ` 施加的私有 ACL（只有该用户、SYSTEM、Administrators），而不是文件模式——Pueue 在非 Unix 分支不设置 `shared_secret`/`certs/` 的文件模式（新建文件默认 0644），这是已记录的边界：这些凭据文件的纵深防御依赖父目录 ACL，不依赖 0600 模式（`docs/PLAN.md` A28）。
- 安装或升级只在目标队列没有活动或非终态任务时执行，历史 `Done` 记录可以保留。安装器会先暂存并校验 Pueue 二进制、验证依赖与服务端语法，再切换服务；Windows 首次启动后还会验证 Pueue 的 TLS 证书、私钥和共享密钥，并重新施加私有 ACL。健康检查失败会恢复上一份部署。**两个安装器在启动时都会拒绝「上一次运行在换根中途崩溃」的现场**：若根目录缺失或旁边残留事务目录（Windows 为 `.AgentQ.backup.*`/`.stage.*`/`.failed.*`，Unix 为 `..agentq.backup.*`/`.stage.*`/`.failed.*`——双点），它会停止并报出这些路径（旧队列与凭据就在 backup 里），等你把 backup 移回根目录恢复、或确认放弃后手动清掉再重跑——它不会自动删除、合并或恢复任何东西。Windows 上该残留优先于一切检查被拒（旧的「wrapper 已存在」提示只在无残留时出现，且不描述这一情形）。运行中的守护进程状态异常时，服务端拒绝擅自干预队列，避免中断未知任务。
- 已移除任务的请求 tombstone 默认保留 30 天，并由后续 AgentQ 操作按日清理。保留期内同一请求 ID 不能复用；过期并清理后它会变为 `not_found`，因此新任务仍应生成新的请求 ID，避免混淆历史结果。**数据留存需知**：每个 request record 以明文 JSON 保存**完整的命令文本**（`payload.argv`）与工作目录，tombstone 同样保留命令文本——队列里跑过的每条命令在 30 天内都能从数据目录读回。提交含敏感内容的命令前先想到这一点；删除痕迹需要连 tombstone 一起处理（手工清理数据目录前先确认没有活动任务，且不要绕过安装器的锁语义）。**不要清理 `.legacy-orphans/` 目录**：安装升级时，违反当前 request-id 规则的旧 record/tombstone 会被**移入**数据目录下的 `.legacy-orphans/` 存档（改名而不是删除，且不会被保留期清理扫描到），那里是历史记录的唯一副本；确认不再需要时再人工删除。
- 不要用它绕过用户确认、安全策略、权限边界或长任务的资源限制。
- 不要在此链路中启动 `codex exec`；它用于执行目标机命令和回收真实进度/结果。

## 详细参考

`SKILL.md` 只保留操作必需的部分。以下文件是原先同一份文档拆分出来的**完整原文**，按需读取；
若摘要与参考文件在细节上不一致，以参考文件为准。

| 文件 | 内容 |
| --- | --- |
| [`references/contract.md`](references/contract.md) | 每个命令的 JSON 形状、`status` 三种形态、`logs` 编码与不可用形态、`cancel` 重放前提、批量 `remove --label`、退出码 `2` 的四类 `reason` |
| [`references/clients.md`](references/clients.md) | 本地客户端契约：环境变量的「是否设置」判据、配置文件与 BOM/CRLF/NUL、密码认证与 askpass、平台探针与缓存、Windows 终端差异、`sshp` 交互链路 |
| [`references/install.md`](references/install.md) | 新主机接入：安装/升级步骤、非交互 sudo、预置二进制通道、维护锁与事务残留、macOS LaunchDaemon、Windows 服务身份、`sshp` 依赖安装 |
| [`references/windows-installer-invariants.md`](references/windows-installer-invariants.md) | Windows 安装器与路径链的 32 条实现不变量（改 helper 时读，日常接入不需要） |
| [`references/doctor.md`](references/doctor.md) | `doctor` 的 `key=value` 输出、探针失败时的 `unavailable` 语义、`--workdir` 平台规则 |
