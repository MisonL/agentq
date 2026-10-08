# AgentQ 规划 · B 类记录（B1–B5）

**这是 `docs/PLAN.md` 的一部分，不是清单本身。** 全部 B 类条目均已关闭，正文
在此归档；待办与状态见 [`../PLAN.md`](../PLAN.md)。引用 `PLAN.md B2` 即指本文件
中的那一条。

---

## 四、B 类：需要你一个决定

### B1. `git init` —— **已完成（2026-09-29，用户明确授权）**

**用户 2026-09-29 明确选择「你先初始化 git，我再审」**，随后完成。仓库此前没有
`.git`，且 `git init` 在本仓一贯是**用户决定而非 agent 默认动作**——所以拖了这么久
不是疏忽。它阻塞的正是这一整类工作：`git status` 看未提交改动、`git diff` 审计版本
差异、分支试验，以及「这次会话改了哪些文件」这个问题本身。

落地时比「一次初始提交」多做了三件事，每件都有具体理由：

- **`.gitattributes` 用 `* -text`**。这不是风格偏好：开发机 `core.autocrlf=input`
  （实测 `file:/Users/mison/.gitconfig`），而 `assets/` 要**原样部署**——一次换行
  转换就会让 `cmp` 的两条 canonical 资产不再相同。实测同一份 CRLF 文件，有这个
  文件时入库仍是 `0d 0a`，去掉它就变成 `0a`。
- **`.gitignore` 用机制挡住凭据落库**（askpass 助手、密钥、`.env`、本机 agentq 状态）。
  `CLAUDE.md` 的凭据规则此前只是一句话，现在是可执行的。
- **基线提交与改动提交分开**：`63c6061` 是本次会话改动**之前**的状态（由当前树逐处
  回退那 4 处代码改动重建），`0bb95d0` 才是本次改动。这样 `git diff 63c6061` 就是
  「这次会话改了什么」的准确答案。

**顺带纠正一处文档失真**：`CLAUDE.md` 的覆盖边界一节曾写「没有编译器、没有类型
系统、**没有 git**」，git 落地后已改为如实描述。

**`HANDOFF.md` 的「不使用 `git reset --hard`…」那条操作规则已按 B1 原计划改写**：保留那一条是因为
它防的是 `git reset --hard` / `git checkout --` 这类**销毁工作**的操作——本会话真的
因为先删备份再 `git reset --hard baseline` 把工作树回退过，是靠 git 对象
`dcff709` 逐字节恢复的。规则没变，理由写清楚了。

### B2. 协议版本协商：做，还是写成刻意不做 —— **已选 (b)「刻意不做」并写入文档（2026-09-22）**

已核实：`agentq-server` 里 `protocol_version` / `api_version` / `"version"`
**零命中**。`doctor` 报的是 `pueue=`/`pueued=`，不是协议自己的版本。
（**2026-10-08 补**：`doctor` 现在另报一行 `agentq=`——部署单元自身的版本，见 A30。
它仍是**信息行**：两侧都不解析、不据此拒绝，B2 的「无协商」结论不变。）

后果：部署单元被隐式定义为「23 个文件同一版本」，而系统**没有任何机制**发现或
拒绝版本不匹配的一对。今天不咬人（没有升级故事），但这是典型的「默默成立、
升级时静默破掉」的假设。

两个选项：

- **(a) 实现最小版本协商**：`doctor` 输出协议版本，客户端在首个请求带
  `protocol_version`，不匹配退 `2` 并给出可读消息。改动在 canonical pair + 两个
  客户端 + SKILL.md，是行为变更。
- **(b) 写成刻意不做**：在 `SKILL.md` 明写「本项目不支持跨版本互操作；部署必须
  整体升级；`doctor` 报的 `pueue=`/`pueued=` 版本即部署版本」，并在 `CLAUDE.md`
  的操作边界加一条「不得只升级服务端或只升级客户端」。

**已选 (b)，已完成**（2026-09-22）：`SKILL.md` 的「新主机接入」段与 `CLAUDE.md`
的操作边界各写了一条，措辞明确是**决定**而非遗漏。单操作者、整体部署、23 个
文件本来就同源，(a) 的复杂度买不到什么。

