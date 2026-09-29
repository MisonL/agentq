# AgentQ 交接（2026-09-19 重写）

日常开发看 `CLAUDE.md`。本文件只保留仍然有效的操作规则与边界。

**待办事项不在这里**——唯一权威清单是 `PLAN.md`。本文件下方的「未完成」段落是
历史记录，不是任务清单。

---

## 一、当前结论

- AgentQ 的本地开发和可靠性完善工作完成过一次有界收口，当时 7 项核心动态检查、
  Bash/Zsh 语法、ShellCheck、PowerShell AST、canonical server parity、Ling 边界
  检查和残留检查均为退出码 0。
- **这些结论现在无法在仓库内复核**，仓库只保留 `smoke/` 的当前覆盖。
- 上一轮 Goal 已标记 `complete`；当前没有活动 Goal。继续开发时应新建一个
  明确范围的 Goal，不要把历史 Goal 重新解释成无限任务。
- “完成”仅指当前授权的本地开发与可靠性范围完成，不等于所有真实主机、真实
  Windows NTFS/ACL、服务生命周期、外部渠道或生产验收完成。

### 归档会话复核增补（2026-09-18）

本次复核的源会话为 `019fa2b6-2ce4-7a71-a481-d4ac8e276008`。该会话已归档，
不是丢失；原始记录位于
`/Volumes/Work/CodexArchive/archived_sessions/rollout-2026-07-27T16-34-35-019fa2b6-2ce4-7a71-a481-d4ac8e276008.3090113d26e829405dd42bda0f5c2b3d9daa7fc801410f6df86d1ac4c7abb9ec.jsonl`，
对应元数据状态为 `evicted`，SHA-256 与元数据一致。

原会话不能视为完整闭环：全面复核期间发现了服务端读路径会改写 Pueue group、
`logs --tail all` 长时间持有 operation lock、外部移除后 cancellation marker 残留、
空锁目录以及 request record/tombstone 持久化同步不足；随后 Windows 审计又发现
SSH 短断恢复、Windows `submit` 参数解析、Int32 重试参数上限和主机名/session name
校验问题。原会话末尾只看到 Windows 客户端补丁，未看到补丁后的完整回归、最终远端
验证或最终审查；之后连续“继续”回合以 `invalid_encrypted_content` 中断。

后续本地开发已对其中确定性问题完成修复和有界验证；这不改变下面的外部环境边界。
后续处理清单如下：

1. **P1-3 整体操作矩阵**：在获得明确授权并建立新的证据切片后，补齐真实四机各类
   操作和网络中断变体的矩阵；已证明的 submit-response-loss 范围不得重复执行，
   也不得升级为整个 P1-3 已完成。
2. **原生 Windows 边界**：如确有验收需要，单独验证 Windows PowerShell 5.1、NTFS
   reparse、ACL、registry/profile、跨用户身份和 PID reuse；本机没有可代替这些证据
   的验证手段。
3. **平台和安装矩阵**：补充 WSL、arm64、RHEL、Fedora、Alpine，以及原生包管理器、
   权限/网络/特权组合和真实升级回滚；这些属于未证明边界。
4. **真实服务与生产边界**：在得到精确主机、用户、工作目录、恢复方式和副作用授权后，
   才能验证远端服务/队列生命周期、TLS/shared key、生产凭证、发布、回滚和生产接受。
5. **P2-18 外部审查**：明确审查主体、输入版本、验收标准和授权边界后，另立外部
   approval receipt、live security acceptance 和 final adjudication 证据；目前没有
   当前授权，也没有可替代它们的现有证据。
6. **项目版本控制管理**：当前 `/Volumes/Work/code/agentq` 没有 `.git` 目录，因而
   不能用 Git 状态确认该项目的未提交改动。若后续需要提交或审计版本差异，必须先由
   用户明确决定是否初始化/接入版本库；在此之前以文件和 `CHANGELOG.md` 为准。

以下事项已明确取消或不构成后续任务：压力、重启、注销、物理断电验收；历史全量扫描、
完整历史 `shasum -c`；以及未获授权的远端安装、服务变更、队列 mutation、凭证操作或
生产写入。它们不得重新写入 Goal、待办清单或完成门槛。

## 四、明确未完成、取消或未授权事项

以下事项不能在交接时被写成“已完成”：