### B3. `2` 的机读化（推荐做，兼容） —— **已完成（2026-09-22）**

服务端有 **17 处 `exit 2`**，其中三类靠 **stderr 文本**区分：
`already in progress`（可重试）、`task is not running`（不可取消）、其余（改参数）。
本质问题是机读信号（退出码）被人读信号（消息）消歧——每个客户端实现都必须
字符串匹配 stderr 才能正确重试。

**已实现，做法与最初设想不同——值得记下来。** 原计划是在错误 JSON body 里加
`reason` 字段；实测发现**两个客户端都不把远端 stderr 转发给调用端**（POSIX 端只
打印 `SSH diagnostic omitted for safety (class=…, N bytes)`，原始内容按设计被
脱敏），所以走 stdout 的 JSON 字段在失败路径上根本到不了调用方。改为：服务端在
每条以 `2` 退出的路径上，在 stderr 消息之后多打一行 `<程序名>: reason=<class>`
（`fail()` 是唯一出口，默认 `protocol_error`，锁竞争与 cancel 两类显式覆盖；
另有 3 处非 `fail` 的顶层 `exit 2` 各带一行）。两个客户端从 SSH 日志里取出这一
行，以 `remote failure reason: <class>` 转发——**只**转发这个受控标识符（正则
限定 `[a-z][a-z_]*`），日志其余内容仍只以脱敏元数据呈现。退出码与消息文本都没变，
所以完全向后兼容；`reason` 本身则是新的机读契约，改它属于破坏性变更。

变异验证 10/10 全部被抓（服务端 5 个：删掉整行、默认值硬编码、锁类与 cancel 类
各改错、协议类改错；POSIX 客户端 3 个：停止转发、放宽字符集、回显原始 stderr；
PS 客户端 2 个：停止转发、放宽字符集），全部运行后 4 个文件按 sha256 逐字节还原。
断言落在 `02`（9 个坏调用须带 `reason=protocol_error`）、`03`（对已结束任务 cancel
须 `task_not_running`——这一类只有真运行时能构造）、`06`（锁拒绝须
`lock_contention`）、`05` 与 `12`（转发 + 注入安全）。

**这条的紧迫性随 `exit 2` 的处数增长**：每新增一处，机读化的收益就降一点、
成本就升一点。

### B5. 三台真实主机的部署版本已落后于仓库 —— **两轮重装均已完成（首轮 2026-09-24/26；第二轮 2026-10-08 三台已到当前版本，均见下）**

A8 盘查的副产品，**是一个事实，不是一个我该自己动手的事**（安装/升级属服务变更，
需你明确授权）。实测三台（主机 C 亦已盘查，见 A8 续查）：

| | 仓库 | 主机 A（Windows） | 主机 B（Linux） |
| --- | ---: | ---: | ---: |
| 服务端 | 4,736 行 | **4,715 行** | **2,716 行** |
| 客户端 | 3,276 行 | `agentq.ps1` 仍是 **A5 之前**的 `-EncodedCommand` 探针 | 5 行 shim → 旧服务端 |

主机 A 服务端与仓库的差集（`scp` 取回后逐行 `diff`，15 个 hunk）**恰好只有 A6 与
B3 两组改动**：`task_instance_created_at` → `task_instance_created_at_is_recorded`、
4 处 `reason=` 行、2 处 `lock_contention` 实参。主机 B 停在 **8 月 17 日**的代。

**两个直接后果，A8 里都撞到了：**

1. **客户端 reason 通道在这些机器上取不到值。** 旧服务端不打印 `reason=` 行，所以
   客户端转发的 `remote failure reason:` 是空的——**不是 `05`/`07` 钉的那条通道坏了**，
   是这些主机上根本没有那个输出。排查时容易误判成客户端缺陷。
2. **我在盘查时用的是仓库当前客户端**，配这些旧服务端，正好构成 `CLAUDE.md` 明说
   「不会部署」的新旧配对。也就是说 A8 的部分观察是在一个**不受支持的组合**上取得的
   ——这不影响探针修复的结论（那是客户端侧、由变异与跟踪确认），但**任何"某台主机
   经 AgentQ 协议可用/不可用"的结论，在重装之前都不可靠**。

**需要你决定**：重装（整体替换 23 个文件，逐台授权、逐项确认），还是**先记下**、
等有实际需求时再做。我建议**先记下**——当前没有升级故事，且三台都是生产机；
但至少要知道「仓库里的修复在这些机器上还没生效」这件事，否则会拿仓库代码的状态
去推断线上行为。

（这条与 B2 相关：正因为**没有协议版本协商字段**，系统**无法自己发现**这种不匹配——
B2 选 (b)「刻意不做」时已经写明这一点，B5 是它的第一个真实实例。）

### B5-执行. 三台重装 —— **三台全部完成（C 同日完成；2026-09-26 用户改指定另一台 macOS 机为 C，见下）**（2026-09-24，用户授权：安装/服务变更）

用户授权 A+B+C 全做。逐台只读盘查后逐台安装，**结果与真机发现**：

| 主机 | 结果 | 服务端 | 端到端 |
| --- | --- | --- | --- |
| 主机 A（Windows） | **已重装成功** | 4,715 → 4,736 行 / `e3b132af` | **已完成**：`status`/`submit`/`wait`/`logs`/`remove` 全通，验证任务已清理 |
| 主机 B（Linux） | **已重装成功** | 2,716 → 4,736 行 / `e3b132af` | submit→wait(`Success`)→logs→remove 全通，**已清理** |
| 主机 C（macOS，旧机） | **2026-09-24 已重装成功** | 4,727 → 4,736 行 / `e3b132af` | **该次已完成**：`status`/`submit`/`wait`/`logs`/`remove` 全通，验证任务已清理。**但 2026-09-26 用户改指定另一台 macOS 作为主机 C 并完成全新安装，本机不再追** |

**主机 A（Windows）已于 2026-09-25 升级到 `4,798 行 / 97088c62`（= 仓库）**，用户当次
授权、走官方安装器 `install-agentq.ps1 -StageDirectory`，`INSTALLER_EXIT=0`、
`updated_atomically: true`；升级前 0 running/0 queued/0 paused，升级后 `status` 输出
**147,911 字节与升级前逐字节相同**、元数据 **272 records / 27 tombstones 零丢失**、
`submit→wait(Success)→logs→lookup→remove` 端到端全通。**所以 A12 那个 P0 在该机上已消除。**

**主机 B（Linux）亦已于 2026-09-25 升级到 `4,798 行 / 97088c62`（= 仓库）**，用户当次
授权、走官方安装器 `install-agentq.sh`（`AGENTQ_PUEUE_SOURCE_DIR` 复用该机已有的
pueue 二进制，哈希与安装器常量逐一相符，仍走内置 SHA 校验），`INSTALLER_EXIT=0`。
升级前 0 running/0 queued/0 paused；升级后 **257 records / 43 tombstones 零丢失**、
权限 700 保持、systemd `active`+`enabled`、`bash -n` 通过；端到端
`submit`(839)→`wait`(退 0 + `Done.result=Success`)→`logs`→`lookup`(`reused:true`)→
`remove`→`wait`(**退 5 / `removed`**) 全通。**并且在这台真机上跑了 `smoke/15` 验证
A12 的 P0 修复**：`exit=2/reason live-request-preserved=yes tombstones=0 recovery=ok
task=survived` —— 这是该修复第一次在**非沙箱的真实主机**上被验证。**注意 Linux 路径
不需要 root**（服务装到 `$HOME/.config/systemd/user/`，`replace_service_file` 用普通
`mkdir -p`），实测全程未触发 sudo。