1. P1-3 的整体跨主机完成度。已完成的只是 submit-response-loss 一项，不是整个
   P1-3 矩阵。
2. 原生 Windows 的其余边界。**已实测（2026-09-21，一台真实 Windows 主机）**：服务端在
   真实 Windows 上跑通完整协议（submit/wait/logs/remove/cancel 两条路径与重放/
   base64 日志/doctor/锁竞争/坏参数退出码/launcher 的 `ArgumentsBase64` 转发）；
   原生 PowerShell 5.1 的客户端坏参数路径亦已在 Windows 11 虚拟机实测。过程中
   发现并修复了四个 Windows 专属缺陷（`FlushFileBuffers` 访问掩码、jq 的 POSIX
   路径参数、PowerShell 5.1 词分割脚本参数，以及 `chmod` 在 `noacl` 挂载上的静默
   空操作），详见 `CHANGELOG.md` 与 `smoke/08`、`smoke/09`、`smoke/10`。
   第四项已修：客户端安装器改走 ACL（`Set-ClientLauncherAcl`，含 `Get-Acl` 读回
   校验），`chmod` 已从该资产移除。**仍未验证**：NTFS reparse 点语义、
   registry/profile、跨用户安装/服务身份。
3. 真实远端服务、队列、TLS/shared key、生产凭证和外部通知/外部渠道验收。
4. 额外高风险生命周期和持续压力验收。用户已明确取消，不再作为待办或门槛。
5. 真实安装、升级、回滚、第二 Windows 身份迁移和生产发布。除非用户另行明确
   授权，不要执行这些有副作用操作。
6. 历史全量扫描和完整历史 `shasum -c`。交接后默认只核验当前变更。
7. 任何历史文档中出现的 `active` 标记。它们是当时的记录字段，不代表当前 Goal
   仍活动；上一轮 Goal 已完成，当前没有活动 Goal。

## 五、操作规则

- 新主机先运行：`agentq --host <host> doctor`。
- AgentQ 任务只走 JSON 协议：`submit -> status/logs -> wait`，需要停止时才
  `cancel`，确认终态且不再需要日志时才 `remove`。
- SSHP 只承载人类交互会话，不用来代替 AgentQ 任务。
- 任何 `wait` 必须同时核对调用退出码和 `task.status.Done.result`。
- 退出码 `2` 的类别读 `reason=<class>`（`protocol_error` / `lock_contention` /
  `task_not_running`），不要匹配消息文本；细节见 `CLAUDE.md` 与 `SKILL.md`。
- 不得只升级服务端或只升级客户端——没有协议版本协商，部署单元是 23 个文件的同一
  版本（刻意决定，见 `CLAUDE.md` 操作边界）。
- response loss 只能使用同一 request ID lookup/reconcile；不得换新 request ID
  重复有副作用命令。
- `cancel`/`remove` 响应丢失时不要自动重试；先读取 status/logs/wait 重新确认。
- 保留 dirty worktree，不使用 `git reset --hard`、`git checkout --` 或宽泛清理。
- 证据采用 `CHANGELOG.md` 的一行记录加 `run-tests.sh` 的退出码；不要把局部验证
  说成全局验证。
- 不在目标机运行 `codex exec`，不把 Skill 客户端降级为普通前台 SSH。

## 七、关键当前文件

- 运行规则与命令契约：`SKILL.md`
- 开发入口与流程：`CLAUDE.md`
- 日常验证：`run-tests.sh`（`--quick` 只跑 `01`）
- 冒烟检查：`smoke/` 下的 16 项，逐项的「覆盖什么 / 不覆盖什么」以
  `CLAUDE.md` 末节的覆盖表为准——本文件不再复制那份清单（复制过一次就漂移过一次）
- `03`/`04`/`06`/`07` 需要 `AGENTQ_SMOKE_HOME` 指向含真实 `pueue` 的运行时，否则 SKIP；
  `03` 还要求它本身是可用运行时（`config/pueue.yml` + 已在运行的 `pueued`）。
  仓库根的 `./sandbox.sh up` 可一键搭出这个运行时（`up` / `status` / `down`），
  它打印的 `AGENTQ_SMOKE_HOME` 形如 `/tmp/aqsb/home/.agentq`
- 覆盖边界与假绿防护：见 `CLAUDE.md` 末节
- 变更记录：`CHANGELOG.md`
- 产品本体：`assets/`（23 个文件）