**主机 C 已于 2026-09-26 解决，但方式与预期不同**：用户给的地址是一台
**从未装过 AgentQ 的 macOS 机**（无 `~/.agentq`、无 `pueued`、launchd 两域都无服务、
0 records），并非原记录中那台 `4,736 行 / e3b132af` 的 macOS 主机。已按用户授权**全新安装**
（`INSTALLER_EXIT=0`、`97088c62` / 4,798 行、LaunchDaemon `state = running`、端到端全通）。
**原那台「已装 `e3b132af` 的 macOS 主机 C」仍在运行带 A12 P0 的旧版本，但 2026-09-26 用户
明确决定（「你就用它就好了」）以新那台作为 macOS 主机，旧机 **不再追**。所以它的状态是
「**不在范围内**」，不是「已修复」——更不是「下落不明」：地址一直在记录里（见本文件的
fleet 表），此前写成「下落不明」是我没查就说话，已更正。

**A15（撤销）：不是新发现，`SKILL.md` 早有记录。** 我 2026-09-26 在 macOS 全新安装时
"发现"了「无 tty 时安装器必然失败」，并重新推导出绕过办法（`sudo` 包装强制 `-A` +
`SUDO_ASKPASS`）——**但 `SKILL.md` 的「非交互会话里装 macOS/Linux 服务端」一段早就写着这件事**，连代码模板、`env_reset`
会清掉 `SUDO_ASKPASS` 的解释、以及「装完立即删除 askpass（含明文密码）」的告警都在。
更直接的反证：`PLAN.md` 自己记着 2026-09-24 那次主机 C 重装**就是**用这个包装做的。
**根因是我没先读 `SKILL.md` 就上手试**，浪费了十几轮去重新发现已记录的东西。
教训记在此而非删掉了事：本项目说「完整语义以 `SKILL.md` 为准」，**动手前先读它**。
（我推出来的机制解释——子 shell/tty 绑定、而非 umask 本身——与 `SKILL.md` 的
`env_reset` 说法**不同**。两者都能解释现象，但我**没有**去验证哪个是真的；
`SKILL.md` 的说法来自实测，应以它为准。不要把我这段当证据。）

**A16（2026-09-26 实测发现；2026-09-27 已修）：Windows 客户端缺 `BatchMode` 认证提示。**
POSIX 客户端在认证类失败时多打一行（点名 `BatchMode=yes` 与可行做法，见 A9），
**Windows 客户端没有**（实测 `grep -c` = 0），而它同样在两处硬编码 `BatchMode=yes`
（`agentq.ps1:775`、`:1013`）。`PLAN.md` 此前只记了 `sshp` 不加提示的理由（人类交互终端），
**漏记了 Windows 客户端这一处**。实测证据：新装的 Windows 客户端在认证失败时输出
`SSH diagnostic omitted for safety (class=authentication, 31 bytes)` 后接
`unable to detect the remote platform; set AGENTQ_REMOTE_PLATFORM ...`——**分类器是对的**
（`authentication`，旧版会报 `class=ssh`，这顺带**真机验证了** A9 记录的「Windows 分类器已改
但未在真机验证」），**但提示缺失**，操作者仍会被指向 `AGENTQ_REMOTE_PLATFORM` 这个
救不了缺密钥的方向。修法与 A9 相同（在 `Write-Diagnostics` 里按 class 追加），
但要跑全套件并配 `smoke/12` 用例。

**已修（2026-09-27，零授权，只改 `skill/assets/client/windows/agentq.ps1` + `smoke/12`）**：在
`Write-Diagnostics` 里，打印完 class 行之后按 `$diagnosticClass -eq "authentication"` 追加一行，
文案与 POSIX 端**逐字相同**，并点名 `$script:TargetHost`（不点名主机，操作者不知道该装哪把钥匙）。
位置同样在 `Write-Diagnostics` 内而非调用方决策点——调用方是在命令替换里调探针的，
到决策点 class 与日志都已不在手上（与 A9 同一个理由）。

**回归锁 `smoke/12` 新增一组用例（32 个用例，原 31）**：四个诊断串各跑一遍
`Write-Diagnostics`（捕获 `[Console]::Error` 到 `StringWriter`），断言**两个方向**——
`Permission denied` 与 `Host key verification failed.` 必须打出提示**且提示里含目标主机名**，
`Connection refused` 与空串**必须不打**。第二个方向不是凑数：提示若对所有 class 都打，
就会退化成操作者学会跳过的噪音，那正是原提示失去价值的路径。

**红/绿实测**：删掉提示行 → 用例报红且消息精确（`auth hint case permission: expected hint=True got=False`、
`hint does not name the target host`、`hostkey` 同）；恢复 → 绿。**变异 5/5 有效者被抓**，
另有 **1 个无效变异如实记录**：把 `-eq "authentication"` 改成 `-eq "Authentication"` 报 MISSED，
查证为**变异无效**而非检查盲——PowerShell 的 `-eq` **本身大小写不敏感**（实测
`"authentication" -eq "Authentication"` 为真，`-ceq` 才是敏感的），该改动行为完全不变。
换成真正改变行为的两个变异（把条件收窄成只认 `Permission denied`、把 class 计算替换成常量）
后**均被抓**。

**主机 C（macOS）仍落后一个修订**：装的是 `4,736 行 / e3b132af`，差的就是 **A12 那个
P0 修复**（瞬时 Pueue 读取失败会把活着的任务归档成 `removed`）与 A13（探针 stderr）。
所以**在修复前的部署上，一次 Pueue 抖动就可能永久污染一条 request**。
按本仓「不得只升级服务端或只升级客户端、必须整体替换」的硬约束，要修就得整体重装——那是安装/服务变更，**需要明确授权**。
**2026-09-26 用户决定：macOS 主机以新那台（用户当次会话给出的地址）为准，原那台不再追。**
所以当前有效机群是主机 A（Windows）、主机 B（Linux）、主机 C（macOS）三台，
**均已 `97088c62` / `4,798 行`，无 A12 P0**。
原那台 macOS 上的 `e3b132af` 仍带 P0，但它已不在用户的机群内——**这不是「已修复」，
是「不在范围内」**，若将来重新启用它，需先升级。

**地址更正（2026-09-24，我先前记错了，在此更正）：当时的主机 C 是原那台 macOS，
不是后来新给的那台。** 证据是 C1 记录里的原文（`HOST=<user>@<host>`）：C1 的主机 C 矩阵
（15 个 Done 任务、`cancel` 两条路径、三类网络中断变体）全部跑在原那台上，那个用户就是
我在 C1 之前装上去的（系统级 LaunchDaemon、macOS 15.7.7 / Intel i5-10500）。我上一轮把它
误标成新那台，是因为把**自己在 A8 轮的一句错误复述**当成了原始记录——**这是"从自己的旧结论里取证据"
而不是回查原始记录**，正是本项目反复出现的那类错误。

**新给的那台 macOS（record 35884）实测是一台干净新机**：macOS 15.7.9 / x86_64，`/Users` 下
只有该机用户与另一个用户目录（**没有原那台的用户**），全盘（`/usr/local`、`/opt`、`/Users`）
找不到任何 `agentq*`/`pueue*`，无 launchd 条目、无进程、不在 PATH、无 `~/.agentq`。
**所以它没有 15 个任务，也没有可清理的残留**——那 15 个任务在原那台上。

**凭据状态**：你给的那组账号 + 密码在新那台上**有效**（我已用它完成只读盘查）；在原那台上
**被拒**——`Permission denied`，试了两个用户名。所以**当时主机 C 仍缺凭据**，A8/B5 当时
仍未完成。

**已实测排除的假设**：新那台的 sudo 需要密码（`sudo: a password is required`），
但我没有做任何提权尝试，也没有对它做任何写操作——只跑了只读的 `ls`/`find`/`ps`/`command -v`。

**主机 B 不需要 sudo 密码**（我先前那句是错的）：Linux 路径的服务全部走
`systemctl --user`，`run_as_root` 的调用点全在 `platform_kind = macos` 分支里；
`ensure_linux_linger` 只在 linger 为 `no` 时才需要提权，而该机实测已是 `yes`。
所以主机 B 是纯用户级安装，**零提权**。数据（`shared_secret`、`certs`、258 个 Done 记录）
完整保留，无事务残留，服务 active。

**主机 A 重装撞出一个真实的 Windows 缺陷（本仓第 7 个，只有真机能撞到）。**
第一次运行安装器在第 453 行失败：

```
if (!$applied.AccessRulesProtected -or !$ownerRule) {
```

`AccessRulesProtected` **不是** .NET ACL 对象的属性，真名是 `AreAccessRulesProtected`。
在 `Set-StrictMode -Version Latest` 下读不存在的属性**抛错**（不是返回 `$null`），
所以 ACL 校验那步让每次安装都死在该行。**客户端安装器 `install-client.ps1:471` 一直是拼对的**
——两份拷贝不一致，而只有客户端那份在真机上被跑过。**安装器回滚干净**：服务端仍是
4,715 行 / `e114e2b8`，launcher 未变，`pueued` 仍在跑，无事务残留。修好后重跑成功。

**为什么现有检查都抓不到它**：`smoke/13` 在 macOS 上第一条语句就死（`Resolve-GitBashPaths`
报 `Windows Principal functionality is not supported on this platform`），根本不执行那一行；
`smoke/10` 的规则 D 只要求 `Set-Acl` 之后**有** `Get-Acl` 读回——读回确实存在，规则满足。
故新增**规则 F**：ACL 对象的属性名必须在允许集内。**变异 2/2 被抓**（服务端/客户端各一），
基线绿。**一个自己踩的坑如实记录**：规则 F 第一版用了 `\b`，而 **BSD awk（macOS）不支持 `\b`**
——匹配返回 `RSTART=0`，规则**静默通过了它本该抓的那个缺陷**；去掉 `\b` 后正常
（`[A-Za-z]*` 本身已是贪婪）。第二版又把合法的 `AccessControlType`（`AccessRule` 的属性，
不是 ACL 对象的）报成违规 4 处，已加进允许集。

**主机 A 的端到端验证被我自己的孤儿进程反复阻塞——同一个错误我犯了多次，如实记录。**
形态与 A8 完全相同：我用本地 `timeout` 包住远端的 `status`，超时后**本地** ssh 被杀，
但**远端 `bash.exe ./agentq status` 继续运行**并持有 operation lock。第一次（PID 98392）
我按 A8 规则**不手动删锁**（持有者活着），实测该进程 **CPU 两次读数完全相同、20 秒采样
不变、子进程已消失**——已冻结在向断裂的 stdout 管道写入，**永远不会自己退出、也就永远
不会释放锁**。处理方式：**只终止我自己的冻结进程，绝不碰锁目录**（AgentQ 元数据），
交给服务端自己的陈旧锁恢复逻辑（`smoke/03` 钉的正是这条路径）——实测该逻辑**确实生效**
（下一次操作越过了获取阶段，锁转为新持有者）。

**但我随后又犯了两次同样的错误**（一次仍是本地 `timeout`，一次是我在说「不再并发」
之后又并发启动了一个直接调用），累计留下多个孤儿：实测采样后清掉 3 个冻结的
（CPU 20 秒内不变），保留在跑的。**根因是我自己的操作纪律，不是产品缺陷**：
远端操作必须允许它自己跑完，任何本地超时都会制造一个永久持锁的孤儿。
**已改**：最后一次改用**不设本地超时**的方式，并停止一切并发。

**那项"8 分钟未返回"的观察已查明成因，且不是缺陷——但成因和我先写的那句相反，
在此更正。** 我原先写「`compact_status` 先做 `prepare_request_metadata_files`、
**然后**才取锁」。读调用链后确认**顺序是反的**：`status_with_operation_lock` →
`with_operation_lock status` → `acquire_operation_lock` **先拿锁**，拿到之后才
执行 `status()`，而 `compact_status` 里的 `prepare_request_metadata_files`
（遍历 273 条 record、每条多次 jq）在**锁内**。所以 N 个并发 `status` 不是「各自
先全量扫描再排队」，而是**在锁内串行做 N 次全量扫描**——同样的分钟级后果，但机制
不同：**是锁把扫描串行化了**，不是扫描发生在锁之前。后者读起来像「锁没起作用」，
与事实相反。

**主机 A 的端到端验证已完成（2026-09-24 补测，严格无并发、无本地 `timeout`）：**

| 操作 | 退出码 | 耗时 | 结果 |
| --- | ---: | ---: | --- |
| `status`（默认探针超时 30s） | **0** | 363s | 147,911 字节合法 JSON、273 个任务、stderr 全空 |
| `submit` | **0** | 285s | `task_id=275`、`reused:false` |
| `wait` | **0** | 332s | 调用退出码 **与** `task.status.Done.result == "Success"` 两项都核对 |
| `logs --tail all` | **0** | 323s | `output` 字段存在，且与提交的标记**逐字节相同** |
| `remove` | **0** | 233s | `{"task_id":275,"removed":true}`；其后锁目录已释放、任务已从 Pueue 消失 |

**那两次 30 秒探针超时是我自己造成的，已实测排除。** 主机 A 上**手动照客户端方式**
（同一组 ssh 选项、脚本经 stdin）跑平台探针与协议探针，各轮均 **2 秒**返回正确 token
（`agentq-windows` / `agentq-windows-launcher-ready`，含 `agentq-exit:0`）。超时期间
该机 **load=42**、积压 **14 个 `bash.exe`**——正是我留下的孤儿把机器压垮，探针被
拖过 30s 预算。孤儿清空后默认超时**一次通过**。**探针、长度、退出码 token 三条契约
在真机上均无缺陷**；30s 这个默认值在这台机器上偏紧，但那是负载的函数，不是缺陷。

**另一处更正：Windows 上服务端文件叫 `agentq`，不叫 `agentq-server`。** 我先前用
`/c/ProgramData/AgentQ/agentq-server` 探测，得到「MISSING」，一度以为部署不见了——
实际是我记错了名字（仓库里该资产是 `skill/assets/windows-git-bash/agentq`）。实测
`sha256 = e3b132afc2ec624cbdd49a11d042111f6e673b47f0ae932a2f126a8d223f2af7`，
**与仓库逐字节相同**，部署完好。

**结论：主机 A 重装与端到端均已完成。** 安装器 exit 0、`updated_atomically:true`、
服务端逐字节等于仓库、`pueued` 在跑、无事务残留。

**第二轮重装（2026-10-08，用户点名机器）——三台全部完成，仓库此前的 A28/W4/W5/C2 各轮改动
至此全部上线**：三台各走官方安装器升到当前 `9721403c` / 5,332 行，升级后各自端到端
`submit→wait(退 0, `Done.result=Success`)→logs→remove` 全通、队列与 record 零丢失。

| 主机 | 升级方式 | 结果 |
| --- | --- | --- |
| 主机 A（Windows） | `install-agentq.ps1 -StageDirectory` | `INSTALLER_EXIT=0`、`updated_atomically:true`；服务端 `9721403c`、`pueue status` rc=0 |
| 主机 B（Linux） | `install-agentq.sh` + `AGENTQ_PUEUE_SOURCE_DIR` | `INSTALLER_EXIT=0`（"AgentQ 4.0.4 installed"）；`service: active` |
| 主机 C（macOS） | `install-agentq.sh` + 文档化的非 TTY sudo 通道 | `installer_rc=0`；LaunchDaemon 重启后 daemon 在跑（新 pid） |

**主机 B 首试被内置 SHA 校验拒**（`sha256 mismatch for staged asset:
…/pueue-x86_64-unknown-linux-musl`）：`AGENTQ_PUEUE_SOURCE_DIR` 指向的文件必须用**平台资产名**
（该机 `~/.agentq/pueue` 名字不符）——改用 `~/aq-pueue-src/pueue-x86_64-unknown-linux-musl`
（从该机既有二进制复制，哈希与安装器内置常量逐一相符）后通过。**这次失败是校验按设计
工作的证据**，不是缺陷。

**同轮主机 A 的 Windows 客户端也补齐到 canonical**（部署单元规则：客户端与服务端同批）：
`agentq.ps1` `bf61bf00`→`20bad08c`、`sshp.ps1` `dc317937`→`62bf0754`、Git Bash 启动器
`35d6a030`→`240a7bf8`；`-Check` 先报三处漂移、安装后 `-Check` 退 0、六个入口逐字节相符、
`.local\bin` 零残留。