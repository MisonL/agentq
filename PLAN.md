# AgentQ 规划（2026-09-22 重建）

本文件取代 `HANDOFF.md` 的「待办 / 未完成」职能。日常开发看 `CLAUDE.md`，
命令契约看 `SKILL.md`，变更记录看 `CHANGELOG.md`。

**本文件是待办事项的唯一权威清单。** 别处出现的待办（HANDOFF 的历史段落、
CHANGELOG 里的过程记录）都是历史，不是任务。

---

## 一、对设计的判断

**骨架完善，演进机制与证据覆盖不完善。** 这两件事修法不同，不要混谈。

契约的语义设计可以放心依赖，四条是少见的正确决定：

1. **对「不知道」fail-closed。** `4`（无法安全判断）和 `6`（无法确认终态）都
   不是完成，`5`（removed）也不是。多数任务队列在这里会猜。
2. **reconcile 而非 retry 的非对称性。** response loss 用同一 request ID 重放
   （构造幂等），但 `cancel`/`remove` 丢响应后**不许**自动重试。多数系统错在
   「什么都盲目重试」。
3. **cancel marker 绑定 `created_at`。** Pueue 复用数字 task id 是真实问题，
   解法窄而准；保证窗口有限这件事被写下来而不是藏起来。
4. **单写者串行化**（operation lock + 有界重试），被拒者零副作用——有实测
   （12 并发：4 成功、8 被拒在 33.8s 退 2、0 副作用）。

不完善的是三件事，**逐项给出实际状态**（2026-09-24 复核——只列症状不结账，
下一个人就不知道哪些已经解决）：

1. **协议怎么演进** —— 三个子项各自结清：① **无版本协商**：已选「刻意不做并写下来」
   （B2），落点在 `SKILL.md` 的「新主机接入」段与 `CLAUDE.md` 的操作边界；
   ② **`2` 三义**：已加机读 `reason=` 通道（B3），落点在服务端与两端客户端；
   ③ **协议文本三份拷贝**：**三份仍然存在，这是刻意的**——launcher 自身、
   Windows 客户端内嵌 wrapper、POSIX 客户端内嵌 wrapper 各自必须能独立发出同一份
   payload 协议，无法合并。漂移由 `smoke/10` 规则 E 检测（比较 token 序列而非字节），
   四类分叉实测全部被抓。**所以这一项是「已加护栏」，不是「已消除重复」。**
2. **一半代码凭什么被相信** —— 没有任何行为检查的资产占 **14.2%** 的代码量
   （9 个资产 / 3,498 行，2026-09-24 重算；**这个口径此后未再重算**，逐轮补检查已使
   其缩小——见第八节的现役口径，2026-10-07 为 391 行 / 27,028 = 1.4%）；另有更大
   一片是「只有源码断言、没有行为执行」。**这一项本质未变**，只靠逐项补契约检查
   推进（A1/B4 已做 3 个）。
3. **决定散落在文档里** —— **已落点**：主机授权边界在 `CLAUDE.md` 操作边界、
   协议版本策略在 `SKILL.md` 与 `CLAUDE.md`、安装器参数契约在 `smoke/13`（可执行）
   加 `SKILL.md` 的安装段。

---

## 二、规划原则

1. **证据的成本必须低于它提供的价值。** 不为覆盖而覆盖。
2. **覆盖债优先于新特性。** 本会话 7 个缺陷里 6 个是安装器缺陷——那不是巧合，
   是「哪一半没有行为覆盖，缺陷就长在哪一半」的预测结果。P0 全部在这里。
3. **一次性决定优先于长期债。** `git init` 这种十秒钟的事，拖着就是每次会话
   都要重新论证一遍。
4. **已取消项不得复活。** 见第六节，它们不是待办、不是门槛、不写进任何 Goal。
5. **不做的决定也要写下来。** 「刻意不做版本协商」和「忘了做」是两回事，
   前者可以接受，后者会在升级时静默咬人。

---

## 三、A 类：现在就能做（零授权）

只改 `smoke/` 与文档，不碰 `assets/`，不触任何真实主机。

### A1. `install-agentq.sh` 的契约检查 —— **已完成**

新增 `smoke/11-installer-contract`，11 个用例，全部必须在安装器写入任何东西之前
被拒。三条隔离手段缺一不可，每条都是实测逼出来的：

- **HOME 指向沙箱**，且路径必须是 `/tmp`（`pwd -P` 解析）——安装器的
  `installer_path_is_safe` 会走每一个路径成分并拒绝符号链接，而 macOS 上 `/tmp`
  就是 `/private/tmp` 的符号链接。
- **PATH 换成桩**。本机真有 `jq` 和 `brew`，**沙箱 HOME 挡不住 `brew install`**，
  所以包管理器必须从 PATH 里彻底移除，再放「记录并失败」的桩——「什么都没装」
  才是断言而不是期望。
- **sudo 桩必须真的执行命令**，不能只 `exit 0`：`remove_installer_file` 在 macOS 上
  走 `run_as_root rm -f`，桩不干活就会留下 maintenance lock，安装器于是正确地报
  「lock metadata remained after cleanup」——看起来像产品缺陷，实际是 fixture 自己
  造成的，白查了一轮。

fixture 自检：先证明安装器能走到**依赖解析**这一步。这条自检抓到过一次真问题——
漏拷 macOS 的 plist 时，11 个用例会一起死在「缺资产」上、报同一个错消息。

**变异：见下（这个数字曾自相矛盾，已重测钉死）。** 2026-09-22 复测时发现
`PLAN.md` 与 `CLAUDE.md` 对这个文件记了两套数字（7/7 与最初的 10/10）。重跑一套
11 个变异后**有 4 个 MISSED**，逐个手工构造情形查证，全部是**可达但 `11` 从未走过
的分支**——不是变异无效：
- `drop existing-path-is-directory fail`（`~/.agentq` 是普通文件时；`installer_path_is_safe`
  只拒符号链接，普通文件能过）
- `drop sha256 mismatch (downloaded binary)`（下载路径，原先只有 staged 路径被覆盖）
- `drop maintenance-lock stale refusal` / `drop maintenance-lock confirm refusal`

已补 4 个用例（`existing AgentQ path is not a directory`、`downloaded binary hash mismatch` 配一个产出坏内容的
`curl` 桩、`unrecoverable stale maintenance lock`、以及 `lock liveness cannot be re-confirmed`——最后一个需要
一个「只答一次身份查询」的有状态 `ps` 桩，因为 `recover_stale_maintenance_lock` 的 TOCTOU 再确认在单进程
fixture 里否则不可达），用例数 11 → 15。复测 **11/11 全部被抓**。
补第一个用例时我的断言写错过一次：断言 `pid` 文件仍在，而正确路径上
`remove_maintenance_lock` 会先删 `pid` 再在 `rmdir` 上失败——**断言该落在锁目录是否
存活**，已改。
其中 `drop maintenance-lock refusal` 一开始报 MISSED，查下来是**变异无效**：那条
消息在源码里出现两次（mkdir 前与 mkdir 失败各一次），只改一处行为不变。同时它暴露
我的用例断言太弱——原先用「不存在的 pid」种锁，安装器无论如何都会在「无法确认陈旧
锁」上失败，所以**删掉拒绝逻辑照样通过**。改为用**活进程 + 真实身份**
（`ps -o lstart=`）种锁后，偷锁才会被看见。

### A2. `05-client-contract` 补 `.ps1` 契约 —— **已完成**

新增 `smoke/12-ps-client-contract`，29 个用例，**在 pwsh 7.5.4 下真正执行**。

**必须重定向 `AGENTQ_CONFIG`**：客户端会从 `~/.config/agentq/config` 读
`AGENTQ_HOST`，而本机**确实存在**该文件。不重定向时「无 host」用例会静默解析出
真实 host、走到别的分支——**读开发者自己配置的检查不是封闭的**，换台机器行为就变。

写这个检查时踩到的：我按推测写了 5 条消息文本，其中 4 条与客户端实际输出的**不一致**
（`status accepts no arguments` 而非 `status takes no arguments`；`logs requires a
task id and optional --tail <lines>` 而非 `logs requires one task id`；
`--workdir is required` 而非 `submit requires --workdir`；
`must be a positive 32-bit integer` 而非 `positive integer`）。全部改成实测值。
**别猜消息文本——去跑一次。**

**局限（不可省略）**：pwsh **不复现**本项目实际踩过的两个 PS 5.1 缺陷，所以默认
（pwsh）配置下本检查**不关闭** PS 5.1 的缺口；**2026-09-25 起**可经
`AGENTQ_SMOKE_PWSH` 在真 PS 5.1 上按需跑（2026-10-02 已在专用测试机上实跑
`ps51=covered`），此前只有 Windows 11 VM 的 13 例坏参数路径。

### A3. `run-tests.sh` 的 SKIP 语义 —— **已完成**

总结行之后紧跟一行 `NOT A FULL PASS: N check(s) skipped and M check(s) only partially
verified.`，并给出如何补跑。退出码仍是 0——SKIP 是环境属性，不是被测代码的失败。
（**2026-10-05 更新**：判定覆盖「skipped 或 partial」两种情况——第三桶 PART 是为
`01` 内层 `skipped(pwsh-absent)` 这类「整体跑完但自报未验证子部分」的检查加的，
见 `CLAUDE.md` 的防假绿段。）

### A4. 文档整理 —— **已完成**

- `CLAUDE.md` 覆盖表补 `11`/`12` 两行，计数改为十二项，SKIP 措辞段落改写
- **主机授权边界写进 `CLAUDE.md` 的操作边界**（只有用户当次点名的机器可触碰，其余
  连只读调用也不行；**地址一律不写入仓库**）——这条此前只在会话记忆里
- `CLAUDE.md` 增加指向 `PLAN.md` 的一行
- `HANDOFF.md` 删掉与 `CLAUDE.md` 重复的 smoke 清单（改为指针），头部声明待办不在
  这里

### A5. Windows 远端终端兼容性 —— **已执行（A5a/A5b 均已修，两台客户端）**

C1 在主机 A 上实测。**先说清一个我最初搞错的框架**：Windows 上 sshd 用
`<DefaultShell> <DefaultShellCommandOption> "<cmd>"` 解析客户端发来的命令，
`DefaultShell` 至少三种（`cmd.exe` / `powershell.exe` / Git Bash），
**每一种都是一个不同的解析器**。我第一轮只测了该机当前的 Git Bash，就把结论写成
"Windows 命令行上限 8186"——那是**一种终端**的数字，不是 Windows 的数字。

**实测（主机 A，逐字符二分，同一台机器上换外层解析器）：**

| `DefaultShell` 形态 | 远端命令行上限 | 客户端命令的退出码 |
| --- | ---: | --- |
| Git Bash（`bash -lc "<cmd>"`） | 8,176 | **保留**（42/45/124 原样） |
| `cmd.exe`（`cmd /c "<cmd>"`） | 8,155 | **保留** |
| `powershell.exe`（`powershell -c/-Command "<cmd>"`） | 8,125 | **压平为 1** |

**两个独立问题，都与终端类型有关：**

**A5a 长度**：仓库探针命令行 **8,658** 字符（Windows 客户端 **10,146**），
**超过全部三种上限**。所以这不是 Git Bash 专属——换任何终端都会截断，只是截断点
不同（8,125–8,176）。截断落在 base64 中段，PowerShell 报
`TerminatorExpectedAtEndOfString`，客户端报"协议探针失败"，**该主机上所有命令都
走不通**。成因是探针里的 reparse 路径校验把脚本顶到 3,216 字符（不含该校验的旧版
491 字符）。**"何时引入"不可考**：`CHANGELOG.md` 查不到这条加固的记录，本机已装的
两个旧客户端都不含该代码。

**A5b 退出码**：`DefaultShell` 是 `powershell.exe` 时，外层 PowerShell 把内层
原生程序（`powershell.exe -EncodedCommand …`）的**非零退出码全部压成 1**——实测
内层 2/42/43/44/45/124 一律变 1，只有 0 和 1 保留。Git Bash 与 `cmd.exe` 都原样
传递。**这直接打穿协议**：`42-45` 是 launcher 的契约退出码（缺 launcher /
不兼容 / reparse 非法 / 过大），压成 1 后客户端分不出"部署不完整"和"一般失败"；
`124`（平台探测超时）同理。

**2026-10-01：这一列终于有真机了——在专用 Windows 测试机上真造出
`DefaultShell=powershell.exe` 并端到端跑通。** 做法：写
`HKLM:\SOFTWARE\OpenSSH` 的 `DefaultShell` = 系统 PowerShell 5.1 路径、
`DefaultShellCommandOption` = `-c`（该键此前不存在 = 默认 `cmd.exe`），重启 sshd。
先**证明这一列真的生效**：`echo $PSVersionTable.PSVersion` 回 `5.1.19041.3996`。
**压平的精确边界（干净复现，比此前更准）**：压平的对象是**原生子进程的非零退出码**，
不是 PowerShell 自身的 `exit`——`cmd /c exit 0`→0、`cmd /c exit 2`→1、`cmd /c exit 5`→1，
而 PowerShell 自己的 `exit 0`→0、`exit 5`→5。**AgentQ 的远端操作恰好走前者**：
客户端发的是 `powershell.exe -EncodedCommand <wrapper>`（原生子进程），wrapper 内层
`exit ([int]$launcherExitCode.Value)` 是对的、内层确实以该码退出，但 sshd 这一层
把它压成 1。

**实测的客户端行为，与预测完全一致**：成功路径（`0`）不受影响——`doctor`、
`submit`、`wait`(`result=Success`)、`logs`(`A5B-PS-OK`)、`remove`(`removed:true`)
**全部退 0**；而失败/状态路径失真——`lookup` 对 not_found **返回了正确的
`{"state":"not_found"}` 却退 1**（应退 3）、`lookup` 对 removed 应退 5 却退 **1**、
`logs`/`remove` 对未知 id 应退 2 却退 **1**。**根因定位到行**：`run_operation_ssh`
直接取 `$?` 作为远端退出码（`skill/assets/client/unix/agentq` 的 `run_operation_ssh`，行号按本仓规矩不引用），**没有**任何
带外 token——`agentq-exit` 只加在**探针**路径（`windows_probe_apply_exit_token`），
所以探针能工作、操作路径不能。这**确认**了本节此前的判断（「客户端依赖 `3/4/5/6`
做恢复判定」），并把「未验证」升级为「真机实测的缺陷」。

**已修（2026-10-02）——通道就是 stderr。** 原先以为要在 stdin（被 base64 payload 占）
或 stdout（是 JSON 响应本身）之间取舍，但客户端**本来就把远端命令的 stderr 捕获进一个
受保护临时文件**（服务端的 `reason=` 通道就是这么过来的，见 `run_ssh_logged`）。所以
launcher wrapper 把 `agentq-exit:<code>` 写到 **stderr**，客户端从那一个通道里取。
**改动面**：`build_windows_remote_command` 的 wrapper 在两份客户端里各加一行
`[Console]::Error.WriteLine("agentq-exit:$agentqLauncherExit")`（规则 E 的 parity 仍然
绿——两份逐 token 相同）；POSIX 侧新增只读的 `agentq_remote_exit_token`（字符集限定
`[0-9]+`，与 `reason` 通道同样的纪律：只取受控标识符、绝不回显 stderr 原文），在
`run_ssh_logged` 里**仅当 `remote_platform=windows`** 时用它覆盖 `ssh_status`；
Windows 侧在 `Invoke-SshLogged` 里用同一个 `(?m)^agentq-exit:(\d+)\s*$` 正则覆盖
`$exitCode`（同样仅限 windows）。

**为什么「以 token 为准」是安全的**：wrapper 对**两种** `DefaultShell` 都发 token，
而 token 的值就是 wrapper 真实 `exit` 的码——所以它在 ssh 退出码可信时**与之一致**、
在不可信时**是唯一正确的**。unix 目标永远不发这个 token，故不受影响。

**真机双向验证（2026-10-01/02，同一台测试机，两列都跑）**：`cmd.exe` 列——
修复前后行为**逐项相同**（`0/2/3/5` 全对，即修复在该列是 no-op）；`powershell.exe` 列
——修复前 `lookup(not_found)=1`、`lookup(removed)=1`、`logs/remove(unknown)=1`，
修复后**分别是 3/5/2/2**，成功路径 `doctor`/`submit`/`wait(Success)`/`logs`/`remove`
仍全 0。**变异 3 个被抓**：关掉提取 → `lookup` 退回 1；两份 wrapper 都丢掉 token
（此时 parity 仍绿，只有行为检查能看见）→ 被抓；把 token 解析的字符集放宽 → 被新增的
注入用例抓住（`agentq-exit:3; echo pwned` 会被当成码 3 传进 `return`，报
`numeric argument required`）。回归锁：`smoke/05` 新增「flattened 目标」桩 + 注入用例，
`smoke/12` 新增 wrapper token 断言。

**仍未覆盖**：真实 `4`（`ambiguous`/`cancellation_pending`）需要竞态才能构造，未构造；
但**通道已用全部协议码（`2/3/4/5/6/42/45/124`）证明**——token 逐码存活、提取模式取到
最后一个，与具体码值无关。

**已实施（2026-09-22，只改 `assets/`，两台客户端）：**

- **A5a**：探针脚本不再进命令行，改**经 stdin** 喂给 `powershell.exe … -Command -`，
  两端命令行都固定为 **76 字符**（不随脚本增长）。POSIX 侧新增
  `make_windows_probe_script_file` / `windows_probe_command_line`，复用既有身份校验
  临时文件机制：新文件注册进 `windows_argument_identity_for_path` 白名单，
  `run_platform_probe` 在交给 ssh 前**先校验身份**（既有的保护没有被绕过）。
- **A5b**：**实测确认 token 与退出码的通道分离**——三种外层下 stdout 上的
  `agentq-exit:<code>` **都完整**，只有「退出码」那一列在 PowerShell 外层下被压平为 1。
  所以调用方以 stdout 上的 token 为准。**修的过程中发现自己第一版有个洞**：探针体内
  的 `exit 42` 会直接结束脚本，追加在后面的 token 行根本不会执行——于是改成把体内
  每个 `exit N` 重写为 `$agentqProbeExit = N`，由末尾统一输出 token。复验：三种外层下
  `42/43/44/45` **全部可恢复**（PowerShell 外层 ssh rc 仍是 1，但有效状态正确）。

**第三条不变量（`DefaultShell=cmd.exe` 与 MSYS 路径转换）未纳入检查**：
`/c` 会被 Git Bash 的转换吃掉（实测 `cmd.exe /c` 在 Git Bash 下变成交互式 cmd）。
那是**本地包装层**的行为，不是客户端发出去的东西，没有可静态断言的形态；
这条留作已记录的事实，不是待办。

**已交付的检查（`smoke/14-remote-command-length.sh`，零授权、纯静态）**：
断言"远端命令行长度 <= 8,125 − 256"这个预算。长度是纯静态量，不需要真机；而它
**已经悄悄破过一次**（探针从 491 涨到 3,216 字符，全套检查没有一条能发现）。
**七个站点**：POSIX 协议探针、POSIX 平台探针、launcher wrapper、Windows 协议探针、
Windows 客户端自己的 launcher wrapper（第 5 个是 C5 审查补上的——此前它从未被测量过，
把它撑到 26,538 字符全套检查依然全绿），以及 **Windows 客户端的 unix 探针脚本（2,707）
与 unix 安装脚本（1,267）**（第 6、7 个是 A21 修法**自己造出来的**：那两条脚本原先作为
裸 argv 发出、命令行上很小，改成 base64 通道后**第一次出现在命令行上**，而 base64(UTF-8)
约为原脚本的 4/3——**这个修复让这两条命令行比它替换掉的字节更长**，而本检查存在的全部
理由就是 Windows 目标的命令行上限。这正是第 5 个站点那条教训的直接应用：站点不在列表里，
就永远量不到。`sshp` 的**会话命令刻意不量**，理由与它不被包装相同——需要 tty）。

**量的是命令行，不是脚本体**——这是修好之后必须重写检查的原因：把脚本体搬到
stdin 之后，"脚本多大"不再是风险，把脚本量进预算会把**修好的代码报成红的**。
所以站点 1/4 改为抽取客户端实际发出的命令行常量的长度，并额外断言它
**不含 `-EncodedCommand`、含 `-Command -`**——将来谁退回把脚本塞进命令行，
预算那一行仍会是短的（提取到的常量没变），抓到它的是后两条断言。
实测顺序：先红（8,658 / 10,146 两处超限）→ 改代码 → 全绿（76/2,426/76）。

**站点 2 一度是假绿，已修**：平台探针改用 stdin 后不再调用
`encode_windows_powershell`，而站点 2 的抽取标记正是那个函数名，于是它匹配到了
**launcher 的调用点**、量到的是变量名 `$windows_launcher_wrapper`（25 字符），
报出无意义的 150——**绿灯，但什么也没量**。现在站点 2 断言的是平台探针的**路由**
（必须经 `make_windows_probe_script_file` + `windows_probe_command_line`，
且不得出现 `-EncodedCommand`），因为平台探针不内联命令行、只共享那个常量。
变异 D（平台探针单独退回 `-EncodedCommand`）被站点 2 的三条断言抓住，而站点 1
保持绿——正是这个洞的形状。三个变异全部被抓。

**一个实现约束要先想清楚：终端类型不能靠"先问一句"来适配。**
`DefaultShell` 只在远端注册表里，而**读它本身就需要先有一条能穿过那个终端的命令**
——鸡生蛋。实测也确认"一条命令同时适配三种"不可行：bash 的 `printf` 在 cmd 下不存在
（rc=127），cmd 的 `echo %OS%` 在 bash 下原样回显 `%OS%`，PowerShell 的 `$env:OS` 在
bash 下被当普通字符串。所以修法只能是**让命令对三种都安全**（短到最小值以下 +
退出码带外传递 + 不依赖外层改写），而不是"先探测再分派"。
唯一已可用的区分是 `uname -s`：Git Bash 返回 `MINGW64_NT-…`，另两种下该命令直接失败
——**这正是客户端现有回退逻辑的依据**（`MINGW*|MSYS*|CYGWIN*` → 走 Windows 探针），
而 cmd 与 PowerShell 之间**目前无法区分**，只能都当"Windows 且终端未知"处理。

**已复验（2026-09-22，主机 A，三种外层解析器）**：真实 3,216 字符探针经 stdin 后，
外层 Git Bash / `cmd.exe` / PowerShell **三者都返回 `agentq-windows-launcher-ready`**；
失败路径 `42/43/44/45` 在三种外层下**有效状态全部正确**。

**（此段已过时，保留作历史）** 当时**仍未验证**：`DefaultShell` 真的配置为
`powershell.exe` 的主机——那是用外层 `powershell -c` 模拟的。**2026-10-01 已在专用
测试机上真造出该配置并端到端实测**（见下文「2026-10-01：这一列终于有真机了」与
「2026-10-02 已修」）。

**2026-09-23 补测：压平的范围比本节原先写的更广——是全部协议码，不只 launcher 的 42-45。**
模拟外层 PowerShell 跑内层原生 `powershell.exe`，内层退 `2/3/4/5/6/42/124` **一律变 1**，
只有 `0` 和 `1` 保留。而客户端**依赖 `3/4/5/6`** 做恢复判定
（`agentq_recovery_status -eq 3/4/5`、`-eq 6` 等分支），所以
`DefaultShell=powershell.exe` 的 Windows 主机上，**整个协议退出码契约都会失真**。

**2026-09-24：A5a 的修复本身引入了 P0 回归——已修，并补了能抓住它的行为检查。**

在 A8 的只读盘查里撞到的：**POSIX 客户端连不上任何 Windows 主机**，报
`native Windows platform probe returned an unexpected response`。成因是 A5a 的实现方式：

`make_windows_probe_script_file` 把承载探针脚本的临时文件路径写进**全局变量**
`platform_probe_stdin_file`，但它的调用点写成 `windows_platform_command=$(windows_probe_command)`
——**命令替换开子 shell，里面设的全局变量传不回来**，于是该全局恒为空、探针拿不到
stdin 上的脚本。PowerShell 读到 EOF、零输出、退 0，客户端于是报"unexpected response"。
（`$(...)` 传不回全局是 POSIX shell 的固有语义，已单独实测确认。）

**同一个函数里还有两个缺陷，都是这次一并修的：**

1. `run_platform_probe` 在开头无条件执行 `platform_probe_stdin_identity=''`，
   把**它下面那步要用的**身份记录清掉了——身份校验随即正确地拒绝了客户端自己的临时
   文件（`refusing to use Windows argument temporary without a recorded identity`）。
   安全网本身是对的，错的是那行清空。
2. 这个临时文件**从未登记进 EXIT trap**，所以每次探针都在 `TMPDIR` 里漏一个文件
   （实测每次 1 个；而 Windows 目标要跑**两个**探针：先平台、后协议，所以一次
   `status` 会漏两个）。`make_windows_probe_script_file` 现在先清掉上一个再建新的。

修法：新增全局 `windows_probe_prepared_command_line`，让
`windows_probe_command` / `windows_agentq_protocol_probe_command` 用**语句**形式调用
（不再在 `$(...)` 里），三个调用点改为先调用、再从全局取命令行。

**为什么全套检查都是绿的——这条必须记住。** `smoke/14` 量的是命令行**长度**与
"脚本不在命令行上"，两者都**只增不减地为真**：探针确实还在用 `-Command -`，只是
stdin 是空的。静态抽取看不出"发出去的东西是空的"。**这类缺陷只有行为检查能抓。**
故在 `smoke/05` 新增一节：用忠实的 MINGW64 桩（`uname -s` 答 `MINGW64_NT-10.0-19045`，
故走 `probe_native_windows_platform` 分支）断言三件事——探针脚本**真的到达 stdin**
（字节数 > 0）、Windows 路径**能跑完**、`TMPDIR` **零残留**。把旧版本客户端换回去
实测：三条断言全部报红（`EMPTY Windows probe script on stdin (got 0 bytes)`、
`left 1 file(s) in TMPDIR`），换回修复版全绿。

**真机复验**：主机 A（Windows）用修复后的客户端跑 `status`，探针通过、无临时文件残留。

**探针路径已修**（探针的退出码经 stdout token 带外传递），**submit 路径没有**：
`build_windows_remote_command` 的 launcher wrapper 仍是 `-EncodedCommand`（长度 2,426，
**在预算内**，所以 `smoke/14` 不会报它），退出码只靠 `exit ([int]$launcherExitCode.Value)`，
**没有** token。要在 submit 路径上照做，先解决**通道冲突**：submit 的 stdin 已经在传
base64 payload，token 只能走 stdout。这条**不是新回归**，是 A5b 原本就记录的未验证范围
在 submit 侧的具体落点。

**2026-09-24：submit 侧补上同一类行为断言（零授权，只改 `smoke/`）。**
探针的 stdin 已被钉住，但 submit 走的是**另一条**通道——`build_windows_remote_command`
的 launcher wrapper（`-EncodedCommand`），payload 经 stdin 传 base64。静态检查对它
同样无能为力：客户端**仍然**在发 `-EncodedCommand`，看不出喂进去的 base64 是空的。
`smoke/05` 新增的断言分两层：payload **字节数 > 0**，且解码后的 NUL 分隔参数向量里
**真的含**该次 submit 的 workdir（`/tmp`）与 request id（`smokeclient00000001`）。

**断言本身踩过一个坑，值得记下来**：status 也走同一条 launcher 路径，且在这个检查里
**先**执行，所以按 `calls.txt` 里第一条 `launcher` 记录取 payload 会量到 **status 的
payload**——第一版就是这样：断言看着在测 submit，实际测的是 status，而且因为 status
的 payload 非空而**恒绿**。改为按桩记录的下标把每次 launcher 调用映射回它写的那份 payload 文件，再取首个参数为 `submit` 的那份。
（这与本仓那条老教训同形：**断言选中了错误的被测对象时，绿灯什么也不证明**。）

**失败必须分得开，否则会把人指错方向。** 这里有三类不同的失败：launcher 从未被调用、
被调用了但 payload **是空的**（P0 那一类）、被调用了但 payload **不是本次 submit 的
向量**。第一版把它们塌成同一句 `never invoked the Windows launcher`——而 launcher
其实被调用了，读的人会去查错的地方。现在三条分支各报各的（外加"payload 里缺哪个参数"
逐项报出）。**空 payload 的判定范围是最后一次 launcher 调用**：这个检查里 submit 恒为
最后一次，若把空判定跨所有调用累积，则"status 的 payload 空、submit 的正常"会误报成
空 payload——一个假红，且消息指向错的操作。

**分支可达性单独证明过**：这个检查里客户端在 Windows submit 下**必然**走 launcher 路径，
所以"launcher 从未被调用"那条分支**无法**由变异客户端产生——把断言块抽出来喂合成
`calls.txt` 与 payload 单独跑，五种输入各得其所：`none` → `never invoked`、`empty` →
`EMPTY launcher payload`、`stale` → `no payload decoded to a submit argument vector`、
`missing` → 逐项 `lacks`、`ok` → 0 failures。**（写这一节时又抓到一个自己的假绿）**：
计数原先写成 `grep -c ... || printf '0'`——`grep -c` 无匹配时**既打印 `0` 又退 1**，
于是变量成了 `0\n0`，下面的 `-eq 0` 直接报错为假，"从未被调用"那条分支**永不执行**；
改用 `awk` 计数。这与本轮的主题是同一件事：**一条读起来像断言、实际不可达的分支，
比没有断言更坏**。

**变异 3/3 被抓**：① payload 为空（报 `client sent an EMPTY launcher payload on stdin`）；
② payload 非空但是**错的向量**（陈旧 `status`，报 `... no payload decoded to a submit
argument vector ... launcher 4 13 status`）；③ payload 是合法 submit 向量但**缺参数**
——第三个是唯一能**隔离**出参数断言的（客户端退 0、桩按 `submit` 回 JSON，其余断言都
不该响），实测报 `launcher payload for a submit lacks smokeclient00000001: submit`。
另有 1 个变异是**坏变异**：`printf 'submit\0'` 在生成的脚本里成了字面反斜杠，桩解不
出来，它什么也没测——记录在此以免被后人当成证据。

**顺带补上 submit 之后的 TMPDIR 残留断言**：原来那条零残留断言只在 **status 之后**跑，
而 submit 会分配**自己**的临时文件——只查两个操作里的一个，正是本节要纠正的那类错误。
实测 submit 路径本来就不残留（`TMPDIR clean after submit`），断言是把它钉住而不是修缺陷。

**为这条断言找变异时，两个变异是无效的，如实记录**：status 与 submit **共用**
`build_windows_remote_command`，所以破坏该函数里的清理（M4）**先**被 status 那条残留
断言抓住，不能证明 submit 那条敏感；改造成"第二次调用才泄漏"（M5）后**没被抓到**——
进一步追查发现 submit 的 payload 文件由**另一条 submit 专属**的清理块
（`cleanup_client_runtime` 里 `submit_input_file` 那一支）负责，M5 改错了对象。
真正的隔离变异是 M6：只拆掉 `submit_input_file` 的清理（该块仅在 submit 时有文件，
而 submit 是最后一步，status 那条断言早已通过），实测报
`client left 1 file(s) in TMPDIR after a Windows submit: .../agentq-windows-arguments.Jcno9N`。
**两个无效变异的价值在于它们暴露了我对清理路径的错误假设**——以为 submit 与 status
共用一份清理代码，实际不是。

**仍未覆盖**：submit 路径的**退出码通道**（A5b 那条），`DefaultShell=powershell.exe`
时非零仍被压平为 1。本节只证明 payload 送达。
（**2026-10-02 更新**：这条已不再是缺口——A5b 的操作路径 token 走 stderr 后，
submit 与其余操作共用同一个 `run_operation_ssh`，退出码随之恢复；见上方 A5b 正文
与 A20 的真机端到端。）

### A6. `task_instance_created_at` 的"取第一条匹配" —— **已修并验证（零授权，只改 `assets/`）**

C1 在主机 C 上实测到的缺陷二。`cancelled_task_replay` 要求 marker 的 `created_at` 等于
`task_instance_created_at` 的结果，而后者遍历 `data/agentq-requests/*.json` 与
`.tombstones/*.json`，**在第一个匹配该 task id 的文件上就 `return 0`**。Pueue 会回收
removed 任务的数字 id，所以一个被复用过的 id 会有多条 record，函数固定返回**最早**
那条的 `task_created_at`，与 marker 指向的**最新**实例必然不等 → 重放被拒、退 2。

**这不是我的测试制造出来的形态。** 三台真实主机的现状：tombstone 里同一个 id 被
重复记录是常态——一台上有 `142×10`、`141×2`、`187×3`、`275×2`，另一台上有 `310×9`、
`378×9`、`358×3`、`232×2` 等。也就是说 Pueue 回收 removed 任务的 id 是**正常运行**
就会发生的事，而只要某个 id 的 tombstone 条目多于一条，"多条 record 抢同一个 id"
就是必然——`task_instance_created_at` 取第一条匹配的返回就会指错实例。
（两台机器的 **record** 目录里都没有重复 id，是因为 record 在 removed 后被搬去
tombstone；重复恰恰累积在 tombstone 一侧。）

这可以**零授权**修（只改 `assets/`，不需要真机），但**必须先钉死行为**：

- `agentq-server` 是 5,332 行无类型 shell，本仓 smoke **抓不到行为回归**
- 这条路径是安全相关的（那两处 `created_at` 相等判断正是防止 id 复用误判的核心）
- 所以顺序是：先为 `cancelled_task_replay` / `task_instance_created_at` 写一份
  针对性契约检查（**改之前就要能红**），再改，再复跑

**要注意这不是"把 return 0 挪到循环之后"这么简单**：marker 只记了一个 `created_at`，
而"哪个实例是当前实例"在 id 复用的语义下需要额外判据（例如同时比对记录的状态与
`created_at` 的先后，或让 marker 记录 request id）。**先想清楚判据，再动代码。**

**已实施（2026-09-22）**：判据选的是**"是否存在一个创建时间匹配的记录"**，而不是
"哪个实例是当前实例"——因为守卫真正要问的就是前者（"有没有证据表明一个 `created_at`
为此值的任务实例用过这个 id"）。函数由 `task_instance_created_at`（返回第一条匹配）
改为 `task_instance_created_at_is_recorded`（在**任何**匹配上返回真，全部遍历完才假），
调用方相应改为布尔判断。这样既修好 id 复用下的重放，也不放松陈旧 marker 的拒绝。

**取证顺序（先红后绿，且证明测试敏感）**：
- `smoke/03` 新增复用重放用例：为 `reused_task_id=999001` 放两条 record
  （`...instance-aaaa` / `2003-03-03`，`...instance-bbbb` / `2004-04-04`）+ 一条指向
  `2004-04-04` 的 marker，要求 `cancel` 退 0 且 `reused:true`。
- 三个变异：**M1**（去掉实例绑定守卫）被抓；**M2**（退回取第一条）也被抓，但
  **M2 是无效变异**——它把比较整个塌掉了，于是**陈旧 marker** 那条断言先触发，
  我新加的复用用例根本没跑到，**敏感性未被证明**。
- 所以补了 **M3**：精确复原原缺陷形态（函数取第一条匹配、调用方在外层比较）。
  结果 **exit=1 CAUGHT**，抓住它的是 **`smoke/03:498`**——即新增的
  `a replay at a REUSED task id was refused` 断言，正是要证明的那一条。
  （日志里那条标签最初是空的，因为 grep 模式大小写不匹配 `REUSED`；不是别的断言抓的。）

同一轮实测还确认了文档的一处归因不准：`CLAUDE.md` 把"重放窗口有限"归因于
"还没人读过它的终态"，而实测表明——**只要该 id 之前被用过，窗口在取消确认的当下
就已经关闭**，与有没有人读过无关。这条归因已改。

### A7. 把 C1 的网络中断变体固化成可重复的检查 —— **已执行（零授权，只改 `smoke/`）**

C1 的中断变体是本轮唯一"真实执行"的中断证据，但它跑在**本地一次性脚手架**上
（已删除），仓库里没有留下可重复的形式。三项已实测的契约值得钉住：

- submit 丢响应 → 同 request ID 对账成功、`reused:true`、**不产生重复任务**
- cancel / remove 丢响应 → **不自动重试**（恰好 1 次远端调用），靠后续读取重新确认
- 安全操作（status 等）遇瞬时中断 → 有限重试并最终成功

**已实施（2026-09-24）**：并入 `smoke/07` 而不是新建检查。07 的文件头本来就写着它
要覆盖 "the response-loss reconcile"，实际却**没有测**——沙箱（真实 sshd + pueued +
ssh 包装）是这个检查里最贵的部分，复制一份约 150 行的搭建代码既费又必然漂移
（launcher parity 那课）。所以 A7 是 07 的第 8 节。

**注入方式（三条契约共用）**：`$work/bin/ssh-flaky`，按远端命令里 `agentq_run '<op>'`
取出操作名，用 `fail.<op>` 倒计时文件控制"第几次调用失败"，并把**每次调用**记进
`calls.<op>`——调用计数就是"不许自动重试"这条断言的证据。两个细节照抄实测：
诊断必须写进 **`-E` 日志**（客户端的 `ssh_transport_error` 读的是那里；实测 OpenSSH
把远端命令的 stderr 送本地 stderr、`-E` 只收 ssh 自己的诊断），且**命令必须真的先执行**
再伪装失败——否则"服务端做完了、调用方只看到失败"这一形态根本不存在，测了等于没测。

**三个用例**：8a submit 丢响应 → 须退 0、`reused:true`、stderr 有 `reconciling attempt`、
且该 label 在 `status` 里**恰好 1 个任务**（按 label 计数，重复提交会暴露成 2 个）；
8b cancel 丢响应 → 须退 255 且 `calls.cancel` **恰好 1**（多一次就是被禁止的自动重试），
再靠读取确认取消**确实生效**；8c status 遇瞬时中断 → 须退 0 且 `calls.status` **恰好 2**
（一次失败 + 一次重试）。

**踩到的两个坑，都值得记**：
- **取消确认的通道取决于走哪条路径**。队列满时目标是 Queued → `queued_removed`，任务被
  从 Pueue 移除，`status` 里**根本没有它**（实测），只能靠 `lookup` 经 tombstone 读到
  `removed`；队列空时任务立即 Running → kill 路径，`status` 里带着
  `.agentq.cancellation_requested_at`。我第一版无论哪条路径都断言 `removed`，于是把一个
  **成功**的取消报成"从未生效"。现在先记录该目标当时是 Queued 还是 Running，再断言对应
  的确认通道——两条真实路径都覆盖。
- **`set -o pipefail` 让 `lookup | jq` 恒判假**：`lookup` 对 removed 请求按设计退 **5**，
  管道因此整体失败，即使 jq 匹配成功。必须**先捕获再匹配**（07 第 6 节本来就是这么写的）。

**变异**：M2（丢掉对账直接失败）被抓；M5（去掉安全操作重试）被抓；"cancel 自动重试"被
退出码断言抓住；**为单独证明调用计数断言敏感**，把 `fail.cancel` 设为 2（两次都失败，
退出码恒为 255，只有计数能区分 1 与 2），此时计数断言抓到 `made 2 remote call(s),
expected exactly 1`。**一个无效变异如实记录**：把对账的 lookup 换回重发 submit
**没有改变行为**——同一 request ID 重发，服务端本身幂等，照样 `reused:true`、照样只有
一个任务，所以它 MISSED 是变异无效，不是断言不敏感（与 A6 的 M2 同一形态）。

### A8. 清理 C1 在三台上留下的队列残留 —— **已执行（2026-09-24）：无需清理，且撞出一个 P0 回归**

C1 跑完后我在三台上留了残留（详见 `CHANGELOG.md` 的收尾审计）：主机 A 一个
tombstone、主机 B 一个任务 + 一条 record + 一条 tombstone、**主机 C 全部 15 个任务
都还在队列里**（都 Done）。这违背了"确认终态且不再需要日志时才 `remove`"的规则——
我为了把矩阵跑全，只在部分用例里做了 `remove`。

清理是**队列 mutation**，需要你明确授权才做。清理本身不难（对每个 Done 且不需要
日志的 task 跑 `remove`），但要注意：**不要顺手删 tombstone 或 record**——那些是
AgentQ 的元数据，`remove` 会自行归档，手动删会破坏实例绑定检查的证据链
（见 A6 那节：`task_instance_created_at` 正是靠这些文件工作的）。

**2026-09-24 执行结果（用户授权：队列 mutation；三台地址由用户在会话中给出，不入库）。**

逐台**只读**核查（`status --json` + 直接读元数据目录，未做任何 mutation）：

| 主机 | 记录里的残留 | 实测现状 | 可清理对象 |
| --- | --- | --- | --- |
| 主机 A（Windows） | tombstone 1 个 | Pueue 最大 id **274**；task 275 已不在队列，只剩 `.tombstones/aq-c1-A-direct-1790070893.json` | **0** |
| 主机 B（Linux） | 任务 840 + record 1 + tombstone 1 | Pueue 最大 id **838**；839/840 **两条都已是 tombstone**（`state: removed`，`removed_at` = 09-22 09:03:57Z / 14:35:18Z） | **0** |
| 主机 C（macOS） | 全部 15 个任务 | **当日未能盘查**：端口通但公钥被拒（`Permission denied (publickey,password,...)`） | **0**（当日的「待定」已消解：后经用户提供凭据补盘，队列已空——见 A8 续查） |

**所以没有执行任何队列 mutation**——A/B 都没有可 `remove` 的对象。PLAN.md 原先那句
"主机 B 任务 840 还在队列"**已过时**：840 在那之后已被正常 `remove` 归档。
两台的 `.locks`、`runtime/`、`/tmp` 均无残留；三台的旧 cancellation marker 都是 8 月的，
不是本轮产生的。**tombstone 一律没动**——那是 AgentQ 元数据，`remove` 自行归档，
手动删会破坏 A6 实例绑定检查依赖的证据链。

**盘查中另有一项未解释的观察，如实记下（未定性、未修）。** 主机 A 上修复后的客户端
跑 `status`，**探针通过**（`sh -x` 跟踪实测：平台探针与协议探针都返回 0，客户端随后
发出真实的 launcher `-EncodedCommand` 调用），但该**操作本身**最终退 2、stdout 为空、
stderr 为空。跟踪显示失败点是 `ssh_status=2` 且 ssh 的 `-E` 日志为空。另做两项对照：
① 手工用合法 NUL 分隔 payload（`status\0`）直接调 `agentq-launcher.ps1`，**退出 0 但
无任何输出**；② 用 `AGENTQ_PLATFORM_PROBE_TIMEOUT=120` 单跑 `lookup` 仍在进行中。
两个已知干扰因素：主机 A 的元数据规模（272 records）使 `status`/`lookup` 本身需
分钟级，而我为诊断并发跑过多次，一度把探针顶到 30 秒超时（**那是我自己造成的负载**，
不是主机问题）。**结论：主机 A 的 AgentQ 协议操作路径是否可用，本轮未能判定**——
`PLAN.md` A5 本来就写着"不能声称主机 A 经 AgentQ 协议可用"，这项观察与那句一致，
**不构成新回归的证据**（探针路径的修复已由变异 + 跟踪 + 67 秒门禁测试三重确认）。
**（2026-09-24 已查明并收尾，见下段：是我自己造成的锁竞争 + 两台部署版本落后；
主机 A 重装后端到端已跑通。此处保留原文作历史。）**

**2026-09-24 续查：主机 A 的"操作退 2"已查明——是锁竞争，且两台的部署都严重落后于仓库。**

沿 A8 留下的那条未解释线索查下去，结论有三层，逐层都有实测：

**一、主机 A 的 `status` 退 2 = operation lock 竞争，不是缺陷。** 直接调**主机上部署的**
服务端（`cd /c/ProgramData/AgentQ && MSYSTEM=MINGW64 ./agentq status`，不经客户端、不经
launcher），拿到确凿的 stderr：`AgentQ operation is already in progress:
/c/ProgramData/AgentQ/runtime/agentq-operation.lock`。该 lock 于 **11:46** 建立——正是我
为诊断并发跑多次 `status`/`lookup` 的时段；该 lock 随后已消失（13:04 复查
`runtime/` 只剩 4 个常驻文件，lock 目录不存在）。**补记一笔**：之后我为确认又跑了一次
长 `lookup`，收工时 kill 了**本地** `ssh`，但**远端服务端进程不会随之结束**——它是有界
工作，会自行跑完并释放锁，所以那一刻主机 A 上留着一个进行中的操作。**我没有手动删那个
锁**（AgentQ 元数据，且远端持有者仍活着）。**所以那是我自己造成的锁竞争**，
客户端退 2 是**正确**行为。这也解释了为什么客户端 stderr 是空的：部署的服务端是
**B3 之前**的版本，**不打印 `reason=lock_contention` 那一行**，所以客户端的 reason
通道（`05`/`07` 钉住的那条）拿不到东西——不是通道坏了，是旧服务端没这条输出。

**二、两台真实主机的部署都严重落后于仓库**（实测行数与 sha）：

| | 仓库 | 主机 A（Windows） | 主机 B（Linux） |
| --- | --- | --- | --- |
| 服务端 | 4,736 行 | **4,715 行**（缺 A6 + B3） | **2,716 行**（8 月 17 日的代） |
| 客户端 | 3,276 行 | `agentq.ps1` 仍用 `-EncodedCommand`（**A5 之前**） | 5 行 shim → 旧服务端 |

主机 A 的服务端差集经 `scp` 取回逐行对比，**恰好只有 A6 与 B3 两组改动**（15 个 hunk：
`task_instance_created_at` → `..._is_recorded`、4 处 `reason=` 行、2 处
`lock_contention` 实参）。主机 B 更旧。**这正是 `CLAUDE.md` 那条"部署单元是 23 个
文件的同一版本、不得只升级一侧"所指向的状态**——两台都停在过去某个整体版本上，
而我在盘查时用的是**仓库当前**客户端，于是构成了 `CLAUDE.md` 明说不会部署的那种
新旧配对。

**三、由此回收 A8 里那句"未判定"。** 当时我写"主机 A 的协议操作路径是否可用，
本轮未能判定"，并注明干扰因素是"我自己造成的负载"。现在查明：**该判断仍然成立，
但原因更具体**——不是主机坏，是①我制造的锁竞争 + ②部署版本落后于我手上的客户端。
两者都不构成回归证据。**探针修复的结论不受影响**（已由变异 + `sh -x` 跟踪 + 67 秒
门禁测试三重确认）。

**四、2026-09-24 收尾：主机 A 重装后，上面三项全部消解，端到端已跑通。** 主机 A 现为
4,736 行 / `e3b132af`（= 仓库），B3 的 `reason=` 行与 A6 的修复都已生效；三项里
①锁竞争是我自己堆的孤儿（已清，见 B5-执行），②版本落后已由重装消除，③"未判定"
不再需要——`status`/`submit`/`wait`/`logs`/`remove` 五项均 exit 0 并返回正确结果。
**A8 那条观察至此完全闭环，无遗留疑点。**

**旧主机 C 已盘查（2026-09-24，用户提供该机账号的密码）。** 实测（macOS 15.7.7）：服务端 **4,727 行**（落后仓库的 4,736）、
`pueued` 在跑（系统级 LaunchDaemon active）、客户端 shim 在。

**那 15 个任务已经不在队列里了**——实测 `pueue status` **total tasks: 0**。而且这
**不是**别人清的：`.tombstones/` 里有一组 mtime 为 **2026-09-22 22:35:45–22:36:45**
的连续 15 条记录（`task_id` **0–14** 恰好连续），正是 C1 当晚批量 `remove` 的形态。
当前元数据为 **record 7 + tombstone 29**，而 A8 盘查时记的是 record 22 + tombstone 14：
**22 − 7 = 15**（被 remove 的 record 转成了 tombstone）、**14 + 15 = 29**。
两处算术都恰好对上那 15 个任务，所以**A8 想清的东西已经清掉了**，没有可做的队列
mutation。（`record 7` 是 `aq-c1-q..q7`，`task_id` 全是 16——那是我在复用 id 上做的
重放用例，属正常元数据，不是残留。）

**主机 C 已重装成功（2026-09-24，用户授权）。** 部署单元 `skill/assets/unix/` 7 个文件经
`scp` 暂存后由安装器原子替换；实测 **4,736 行 / `e3b132af`（= 仓库）**、`bash -n` 通过、
直接调服务端 `status` **exit 0** 返回 `{"tasks":{},"group":{...}}`、
**数据完整保留**（7 record / 29 tombstone / `shared_secret`）、
系统级 LaunchDaemon `state = running`、`pueued` 已重启（新 pid）、**零事务残留**、
我的暂存目录已删。Pueue 二进制走**设计好的** `AGENTQ_PUEUE_SOURCE_DIR` 预置通道——
该机原有 `pueue`/`pueued` 的 sha256 **与安装器内置值逐字节相同**，所以无需访问 GitHub；
安装器仍自行校验哈希。sudo 走 `SKILL.md` 记的 `-A` + `SUDO_ASKPASS` 包装，**装完立即删除**。

**端到端仍未做，卡在密钥上（不是缺陷）。** 该机 `authorized_keys` 里只有 2 把别人的 ED25519，
本机三把私钥（`id_ed25519` 两把、`id_rsa` 一把）逐把实测**全部被拒**。
所以**经 AgentQ 协议仍连不上**——`BatchMode=yes` 不吃密码（这正是 A9 修的那个提示所说明的）。
要跑端到端，需要往该机装一把我们的公钥（凭证操作，等授权）。
**（2026-09-24 更新：用户当天授权后已完成，见 A11。）**

**盘查本身撞出一个 P0 回归（我自己在 A5a 引入的，已修）**：POSIX 客户端
**连不上任何 Windows 主机**。成因是 A5a 的实现方式——承载探针脚本的临时文件路径写在
全局变量上，而调用点用了 `$(...)`：**命令替换开子 shell，里面设的全局传不回来**，
于是探针拿到空 stdin、PowerShell 读到 EOF 就退 0。详细成因、同一段代码里另外三个
缺陷（身份记录被提前清空、临时文件未登记 EXIT trap、两个探针互相孤儿化临时文件）
与修法见上面 **A5 那节**；行为检查加在 `smoke/05`。

**教训（已写进 CLAUDE.md 覆盖表）**：`smoke/14` 量的是命令行**长度**与「脚本不在
命令行上」，这两条在缺陷下**依然全为真**，所以静态抽取一路绿灯——**"发出去的东西
是空的"只有行为检查能抓**。

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
### A9. 目标机只有密码认证时连不上，且报错把人指错方向 —— **已修（2026-09-24）**

用户截图里另一会话的诊断（「AgentQ 使用非交互认证，因而认证失败」）**成立**，我独立
复现并往下查到了两个**真实的报错缺陷**。全貌：

**`BatchMode=yes` 是设计，不是缺陷。** POSIX 客户端四处 ssh 调用全部硬编码它，所以
只有密码、没有可用密钥的目标机上，AgentQ 的所有命令必然失败。实测（一台 macOS 15.7.7，服务器提供 `publickey,password,keyboard-interactive`）：普通 `ssh` 用
密码成功，`ssh -o BatchMode=yes` 退 255 `Permission denied`。无人值守的队列不能停下来
等人输密码，这个取舍是对的。**缺陷在于失败之后告诉用户什么**：

1. **分类器漏判（四个资产同一处）。** 实测 `-E` 日志的 81 字节是
   `<user>@<host>: Permission denied (publickey,password,keyboard-interactive).\r\n`
   ——OpenSSH 加了 `user@host: ` 前缀，而分类正则要求消息在**行首**，于是**永远匹配不到**，
   一律落到兜底的 `class=ssh`。**没有任何测试断言过这个分类器**，所以它在四处同时存活。
   修法：前缀改为可选 `^([^:]*: )?(...)`。**必须可选**——实测
   `Host key verification failed.` 是**无前缀**的裸行首，只加前缀会把它弄坏；
   `smoke/05` 两个方向各有一条用例。**`Could not resolve hostname` 实测不写 `-E` 日志
   （为空）**，所以没有为它编造 fixture。
2. **提示指向错误方向。** 两个探针都失败时客户端只打印「set `AGENTQ_REMOTE_PLATFORM`
   to unix or windows」——**那个变量救不了缺密钥**，而日志按设计脱敏，真实原因完全不可见。
   现在认证类失败额外打印一行，点名 `BatchMode=yes` 与可行做法。

**第一版修错了地方，如实记录。** 我把提示写在调用方的决策点，实测报
`platform_probe_log_file_is_safe: command not found` 且提示永不触发——因为调用方是
`local_platform_output=$(run_platform_probe_with_recovery ...)`，**命令替换开子 shell**，
探针设的全局与它清理的临时文件**都传不回来**，决策点上日志路径已是空串。
**这是本项目第三次踩 `$( )` 同一个陷阱**（前两次：`detect_stat_flavor` 缓存、A5a 探针
脚本临时文件）。改到 `write_ssh_diagnostic_metadata` 内（日志与分类都还在手上）后生效。

**验证**：先红（`class=ssh, 84 bytes`）→ 改 → 绿；真机复核从 `class=ssh` 变为
`class=authentication` 并打出 `BatchMode` 提示。**变异 2/2 被抓**且互不干扰
（退回无前缀正则 → 2 条断言红；删掉提示 → 1 条红）。`smoke/05` 用例 16 不变（新增断言
挂在既有用例上）。

**仍未做**：`sshp` 只改了分类器，**没有**加同样的提示（它是人类交互终端，本来就允许
密码提示，所以缺的不是同一个问题）。Windows 两个客户端的分类器已改，其**真机验证
2026-09-27 由 A16 完成**（认证失败输出 `class=authentication`；本机 pwsh 不跑 ssh
失败路径，此前只能是未验证状态）。

### A10. 两份 POSIX 安装器的搬移语义没有护栏 —— **已补（2026-09-24）**

审查「同一模式抄在多处」时发现的：`install-client.sh` 与 `install-agentq.sh` 共享 6 条
消息，但**共享函数只有 `fail()` 与 `cleanup_on_exit()`**——搬移逻辑是**各自独立实现**的
（`client_move_*` vs `installer_move_*`），语义一致但代码不同源。`01` 的 parity 只覆盖
两条 `agentq-server`，所以「改了一份忘了另一份」是可能的。

**实测：16 个 `mv` 站点今天全部有事后复核**（源已消失、目标存在且是常规文件、非符号链接、
路径链仍安全）。复核是搬移被信任的**全部理由**，也正是 Windows 侧 `chmod`「成功但什么
也没改」那一课的同形。

**新增 `smoke/10` 规则 G**：每个 `mv` 之后，**其所在函数内**必须有复核。作用域是
**函数**而非固定行窗口——`smoke/10` 自己的规则 D 注释早就写着「窗口两个方向都错」，
而我在规则 G 里**把两个方向都犯了一遍，如实记录**：

1. **太窄**：第一版用 9 行窗口，误报 2 处（第 1804/1852 行的复核在 `mv` 之后 18 行，
   因为 `if ! mv` 分支里先有一段恢复代码）。
2. **太宽**：改用「函数」后，我的 awk 把 `end` **反复覆盖**成整个文件里最后一个 `^}`，
   于是扫描范围一路扩到文件末尾、匹配到**别的函数**里的 `is_safe`——**实测：把
   `move_client_file` 的复核整块删掉，规则仍报 green**。这正是 RULE D 警告的
   「宽到能容纳下一个函数的读回」。改成取 `mv` 之后**第一个** `^}` 才正确。

**变异 3/3 被抓**：删 `install-agentq.sh` 的复核、删 `install-client.sh` 的复核、
把复核**挪进下一个函数**（G3 证明「太宽」那一半也被堵住）。

### A11. 主机 C 端到端 —— **已完成（2026-09-24，用户授权凭证操作）**

重装后仍连不上（`BatchMode=yes` 不吃密码），用户授权装公钥后完成。

**装公钥时撞到的真实障碍：本机 `id_rsa` 有口令。** 第一次我装的是 `id_rsa.pub`，
`ssh -v` 显示 `Server accepts key: ... id_rsa` 之后**仍然 Permission denied**——
因为私钥有口令而 `BatchMode` 无法询问。实测三把私钥的口令状态：
`id_rsa` **有口令**、`id_ed25519` 两把 **无口令**。
换成无口令的那把后 `KEY-AUTH-OK`。**教训**：往一台只跑无人值守客户端的机器装公钥时，
必须同时确认**私钥能在 BatchMode 下解锁**——只验「服务器接受了这个 key」是不够的，
那一步在两种情况下都会打印。

**客户端怎么用上这把钥匙**：客户端不接受 `-i`，走 OpenSSH 自己的身份选择。加了
`~/.ssh/config` 的 `Host <该机别名>` 条目（`HostName` / `User <user>` / `IdentityFile`
/ `IdentitiesOnly yes`），插在既有 `Host *` **之前**以免被兜底规则吃掉。
（该文件原有 81 行、13 个 Host 条目，改动是纯追加 + 一个备份 `config.agentq-bak`。）

**端到端实测（`--host <该机别名>`）**：`status` exit 0（3s，队列空）→
`submit` exit 0（`task_id=0`）→ `wait` exit 0 且 **`result == "Success"`** →
`logs` exit 0 且 `output` 与提交标记**逐字节相同** → `remove` exit 0
（`{"removed":true}`）。**主机 C 至此与 A、B 齐平。**

### A12. 一次瞬时 Pueue 读取失败会把**仍在运行**的任务归档成 `removed` —— **已修（2026-09-25，外部审查发现）**

**这是本会话发现的最严重缺陷，P0 级。** 由独立的外部审查（按你的「正规工程审查 + 使用
agents」指示派出的 5 个审查者之一）发现，我在真实运行时上**独立复现**确认。

**机制（根因是一个 bash 语义陷阱，不是逻辑错误）**：`find_request_task`
（`agentq-server` 内，**不要引用行号**——本会话该文件已改多次、行号漂移过）在无法读取
Pueue 时走 `run_pueue status --json > "$f" || fail 'cannot inspect Pueue while
reconciling an AgentQ request'`。而 `fail()` 是 `exit 2`。**`exit` 在 `$( )` 里只终止
子 shell**，所以调用点 `if task=$(find_request_task "$label"); then` 拿到的不是"失败"，
而是**空字符串 + 假**——调用方据此判定"任务不存在"，于是执行
`set_request_state … removed` + `archive_removed_request`：**删除活的 request record、
写入 tombstone**。

`find_request_task` 有 6 个调用点，全部是这个 `$( )` 形状；`reconcile_removing_request`
（经 `recover_removing_requests` → `ensure_daemon`）是同一个缺陷的第二张脸，而
`ensure_daemon` 被**每一条命令**调用。

**实测复现（本机真实 pueue 4.0.4 + 真实 pueued，包装脚本在第 2 次 `status --json`
上注入一次失败）**：

```
submit 一个 sleep 60 的任务            → task_id=0，status 显示 Running
注入一次 Pueue 读取失败，然后 lookup   → exit 5，{"state":"removed"}
再查任务真实状态                       → 仍是 Running
request record 数 1 → 0，tombstone 0 → 1
```

**后果是永久的，不是瞬时的**（审查者另在真实运行时上逐项实测）：此后 `lookup` 永远
返回 `5`/`removed`；`wait`/`logs` 仍能用，但返回的任务**不带任何 `agentq` 元数据**
（request_id、取消字段、`removal_pending` 全没了）；用同一个 request id 重提会被
`request id was already consumed by a task that has been removed`（exit 2）拒绝；
`cancel`/`remove` 再也无法把任务与它的 request 关联起来。

**同一根因还有第三张脸，症状不同但同样误导**：`cancel`/`logs`/`remove` 对**活着的**
任务报 `unknown AgentQ task id`（exit 2 + `reason=protocol_error`），因为 `compact_task`
把"Pueue 读不出来"塌缩成了"没有这个任务"。契约说 exit 2 意味着"改参数"，而同一个底层
状况在 `wait` 上正确地报 `6`/`unavailable`——调用方会据此以为任务 id 写错了。

**为什么 14 项检查一个都没抓到**：它们断言的都是**稳定状态**下的退出码，从不针对
"操作中途 Pueue 读取失败"。这正是本仓反复写下的那句「smoke 抓不到行为回归」的又一例。

**修法（已实施）**：`find_request_task` 不再用 `fail` 表达"读不到"——它改为返回**显式的
状态码**（`3`=读不到 Pueue / `4`=歧义），由调用方在自己的 shell 里判定并 `fail`。
6 个调用点全部改为 `task=$(find_request_task ...) || rc=$?` 的显式捕获形状（`set -e` 下
唯一安全的形式），并在 `rc` 不属于 {0,1} 时于**父 shell** 报错。`reconcile_accepted_request`
的两个调用点同样把 `3/4` 继续上抛。**实测**：注入一次失败后 `lookup` 退 `2` + 正确
reason，**record 保留、tombstone 未写、任务仍 Running**，Pueue 恢复后 `lookup` 正常返回
`rc=0`；完整正常路径回归（status/lookup/submit/wait/logs/remove/removed=5/cancel 已结束=2）
全部保持正确。

**回归锁**：新增 `smoke/15-transient-pueue-failure`（第 15 项检查）。**红/绿实测**：
修复前（`1bbfd403`）五条断言全红、消息精确；修复后全绿。

**消息误导已修（2026-10-07，A13 收尾）**：`cancel`/`logs`/`remove` 三个路径此前把
`compact_task`/`raw_compact_task` 的**任何**失败都报成 `unknown AgentQ task id`——exit `2`
传播是对的，但把「读不出来」说成了「id 不存在」，与 `wait` 把同一状况报 `6` 自相矛盾。
两个助手其实早已区分：**rc=4 是 Pueue 应答了、id 确实不可见；rc=1（读失败）与 2/5
（畸形 status）是存在性未知**——是三个调用点把区别抹平了。现在统一经
`report_compact_task_failure` 分类（rc=4 保持 `unknown AgentQ task id`、其余报
`cannot inspect Pueue while reading AgentQ task`，均退 2 + `reason=protocol_error`）。
顺带修掉同一分支的第二层误导：pending-marker 的「任务已消失」分支原本对**任何** rc 都
进入——读失败时它会对一个只是没查到的任务宣告「the task is gone」（应是
`cancellation_pending`）——现闸在 rc=4 上（只在确认不可见时才宣告消失；确认重放仍在
闸门之前，所以纯本地 marker 重放在 Pueue 读失败时**仍能成功**）。回归锁扩进
`smoke/15`（第 6 节：三条路径 × 注入一次瞬时失败 + pending-marker 组合），修复前
**6 红**（实测），5 个变异各被抓住；`03`/`26`/`27` 复跑全绿（rc=4 路径的消息逐字不变）。

**修复前的部署上，一次 Pueue 抖动就可能永久污染一条 request。** 这不是"窗口正常
关闭"，不要这样解释。

### A13. 平台探针绕过了 stderr 捕获-脱敏纪律 —— **已修（2026-09-25，外部审查发现）**

POSIX 客户端里**所有**操作类 ssh 调用都经 `run_ssh_logged`，它有
`2>"$ssh_stderr_redirection"`（捕获进 `umask 077` 的临时文件、只取受控的 `reason=`、
随即删除）。**唯独平台探针不是**：探针直接调 `"$ssh_binary"`，只有 `-E <log>` 与
`> <output>`，**没有 `2>`**。

而本仓已实测的 OpenSSH 语义是：**远端命令的 stderr 落到本地 stderr**（`-E` 只收 ssh
自己的诊断）。所以探针这一步，远端命令写什么，调用方 stderr 上就出现什么——**未经过
任何脱敏，且不限长度**（同一处 stdout 有 65536 字节上限，stderr 没有）。

**具体后果**：探针在**任何操作之前**执行。一个远端只要在 `uname -s` 那一步往 stderr
打一行完整的伪造串（例如 `agentq: remote failure reason: lock_contention`），那行就会
原样出现在调用方 stderr 上，早于客户端自己的任何输出。而 `CLAUDE.md`/`SKILL.md` 明确
教调用方「读 `reason`，别匹配消息文本」——一个照做的脚本可以被喂一个伪造的
`lock_contention`，于是**去重试一个本不该重试的操作**。

**注入面在「提取」侧是关好的**（`agentq_remote_failure_reason` 把字符集限定为
`[a-z][a-z_]*`、锚定、只取最后一行），缺的是**「不让远端文本到达本地 stderr」**这一半。

`smoke/05` 有「不得回显原始远端 stderr」的用例，但它驱动的是**操作路径**（`status`），
**不是探针路径**——所以这条一直绿着。

**修法（已实施）**：探针的两处 `ssh` 调用加 `2>/dev/null`，并在函数开头写明理由。
选「丢弃」而非「捕获-脱敏」是因为探针路径**根本不消费 reason 通道**——今天远端 stderr
到达本地是**泄漏**而非特性，丢弃不损失任何现有功能，同时彻底关闭注入面。

**回归锁**：`smoke/05` 新增探针路径用例（驱动 `uname -s` 那次探针，桩同时写伪造
token）。**红/绿实测**：修复前（`3780e2a9`）报「探针让远端可控文本到达调用方 stderr」
+「探针转发了伪造的 reason 行」两条；修复后绿。

### A14. Windows 客户端的 exit-token 改写对多行探针**静默失效** —— **已修（2026-09-25，外部审查发现）**

A5b 的带外退出码通道（探针在 stdout 末尾输出 `agentq-exit:<code>`）在两份客户端里各有一份
改写实现，把探针体里的 `exit N` 改写成赋值，好让末尾那行 token 真的能执行。**两份不等价。**

Windows 侧用的是 `(?m)(^|;[ \t]*)exit ([0-9]+)`，而 **`(?m)^` 只在换行之后立即匹配**。
AgentQ 协议探针体是一个**缩进的多行 here-string**，所以它的 `exit` 前面是空格、不是 `;`——
**7 个 `exit` 一个都没被改写**（实测：改写前 7 个、改写后仍 7 个、赋值 0 个）。于是脚本在
第一个 `exit 42` 就结束了，末尾的 token 行根本不执行。平台探针是单行，所以它一直正常——
这正是问题没被发现的原因。

**后果**：`Resolve-ProbeExitToken` 在 token 缺失时回退到 SSH 退出码；而在
`DefaultShell=powershell.exe` 的主机上那个码被压平为 `1`，于是
`Confirm-WindowsAgentQProtocol` 再也分不出 missing / incompatible / unsafe / too-large 四种
launcher 状态。成功路径（`0`）不受压平影响，所以这只伤诊断、不伤正常运行——
但**这正是 A5b 存在的理由**。

**修法与验证**：正则改为 `(?m)(^[ \t]*|;[ \t]*)exit ([0-9]+)`（允许行首缩进）。
实测：修复前裸 `exit` 剩 3、修复后剩 0、赋值 4。**POSIX 侧同一处也加固了**——它目前靠
「探针恰好是单行」侥幸成立，而那正是两份拷贝分叉的典型形态；加固后两侧对
`    exit N` / `; exit N` / `;exit N` / `exit N` 四种形态输出**逐字相同**。
回归锁：`smoke/12` 新增用例，断言「改写后不得残留裸 `exit N`、4 个码必须都变成赋值、
且必须含 `agentq-exit:`」。**红/绿实测**：修复前（`c93c0093`）报「3 个裸 exit 残留」，修复后绿。

### A17. 脱敏不变量已静默失效：仓库里重新出现 7 个地址 —— **已修（2026-09-27，零授权，`assets/` 零改动）**

**这条不是新规则，是一条旧规则的回归。** 规则写在 `CLAUDE.md` 的操作边界里（「仓库与记忆里
一律不出现主机名或 IP」），`CHANGELOG` 也记着 2026-09-22 清过 9 处，验证方式写得很清楚：
「全仓（所有文件类型）与记忆目录用正则扫描，排除回环地址后**零命中**」。**问题在于那次扫描
是一次性的**——没有任何检查重跑它，所以它只在下一次有人主动扫描前成立。

**2026-09-27 实测**：仓库里重新出现 **7 个不同地址、共 46 行**（`PLAN.md` 26、`CHANGELOG.md` 20），
另有账号名、两把**他人公钥的注释串**（含真实姓名与两个机器名）、一个 `~/.ssh/config` 别名，
以及**由地址派生的私钥文件名**（同一形状出现 3 次）。全部改为角色化描述（「主机 A/B/C」
「原那台 macOS」）或占位符（`<user>@<host>`），**事实一条未删**——`15.7.7`/`15.7.9`、
`i5-10500`、`4,727/4,736 行`、`e3b132af`、`ARP incomplete` 等证据全部保留。

**修法：把那条一次性扫描变成一项检查**（`smoke/16-no-host-identifiers`，第 16 项）。
五条规则覆盖实际泄漏过的五种形状，扫全仓文本文件 + 记忆目录（2026-10-05 补 `R6`、2026-10-06 补 `R7`，现为七条——见本节末尾的跟进）。

**这里有个陷阱值得单列，因为我自己先踩了**：检查的输出里，匹配**必须打码**。第一版保留了
首尾各两个字符，于是那种「看似打码」的输出**恰好把主机位留在外面**——检测器的输出会被阅读、
粘贴、归档，原样（或半原样）打印等于把检测器变成新的泄漏通道。现在只留前两个字符加长度。

**第二个陷阱**：第一版把样本字面量直接写在源码里，于是**检查报告了它自己**——那条 printf 的
格式串里恰好含一个 mDNS 形状的子串。这不是误报，是检查**正确地**拒绝豁免自己的源文件；
修法是把字面量再拆开，**不是**给该文件开豁免（开豁免就是规则长洞）。**这条记录本身也踩了
同一个坑**：第一版把那个格式串原样引用在这里，于是 `PLAN.md` 被自己的检查报了出来——
描述一个陷阱的文字，本身会带上陷阱的形状。

**验证**：真实红/绿——把清洗前的 `PLAN.md` 放回去 → **27 处违规、五条规则全部触发**；
换回当前版本 → 0。**变异 11 个中 10 个被抓**，1 个 MISSED 如实记录：单独把自校准闸门改成
`if false` **没有任何可观测变化**（闸门本来就没触发过），所以那一个变异单看是良性的；它与
「某条规则被放宽」组合时会被 canary 抓住（实测 `R2`/`R5` 各自 + 关闸门 → `canary caught 4 of 5`）。
**不声称它是缺陷，也不声称它被覆盖。** 另有两个自查抓到的真问题：① `R5` 用了 `\b`，而 `\b`
在 `_` 与数字之间**不成立**，所以该规则**永远不匹配**却报绿——「规则写宽了等于没写」，已去掉
`\b` 并由自校准钉住；② `R1` 曾有一条**逐行预过滤**，用 `grep -vE ':[0-9]+:.*^(127\.|...)'` 想
跳过回环行——但 `.*` 之后的 `^` 是**字面量插入符**、不是锚点，所以它什么也没匹配、整个过滤器
是空操作。它无害（没有漏报），但注释在说谎，已删除而不是修好：逐行过滤在这里就是错的形状。

**顺带排除一次 `pwsh` 假故障**：`01` 的 7 个 `.ps1` 解析全部 `Abort trap: 6`。我先怀疑机器
负载（当时 load 22.8），**这个怀疑是错的**——用 `HOME` 二分定位到真因是
`~/.cache/powershell/StartupProfileData-NonInteractive` 损坏（二进制里存着一个零长度程序集名），
pwsh 每次启动都在 `AssemblyNameParser` 抛错。**该文件与 AgentQ 无关**，是 pwsh 自己的启动
缓存；已改名留存而非删除，pwsh 立即自愈并重建。**教训**：上一次同类故障我归因于负载，那次的
归因**可能是错的**（同样症状、同样 `AssemblyName` 栈），所以「负载高导致 pwsh 不稳」不应再被
当作已知事实引用。

**2026-10-06 跟进：规则又漏了一次，这次是 `R7`。** A27 收尾时全仓复查发现，2026-10-06 的 C3 写稿
把**测试机的计算机名**（大写、内嵌 8 位日期、尾字母——克隆虚拟机的自动生成名）写进了 `PLAN.md`
与 `CHANGELOG.md`，另有两个账户名（一个原账户、一个为跨用户验证新建的）、探针账户名、ESXi 的
VM 名；**其中原账户名早在 2026-09-29 就已进仓**（`C:\Users\<账户>\...` 路径里），这次被 C3
写稿一并复述。**`R1`–`R6` 结构上不可能看见它**——六条全都要求
点号、`@` 或地址形状，而计算机名是裸 token，正是本节开头那条「无点裸主机名实测不可关闭」边界
里的一个**可关闭子形状**。修法照 2026-09-27 先例：改字面量、不豁免文件，证据（`UserId=…`、
`MSFT_TaskLogonTrigger`、`UnauthorizedAccessException`）一条未删。新增 `R7`
（`[A-Z][A-Z0-9]*-20[0-9]{6}[A-Z][A-Z0-9]*`），两条边都由自校准样本钉住——**尾字母要求**单独就把带日期的发布标签
挡在外面（`RELEASE-20260926` 是负样本）；合成 task id（`AQAAA-00000000000001` 是负样本）要
**两条边都去掉**才会命中（实测，非推断）；**账号名刻意不建规则**（任意词，无形状可写，只能靠阅读
清理），如实记为边界。实测干净树 + 记忆目录**零误报**（三个候选宽度全部 0 命中，取最窄的）。
真实红/绿：把计算机名放回 `PLAN.md` → 1 处违规（打码输出）+ exit 1，还原 → 0。**变异 5/5 被抓**：
永不匹配 → 自校准 no-longer-fires；去掉尾字母 → 自校准 false-positive（发布标签）；再去掉日期锚
→ false-positive ×2（task id + 发布标签）；**永不匹配 + 关闸门 → canary 独立兜住（`6 of 7`）**；
**`R7` 漏出 `scan_file` 的 spec 列表 → canary 也兜住（`6 of 7`）**。**历史也已清干净**：这些名字原先在
git 历史里（`d9a0957` 引入计算机名与账户名，`63c6061` 基线提交里已有 2026-09-29 那个账户名），
经用户授权后用 `git filter-repo --replace-text` 从全部 22 个提交的 blob 中替换掉——逐提交扫描
零命中、旧对象不可达、工作树与改写前镜像备份逐字节相同（repack 也清掉了库里的不可达对象，
包括第四节 B1 提到的 2026-09-29 恢复用孤儿提交——它本就不可达、任何一次 `gc` 都会清掉；
改写前的镜像备份本身也已按用户要求于同日清理删除，故该孤儿对象现已无处可取）；**所有提交哈希因此改变**，本文件的
哈希引用已刷新（`0d29338`→`d9a0957`、`31d83f3`→`63c6061`、`d7220c5`→`0bb95d0`）。

### B4. 覆盖债的第一刀砍哪 —— **已完成（2026-09-22）**

`unix/install-agentq.sh`（**2,946 行**）和 `windows-git-bash/install-agentq.ps1`
（**3,072 行**）合计 **6,018 行**，占全仓 22.3%（**27,028 行、23 个资产**），是两个最大的
零覆盖资产（B4 当时；两者如今各有一份契约检查）。A1 处理前者。**这几个数字按当前字节重算**
（原先记 2,755+2,881、后记 2,876+2,922；资产随 A18/A27/W5 等增长后失真，2026-10-06 与
2026-10-07 两次更正，覆盖表里的 2,424/2,911/496 亦同）。

**`install-agentq.ps1` 已完成（B4，2026-09-22）：新增 `smoke/13-ps-installer-contract`。**
它需要的证据和 A1 不同：`.ps1` 的参数契约能在 `pwsh` 上测，但 PS 5.1 专有行为
只能在真机测，所以该检查的边界同样写死。

### A18. AgentQ 支持密码认证 —— **已实现（2026-09-28，零授权，纯客户端）**

**起因**：用户实测 `agentq doctor --host <目标>` 被拒
（`Permission denied (publickey,password,keyboard-interactive)`）。
根因是 `BatchMode=yes` **禁用全部交互式认证**，而 POSIX 客户端 4 处 ssh 调用
（`client/unix/agentq`）与 Windows 客户端 2 处（`client/windows/agentq.ps1`）
全部硬编码它。`sshp` 早就没有这个限制（两端 `grep -c BatchMode` 均为 0），
所以**只有 `agentq` 被挡住**。

**用户确认的边界**：两端一起做；人和 Agent 都要（以 Agent 为主）；
密码来源支持多种；守卫**严格——不满足就拒绝运行**。

#### 实测钉住的机制（本机 OpenSSH_10.3p1，非推测）

| 事实 | 证据 |
| --- | --- |
| `SSH_ASKPASS_REQUIRE=force` + `SSH_ASKPASS=<prog>` 让 ssh **无 tty 也**执行 askpass | 口令私钥连真 sshd：`askpass_calls=1`、rc=0 |
| `SSH_ASKPASS_REQUIRE` 是**环境变量**，不是 `-o` 选项 | `-o SSH_ASKPASS_REQUIRE=force` 报 `Bad configuration option` |
| `force` 不需要 `DISPLAY`；无 `force` 且无 `DISPLAY` 时 askpass **不被调用** | env 矩阵四组对照 |
| 每次连接 askpass 被调用**多次**（不同 prompt）→ provider 必须可重复 | `(user@host) Password:` 与 `user@host's password:` |
| **口令私钥与账户密码走同一条 `read_passphrase → ssh_askpass` 路径** | prompt 文本不同，机制同一。**这是 `smoke/17` 能成立的全部依据** |
| `BatchMode=yes` 时 askpass **完全不被调用** | 同一密钥：`Permission denied`、`askpass_calls=0` |
| askpass **不抢占 stdin** | 认证后 `cat` 仍收到完整 payload（submit 的通道安全） |
| **Windows 无控制台时 `readpassphrase` 会挂** | win32compat `misc.c` 用 `_getwch()` 读**控制台**，不读 stdin。所以 Windows **必须**提供 askpass，不能依赖 ssh 自己提示 |

#### ⚠️ 一条被真机推翻的机制声明（2026-09-29 实测，主机 A）

上表原先还有两行，现已**删除**，因为它们在真机上**不成立**：

| 原声明 | 实测结果 |
| --- | --- |
| 「Windows 上 askpass 必须是真可执行文件（`posix_spawnp`、无 shell）」 | **部分错**：取决于该机 `ssh` 是哪一个。Git Bash 的 MSYS ssh 用 `execlp`，同样无 shell 分词 |
| 「但 `SSH_ASKPASS` **可含参数**（`"cmd.exe" /c helper`）」 | **错**。实测 `ssh_askpass: exec(C:\Windows\System32\cmd.exe /c ...): No such file or directory` —— 整个字符串被当成**单个文件名** |

**实测形态矩阵**（主机 A，Windows 10 / Git Bash，客户端 PATH 上解析到的是
`C:\Program Files\Git\usr\bin\ssh.exe` = **OpenSSH_9.9p1 的 MSYS 版**，
不是 `C:\Windows\System32\OpenSSH\ssh.exe` 那个 8.1p1 原生版）：

| `SSH_ASKPASS` 取值 | askpass 是否被 exec |
| --- | --- |
| `/c/Users/.../ap.sh`（MSYS 路径） | **YES** |
| `C:/Users/.../ap.sh`（正斜杠） | **YES** |
| `C:\Users\...\ap.sh`（反斜杠） | **YES** |
| `cmd.exe /c script` | **no** |
| `"cmd.exe" /c script` | **no** |

**结论**：带参数的形态在这个 ssh 上**根本不可能工作**；而**一个带 shebang 的
shell 脚本可以直接作 askpass**（MSYS ssh 能 exec 它）。所以原先那条「必须用
`cmd.exe /c`」的指引把用户指向了一个**必然失败**的形态。

**代码本身没有这个错误**：`agentq.ps1` 只是把 `AGENTQ_ASKPASS` 原样赋给
`SSH_ASKPASS`（`$script:AskPassProgram = $program`），**没有**任何 `cmd.exe /c`
的构造——`grep -c 'cmd.exe'` 的 5 处命中全在**注释与 `--help` 文本**里。
所以这是**文档/注释缺陷，不是行为缺陷**：照文档写的用户会失败，照代码语义
（给一个可执行程序）写用户会成功。

**仍未验证（仅指 `System32` 8.1p1 这一格）**：该构建的 `ssh_askpass` 走 win32compat 的
`posix_spawnp`，与 MSYS 版不是同一实现，可能确实支持带参数形态。**但主机 A 的客户端
解析到的是 MSYS 版**，所以「`System32` 8.1p1 下能否用 `cmd.exe /c`」在这台机器上
**测不到**，不得声称。
（**2026-10-02 更新**：**原生 Windows ssh 整体已不再是未验证项**——专用测试机上验证的是
`C:\Program Files\OpenSSH\ssh.exe` 9.5p1，同样原生。唯一仍属边界的是这里说的
`System32` 8.1p1（早于 `SSH_ASKPASS_REQUIRE`，且不是客户端默认解析到的构建）。
见下方 A18 结论与 A20。）

#### 实现

`BatchMode` **条件化**而非删除：

```
无来源 → -o BatchMode=yes                （与改动前逐字节相同）
有来源 → -o BatchMode=no
         -o NumberOfPasswordPrompts=1
         SSH_ASKPASS / SSH_ASKPASS_REQUIRE=force（仅在真有程序时导出）
```

三种来源按序取第一个：`AGENTQ_ASKPASS`（**排第一**——AgentQ 只传程序名，
从不接触密码本身，所以它不是凭据存储）→ `AGENTQ_PASSWORD`（环境变量）→
`AGENTQ_PASSWORD_PROMPT=1`（人类交互，**不自动探测 tty**）。

#### 实现里三个真被踩到的坑

1. **凭据解析必须早于探针。** `initialize_remote_invocation` 在任何操作分发**之前**
   跑平台探针，而探针自己就是一处 ssh 调用。来源若只在操作路径生效，探针会先失败，
   命令根本走不到操作路径——**整个特性不可达**。
2. **`SSH_ASKPASS` 空串 ≠ 未设置。** OpenSSH 测的是 `getenv() != NULL`，空串会让它
   去 exec 空字符串。第一版无条件导出，prompt 路径就成了 `SSH_ASKPASS=""`
   + `REQUIRE=force`。现在只在真有程序时导出（实测）。
3. **清理只删自己建的临时文件。** 变量 `agentq_askpass_program` 一度同时表示
   「ssh 要跑的程序」和「要清理的临时」——对 `AGENTQ_ASKPASS` 来源，
   前者是**用户自己的文件**。实测该路径会去删用户的 askpass。
   已拆成 `agentq_askpass_program` / `agentq_askpass_temporary` 两个变量，
   并由 `smoke/17` 的变异钉死。

**Windows 侧刻意与 POSIX 不同**：只支持 `AGENTQ_ASKPASS`。
`AGENTQ_PASSWORD` / `AGENTQ_PASSWORD_PROMPT` **拒绝**——前者要 AgentQ 把密码写到
ssh 能读的地方，而该客户端**没有顶层 trap 可挂清理**，且 cmd.exe 读回会破坏含
元字符（`&`/`|`/`>`）的密码；后者在该平台**会挂死**（`_getwch()` 读控制台）。
两条都必须真机才能试，所以不给。

#### 测试与未验证范围

- `smoke/17-askpass-credential`（新）：真实 sshd + 真 pueue，**有来源时
  submit→wait 端到端**、**无来源时 askpass 一次都不被调用**，两个方向都断言。
  变异 3/3 被抓（含「清理越界删用户程序」）。
- `smoke/05`：新增记录 argv 与 askpass 环境的 ssh 桩，断言两端参数值。变异 6/6。
- `smoke/12`：Windows 侧选项构造 + 拼接是否真落到 argv + 三个黑盒拒绝。变异 4/4。

#### 真机验证（2026-09-29，用户点名的三台主机，地址不入库）

用户点名三台并授权端到端验证。**A18 原先标注为「尚未在任何真实主机上验证」的
两项，本轮都验证了**：

| 验证 | 结果 |
| --- | --- |
| **账户密码登录成功**（POSIX 客户端 → macOS 主机，该机**只有密码、密钥完全不通**） | `submit`→`lookup`→`wait`→`logs`→`remove` **全部通过**；`wait` 退 0 + `Done.result="Success"`；`logs` 回 `E2E-PASSWORD-OK\nDarwin`（证明任务真在该机执行） |
| **Windows 客户端密码认证**（Windows 客户端 → 同一台 macOS 主机） | 同样跑通完整协议：`wait` 的 `Done.result="Success"`、`logs` 回 `WIN-E2E-OK\nDarwin`、`remove` `removed:true` |
| POSIX 客户端 → Linux 主机 | 完整协议通过（`Done.result="Success"`、`output="LINUX-E2E-OK\nLinux"`） |
| Windows 客户端升级 | 走官方 `install-client.ps1 -SkipPathUpdate`，`agentq.ps1` `789b6ff7`(2,176 行) → 当时的 canonical `4c74047f`(2,316 行)，随后又随本轮的守卫修正升到 `bf6c6a77`(2,327 行)；`-Check` 由漂移转为匹配；ACL 复核 `AreAccessRulesProtected=True`、owner 保留 FullControl、其余 ReadAndExecute，**升级前实测存在的 `CodexSandboxUsers` Modify 已消除** |

**代价与注意事项（实测，不是推测）**：那台 Windows 主机 CPU 负载 **100%**，裸
`powershell.exe -NoProfile -NonInteractive -Command 'exit 0'` 实测 **33.9 秒**，
平台探针端到端 **40.2 秒**——**超过默认 30 秒预算**，于是报
`remote platform/protocol probe timed out`，看起来像凭据或客户端缺陷。设
`AGENTQ_PLATFORM_PROBE_TIMEOUT=300` 后同一命令 **rc=0 成功**。这与 `CLAUDE.md`
已记录的「先看目标机负载，再怀疑探针」是同一现象，本次是该结论的**又一次独立复现**。

#### 真机推翻的第二处：Windows 守卫接受了 ssh 永远无法执行的形态（**已修**）

上表删除的两行机制声明（见前）有一个**行为后果**，本轮真机测出并已修：

守卫原先**只校验 `AGENTQ_ASKPASS` 的第一个 token**（引号内或首个空格前），
因为当时相信 `"cmd.exe" /c helper.cmd` 是可行形态。但 ssh 执行的是**整个值**，
于是这两种形态**都能过守卫、却永远无法被 exec**：

| 形态 | 修前 | 修后 |
| --- | --- | --- |
| 裸路径 `C:\...\ap.sh` | rc=0 成功 | rc=0 成功 |
| `C:\...\ap.sh --flag` | **过守卫**，最终报 `class=timeout` | **rc=2 被守卫拒绝** |
| `"C:\...\ap.sh"` | **过守卫**，最终挂死 | **rc=2 被守卫拒绝** |

**危害是把配置错误说成连接超时**——与 A9/A16 反复纠正的那类误导同一类。
**修法经过一次纠错，两次都要记**：第一版把判据写成「整个值含空格**或**引号即拒绝」——
**那是错的**。ssh 不做分词，所以**含空格的路径完全合法**，实测
`C:\Users\<账户>\.aq sp\ap.sh` **rc=0 成功**（`C:\Program Files\...` 正是这种形态）；
第一版会把这类合法路径一并拒掉，**把合法配置说成非法**。正确判据是**文件系统**：
整个值作为路径存在且可执行即合法；不存在时**再**诊断形态并说明原因。
（这次纠错本身是本轮最有价值的产出之一：它说明「看起来更严格」的守卫不等于更正确。）

**对照证据**（本机 OpenSSH 10.3p1，独立于 Windows，四组）：裸路径 rc=0、**含空格路径 rc=0**、
带引号 rc=255、带参数 rc=255——即后两者**永远不会成功**，而前两者都合法。

**仍未验证，不得声称**：
**`System32\OpenSSH\ssh.exe`（8.1p1）那一格的 askpass 行为**——它是原生 ssh，但**早于
`SSH_ASKPASS_REQUIRE`**，实测「有无 `REQUIRE`」两列都阻塞。**但「原生 Windows ssh
未验证」这个更大的说法已在 2026-10-02 关闭**：专用测试机的客户端 PATH 解析到
`C:\Program Files\OpenSSH\ssh.exe`（`OpenSSH_for_Windows_9.5p1`，**原生**，非 MSYS），
经它跑通完整协议（见 A20）。所以现在**原生 ssh 已验**，只有 8.1p1 那个更旧的构建
是记录在案的边界，且**它不是客户端默认解析到的那个**。
**macOS 本机非 root 的用户级 sshd 仍验不了真实密码**（`getpwnam().pw_passwd`
是 `'********'`、无 `/etc/shadow`、`/usr/sbin/sshd` 无 setuid 位、`UsePAM yes`
明确要求 root）——**但这不再限制结论**：账户密码登录成功已在真机上由上述两台
主机独立验证。

**过程中记录在案的一处自造假绿**：`smoke/05` 的失败检查块原先在凭据断言**之前**，
于是那些 `failures` 计数全被累加却从不被检查——检查照常报绿。是变异测试
（把守卫改成恒假后仍绿）暴露的，已把该块移到断言之后。

---

### A19. `DefaultShell=cmd.exe` 的 Windows 目标根本连不上 —— **已修（2026-09-30 / 10-01，两台资产共三处）**

在 ESXi 上新部署一台 Windows 10 目标机做端到端验证时，**POSIX 客户端一条命令都发不出去**，
报 `unsupported or undetectable remote platform: unknown`。两个独立缺陷叠加，都不在
smoke 的可见范围内。

**缺陷一：`auto` 分支漏了 exit-token 剥离（`assets/client/unix/agentq`）。**
平台探针**成功**返回 `agentq-windowsagentq-exit:0`，但 `initialize_remote_invocation`
的 `auto` 分支拿这个**未剥离的整串**去比对 `agentq-windows`，于是永远不等。
带外状态令牌（A5b 加的）只有 `probe_native_windows_platform`（MINGW 分支）剥了，
`auto` 分支没剥——**同一个机制抄在两处、只修了一处**，与本仓 A9、规则 E 同一类。
修法是让 `auto` 分支调用同一个 `windows_probe_apply_exit_token`。

**为什么此前一直没暴露**：`auto` 分支是 `DefaultShell` 为 Windows 默认值 `cmd.exe`
时的必经之路，而 CLAUDE.md 记录的 Windows 验证都在 **Git Bash** 终端下做的
（`uname -s` 答 `MINGW64_*`，直接走 MINGW 分支，绕开了这条路径）。
`smoke/14` 只量命令行长度、`smoke/05` 用 MINGW 桩，两者都碰不到 `auto` 分支。

**缺陷二：安装器在 StrictMode 下把「组不存在」变成终止错误
（`assets/windows-git-bash/install-agentq.ps1`）。**
第 2796 行 `if ($null -ne $groups.agentq)` 的本意是「组已存在就设并行度、否则新建」，
但 `$groups` 是 `ConvertFrom-Json` 的对象，而文件第 8 行是
`Set-StrictMode -Version Latest`——**取不存在的属性会抛 `PropertyNotFoundException`**，
所以**首次安装（组尚不存在）必然失败**。实测消息逐字为
`在此对象上找不到属性"agentq"`，与 PS 5.1.19041.3996 上的独立复现一致。

**同一文件里已有正确写法**：`Get-PueueHealthFromTemporaryFile` 用
`$result.PSObject.Properties["groups"]` 逐级取值。本次把两处（另有一处同类站点在
launcher smoke 的 `$status.groups.agentq`）统一到该惯用法，**没有引入新风格**。

**证据形状**：三处修复都由**真实端到端**确认，不是推理——
`doctor` 返回 `{"tasks":{},"group":{"status":"Running","parallel_tasks":1}}`，
`submit` → `wait`（`"result":"Success"`）→ `logs`（`"output":"AGENTQ-E2E-OK"`，
正是提交的字符串）→ `remove`（`removed:true`）→ `wait`（`5`/`removed`）。
`smoke/13` 明确**不覆盖**安装器行为（只覆盖参数契约与平台闸门），所以这两个缺陷
此前没有任何检查能看见；修复后整套 `./run-tests.sh` 仍 **18 ran / 0 skipped / 0 failed**。

**缺陷三（2026-10-01 真机复核缺陷二时暴露，同一安装器）：回滚路径对首次安装必然误报
「rollback incomplete」。** `Restore-ScheduledTaskDefinition` 的签名是
`param([AllowNull()][string]$Definition)`，守卫写成 `if ($null -ne $Definition)`。
**PowerShell 的 `[string]` 参数把 `$null` 强制转成 `""`**，所以绑定 `$null` 之后
`$null -ne $Definition` 为**真**，于是走进 `Register-ScheduledTask -Xml ""`，
后者对空 Xml 抛 `无法对参数"Xml"执行参数验证`。首次安装时本就没有前一个计划任务
（`Get-ScheduledTaskDefinition` 返回 `$null`），所以**只要首次安装失败，回滚就崩**，
把一次干净的失败说成「rollback is incomplete」并留下 `recovery artifacts` 残留。

**判定与取证**：这不是推理，是 PS 5.1.19041.3996 上的直接实测——把 `$null` 绑到
`[AllowNull()][string]` 后读回 `isNull=False / isNullOrEmpty=True`，而模拟的
`$null -ne $Definition` 守卫**放行**了空串。修法是改用
`![string]::IsNullOrWhiteSpace($Definition)`——**这正是同文件里兄弟守卫
（`Remove-AgentQInstallerResponseTemporaryFile` 的 `$ExpectedIdentity`）一直在用的写法**，
本次把这一处对齐，没有引入新风格。

**两个方向都验过**：① 变异安装器（只还原缺陷二的 `$groups.agentq`，缺陷三的修复保留）
在干净机上失败时，**回滚干净**——stderr 只有缺陷二的原始 `PropertyNotFoundStrict`，
**不再有** `rollback is incomplete`、`Xml 为 Null`、`recovery artifacts` 残留；
② 未修复时（修复前实测）同样场景三条都在。

**已实测（2026-10-01/02）**：`DefaultShell=powershell.exe` 那一列**已有真机**——在专用
测试机上真造出该配置，端到端确认了 A5b 缺陷并修复（见 A5b）。**原生 Windows ssh
也已在同一台机上验证**（该机客户端 PATH 解析到 `C:\Program Files\OpenSSH\ssh.exe`
9.5p1，**原生**，非 MSYS；见 A20）。

---

### A20. Windows 客户端的探针被 `-Command -` 静默吞掉 —— **已修（2026-10-02，一台资产两处）**

**这是本会话最有价值的产出**，也是「`smoke` 抓不到行为回归」的又一实证。缺陷与
A5a/A5b 同类（Windows 远端终端兼容性），但**根因完全不同**，此前从未被识别。

**缺陷**：`powershell.exe -Command -` 把 **stdin 当交互式输入读**。一行若**开启一个块**
（`if {`、`function {`、`try {`），读取器进入**续行**状态，缓冲的语句**只有在遇到一个
空行时才执行**；**EOF 时未终止的缓冲区被静默丢弃**——rc=0、无输出、**什么也没执行**。
单行语句则读一行执行一行。

**为什么这恰好打中 Windows 客户端**：它的**协议探针**是一段**多行 here-string**
（`Get-WindowsAgentQProtocolProbeCommand`，4006 字节、含 `if`/`function`/`try` 块），
经 stdin 喂给 `-Command -`。于是**整个探针体被丢掉**，`Confirm-WindowsAgentQProtocol`
拿不到 `agentq-windows-launcher-ready`，对**任何** Windows 目标都报
`native Windows AgentQ service protocol probe failed`——**指向部署，而不是客户端**。
**平台探针是单行的**，所以从不受影响；**POSIX 客户端的两个探针也都是单行的**，
所以 POSIX 客户端连 Windows 目标**正常**——这正是缺陷能长期潜伏的原因：**只有
「Windows 客户端 → Windows 目标」这一条组合会走到多行探针**。

**四处独立复现**（不是推测）：Mac `pwsh` 7、Windows PS 5.1（经 `ProcessStartInfo`
按客户端的方式喂 stdin）、Git Bash 的 MSYS ssh、Mac 的 OpenSSH ssh。判据一致：
多行块 → 空输出 rc=0；**追加一个空行** → 正常输出 + `agentq-exit:0`。

**修法**：`Add-ProbeExitToken` 是全部探针脚本的唯一出口，在返回的脚本末尾追加
**一个空行**（`"`n`n"`），让 `-Command -` 在 EOF 前冲刷掉最后的缓冲块。一行修复，
两个探针都覆盖。

**验证**：
- **回归锁（行为级，非源码级）**：`smoke/12` 新增一例，构造**真实探针输入**、
  用**当前解释器自身**喂给 `-Command -`，断言输出里出现 `agentq-exit:<code>`
  （只断言「体执行了」，不断言具体码值——有部署是 0、没有是 42，两者都证明执行）。
  **源码级断言看不见这个缺陷**：问题在 PowerShell 如何消费文本，不在文本本身。
- **变异**：去掉那一个空行 → `smoke/12` 在 **pwsh 7 与真 PS 5.1 上都报红**
  （`the probe body did not run when fed to -Command - on stdin (out=[])`）。
- **端到端（真机，2026-10-02）**：Windows 客户端 → Windows 目标（同一台机，密码认证，
  **无密钥**）跑通完整协议：`submit` rc=0（`task_id=1`）→ `wait` rc=0
  （`"result":"Success"`）→ `logs` rc=0（`"output":"WINWIN-OK"`）→ `remove` rc=0
  （`"removed":true`）。修复前同一条命令报 `protocol probe failed`、rc=2。
  **这同时关闭了两个此前的「不得声称」**：Windows 客户端经**原生 Windows ssh**的行为
  （该机 `Get-Command ssh.exe` 解析到 `C:\Program Files\OpenSSH\ssh.exe`，
  `OpenSSH_for_Windows_9.5p1`——**不是** Git Bash 的 MSYS ssh），
  以及「Windows 客户端 → Windows 目标」这一组合。认证走的是 **askpass 密码路径**
  （实测 askpass 被调用 4 次且认证成功；若公钥可用则 askpass 根本不会被调用）。

**askpass 的 `SSH_ASKPASS_REQUIRE` 也已同机实测（2026-10-02）**：本机三种 ssh 各跑
「有无 `REQUIRE`」两列，判据是 askpass 是否被调用、调用是否返回——按客户端的
`ProcessStartInfo`（重定向流、无控制台）：

| ssh 实现 | 无 `REQUIRE` | `REQUIRE=force` |
| --- | --- | --- |
| `Program Files` 9.5p1（**PATH 默认，原生**） | **阻塞**、askpass 未调用 | rc=0、askpass 调用一次 |
| `System32` 8.1p1（原生，更老） | 阻塞 | **仍阻塞**（该构建早于该变量） |
| Git Bash MSYS 9.9p1 | rc=255 | rc=0、askpass 调用一次 |

所以客户端**必须**发 `SSH_ASKPASS_REQUIRE=force`（它此前只发 `SSH_ASKPASS`，头注释里
还写着「Windows ssh 没有 `SSH_ASKPASS_REQUIRE` 的对应物」——**该前提是错的**）。
Windows 上没有 `DISPLAY`，没有这个变量 ssh 永远不会去调 askpass，而是退回读**控制台**
的 `_getwch()`——无控制台时**永久阻塞**。已修（`New-SshProcessStartInfo` 与
`Invoke-SshLogged` 两条路径都发它，且无来源时显式清除继承来的值——Git Bash 会导出
`SSH_ASKPASS`）。**唯一不支持它的是 `System32` 的 8.1p1**，而那不是客户端默认解析到的
构建；8.1p1 那一格如实记为「本机测到的边界」，不是缺陷。

---

### A21. 两个 Windows 客户端把 unix 远端脚本作为 **ssh 的原生参数**发出 —— **已定位并修复（2026-10-02），回归锁 `smoke/20`，2026-10-08 真机直测**

**这是 A5a/`09` 同一机制（PS 5.1 原生参数词分割）的第三处落点，而 `09` 的扫描规则
看不见它。** 发现路径：给 `sshp`（POSIX）写 `smoke/19` 时顺手看 `sshp.ps1`，
发现它把一段 **2010 字节、含 32 个双引号的多行 shell 脚本**当 ssh 的参数传出去。

**调用形态**（`09` 只扫 `-c`/`-lc` 与 `Invoke-GitBashScript -Script`，都不匹配）：

| 资产 | 行 | 形态 |
| --- | --- | --- |
| `client/windows/sshp.ps1` | `& $script:SshPath @sshArguments` | `-RemoteCommand (Get-UnixProbeCommand)` / `(Get-UnixInstallCommand)` |
| `client/windows/agentq.ps1` | `& $script:SshPath @sshArguments` | `New-UnixRemoteInvocation` 拼出的 `agentq_run() {...}` |

**对照：`agentq.ps1` 的探针路径本来是对的。** 它走 `Invoke-SshLoggedWithTimeout` →
`New-SshProcessStartInfo` → `Convert-ToProcessArgument`（逐字符转义，`\"` 正确产出）。
把该函数的输出喂回同一条 CRT 模型：**argc=1、且逐字节往返一致**。所以问题不在
「PowerShell 传原生参数」本身，而在**用 `&` 调用运算符 splat 数组**——那是
`09` 已经实测钉过的、不转义内部双引号的路径。

**实测证据（模型 + 差分执行，不是推测）**：

1. 用 pwsh 真跑 `sshp.ps1 --check`（`SSHP_SSH` 指向记录 argv 的桩），取出它**实际发出**的
   那个 argv 元素：2010 字节，与源码里 `Get-UnixProbeCommand` 的 here-string **逐字节相同**
   ——证明这段脚本确实走命令行，不走 stdin/文件。
2. 把该字符串与 `agentq.ps1` 的 `New-UnixRemoteInvocation` 输出分别喂给**与 `smoke/09`
   同一份、同一组 5 行实测校准值**的 CRT 模型：argc 分别为 **17** 与 **1**（后者不含换行，
   仅引号被剥）。
3. **决定性差分**（在真实 bash 上跑「完好脚本」vs「模型受损脚本」）：
   - `sshp.ps1` 探针、目标缺 tmux 且只有 apt 时：**完好 exit 42 / stdout
     `__SSHP_INSTALL_REQUIRED__:Linux`；受损 exit 127 / stdout 变成
     `sshp:ntmuxnisnmissingn`**。客户端 `Get-ProbeOutcome` 对这组「退出码 + marker」
    都匹配不上 → 返回 `$null` → 报
     `remote dependency probe failed`（**指向部署，不指向客户端**）。
   - `agentq.ps1` 的 unix 操作：`"$@"` → `$@`、`"$agentq_server"` → `$agentq_server`，
     于是 `exec $agentq_server $@` **把参数再词分割一次**。实测把
     `submit --workdir '/tmp/my dir' -- echo a*b` 交给两版：完好 argv n=6 含
     `[/tmp/my dir]`，受损 n=7 裂成 `[/tmp/my]` `[dir]`。
   - **反例同样记录**：`sshp.ps1` 的 READY 与 MINGW 两条分支在这组输入下**仍然匹配**
     （marker 正则 `[^\r\n]+` 容忍了尾部那个 `n`，退出码也保住），所以这不是
     「凡受损必失败」——**损坏是真实的，后果依分支而定**。

**诚实边界（不要过度声称）**：以上是**模型 + 差分**，模型经 5 行真机实测校准；
**「这一具体调用形态（`& $exe @splat`）尚未在任何真 PS 5.1 上直接测量」这一条已于
2026-10-08 关闭**（见本节末「直接测量」）。`sshp.cmd`/`agentq.cmd` 都经
`powershell.exe`（= 5.1）调用，所以平台是可达的；pwsh 7.5 不复现该缺陷（这也是它能在
本机一路绿灯的原因）——真机实测与这两句一致。

**为什么 `09` 没抓住**：它的两条 grep 模式只认 `-c`/`-lc` 与
`Invoke-GitBashScript -Script`，而这里是 splat 数组；`sites` 因此根本没计入这两个文件。

**修法（已落地 2026-10-02）**：改用 `09` 自己列为**唯一许可通道**的 base64——两个资产
各新增一个小助手（`agentq.ps1` 内联同款、`sshp.ps1` 的 `Convert-ToPosixScriptCommand`），
把脚本编码成 `printf %s <b64> | base64 -d | sh`。base64 字母表无需引号，故命令行无论本地
PowerShell 对它做什么都能存活；`sh` 放在管道末位，所以脚本的退出状态就是 ssh 返回的状态
（与旧的裸脚本 + `agentq_run` 形式保持同一退出码语义）。**为什么不用 stdin**：`sshp.ps1`
的安装路径以 `-tt` 运行，stdin 要留给终端。

**一处刻意的例外：会话命令必须保持裸参数。** `Get-UnixSessionCommand`（`exec
tmux/screen/zellij`）**不**走 base64，因为该通道是 `printf %s <b64> | base64 -d | sh`，
`sh` 的 **stdin 是管道**，而多路复用器要求 stdin 是 tty——实测（pty 下跑两版）：
`stdin=tty` 时 screen 正常起，`stdin=pipe` 与 `< /dev/null` 一律
`Must be connected to a terminal.`。它能安全地裸着是因为**一个双引号都没有**（`"` 才是
PS 5.1 词分割的触发字节；会话名用单引号且值已被 `[A-Za-z0-9_.-]` 限定）。
**所以这条例外是有条件的，条件本身要被守住**，否则往那段脚本里加一个 `"` 就会静默复发
A21——`smoke/20` 为此有 4 例（必须仍裸、必须仍带 tmux 分发、必须仍是一个参数、字节必须不变），
两个方向都断言（只测一个方向，一个「一律 base64」的退化实现也能过）。
变异 3/3 被抓。

**回归锁（已落地）**：`smoke/20-ps-native-argv-roundtrip`（9 例）——**行为级**，在 pwsh 里
真跑两个客户端、用记录 argv 的桩捕获**实际发出**的那个 argv 元素，再套用 `09` 同一份
校准模型，断言过模型后**恰好一个参数且字节完全一致**；**并**解码 base64 断言通道里装的
确实是客户端本意的脚本（只断言「命令行完好」会让一个「完好但什么都不做」的命令通过）。
**变异 2/2 被抓**（两个资产各自退回裸脚本）。**为什么不是给 `09` 加第三条 grep**：先试过
静态规则，两次都没能触发（只读数组初始字面量、漏了 `+=` 追加；嵌套 heredoc 弄坏外层
`case`）——**一个静默不触发的检测器正是本套件的头号反模式**，故不修补第三次。

**直接测量（2026-10-08，专用测试机，PS 5.1.19041.3996）——原「尚未在任何真 PS 5.1 上
直接测量」已关闭。** 装置：真机上用系统自带 `csc.exe` 编译一个原生接收器（每次调用把
原始命令行与 NUL 分隔的 argv 落盘，可按 `reply.txt` 应答），把两个客户端的**修复前版本**
（`63c6061`）与**当前版本**分别指向它运行；本机（macOS）侧用记录 argv 的桩在 pwsh 下取
同一客户端的参照 argv，两侧逐字节对照。结果：

| 载荷 | pwsh 参照 | 真 PS 5.1 实测 |
| --- | --- | --- |
| `09`/`20` 的六行模型值（直测 splat） | —— | **argc 6/6 全对**；不含引号的行逐字节一致 |
| `sshp.ps1` 修复前 unix 探针（2010B、32 个 `"`） | 远程命令 1 个参数（总 argc 16） | **裂成 17 个参数（总 argc 32）**，碎片与模型 pieces **逐字节相同**，32 个引号全部被消费 |
| `agentq.ps1` 修复前 unix 操作（多行、6 个 `"`） | 1 个参数 | 1 个参数，**引号被全剥**（`"$HOME/…"`→`$HOME/…`、`"$@"`→`$@`——即「远端再分割」那条路径） |
| 当前 `sshp` 探针（base64 通道，2707B） | 1 个参数 | **逐字节一致** |
| 当前 `sshp` 会话命令（裸参数、333B、零引号） | 1 个参数 | **逐字节一致**（这条例外形态在真机上也成立） |
| 当前 `agentq` unix 操作（base64，171B） | 1 个参数 | **逐字节一致** |
| 当前 `sshp` windows 探针回退（23210B） | 1 个参数 | 1 个参数；**唯一差异是一个 `\r`**——载荷由 `Convert-ToEncodedPowerShellCommand` 前置 `[Environment]::NewLine`（Windows 上 `\r\n`、macOS 上 `\n`），是构造差异不是传输损坏 |
| 带引号的会话名 `quo'te` | 拒（exit 2、未调 ssh） | **rc=2、消息逐字一致、ssh 零调用** |
| 真 `ssh.exe` 接收端 | —— | `# a " b` → 主机名 `# a `（**含尾随空格**，即两个参数）、`"$PATH" --config "x"` → 单个 `$PATH --config x`（引号被消费） |

**两处模型精度记录（不改变任何一条判定）**：① 六行里三行（`echo "hi there"`、
`"$PATH" --config "x"`、`printf "%s" "$MSYSTEM"`）的真实交付物把**所有** `"` 字节消费光，
而模型把 `""` 当字面引号保留、piece 会多留一个悬空 `"`——**argc 完全一致**，而全部断言
只用 argc 与「无引号载荷的字节往返」，故判定不变；记为模型在字节级的一个保守近似。
② `ssh.exe` 报错里的主机名会**被 ssh 自身小写**（对照组 `NoSuchHostXyZ.Invalid` →
`nosuchhostxyz.invalid`），我曾误读成「PowerShell 改了大小写」。**结论**：A21 的机制、
修复前形态的后果、修复后形态的完好，均已**在真 PS 5.1 上直接测量**；`smoke/20` 仍在
pwsh 下跑同一模型（它证明的是资产当前字节的形状，不是 PS 5.1 的运行时行为）。

---

### A22. POSIX 安装器渲染 launchd plist 时**不检查占位符是否被替换** —— **已修（2026-10-03，零授权，一台资产一处）**

**同一机制抄在多处、只有一处设防**的又一例（A9 / A19 / `smoke/10` 规则 E 同类）。

**机制**：`install-agentq.sh` 的 macos 分支用三条 `sed` 把 `__AGENTQ_HOME__`、
`__AGENTQ_USER__`、`__AGENTQ_HOME_PARENT__` 替换进 `com.agentq.pueued.daemon.plist`，
然后 `plutil -lint` 就完事。**它的 Windows 姊妹渲染器两个方向都设了防**——
`Install-PueueConfiguration` 与 launcher 配置函数都在替换前查「模板缺占位符」（`IndexOf(...) -lt 0` → throw）、
替换后查「渲染结果仍含占位符」（`IndexOf(...) -ge 0` → throw）。POSIX 这一处**两个方向都没有**。

**为什么长期不可见**：`plutil -lint` 只验 XML 合法性，而 `__AGENTQ_HOME__/pueued` 是**完全合法的字符串**。
实测（修复前）：把 plist 里一个占位符改名成安装器不认识的名字 → `01`/`10`/`11` **全绿**；
把 `sed` 模式改成永不匹配（模拟漏替换）→ 同样全绿。后果是 launchd 去 exec 一个字面量
`__AGENTQ_HOME__/pueued`，**到服务加载才现形**。

**修法**：渲染后加运行时守卫——泛化扫 `__[A-Z][A-Z0-9_]*__`，命中即 `fail`。用泛化模式而非三个已知 token 的列表，
是为了让「模板新增了 token 但 `sed` 列表没跟上」这种漂移也被抓住（那正是本缺陷的形状）。
误报面已评估：替换进去的值必须**含一段字面 `__ALLCAPS__`** 才会命中，真出现时安装**大声失败**并打出消息，不会写出坏服务。

**回归锁（已落地）**：
- `smoke/10` 规则 I（**静态**）：三对 template↔renderer（plist↔POSIX 安装器、`pueue.yml`↔Windows 安装器、
  `agentq-launcher.ps1`↔Windows 安装器）的 token 集合必须互相知晓，且每个渲染器必须带那个运行时守卫标记。
  带**自检闸门**（任一侧 token 提取为空即拒绝给结论）与**配对数下限**（<3 即报「规则没在检查它声称的东西」）。
  **变异 6/6 被抓**（三对各自改模板 token、三处各自去掉守卫）。
- `smoke/11`（**行为级**）：把安装器里那段渲染代码按锚点抽出来、桩掉三个 helper 后真跑，
  断言未知占位符必须退 2 且消息正确、**真实模板必须渲染干净**（两个方向都断言）。
  **变异 2/2 被抓**（去掉守卫 → 抽取自检报 `guard block was not extracted`；守卫改成恒假 → `expected exit 2, got 0`）。

**刻意排除一个文件**：legacy `com.agentq.pueued.plist`（25 行）**不被渲染**——它只被
`require_file` 检查存在，是旧安装路径的遗留（`~/Library/LaunchAgents/` 那个位置现在只用于
停用并备份既有文件）。把它纳入同一 token 集会让正确代码报红，故规则注释里显式写明这条排除。
**这是一处可清理的死资产**（`require_file` 一个从不使用的文件），但删它会改变部署单元，
需要单独决定，不在本次范围。

### A23. `wait_reconcile_missing_task` 看似能复用 `load_request_records` —— **否掉，不改**（2026-10-03）

**（2026-10-06 注：本节原先给 `agentq-server` 的函数标了行号，A25/A26 的折叠让它们全部漂移；
按本仓对无类型 shell 的既有规矩（见 A12）已全部移除，锚点只留函数名。）**

**起因**：本轮补 `smoke/26`（`lookup`/`wait` 的记录读取路径）时注意到，
`wait_reconcile_missing_task`自己逐文件扫描 `*.json`，
每条记录经 `read_request_record_state_and_body` 调一次 jq，而同文件里早已有聚合加载器
`load_request_records`——正是 2026-09-30 那次优化（每 record jq 4.05 → 1.05）动过的。
按 A9/A19 的教训，同一机制抄在多处、只在一处设防，所以看上去是个明显的重复。

**但复用并非行为等价，所以不改。** 两个读取器的判据在 `removed` 这个状态上分岔：

| 读取器 | 判据 | 对 `removed` 记录 |
| --- | --- | --- |
| `wait` 逐条扫描 → `read_request_record_state_and_body` | `request_record_filter`**接受** `removed` | 接受，随后 `case` 只匹配 `accepted\|removing`，**跳过** |
| `load_request_records` → 聚合 | `request_records_filter`的 `valid_request` 只接受 `prepared\|adding\|accepted\|removing`——**排除** `removed` | 整批 `error("invalid AgentQ request record")` → `exit 2` |

即换成聚合加载器会把 crash-window 状态（本仓最在意的那个状态）从「跳过」变成**致命 exit 2**。
这正是 `CLAUDE.md` 记的「两处规则不等价，删任何一个都改变行为，而这是安全路径，**不要为提速顺手改**」
的又一实例。**故保持现状**，并把这个判据差写进 `smoke/26` 的注释，让下一个人不必重推一遍。

**顺带坐实的一处既有重复（非缺陷，仅记录）**：`lookup` 的 `state==removed` 分支
自己调 `archive_removed_request`，而 `acquire_operation_lock` 会先跑
`ensure_request_record_layout → migrate_removed_request_records → repair_removed_request_records`
，后者**自己就归档 `removed` 记录**——所以 lookup 那次调用当前**冗余**。
实测：树里放一条 `removed` 记录 + 墓碑，跑 `lookup` 记录数 1→0、墓碑 0→1；把 lookup 的
`archive_removed_request` 调用去掉（变异 M2），输出与 counts **完全不变**。
两处归档**语义一致**（都调同一个 `archive_removed_request`），所以不构成正确性缺陷，
只是同一机制两处存在。**不在本次删除**——删它需要真机验证崩溃窗口的恢复，而收益是零子进程。

**一个必须记的可达性边界（否则会写成假绿）**：`wait_reconcile_missing_task` 的
逐条扫描**只看得到 `accepted` 记录**。`removed` 记录已被锁布局的 repair pass 归档
（每条命令的必经之路），`removing` 记录已被 `ensure_daemon → recover_removing_requests`
归档（`wait` 在扫描前先调 `ensure_daemon`）——两者都**早于**那次扫描。实测：`wait` 一个
`removing` 记录自己的 task id，基线与「从 case 里删掉 removing 匹配」的变异体输出**逐字相同**。
所以 `smoke/26` **不声称覆盖** wait 扫描的 `removed`/`removing` 分支，也不声称能挡住那个重构。

### A24. `submit`/`cancel`/`remove` 的记录读取路径覆盖 —— **已补（2026-10-04，零授权，`skill/assets/` 零改动）**

`smoke/26` 覆盖了 `lookup`/`wait`，其「不覆盖」列留下 `submit`/`cancel`/`remove`。
本轮补上（`smoke/27-record-write-paths.sh`，34 例，同一合成运行时骨架；2026-10-06 起为 41 例）。至此
**每条依赖读取请求记录的命令都有针对性检查**：`status`（`18`）、`lookup`/`wait`（`26`）、
`submit`/`cancel`/`remove`（`27`）。

**实测得到、且改变了第一版用例的两条**（不是猜测，是踩出来的）：
① `normalize_workdir` 把 `/tmp` 解析成 `/private/tmp`（实测），所以「匹配 payload」的
合成记录必须写**解析后**的路径；第一版 5 个 submit 用例里 4 个因此落到 payload-mismatch
分支、完全没测到目标。
② 若 pueue 桩在 `pueue add` **之前**就报告 task 可见，`submit` 走**恢复**路径
（`reused:true`）而非 add 路径；S5 因此改用**有状态桩**（`add` 后才可见）。

**可达性边界（与 `26` 同源，实测）**：`submit` 的 `state=removing` 分支**不可达**——
`ensure_daemon → recover_removing_requests` 在 submit 自己的分派读记录**之前**就把
该记录归档；`cancel` 的 **queued** 分支（`pueue remove` + `queued_removed`）需真实
排队任务，由 `smoke/03` 端到端覆盖。两者都写进了 `27` 的「不覆盖」列，不声称覆盖。

---

### A25. 折叠 `repair_removed_request_records` 的逐条 jq —— **已完成（2026-10-04，零授权，`skill/assets/` 两处同步改）**

**为什么现在能改**：`status`（`18`）、`lookup`/`wait`（`26`）、`submit`/`cancel`/`remove`
（`27`）都已把记录读取路径的行为钉住，这是本仓「先钉行为、再动热点」的前提。

**热点**：`repair_removed_request_records` 对**每个** `*.json` 调一次
`read_request_record_state_and_body`（内部一次 jq），而它**只需要找出
`state == removed` 的记录**。它**每条命令都跑**（`acquire_operation_lock` →
`ensure_request_record_layout` → `migrate_removed_request_records` → `repair`）。
这是继 2026-09-30 折叠 `load_request_records` 之后**最后一处**逐条 jq。

**改法**：新增 `request_removed_records_filter`（一次聚合 jq，逐条套用
`request_record_filter`——**它接受 `removed`**，与 `load_request_records` 的
`request_records_filter` 不同，见 A23），快路径一次拿到全部 removed 记录；**任何
失败（守卫、长度不符、畸形、正文读不到）都回退到原来的逐文件循环**。回退是**保真的
唯一手段**：聚合 jq 丢掉 per-file 的 `:1` 行号与路径归属，无法逐字节复现 jq 的
parse error，而 `smoke/18` 逐字节 diff stderr。另把守卫序列抽成
`request_record_path_guards_or_fail`，使逐文件读取器与快路径不会漂移（规则 E）。

**子进程计数（shim 实测，`status`）**：N=0 5/42→5/42；N=40 63/152→24/113；
N=80 119/260→40/181。**每 record 恰好省 1 次 jq、1 个子进程，N=0 零成本**。

**这次踩到一个 bash 语义陷阱，是本轮最重要的记录**：`output=$(…) 2>/dev/null`
**不抑制**命令替换里命令的 stderr——重定向绑在**赋值**上，不在替换上。第一版就是
这么写的，快路径的聚合 jq 把 parse error 漏到 stderr，**每条坏记录打印两遍**。

**而我最初以为「已验证」的其实是假绿**：我以 `AGENTQ_SMOKE_SERVER=<folded> ./smoke/18`
跑，全绿——但默认运行里 base 与 variant 是**同一份资产**，`compare_case` 只 diff
两侧，**确定性的重复行两侧相同、它看不见**。真正抓住它的是**把 base 换成 pre-fold
版本**做对照（那一刻报 6 处 `stderr differs`）。修法是给快路径整个子 shell 加花括号
`{ …; } 2>/dev/null`。**教训**：`AGENTQ_SMOKE_SERVER=<改后的同一份资产>` 与默认运行
等价，证明不了任何东西；变体模式的意义在于 base 与 variant **不同**。

**回归锁**：`smoke/18` 新增第 27 例 `assert_jq_diagnostics`（每条坏记录的 jq 诊断
**恰好 1 条**），在**默认运行**下就能红——实测把漏 stderr 的形态放回资产：6 处
`expected 1 jq diagnostic line(s), got 2`。

**变异（结构层，全部被抓）**：去掉 removed-only `select` → 5 处红；去掉快路径的归档
循环 → `crashwin` 不自愈；去掉逐条 `valid($ids[$i])` 绑定判据 → 12 处红，且**直接
probe 证明**它承重（一条「文件名与 request_id 不符、state=removed」的记录会被错误
归档，tombstone 1→2）。**1 个无效变异如实记录**：我第一版把绑定判据改成
`[ range(0; length) ]`，那**丢掉了记录本身**（输出整数而非记录）、行为上是 no-op——
改成保留记录、只去掉 `valid()` 才是有意义的变异（MC2）。

**边界**：全部证据来自 macOS 合成运行时，不证明真实 Pueue/远端/Windows；回退路径的
正确性依赖「快路径失败 ⟺ 回退能逐字复现」这一等价，由 `smoke/18` 的逐字节 diff 守住，
但**没有**对「快路径失败而回退也失败」这种双重失败单独构造用例（实测中未出现）。

---

### A26. 折叠 `wait` 恢复与 cancel 重放路径的逐条 jq —— **已完成（2026-10-04，零授权，`skill/assets/` 两处同步改）**

A25 折叠的是**每条命令都跑**的 `repair`。折叠后我用 jq-shim 把**全部命令**在
N=272（生产规模）上重新计数，发现还有三处**同类**热点——它们不在 `status` 热路径上，
但都在**阻塞式**调用（`wait`）或**取消重放**（`cancel`）上，每次仍对每个文件各起一个 jq：

| 路径 | 函数 | 折叠前 jq（N=272 rec + 58 tomb） |
| --- | --- | ---: |
| `wait`（任务已从 Pueue 消失） | `wait_reconcile_missing_task` 记录扫描 | 272 |
| 同上 | 同函数 墓碑扫描 | 174（3 jq × 58） |
| `cancel` 重放 | `task_instance_created_at_is_recorded` | 330（272 + 58） |

**改法**：三处都照 A25 的**快路径 + 保真回退**模式。新增三个聚合过滤器——
`request_records_states_filter`（每条记录输出 id/state/task_id/正文四行）、
`request_tombstones_states_filter`（每个墓碑输出 id/task_id/created_at 三行）、
`request_instance_probe_filter`（一个布尔：是否存在某文件记录该 task id 与该
created_at）。前两者复用 `request_record_filter` / 新抽出的 `request_tombstone_filter`
（把原内联过滤器提到变量，规则 E），并各自配一个守卫 helper
（`request_record_path_guards_or_fail` 复用、`request_tombstone_path_guards_or_fail` 新增）。

**第三处的语义**与另两处**不同**，是它必须单独设计的原因：
`task_instance_created_at_is_recorded` 的原循环**吞掉**畸形文件
（`2>/dev/null || continue`）继续扫描，**不是 fail-closed**；且它**不做**逐文件路径守卫。
所以它的聚合过滤器**必须容忍**：一个畸形文件让整次 slurp 失败 → 回退到逐文件循环
（那里 `|| continue` 复现 skip 行为）。**不能用 fail-closed 的记录过滤器套在这里**——
那会把「跳过畸形文件」变成「拒绝整个重放」，改变语义。另外原循环**先扫完记录再扫墓碑**
（记录命中即 `return 0`，从不读墓碑），所以快路径把两个列表**分开**扫，不在一次 jq 里合并。

**子进程计数（jq-shim 实测，N=272 + 58 tomb）**：

| 命令 | 折叠前 | 折叠后 |
| --- | ---: | ---: |
| `wait`（任务消失） | 892 | 9 |
| `cancel` 重放（无匹配，最坏） | 339 | 10 |
| `status` | 251 | 8 |
| `doctor` | 251 | 8 |
| `lookup` / `logs` / `remove` / `wait`（普通） | — | 各 1 |

**至此 N=272 上全部命令的 jq 调用都是 O(1)**（不再随记录数增长）。

**验证**：三处各自与 pre-fold HEAD 做**逐字节**对照（stderr + stdout + 退出码），
覆盖命中记录/命中墓碑/无匹配/畸形文件回退/文件名与 id 不符/多墓碑取首个匹配等
场景，全部 IDENTICAL。变异：`MR1`（记录快路径丢掉正文行 → 4 行读取器错位）、
`MR2`（墓碑快路径丢掉 created_at 行）、`MR3`（记录快路径永不匹配）三者被
`smoke/26` 抓住（7/3/7 处红）；`M3a`（探测恒真 → 陈旧 marker 被误判为重放）、
`M3b`（探测恒假 → 真重放被拒）被 `smoke/03` 与自建 harness 抓住。

**边界**：全部证据来自 macOS 合成运行时，不证明真实 Pueue/远端/Windows；三处的回退
路径同样依赖「快路径失败 ⟺ 回退逐字复现」这一等价，由逐字节对照守住。

---

### A27. POSIX 安装器的 17 处临时路径由 `$$` 派生 + 检查与写入非原子 —— **已修（2026-10-06，零授权，一台资产 17 处）**

2026-10-05 的六维度审查留下这一条，当时的结论是「**形状为真但非提权**——非 root
写入都落在用户自己的 `~/.agentq`，唯一的 root 上下文写入落在 root 拥有的
`/Library/LaunchDaemons`，非 root 无法在其中种 symlink；**未改**，建议改用
`mktemp`/O_EXCL 原子创建」。那个判断本身没错，但它把**形状为真**当成可以搁置的理由，
于是留到今天。本轮做完。

**范围先核清楚：17 处，不是我当时说的 6 处。** `grep '\.\$\$'` 的结果是 17 个
「路径值里插值 `$$`」的赋值点（其中两处在注释里）。按「谁创建它」分三类：

| 类 | 处数 | 站点 | 改法 |
| --- | ---: | --- | --- |
| 写入目标（`curl --output` / `cp` / `sed >` / 重定向） | 11 | `download_and_verify`、`stage_verified_binary`（两分支各一）、`assert_existing_queue_has_no_active_tasks`（两处，含 gzip 分支）、`prepare_service_stage`（linux/macos 各一）、`verify_health_status`、`ensure_agentq_group`、`replace_service_file`、`replace_wrapper` | **`mktemp`**：原子创建（O_EXCL）+ 后缀不可预测 |
| 重命名目标 | 3 | `service_backup`、`wrapper_backup`、`macos_legacy_plist_backup` | **`mktemp -u`**：只取名 |
| 目录名 | 3 | `stage_home`、`backup_home`、`failed_home` | **`mktemp -u`**：只取名 |

第二、三类为什么用 `-u` 而不是创建形态：它们的创建者是随后的 `mv`（重命名）或
`mkdir`（建目录），而**这两个操作在末段组件上本就是原子的**——`mkdir` 对已存在的
目录失败、`mv` 不跟随末段的符号链接（**实测**：`mv file symlink-to-dir` 会把文件搬进
那个目录，所以这里恰恰需要不可预测的名字）。它们缺的从来不是原子创建，只是一个
猜不到的名字。11 处写入目标才需要真正的 O_EXCL。

**顺带发现：11 处写入目标里有 4 处原本连 `require_installer_absent_path` 都没有**——
`prepare_service_stage` 的两个平台分支、`verify_health_status`、`ensure_agentq_group`
是直接 `cp`/`sed >`/重定向就写。所以它们不但名字可预测，检查-写入的窗口也比其余 7 处
更宽：连「查一下不存在」这一步都没有。

**两个必须显式处理的点**：

1. **目录链守卫不能丢。** 原来的 `require_installer_absent_path` → `installer_path_is_safe`
   会**走遍路径每一个组件**拒绝符号链接；`mktemp` **只守末段组件**。直接换掉会把这条
   属性**静默**丢掉。所以守卫搬进了两个助手（`installer_directory_is_safe`）。这条是
   本次改动里最容易犯而最难发现的错——测试全绿、属性没了。
2. **助手不能用 `fail`。** 它们在 `$( )` 里被调用，`fail` 的 `exit 2` 只终止子 shell，
   调用方拿到空串（本仓记过四次的 `$( )` 陷阱）。故助手 `return 1`，由调用方的
   `|| fail` 报错。

**root 上下文**：macOS 的服务目标目录是 root 拥有的 `/Library/LaunchDaemons`，`mktemp`
在那里必须经 `run_as_root`。但**不能按 `platform_kind` 判断**——同一平台上包装器目录
（`~/.local/bin`）是用户自己的。故新增 `installer_directory_needs_elevation`，**按目录
本身**判断（`[ -w ]`），服务两处用它、包装器两处不用。**BSD 实测**：`mktemp -u` 仍会
打开模板（建后即删），所以它和创建形态一样需要目录写权限——这正是 root 目录在 `-u`
形态下也要提权的原因（这是实测出来的，不是推断）。

**一个我自己引入又修掉的泄漏**：`binary_temporary` 起初被改成**在函数开头提前创建**，
而下载回落分支从不碰它、却把变量清空——会在 staging 树里留下一个没人负责的空文件。
改为**在各自的写入分支内按需创建**。同一个名字在同一函数里出现两次（预置源分支、
既有二进制分支）不是重复代码，两条路径互斥。

**回归锁（`smoke/11`，17 → 20 例）刻意是三层**，因为可达性差别很大：

- **① 行为级，只看得到一处**：`mkdir` 桩记录真实 staging 路径**连同调用它的 shell 的
  `$PPID`**（即安装器的 `$$`——`exec` 与 `$( )` 都保留 `$$`，实测），断言名字**不由 pid
  派生**：后缀等于 pid 就红，短于 6 字符也红（后者堵住「pid 恰好不等于本次 pid」的退化）。
- **② 源码规则，覆盖其余 16 处**：赋值语句同时满足「值里插值 `$$`」**且**「变量名是
  安装器创建的路径」。两半都必需：只看 `$$` 会误报维护锁的 `lock_current_identity`（那里
  `$$` 是**正确的**锁持有者身份）；只看名字会误报只转发路径的 `discard_*` 助手。
- **③ 助手行为级**：把两个助手**连真实的守卫**（`installer_path_is_safe` 与
  `installer_directory_is_safe`）从资产**按锚点抽出**真跑——手写替身可能接受资产拒绝的
  输入。断言：创建形态调用后**文件确实存在**（`mktemp -u` 不会）、两次调用名字不同、
  名字形态**不创建文件**、**两种形态都拒绝符号链接目录**（mktemp 本身不管这个）。

**变异 5/5 被抓，且各自的定位互不相同**：M1 staging 名退回 `$$` → ① 与 ② 各报一次；
M2 创建形态退回 `mktemp -u` → **只有 ③ 报**（`got 4 / not created`，定位精确到那一条）；
M3 把 fixture 到不了的 `health_temporary` 退回 `$$` → **只有 ② 报**（它正是为这类站点
存在的）；M4/M5 各删掉一个助手的目录链守卫 → `got 8` / `got 9`（符号链接目录被接受）。
**一个反向用例**：加一个「值是 `$$` 但与路径无关」的变量 → ② 保持绿，证明它不是
「见到 `$$` 就报」的启发式。

**边界（如实记）**：11 处写入目标里只有 staging 根在离线 fixture 里可达，其余需成功
下载、既有安装或回滚。**② 只证明「名字不再由 `$$` 派生」，不证明原子性**——原子性由
③ 对助手本身证明。真实安装的 **Linux 侧（无 sudo）已于 2026-10-07 在容器内补验**（见「C2 补格」）；macOS 侧与含 sudo 的路径仍未跑过。

---

### A28. 七维度全场景审查（2026-10-06，用户指示「使用 agents 全维度全场景审查」）—— **已执行，4 个真实缺陷 + 1 个 P0 级 fail-open 已修**

做法沿用 C5 先例：7 个互不知情的只读审查者各包一个维度——服务端、POSIX 客户端、
Windows/PowerShell 资产、四个安装器、测试套件、文档一致性、凭据与安全；另派一个
补漏审查者专查「长期未被执行的检查」（`03` 余项、`04`、`06`、`08`、`09`、`13`、
`19`–`25`）。**每一条高影响结论都由我本人对代码或实测复核后才动手**——照单采信
agent 结论会凭空造出不存在的 P0，本轮确实有 5 条被复核推翻（见下）。

#### 已修（每条都有变异证明能红的回归锁）

1. **探针的退出码改写是 fail-open（两个客户端，最高影响）**。A5 的改写把探针体里的
   `exit N` 替换成**赋值** `$agentqProbeExit = N`，而赋值不终止执行：探针体是顺序
   `if`（不是 if/else 链），「缺 launcher」的失败分支一路穿透到末尾**无条件**写出的
   `...-ready`，token 被最后一个赋值覆盖——客户端把「没装」报成「probe failed」，
   42/43 两个诊断分支不可达。两侧都已改为失败点
   `[Console]::Out.Write("agentq-exit:N"); exit N`。`smoke/12` 新增两条**行为级**用例，
   驱动**资产自己的**探针体与改写（回退任一侧即红）。
2. **同族的四条通道纪律**：token 限 **1–3 位数字**（超长 token 让 POSIX 侧 `return`
   失败、在条件上下文里被读成成功——fail-open）；**远端探针输出过滤成单 token 再进
   消息**（首行 + `[A-Za-z0-9_.-]` + 截断——原样回显时远端可用
   `FreeBSD\n\033[2Jagentq: remote failure reason: ...` 伪造出与客户端自身逐字同形的
   诊断行）；**捕获文件读取 BOM 感知**（PS 5.1 的 `2>` 与 `1>` 同机制产出带 BOM 的
   UTF-16LE；UTF-8-only 读取器在真 5.1 上丢 token——两个 PS 客户端的
   `Get-FileTextOrEmpty` 已改，`smoke/12` 用 UTF-16LE+BOM 夹具钉住）。**真机已验
   （2026-10-08，主机 A，PS 5.1.19041.3996）**：`2>` 与 `1>` 同机制产出带 BOM 的
   UTF-16LE——实测 `cmd /c 'echo one' 1> f` 12 字节 head=`FF FE 6F 00`、
   `cmd /c 'echo two 1>&2' 2> f` 450 字节 head=`FF FE 63 00`、CJK 版 474 字节
   head=`FF FE 63 00`。所以 BOM 感知读取是**必需**的，不是「两种结果都成立」的
   降级说明。
3. **服务端 C1：`submit --workdir` 的校验没被接住（fail-open）**。`normalize_workdir`
   用 `fail` 报错而被 `$( )` 调用（`exit 2` 只终止子 shell），且 `with_operation_lock`
   用 `if "$@"` 调命令体（条件上下文里 `set -e` 全程失效）——无效 `--workdir` 打出
   拒绝消息后**照常继续**，以 `"workdir":""` 落盘并把空 `--working-directory` 交给
   `pueue add`。调用点已改为 `... || return $?`。`smoke/27` S6 钉住（变异：删守卫 →
   `expected exit 2, got 4` 并打印出落盘的坏记录）。
4. **rc=4 被六处调用点折叠成 exit 2**：多任务共用同一 AgentQ 标签时
   `find_request_task` 返回 4（必须停止），六处把它折叠成「cannot inspect Pueue」退 2
   （可重试语义）。已改为 4/`ambiguous`；`smoke/26` W6 钉住（3381/3440 两处本就正确
   传播，刻意不动）。
5. **pending marker 退 2 而非 4**：任务已从 Pueue 消失、cancellation marker 为
   `pending` 时曾退 2 `unknown AgentQ task id`——id 是已知的，未知的是取消是否生效。
   现为 4/`cancellation_pending`；`smoke/27` C4 钉住。
6. **损坏的 cancellation marker 在成功调用上打 `reason=protocol_error`**：探索性读取
   改为静默回退；fail-closed 的消费者 `remove_cancellation_marker_for_task` 保持响亮。
7. **维护锁的陈旧恢复补上再确认**（先判死、再读一次、再判死，才删除——毫秒窗口内
   可能删掉并发进程刚建好的活锁）。安装器自 2026-09-24 就有这一守卫，服务端一直缺。
8. **POSIX 安装器三处**：下载失败报 `curl exit code N` + URL（原先只有一句「failed to
   download」）；锁创建失败与锁竞争用不同消息；`required_command` 补 `dirname head id
   rmdir wc`；渲染前先做模板占位符预检（缺 token 立即拒绝，而非渲染出半成品）。
   `smoke/11` 20 → 22 例（失败 curl 桩 + 缺占位符第三方向）。
9. **`install-agentq.ps1` 四处 `finally` 可能替换在途异常**（与规则 J/K 同病）——改为
   同文件的 `$operationError`/`$cleanupError` 合并写法。`smoke/10` 新增规则 **K2**
   （按括号深度扫描两个安装器的每个 `finally`；变异还原一处 → 被抓）。
10. **服务端临时文件清理的 glob 漏三种后缀**（`.agentq-group`/`.agentq-reconcile-status`/
    `.agentq-log`）——陈旧临时文件永不回收；补上解析分支。
11. **测试套件自身的六处缺陷**（都是「绿灯但没测到东西」类）：`16` 加「树扫描到 0 个
    文件即 FAIL」（空目录曾报 `files=17 violations=0` 退 0——17 全来自记忆目录）；
    `03` 比较时间戳前先断言 `cancellation_requested_at` 存在（两侧同缺时 `null == null`
    曾恒真通过）；`06`/`23` 常量读取加 `|| true`（常量改名时 `pipefail` 在设计好的
    回退之前中止、零输出退 1）；`07` 失败任务的 `wait` 从「非 0」收紧为 **`-eq 1`**
    （沙箱实测 `{"Failed":7}` → exit 1）；`08` 的 walker 补 `--args/--jsonargs` 建模
    （其后的位置参数是字符串不是文件，服务端 `request_payload` 正是这种形态，旧
    walker 会对真实提交误报）；`17` 删掉从未被调用、参数还会翻倍的死 `run_client`。
12. **`smoke/05` 的四个 Windows 桩改为按 stdin 判别探针**（此前平台/协议两个探针
    在桩里不可区分）；`env`/`cred` 计数改为运行时统计（摘要 `env=15 cred=4`）。
13. **`.gitignore`**：askpass 模式收窄 + 补 `*.env`/`*.ppk`/`.git-credentials`/
    `.netrc`/`authorized_keys`/`known_hosts`。
14. **文档**：`SKILL.md` 的「已消费」措辞修正（tombstone 可重复读）；`CLAUDE.md` 覆盖
    表 12 行更新 + 新增两段持久规则（探针 token 纪律；服务端 `$( )` 校验纪律）；
    `PLAN.md`/`HANDOFF.md` 行数与前文修正。

#### 复核后推翻（agent 结论，本人实测否定，未改代码）

- `mktemp -d` 的 0700 权限是**定义行为**，不是缺陷；
- `.gitignore` 对 `id_ecdsa` 的覆盖是**完整的**（agent 漏看了模式）；
- zsh nomatch 假设被该 agent **自己**的实验推翻；
- 安全维度的 I2 与「sshp `--check` 会安装」两条经复核不成立。

#### 记录在案、未修（如实边界）—— **2026-10-07 更新：本清单的可做项已全部处置，见下「A28 收尾」**

- 安装器 **W4**（已修，见上）：**已修（2026-10-07）**。两份客户端安装器都改成「先把全部文件暂存、
  再统一提交」：POSIX 侧两阶段（stage 循环 → 两次相邻 `mv`，暂存路径登记进 EXIT trap、
  按「先提交后清变量」的顺序避免失败时漏清），Windows 侧把 `Install-AtomicFile` 换成
  `Install-CommitSet`（一个 `finally` 管住全部暂存文件，沿用规则 K 的错误合并写法）。
  两侧各有行为级回归锁：`smoke/21` 的 W1 用例（把 `sshp` 资产置为 111——**过 `-f`/`-x`
  预检、只在 `cp` 失败**，正是旧顺序的窗口）断言 `agentq` **未被**更新、无残留；
  `smoke/25` 把 `Install-CommitSet` 连同两个临时文件助手与 reparse 守卫经 AST 抽出、
  在 pwsh 上真跑（平台闸门使它在本机不可达，函数本身是纯 .NET），断言第二个文件暂存
  失败时两个目标都原封不动、且失败原因**就是**那条暂存错误（一个不相关的 throw 也会
  让目标不变，所以必须钉住原因）。**变异 2/2 被抓**（两侧各自退回逐件「暂存+替换」）。
  **仍未覆盖**：提交阶段**中途**崩溃（两次 `[File]`/`mv` 之间）——无事务文件系统上做不到
  原子，残留由 `--check` 检出（一侧漂移）、重跑自愈；这是边界，不是缺陷。
#### A28 收尾（2026-10-07，用户「全都要处理」授权后逐条处置）

上一版「记录在案、未修」清单里的可做项已全部处理：

- **安全 W1（文档限定）与 W2（边界）——已修**：`SKILL.md` 给「0700 Unix socket」那句
  加上平台限定（Windows 是 TCP+TLS + `Set-PrivateTreeAcl` 私有树 ACL，Pueue 在非 Unix
  分支不设 `shared_secret`/`certs/` 的文件模式、新建默认 0644——纵深防御靠父目录 ACL，
  不靠模式，已记录为边界）；并补一句「三个客户端都不设 `StrictHostKeyChecking`，
  OpenSSH 默认与用户配置生效，不覆盖不放宽」。
- **`sshp --check` 重连循环——已修**：交互路径保持无界（人看着、可 Ctrl-C），`--check`
  是非交互只读探针加 **3 次重试预算**（`SSHP_RECONNECT_DELAY` 语义不变），超限退 255
  并报点名 `--check does not retry forever`；`smoke/19` 新用例（每调用一次传输行，桩
  重复最后一行所以单行 `255` 即可）19 例，变异（预算关掉）→ `made 7 ssh call(s)` 被抓。
- **POSIX Info 项——已修**：`HOME` 未设从 `set -u` 裸崩（exit 1，`HOME: unbound variable`）
  改为显式拒绝（exit 2 + 点名消息，`smoke/05` 用例，`env=16`，变异被抓）。askpass+prompt 拒绝、
  `run_ssh_logged` 的 stderr 捕获清理两条**先前已修**，复查确认。
- **`-E` 日志模式——查证后撤回（当天加、当天撤）**：先按「客户端 `mktemp` 在 ambient umask
  022 下出 0644」加了三处 `chmod 600`，随即实测**推翻该前提**——`mktemp`（BSD 与 GNU
  `gmktemp`）在 umask 000/022/077 下一律建 **0600**（`mkstemp(3)`），`ssh -E <新路径>` 自己
  新建时即使 umask 000 也是 0600。且操作/恢复两条路径上 `run_ssh_logged` 先
  `agentq_ssh_log_remove_file` 再调 ssh（实测 ssh 被调时该文件不存在），那两处 chmod 是
  对将被 unlink 的实例操作；平台探针那处文件虽在、但本就是 0600。**唯一真实缺口**是 ssh
  复用已存在的宽模式文件（实测 644 保持 644），而客户端每次先删、故本仓不可达，记为边界。
  三行已撤，`agentq` 3,691→**3,688** 行；文档（本文件与 `CLAUDE.md`）改为与实测一致。
- **Windows Info 5（start-daemon `exit 2` 死代码）——已修**：`Write-Error` 在
  `$ErrorActionPreference = "Stop"` 下抛异常、进程退 1、`exit 2` 永不执行；三处改
  `[Console]::Error` + `exit 2`；`smoke/22` 新增两例用真实子 pwsh 驱动真函数（缺文件
  → 恰好 2 + 消息；正常路径 → 0），变异（还原 `Write-Error`）→ `expected 2, got 1` 被抓。
- **Windows Info 6（`sshp.ps1` 自毁转义）——已修**：会话命令里把 `'` 变 `'""'` 的转义
  会**插入双引号**——恰是 A21 词分割的触发字节；已删除，改为「含引号直接 throw」的
  fail-closed（charset 守卫仍是第一道），`smoke/20` 新用例断言带引号会话名**不调 ssh**
  即拒（8→9 例，变异「守卫放行 + 恢复注入转义」→ 2 failure 被抓）。
- **服务端 I2——查实，定为边界不改**：`wait_reconcile_missing_task` 快路径与逐文件
  回退对 **numeric** `task_created_at` 判据不同（快路径要求字符串）；服务端自己写记录时
  **总是字符串**，只有手工改写记录才可达，且不匹配时拒绝更保守。改它要为手改数据
  放宽判据，不值得。记录在此，不再列为待办。
- **Windows `$PID` 命名（安装器 I1）——保留为边界**：`.stage.$PID` 等事务名由真实进程
  id 派生（锁的身份校验本身就用它），PID 回收跨时间存在、跨用户不共享；POSIX 侧
  （A27）已改 `mktemp`，Windows 侧改动需真机验证事务路径，且当前形状不是可演示的
  缺陷。不改，理由如上。
- **安装器 W5（换根中途崩溃后重跑静默成空部署）——已修（2026-10-07）**：
  新增 `Find-AgentQCrashLeftovers` + `Assert-NoCrashLeftoverTransactions`（两个纯 .NET 函数），
  在 preflight **之前**扫描根目录旁 `.AgentQ.{stage,backup,failed}.<token>` 残留并**拒绝**，
  消息按方向给出恢复指引（root 缺失 → 把 backup 移回；root 尚在 → 检查是崩溃还是并发）。
  **两个方向都拒绝**是刻意的：成功路径退出前必删自己的 backup，所以残留从不正常，而
  「换根完成但清理时崩溃」与「中途中止」只有操作者能分辨。**不做任何自动删除/合并/恢复**。
  维护锁刻意不参与——`Acquire-MaintenanceLock` 只在**活着**的持有者存在时拒绝，崩溃的 run
  什么都没持有。**扫描失败 fail-closed**（返回 `scan-failed` 条目并拒绝），否则不可读的
  目录会像缺失的 root 一样绕过守卫。**回归锁是行为级的**（`smoke/13`，cases 6→7）：平台闸门
  使整个文件在本机不可跑，但这两个函数是纯 .NET，按 `22`/`23`/`25` 的 AST 抽取手法**抽出真跑**
  七种目录树（干净无 root / 干净有 root / 缺 root+backup / 缺 root+stage / 有 root+backup /
  相似名不误报 / 父目录不可列）。**变异 6/6 被抓**，其中**两个是我第一版检查的假绿**并已修：
  M4（扫描 fail-open）与 M6（两个方向互换）当时**通过**——因为 fixture 的父目录总是存在、
  且只断言了 `refusing to install:` 前缀；现在按**方向**断言消息片段、并加「父目录不可列」一例。
  **换根本身两侧均已补验（POSIX 侧 2026-10-07 容器内真实 systemd；Windows 侧 2026-10-08
  真机，见本条目末）**：
  在 `jrei/systemd-ubuntu:24.04` 特权容器里以普通用户 `aqtest` 经 `su -`（真实 logind 会话）
  走完全部三格——① 真实安装 exit 0；② 用坏 `pueue.yml`（daemon 起不来）做**失败升级**：
  安装器退 2、自动回滚后 server 字节/配置/服务/任务/record 全部复原、零残留；③ **手工制造
  真崩溃现场**（`mv $HOME/.agentq $HOME/..agentq.backup.CrashSim`）后重跑：安装器按新守卫
  拒绝（exit 2、什么都没改），**照消息指引恢复**（移回 backup + 重启 daemon）后重跑 exit 0、
  任务与 record 保留、零残留。③ 还实测出**指引本身缺一步**并已修：崩溃的 run 已把 daemon
  停掉，「把 backup 移回去」不够——照做会在下一道检查被 `existing AgentQ daemon is
  unavailable` 拒（两侧同病，Windows 的 `Assert-ManagedPueueConnection` 同样要求活 daemon）；
  两条消息都补了「and restart the AgentQ daemon (the crashed run stopped it)」，
  `smoke/11`（+1 例）与 `smoke/13`（driver +1 断言）各自钉住，变异（删掉该句）被抓。
  **同类的相邻实例一并修**：那条 `existing AgentQ daemon is unavailable; refuse to overwrite`
  自身原先也**只拒绝、不说怎么办**——而 W5 的恢复路径正把操作者引到这里（移回 backup 但
  忘了重启 daemon）。两侧消息都补「start it and re-run (the installer must confirm the queue
  is idle before replacing a deployment), or restore the deployment manually」；`smoke/11` 再加
  1 例（Linux 平台桩 + 永远失败的 client 桩，直达该分支），变异（删掉动作）被抓。
  **Windows 侧换根本身已于 2026-10-08 在专用测试机实测（真机）**：先把该机从
  `a0b54bcb`/4,513 行升到当前 `9721403c`/5,332 行（`INSTALLER_EXIT=0`、
  `updated_atomically:true`、任务与 7 个 tombstone 保留、零残留），再忠实模拟崩溃
  （停 daemon + `Move-Item C:\ProgramData\AgentQ → C:\ProgramData\.AgentQ.backup.W5Sim`）：
  重跑安装器按守卫**拒绝**——消息逐字含「Move it back to C:\ProgramData\AgentQ and
  restart the AgentQ daemon (the crashed run stopped it) … Nothing was modified.」，
  退出码实测 **1**（PowerShell 抛错的失败契约是**非零**+消息，与 POSIX 侧退 2 不同；
  `smoke/13` 断言的正是非零）——**state 逐项未变**（root 仍缺失、backup 内 server 仍是
  `9721403c`、无新残留）；按消息恢复（移回 + 起 daemon）后重跑 `INSTALLER_EXIT=0`、
  不误触守卫；反向（root 尚在 + 残留）同样拒绝且 **daemon pid 未变**（守卫在 preflight
  之前，连 daemon 都没碰）；清理后经 **launcher 路径**（受支持的客户端入口）端到端
  `submit→wait(退 0, Success)→logs→remove` 全通。**一处我自己的假红如实记录**：先用
  `<Git>\usr\bin\bash.exe` 直跑服务端做 e2e，submit 稳定死在 `failed to prune expired
  AgentQ request tombstones`——该入口不调整 PATH，`find` 解析到 Windows `find.exe`；
  受支持的 launcher 用安装器解析出的 `<Git>\bin\bash.exe`，实测同一环境里
  `find`/`date`/`rm` 全部解析到 `/usr/bin/*`（GNU），换过去同一实验全通。**是驱动方式的
  产物，不是产品缺陷**——与「桩必须照抄真实行为」同类。
  **POSIX 侧同一窗口也已修（2026-10-07，验证 Windows 侧时实测发现）**：`install-agentq.sh`
  的 `mv agentq_home→backup_home` 与 `mv stage_home→agentq_home` 之间是同一个窗口，
  且**此前只被一个不相关的检查偶然挡住**——`previous_install` 因 `[ -e "$agentq_home" ]`
  为假而保持 false，随后 wrapper 检查以 `refuse to overwrite an existing wrapper` 拒绝，
  **消息指向 wrapper 而非残留的 backup**；操作者照字面删掉 wrapper 再重跑就落进静默空部署
  （实测：wrapper 缺失时安装器继续走到 staging，残留原封不动）。新增
  `assert_no_crash_leftover_transactions`（与 Windows 侧对称：两方向都拒、不删不并不恢复、
  扫描 fail-closed），调用点在 `installer_directory_is_safe "$agentq_parent"` 之后、取锁与
  staging **之前**。**残留名是双点前缀 `..agentq.{stage,backup,failed}.*`**（`agentq_base`
  本身是 `.agentq`）——`smoke/11` 25 例（23→25），变异 5/5 被抓；其中 **M4（扫描 fail-open）
  第一版没抓到**（fixture 父目录恒可列），补「父目录 chmod 000」一例后被抓；**M5 我第一版写成了
  坏变异**（glob 用单点 `.agentq.stage.*`、匹配不到真实的双点名，等于什么都没测），改正后
  抓到「守卫删除了残留」。
- 本机 `~/.local/bin/agentq` 与 `sshp` **已于 2026-10-07 重装**（用户「所有权限」授权）：
  逐字节等于 canonical、`--check` 退 0、mode 700、HOME 守卫生效。
- **真机实验——三项已全部执行（2026-10-08，用户点名机器）**：① PS 5.1 的 `2>` 实测与
  `1>` 同机制产出 UTF-16LE+BOM（见 A28 段；BOM 感知读取是必需而非降级说明）；
  ② **Windows** 侧 W5 换根崩溃恢复端到端已在专用测试机实测——两个方向都按消息拒绝且
  **什么都没改**、恢复后重跑 exit 0、经 launcher 的端到端全通（见 W5 条目末）；
  ③ B5 三台已重装到当前版本（见 B5-执行）；
④ `& $exe @splat` 在真 PS 5.1 上的直接测量（见 A21「直接测量」：六行 argc 6/6、
修复前形态按模型预测裂开、修复后载荷逐字节完好）。

### A29. 公开仓库标准化（2026-10-08，用户指示「项目体系标准化处理」）—— **①②④已完成；③ CI 已写，未经 Actions 实跑**

**决策（用户在本会话选定）**：面向 = 四个子项全做**参考主流开源项目**；发布目标 =
**公开仓库**；许可证 = **代码自研、自定 → 选定 MIT**；路线 = **「薄壳加装」**（保留本仓
五份内部工作文档的职责与结构，只加对外层）。**明确不做**：拆分或重写 `CLAUDE.md`、
`PLAN.md`、`HANDOFF.md`、`CHANGELOG.md`——它们服务的是本仓的 agent 工作流，重组收益低、
风险高（跨文档职责边界与计数已被反复踩过）。**语言**：对外层（`README`/`CONTRIBUTING`/
`LICENSE`）英文，内部工作文档保持中文。

**② 版本与发布（已完成）**：`agentq_version='0.1.0'` 与 `$agentqVersion = "0.1.0"` 从
Pueue 的 `release_version='4.0.4'` 拆出（该值此前被两处安装器当成 AgentQ 版本打印）；
`smoke/01` 新增**三方一致性**规则（两个安装器 + `README.md`，另加「成功行必须插值
AgentQ 版本」——回退成 `release_version` 时三处定义仍然一致，值相等抓不到那个形态）。
**bump 规则**：部署单元字节变即 bump（文档变更不 bump）。**发布物** = git tag + Release
notes 指向 `CHANGELOG.md` 条目，无二进制产物。

**①④ 文档与流程收口 / 对外协作面（已完成）**：`LICENSE`（MIT；版权人按 git 身份写
`MisonL`，用户可改）、`CONTRIBUTING.md`（三步循环、沙箱跑法、七条承重规则、文档权威边界
表、版本纪律、PR 要求）、`README.md` 的 License/Contributing/Documentation 三处、`CHANGELOG.md`
顶部「怎么读」段、`.github/` 的 PR 模板 + 两枚 issue 模板 + `SECURITY.md`（私下报告渠道，
不引导公开 issue）。

**③ 质量门禁自动化（已写，未实跑）**：`.github/workflows/ci.yml` 三个 job——ubuntu 用
`sandbox.sh up` 把需要真实运行时的 6 个检查也跑起来（`run-tests.sh` **SKIP 时退 0**，所以
每个 job 断言摘要形状而不是只信退出码）；macOS 跑 `--quick`（唯一有 `plutil -lint` 的平台）；
windows-latest 用 `AGENTQ_SMOKE_PWSH=powershell.exe` 跑 PS 5.1 客户端契约（pwsh 7 不复现本仓
踩过的两个 5.1 缺陷）。另有 `.github/workflows/release.yml`：`v*` tag 的版本值必须等于
安装器里记录的值。**本仓尚无 git remote，两个 workflow 都从未被 Actions 执行过**——这是
已知边界，不是「已验证」。

**未定/后续**：`CHANGELOG.md` 条目是否显式带版本号（当前由 `smoke/01` 三方一致性 + tag
门禁间接覆盖）；把 CI 首次实跑的结果回填到本条。

### A30. `doctor` 报告 AgentQ 自身版本 —— **待做（用户 2026-10-08 已同意，单列一次改动）**

现在运行期无法知道部署的是哪个 AgentQ 版本：`doctor` 的 `pueue=`/`pueued=` 是**队列实现**
的版本（B2 的刻意选择）。做法：服务端加 `agentq_version` 常量（**A 类里唯一触碰
`skill/assets/agentq-server` 的条目**，canonical 两处同步改、`cmp` 必须为 0），`doctor` 在
stderr 多报一行 `agentq=`；`smoke/03` 的 doctor 断言相应加一条；`SKILL.md` 的 doctor 段与
`CLAUDE.md` 的 doctor/版本段落同步。**范围检查**：客户端只透传 doctor 的 stderr（不解析
`pueue=` 行），所以两份客户端不动；`smoke/01` 的三方一致性规则随之扩为**四方**（加服务端
常量）。

---

## 五、C 类：需要你给范围

这些我无法自己划定边界，需要你明确主机、用户、工作目录、恢复方式和副作用授权。
**在拿到之前它们不是待办，是待定。**

| # | 事项 | 需要你给什么 |
| --- | --- | --- |
| C1 | P1-3 整体操作矩阵（**改为三台**、**真实网络中断**；2026-09-22 用户裁定） | **已执行（2026-09-22）**，结果与两个新缺陷见 `CHANGELOG.md`。三台里只有一台跑当前版本。**两项遗留均已消解（2026-09-24）**：① 主机 A 的客户端路径——重装后 `status`/`submit`/`wait`/`logs`/`remove` 五项 exit 0（见 B5-执行）；② 缺陷二已修并验证（见 A6，`smoke/03` 有用例、M3 证明其敏感）。**C1 无遗留** |
| C2 | 平台/安装矩阵（WSL、arm64、RHEL、Fedora、Alpine、真实升级回滚） | **已执行容器可覆盖的部分（2026-09-24，用户全权授权）**，见下；**真实升级回滚 2026-10-07 已补验**（见「C2 补格」） |
| C3 | 原生 Windows 其余边界（NTFS reparse 点语义、registry/profile、跨用户安装/服务身份） | **已执行（2026-10-01 与 2026-10-06，专用测试机）**，三项全部关闭，见下。**用户已声明无生产权限**，故不在生产机上做 |
| C4 | 真实服务/生产边界（远端服务生命周期、TLS/shared key、生产凭证、发布回滚） | **不是「不做」，是「用户无权授权」**：生产环境属上游，用户是 fork 贡献者，只在私有 CF 上部署测试。此项**不得**记为待办，也不得声称已验证 |
| C5 | P2-18 外部审查 | **已执行（2026-09-24，用户指示「按正规工程审查做、使用 agents」）**，见下 |

#### C2 执行结果（2026-09-24）—— 容器可覆盖的部分

用 docker 在本机做了 5 格，全部是**真实执行**，不是常量核对：

| 格 | 做法 | 结果 |
| --- | --- | --- |
| **真实 Linux 安装（Ubuntu 24.04 + systemd PID 1 + 真实 logind）** | 特权容器、以普通用户 `aqtest` 身份、`AGENTQ_PUEUE_SOURCE_DIR` 预置真实二进制（仍走内置 SHA-256 校验，两个哈希逐一相符） | `INSTALLER_EXIT=0`；私有树 700/600；unit `enabled`+`active`；linger `yes`；socket 就位；**零残留**。**本仓首次跑通 Linux 成功路径** |
| **真实 Linux 协议端到端** | 同一运行时上跑完整命令面 | `wait` 成功=0/`Success`；**`wait` 失败任务=1/`{"Failed":7}`（未被报成成功）**；`logs` 有真实输出；`remove`→`wait`=**5**/`removed`；`lookup` 连查 3 次都是 **5**（独立印证「tombstone 非消费制」）；`cancel` 已结束任务=**2**+`reason=task_not_running` |
| **真实升级路径** | 同版本重装，走 `previous_install` 分支 | 服务端 inode 变化（真替换）、daemon 重启、**record 数保留、旧任务仍可读（`reused:true`）**、服务 active、零残留、权限正确 |
| **真实 arm64 安装 + 协议** | 自建 arm64 systemd 镜像（`--platform linux/arm64`，模拟层） | 平台判定选中 `pueue-aarch64-unknown-linux-musl`；安装出的二进制是 aarch64；`wait`=0/`Success`；零残留 |
| **失败模式** | Alpine（musl/apk，无 systemd）、Fedora（dnf） | 两者都在**任何写入之前**干净拒绝、**零副作用**。Alpine 先在依赖闸门拒（缺 perl 且无 sudo），补齐依赖后精确停在 `required command is missing: systemctl` |
| **真实 Fedora 安装 + 协议端到端（2026-09-30 补做）** | `jrei/systemd-fedora`（Fedora 44、systemd PID 1），以普通用户 `aqtest` 身份、`su -` 建真实 logind 会话、`AGENTQ_PUEUE_SOURCE_DIR=/stage` 预置真实二进制（仍走内置 SHA-256 校验） | **`INSTALLER_EXIT=0`**，`AgentQ 4.0.4 installed`；私有树 700/600；unit `enabled`+`active`（`Main PID pueued --config .../pueue.yml`）；linger `yes`；**零残留**；两个二进制哈希与内置常量**逐一相符**；**部署的服务端与仓库当前版本逐字节相同**（`sha256=a0b54bcbee455cee…`），所以这一格验的是**含 2026-09-30 优化的当前代码**，不是旧副本。协议面：`status`=0；`submit→wait`=`Success`、`logs` 回 `FED-OK` + `Linux`；**失败任务 `wait`=1 且 result 为 `Failed:7`（未被报成成功）**；`remove`→`wait`=**5**/`removed`；`lookup` 连查 3 次都是 **5**；`cancel` 已结束但仍在 Pueue 的任务=**2**+`reason=task_not_running`；`cancel` queued 返回 `cancel_requested`，**重放 `reused:true`**；`status` 能读到 `cancellation_requested_at`；`doctor`=0 且 stderr 报 `pueue=4.0.4`/`pueued=4.0.4`/`systemd_user_service=active` |

**aarch64 与 x86_64 四个二进制哈希全部与安装器内置常量相符**（逐一实测）。

**两格明确不可达，记录以免被当成「已覆盖」**：
- **WSL 无法在容器里伪造**：安装器读 `/proc/version`，而 runc **拒绝**在 `/proc` 内 bind-mount
  （`check proc-safety of /proc/version mount`）。造一个假 fixture 就是本仓反复警告的
  「桩测自己」，所以不做。
- ~~**Fedora 的 dnf 依赖安装路径未走通**~~ —— **2026-09-30 已补做并关闭**（见上表最后一格）。
  当时的归因（「两次并发 dnf 抢锁」）**只说对了一半**，重做时才看清全貌：真正的原因是
  **容器缺两样东西，与安装器无关**——① 最小 Fedora 镜像没有 `procps-ng`，而安装器
  要求 `ps`（它**正确**地报 `required command is missing: ps`）；② `loginctl
  enable-linger` 需要 polkit，镜像里没有，于是报 `Could not enable linger:
  Access denied`。另有一条环境事实：`docker exec` **从不建立 logind 会话**，
  `loginctl show-user` 因此恒报 `User ID 1000 is not logged in or lingering`
  （**这个 rc=1 是真实信号**，安装器据此 `fail` 是对的），必须经 `su -` 才有会话。
  **三轮失败各自报出准确原因、每轮都在写入前停住、回滚干净**——这本身就是安装器
  失败契约的一次真机复核。补齐这两样后**一次通过**。

#### C2 补格（2026-10-07，用户「继续处理完」）—— 真实升级回滚 + W5 换根崩溃端到端

此前记为「WSL 本机也无法伪造」的**真实升级回滚**在容器里是可达的，本次补做。载体：
`jrei/systemd-ubuntu:24.04`、特权容器 + `--cgroupns=host`、真实 systemd PID 1；普通用户
`aqtest` 经 `su -` 建真实 logind 会话；`AGENTQ_PUEUE_SOURCE_DIR` 预置真实 Linux 二进制
（哈希与安装器内置常量逐一相符）。**全部是真实执行**：

| 格 | 做法 | 结果 |
| --- | --- | --- |
| **真实安装（基线）** | `install-agentq.sh` exit 0；留一条任务（`preupgrade0000001`）作待保留数据 | 队列 `Running`、service `active`、record=1 |
| **失败升级 → 自动回滚** | 构造 v2：`pueue.yml` 把 `pueue_directory` 指向一个 daemon 建不出来的路径，其余资产同仓库 | 安装器 `daemon did not become ready` → `installation failed; restoring the previous AgentQ deployment`，**退 2**；回滚后 server **字节回到升级前**（sha 逐字相同）、配置回旧值、service `active`、**任务与 record 全保留**、HOME 与 `/tmp` **零残留**、wrapper 完好 |
| **回滚后立即重跑** | 干净回滚之后直接再跑一次安装 | exit 0——证明回滚不留残留、**不会误触 W5 守卫** |
| **W5 崩溃现场端到端** | 手工 `mv $HOME/.agentq $HOME/..agentq.backup.CrashSim`（崩溃的真实状态：daemon 已停、root 缺失、backup 在） | 重跑**按新守卫拒绝**（exit 2、消息点名 backup 与恢复动作、什么都没改）；**照消息指引**（移回 backup + `systemctl --user start`）后重跑 **exit 0**、任务与 record 保留、零残留 |
| **指引本身实测纠错** | 第一版指引只说「把 backup 移回去」 | 照做后重跑被 `existing AgentQ daemon is unavailable; refuse to overwrite` 拒——崩溃的 run 已停掉 daemon，指引缺一步。两侧消息均已补「and restart the AgentQ daemon (the crashed run stopped it)」，`smoke/11`/`smoke/13` 各钉一句，变异被抓 |

**Windows 侧的换根崩溃已于 2026-10-08 在专用测试机补验**（两方向拒绝 + 恢复 + 经
launcher 端到端，见 W5 条目末；Windows 侧**升级回滚**仍未单独构造）；**仍未覆盖**：
WSL 仍不可伪造（安装器读 `/proc/version`，runc 拒绝在 `/proc` 内 bind-mount）。

#### C3 执行结果（2026-10-01）—— 专用 Windows 测试机上可做的部分

在那台新部署的 Windows 10 测试目标机（`DefaultShell=cmd.exe`，见 A19）上做了
**两项此前只有源码断言、没有执行证据**的验证。两者都是**真实执行**，不是常量核对：

| 项 | 做法 | 结果 |
| --- | --- | --- |
| **NTFS reparse 点语义**（此前记「未测 reparse 点本身」） | 从**已发布资产** `client/windows/agentq.ps1` 经 PowerShell AST **逐字抽出** `Test-NonReparseWindowsFilePath` 的函数体（不是副本，是发行版里的那份），在真机上造 fixture：普通目录／普通文件／**目录 junction**（`mklink /J`）／junction 下的文件／**文件符号链接**（`New-Item -ItemType SymbolicLink`），跑 8 个用例 | **8/8 符合预期**：普通文件 True；普通目录、junction 本身、junction **之下**的文件、文件符号链接、缺失文件、空串、普通目录里的缺失文件全部 False。fixture 自证属性：junction `container=True reparse=True`、文件符号链接 `container=False reparse=True`。**变异 3/3 被抓**（M2 最初 MISSED——是**用例缺口**：没有「非目录叶子重解析点」这一形态，补上文件符号链接用例后被抓） |
| **客户端安装器真机行为**（`client/windows/install-client.ps1`，此前只有 `10` 的两条源码不变量） | 在真机上真正运行安装器 | 安装 **exit 0**；`-Check` 双向断言；**ACL 已核实**（`CodexSandboxUsers` 不再出现、`AuthenticatedUsers : ReadAndExecute`）——即 `chmod`→ACL 那处修复在真机上确实生效 |

**C3 余项已于 2026-10-06 关闭**，见下面「C3 执行结果（2026-10-06）」一节——
两项都做了**真实执行**，且第一项暴露出本文档原先记的**前提是错的**。

#### C3 执行结果（2026-10-06）—— 余下两项（registry/profile、跨用户服务身份）

同一台专用 Windows 测试机（Windows 10 22H2 19045.3996；**地址按项目规则不入库**）。
SSH 走 **2222** 端口
（`DefaultShell` 未设置 = `cmd.exe`），登录账户为本地管理员。**方法照 2026-10-01 那次**：
函数体从**发行版资产** `skill/assets/windows-git-bash/install-agentq.ps1` 经 PowerShell AST
**逐字抽取**后在真机上执行，不是副本、不是常量核对。

| 项 | 做法 | 结果 |
| --- | --- | --- |
| **registry/profile** | 抽取 `Resolve-GitBashPaths` 真机执行；再对 `HKLM\SOFTWARE\GitForWindows` 的 `InstallPath` 做**两个方向的变异** | **该机注册表键存在**（`InstallPath = C:\Program`），走的是**注册表分支**。基线解析 `C:\Program\bin\bash.exe`；变异一（`InstallPath`→`C:\Git`）解析**随之变成** `C:\Git\bin\bash.exe`（证明该值真被读）；变异二（整键移走）**回落到 PATH 分支**、结果仍是 `C:\Program\bin\bash.exe`。两次变异均已还原 |
| **跨用户安装/服务身份** | 建第二个**非管理员**账户，以它 SSH 登录并执行发行版的 `Get-CurrentWindowsUserEnvironment`；另做环境变量污染测试与私有树隔离探测 | 身份解析正确（`UserName=<第二账户>`、`LocalAppData=C:\Users\<第二账户>\AppData\Local`、`IsAdmin=False`）；**污染测试**：故意把 `USERPROFILE`/`HOME`/`USERNAME`/`TEMP` 全指向第一账户的 profile，函数**仍返回第二账户的路径**（读 SID→ProfileList，不信任继承值）；**隔离测试**：第二账户对 `C:\ProgramData\AgentQ` 的 `Get-Acl` 被拒、四个子项（`config`/`agentq-launcher.ps1`/`data`/`runtime`）**全部 `UnauthorizedAccessException`**；**注册身份**：现有任务 `UserId=<账户名> LogonType=Interactive RunLevel=Limited`，触发器 `MSFT_TaskLogonTrigger user=<计算机名>\<账户名>`；把注册身份换成不存在的用户名会被 `Register-ScheduledTask` 拒绝并给出明确消息，而两个账户都能注册 |

**本文档原先关于 registry/profile 的前提是错的**：上一版写「本机 PortableGit 未写注册表，
是走 PATH 分支解析到的」——那是 2026-10-01 那台机的情况，**这台机装的是 Git for Windows
全量版、注册表键存在**，所以走的正是注册表分支。两台机不是一回事，已按实测改正。

**证据形状（如实记）**：函数体是**从发行版资产抽取**后执行，但**不是安装器整体运行**——
安装器全文在本机仍不可执行（`13` 撞平台闸门），所以这两项证明的是「这两个函数在真机、
真注册表、真第二账户下的行为」，不是「安装器端到端在第二个用户下装成功」。后者的前置
（`Set-PrivateTreeAcl` 对第二用户的隔离、跨用户注册能力）本次已各自单独证明。

**机器状态**：测试用的第二账户 **保留**（跨用户验证的现场）；探针账户已删；测试脚本与结果文件已全部清除（`dir /b` 确认为空）；`InstallPath`
已还原为 `C:\Program`。

#### C5 执行结果（2026-09-24）—— 外部审查

按你的指示派出 **5 个互不知情的独立审查者**（安全 / 正确性 / 测试证据 / 跨资产一致性 /
文档与实现一致性），要求只读、结论必须落到代码行、且**必须先自己试图证伪**。这是本仓
第一次有「不是我自己写、也不是我自己评」的审查。产出见 **A12（P0，已复现）**、
**A13（探针 stderr 通道）**，以及一批文档失准的修正。

**日期说明（2026-10-08 复核）**：派发发生在**本地 2026-09-24 23:06**，修复与收尾跨过本地午夜
（最后一批文档改动在 09-25 00:50 本地），而 `CHANGELOG.md` 的 C5 条目按**成文时间**署 09-25。
所以 A12/A13/A14 三条小节标题写「已修（2026-09-25）」、本小节与 C5 行写「2026-09-24」，
指的是同一件事的两端，不是两个事件；依据是会话时间戳（派发 `2026-09-24T15:06Z`、
成文 `2026-09-24T16:32Z`，本地 = UTC+8）。

### 另一条值得单列的设计债：Windows 专有分支的不可执行性

`08-jq-path-arguments` 的存在本身就说明了一件事：服务端有**只会在 Windows 上
执行**的分支（导出 `MSYS_NO_PATHCONV=1` 的那些），而 macOS 上没有任何检查会
走进它们。`08` 是用 shim 断言「不把路径当 jq 参数」来间接覆盖的——**这是间接
证据，不是执行证据**。

没有 Windows 机器就无法关闭这个缺口。它不是新发现的缺陷，是**已知的证据形状
局限**，写在这里以免被当成「已覆盖」。

---

## 六、明确取消 —— 不是待办，不得复活

以下事项已被明确取消，**不得**重新写入 Goal、待办清单或完成门槛：

- 压力测试
- 重启 / 注销 / 物理断电验收
- 历史全量扫描、完整历史 `shasum -c`
- 为每个旧 fixture 重建当前报告

以下需要授权，**默认不做**：

- 未获授权的远端安装、升级、回滚、服务变更、队列 mutation、凭证操作、生产写入
- 触碰真实 `/Users/mison/.agentq` 与真实 launchd 域
- 触碰 13 台真实生产 SSH 主机（仅用户在当次会话中点名的那几台获授权）
- 在目标机运行 `codex exec`，或把 Skill 客户端降级为普通前台 SSH
- 打印凭证内容（`shared_secret`、`daemon.key`）——只检查结构

---

## 七、警告清单

### 操作陷阱（会静默骗人）

1. **`doctor` 不是只读的。** 它先 `ensure_daemon`；daemon 未运行时在 macOS 走
   `launchctl kickstart gui/<uid>/com.agentq.pueued`、Linux 走
   `systemctl --user start agentq-pueued.service`——那是**服务变更**；成功路径还会
   经 `recover_removing_requests` 改写 request record。要只读地探查一台机器，
   **别走 AgentQ 协议**：直接 ssh 过去看 `~/.local/bin/agentq` 在不在、版本多少。
   同理，对真实远端跑 `doctor`/`status`/`lookup` 前，先确认该机 `pueued` 已在运行。

2. **`05`/`07` 的沙箱 sshd 不读 `~/.ssh/config`。** 它用全新 host key、高端口、
   只监听 127.0.0.1。所以 `07` 通过**不**代表用户 `~/.ssh/config` 提供的选项
   （ProxyJump、IdentityFile、`Host` 别名等）可用。

3. **`03` 的 `not_started` 恢复态只有 `03` 覆盖，`07` 只有一种变体。** 崩溃恢复
   的其余形态没有证据。

4. **`10` 只保证「这个具体失效无法再静默复发」，不等于安装器正确。**
   安装器是否真的能装——那仍需真机。

5. **`01` 只证明能解析，不证明任何分支的行为正确。** `skill/assets/unix/agentq-server`
   是 **5,332** 行无类型 shell：没有编译器、没有类型系统。（**2026-09-29 起有 git**，
   但版本控制不改变这一条——它给的是「改了什么」，不是「改对了没有」。）改它时把
   这一点计入风险。

6. **`pgrep -f` 在本机匹配不到沙箱 `pueued`**（实测）。别用它判断 daemon 是否
   在跑——直接看 socket 是否出现、`pueue status --json` 是否有响应。

7. **`AGENTQ_SMOKE_HOME` 指向 agentq home 本身**（`$HOME/.agentq`），不是父目录。
   指错一层不报错，只会让 `03` 继续 SKIP，极易被误读成「环境不满足」。

8. **沙箱路径必须短。** `pueued` 在 home 里绑 unix socket，macOS 上超过
   `SUN_LEN`（约 104 字节）直接起不来。**不要用 `$TMPDIR`**（`/var/folders/...`
   太长），用 `/tmp`。

9. **`detect_stat_flavor` 这类缓存必须在父 shell 里调用。** `$(...)` 开子 shell，
   在命令替换内部设的全局变量传不回来——缓存会静默失效。

10. **改完 `skill/` 必须同步全局 Skill 目录**（**整个目录**，不是只同步 `assets/`），
    否则安装装出旧代码、且 `SKILL.md` 会静默分叉。两者不会自动保持一致，忘了就分叉：
    ```sh
    SKILL_DIR="${SKILL_DIR:-$HOME/.agents/skills/agentq}"
    rsync -a --delete /Volumes/Work/code/agentq/skill/ "$SKILL_DIR/"
    diff -rq /Volumes/Work/code/agentq/skill "$SKILL_DIR"   # 必须无输出
    ```
    **为什么是整目录**：旧规则只同步 `assets/`，于是 `SKILL.md` 不在范围内、静默分叉
    （2026-09-29 实测：仓库的 `SKILL.md` 比全局目录里的新 5 行，差的正是几处已被推翻的断言）。
    与 `CLAUDE.md`「改完 `skill/` 必须同步全局 Skill 目录」一节同一条规则。

11. **`skill/assets/unix/agentq-server` 与 `skill/assets/windows-git-bash/agentq` 必须逐字节
    相同**（硬约束，任何时候 `cmp` 都必须是 0）。

### 已知边界（不是缺陷，是没证据）

- 真实远端服务、队列、TLS/shared key、生产凭证**均未被验证**
- 原生 Windows 上**已实测**：完整协议（submit/wait/logs/remove/cancel 两路径与
  重放/base64 日志/doctor/锁竞争/坏参数退出码/launcher `ArgumentsBase64` 转发）、
  PS 5.1 客户端坏参数路径、`noacl` 挂载下 `chmod` 无效、**NTFS reparse 点语义**
  （2026-10-01，8/8 + 变异 3/3）、**registry/profile** 与**跨用户安装/服务身份**
  （2026-10-06，见「C3 执行结果」）——**C3 三项已全部关闭**
- 原生 Windows 上**仍未验证**：真实远端队列（那台专用测试机是本机目标，不是
  经 AgentQ 连的生产队列）、生产凭证。**Windows 侧的 W5 换根崩溃恢复已于 2026-10-08
  在专用测试机上实测**（两个方向拒绝 + 恢复 + 经 launcher 的端到端，见 W5 条目末）。

### 性能事实（改热点路径前先读）

`status` 要调几十个子进程，执行时间基本由**子进程数量**决定。本机一次
fork+exec 约 15ms。

**但这条路径不要为了提速而顺手改**：`prepare_request_metadata_files` →
`load_request_records` / `load_cancellation_markers` 会遍历每个 `*.json`，每个文件
经 `request_record_is_valid` 调 jq。这些校验是**完整性防御**，不是可省的冗余。
`agentq-server` 是无类型 shell，本仓 smoke 抓不到行为回归，而这条路径正好是
安全相关的。要优化就得**先把行为钉死**（写针对性测试或真机验证），再动。

**2026-09-30 已按这条纪律做了一次，并且坐实了「smoke 抓不到行为回归」不是空话。**
实测到一个**跳过 crash-window repair 扫描**的变体（约 1.9× 加速）会让合法的
crash-window record **永远无法自愈**，却跑出 `17 ran 0 failed` 全绿；另一个去掉
filename↔`request_id` 绑定的变体**静默接受**错配记录，同样全绿。所以顺序是
**先写能红的 `smoke/18-record-metadata-contract`（21 例），再改扫描代码**。
改动内容：折叠三处逐条重复的 jq（每 record **4.05 → 1.05** 次，N=40 时 167 → 47），
外加 `set_current_process_lock_metadata` 的幂等缓存（`status`/`doctor` 2→1、
`lookup` 7→1 次身份解析）。`status`/`doctor` 在真实任务下输出**逐字节相同**。
**没有做的**（连同理由）：合并三遍扫描为一遍（会改变 pass 2 归档与 pass 3 的
可观察顺序，且 pass 1 在锁外、pass 2/3 在锁内）；折叠 `repair` 整轮（它是
crash-window 自愈的承重路径）；动 26 个 `stat`（TOCTOU 守卫）；结果缓存（无失效机制）。
**其中「折叠 `repair` 整轮」后来做了**——见 `PLAN.md` A25/A26（2026-10-04）：在
`smoke/18`/`26`/`27` 把行为钉死之后，`repair` 与 `wait`/`cancel` 恢复路径的逐条 jq
已折叠成单次聚合，回退路径保真；上面「不折叠」是 2026-09-30 当时的判断，不是长期边界。

实测规模因子（2026-09-21，真实 Windows 主机）：272 个 record + 29 个 tombstone
+ 3 个 marker → `status` 1930 次 jq 调用 / 114s。`logs`/`status` 到分钟级是这个
规模因子的结果，不是卡死——**排查时先数元数据文件，再怀疑死锁**。

---

## 八、执行状态

已完成（本会话）：A1、A2、A3、A4（零授权项），A5、A6（零授权、只改 `assets/`），
A7（零授权、只改 `smoke/`），B2、B3、B4（用户已授权），**C1（三台，用户已裁定范围）**。

**A29 公开仓库标准化（2026-10-08，用户指示）**：用户选定「薄壳加装」路线、公开仓库、
MIT、四子项全做。①②④ 已完成（版本 0.1.0 与 Pueue 4.0.4 拆开并加 `smoke/01` 三方一致性
规则；`LICENSE`/`CONTRIBUTING`/`README`/`CHANGELOG` 头部/`.github` 模板与 `SECURITY.md`）；
③ 的 `ci.yml`/`release.yml` **已写但从未被 Actions 实跑**（本仓尚无 remote）——见 A29。
**A30（`doctor` 报 AgentQ 版本）已获用户同意、单列一次改动，尚未实施**。
**A8 已执行（2026-09-24）**：主机 A/B 只读核查后**无需清理**（无可 `remove` 对象），
主机 C 后经用户提供凭据补盘（其队列已空，见 A8 续查）——详见 A8 那节。执行过程中撞出并修复了 A5a 引入的 P0 回归
（POSIX 客户端连不上任何 Windows 主机）。

**B5 已执行（2026-09-24，用户授权）**：主机 A（Windows）与主机 B（Linux）**均已重装
并完成端到端验证**，验证任务都已清理；主机 A 撞出本仓第 7 个真实 Windows 缺陷
（`AccessRulesProtected` → `AreAccessRulesProtected`，见 B5-执行）。**主机 C 亦已重装并完成端到端验证**（2026-09-24，用户授权凭据操作，见 B5-执行 与 A11）。
**B5 首轮无遗留项**（仓库此后又前进，三台再次落后）。**第二轮重装已于 2026-10-08 完成**
——三台均升到当前 `9721403c`/5,332 行并各自端到端验证，主机 A 的 Windows 客户端同批补齐
（见 B5-执行 与「真机实验」，后者三项已全部执行）。

**C5 外部审查已执行（2026-09-24 23:06 本地派发 5 个审查者，跨本地午夜收尾；`CHANGELOG.md` 该条按成文时间署 2026-09-25）**：5 个互不
知情的独立审查者，产出 **3 个真实缺陷（A12 P0 / A13 / A14，全部已修并配回归锁）**，以及
**6 处测试假绿**（5 处已修：`07` 的 `not_started` 死分支、`14` 缺失的站点 5、`09` 的
`-c "$var"` 静默掉落与兜底、`02` 的续行形态；`10` 的规则 B/G 两处**未修**，已如实记录）。
**（2026-09-25 续：「全部优化好」已把这六处全部修完）** —— `10` 的规则 B 改为在**读取器
函数体内**要求 BOM 常量（原先整文件 grep，改注释措辞就能骗过）、规则 G 排除注释行并要求
helper **在本文件中确有定义**、规则 F 从「前缀式」收紧为**只作用于 `Get-Acl` 赋值来的变量**；
`09` 补 `-c "$var"` 分支与兜底、`14` 的 `check_site` 加 `min_plausible=32` 下限、`03` 的
三处条件跳过改为硬失败，并**新增一条直接覆盖**（`task_identity_is_unambiguous` 的
`6`/`unavailable` 分支，此前无任何用例直达——`04` 走的是另一条路径）。
另修正一批文档失准（分母、百分比、检查计数、`SKILL.md` 把已修缺陷写成「已知」、
`PLAN.md` 五处仍说主机 C 缺凭据、Windows 缺陷数「三个」实为四个）。

**W4 成对原子安装已修（2026-10-07，用户授权「所有权限」）**：见上。两份客户端安装器
改为「全部暂存、统一提交」，各配行为级回归锁（`smoke/21` W1、`smoke/25` 的 AST 抽取真跑），
变异 2/2 被抓。

**A28 收尾批次已修（2026-10-07，用户「全都要处理」）**：安全 W1/W2 文档限定、
`sshp --check` 重试预算（`smoke/19` 19 例）、POSIX `HOME` 守卫（`smoke/05` env=16）、
start-daemon 三处 `exit 2` 死代码（`smoke/22` 59 例）、`sshp.ps1` 自毁
转义（`smoke/20` 9 例）；`-E` 日志 0600 那项**当天查证后撤回**（前提实测为假，见上）。
服务端 I2 与 Windows `$PID` 查实为边界；**W5 两侧已修、本机旧客户端已重装**
（均 2026-10-07，见上）。当时仅剩的 `2>` 实验与 B5 三台重装**已于 2026-10-08 全部执行**
（用户点名机器；见 B5-执行 与 W5 条目）。

**A13 的最后一处消息误导已修（2026-10-07，用户授权「继续」）**：`cancel`/`logs`/`remove`
把瞬时 Pueue 读失败报成 `unknown AgentQ task id`（`wait` 对同一状况正确报 `6`/`unavailable`）
——现经 `report_compact_task_failure` 分类，读失败报 `cannot inspect Pueue while reading
AgentQ task`，rc=4 保持原消息；pending-marker 分支闸到 rc=4。锁在 `smoke/15` 第 6 节
（修复前 6 红、5 变异 5/5 被抓）。**A28 记录在案项至此清零可做项**，余下全部需要授权
（B5 三台重装、真机 `2>` 实验——**两者均已于 2026-10-08 执行**）或属设计决定（W4）。

**A28 七维度审查已执行（2026-10-06，用户指示「使用 agents 全维度全场景审查」）**：
7 个互不知情的只读审查者（服务端 / POSIX 客户端 / Windows 资产 / 四个安装器 / 测试
套件 / 文档一致性 / 凭据安全）+ 1 个补漏审查者（专查长期未执行的检查）。每条高影响
结论都由本人复核后才动手；**复核推翻了 5 条 agent 结论**（`mktemp -d` 0700、`id_ecdsa`
覆盖、zsh nomatch、安全 I2、sshp `--check`）。**修掉 1 个 P0 级 fail-open（两个客户端
的探针退出码改写把 `exit` 变成了赋值）+ 服务端 C1 workdir fail-open + rc4 折叠 +
pending marker + 同族四条通道纪律 + 安装器 8 处（POSIX 4 + PS 4 个 `finally`）
+ 服务端清理 glob + 套件自身 6 处**，全部配变异证明能红的回归锁。详见 A28。

**C2 容器矩阵已执行（2026-09-24 本地深夜——该轮 63 次 docker 调用落在 23:01–23:46，本地午夜前完成）**：本仓**首次跑通 Linux 成功路径**（真实 systemd + 真实
logind + 真实二进制走内置 SHA 校验，`INSTALLER_EXIT=0`、零残留），外加真实 Linux 协议端到端、
真实升级路径、真实 arm64 安装+协议、两个失败模式格（均零副作用）。四个二进制哈希逐一相符。
两格明确不可达并记录（WSL 无法伪造、Fedora 的 dnf 路径未走通——**后者已于 2026-09-30
补做成功**，见 `PLAN.md` C2 一节与 `CHANGELOG.md`）。

**2026-09-25 真机补测（用户点名一台 Windows 主机，地址不入库）**：三件事全做。
**① PS 5.1 契约**：`smoke/12` 新增 `AGENTQ_SMOKE_PWSH` 覆盖点后，在真
**Windows PowerShell 5.1.19041** 上跑通全部 **31 个用例**（`ps51=covered`）——
本仓第一次在 PS 5.1 上执行该客户端契约（此前只有「Win11 实测 13 例」的文字记录）。
过程中修了两处**只在 PS 5.1 下暴露的检查移植问题**：PS 5.1 不接受 POSIX 路径作
`-File`（pwsh 7.5 接受），须经 `cygpath -w`；`ps51=` token 改为反映实际解释器。
**② `smoke/09` 的 CRT 模型获真机证实**：5 组校准值逐条复现、argv 逐字一致。
**③ 性能**：`status` 5m47s 的根因是 jq 走了 chocolatey 的 .NET 壳（单次 167ms vs
真 jq 23ms，**7.1 倍**；1930 次调用累积成 **3.1 倍**端到端）。**不是缺陷，是环境**；
`CLAUDE.md` 记的 114s 用的是真 jq，两者都对。**④ 该机已升级**（见 B5）。
**⑤ A5b 当时仍不做**：该机 `DefaultShell` **未设置** = 默认 `cmd.exe`，
实测 `2`/`5`/`124`/`42` 原样传回——A5b 的压平只在 `DefaultShell=powershell.exe`
时出现，而那列当时无真机，改一条无法验证的路径属于「凭想象写」，不做。
（**2026-10-01/02 更新**：`powershell.exe` 那列已在专用测试机上造出真机，
A5b 随之修复并经两列双向验证——见 A5b 正文与本节 A5b 行。）

**C4 已重定性**：用户**无生产权限**（上游才有；用户是 fork 贡献者、只在私有 CF 部署测试），
故 C4 不是「不做」而是「**用户无权授权**」——不得记为待办，也不得声称已验证。

**A9 已执行（2026-09-24，零授权）**：修两个「报错把人指错方向」的缺陷——ssh 诊断分类器
在四个资产里因缺 `user@host: ` 前缀而**永远漏判认证失败**，以及失败提示把人引向
`AGENTQ_REMOTE_PLATFORM`（那个变量救不了缺密钥）。全量 suite **14 ran 0 skipped 0 failed
(777s)**，套件窗口内 `assets/`+`smoke/` mtime 快照无差异；变异 2/2 被抓。

验证（该轮全量）：`AGENTQ_SMOKE_HOME=/tmp/aqsb/home/.agentq ./run-tests.sh` →
**14 ran, 0 skipped, 0 failed (696s), exit 0**（2026-09-24，submit 侧行为断言之后；
跑前跑后对 `assets/`、`smoke/`、`run-tests.sh`、`sandbox.sh` 共 40 个文件做 mtime
快照，`diff` 无输出 = 运行窗口内零改动）。
结果已写入 `CHANGELOG.md` 对应行。

**一条关于证据的纪律（2026-09-22 踩过）**：跑全量 suite 期间**不要改 `assets/` 或
`smoke/`**。我先跑了一次、中途改了客户端，套件照样报 `14 ran 0 failed`——但早期检查
读的是旧字节、晚期读的是新字节，**哪个版本都没被验证**。绿色摘要看不出这一点。
判据：把 `assets/` 与 `smoke/` 下每个文件的 mtime 与套件窗口（结束时间 − 报告的时长）
比对，任何文件落在窗口内，这次结果就要作废重跑。

**C1 之后新增三项零授权待办**（都是 C1 直接产出的，不需要再要授权）：

| 项 | 性质 |
| --- | --- |
| **A5 探针超长** | **已修（A5a 长度 + A5b 退出码，两端客户端）。引入时间不可考（见正文）**。2026-09-24 另补 submit 侧的行为断言（探针与 submit 两条通道的 stdin 都钉住了，含各自的 TMPDIR 零残留）|
| **A6 `task_instance_created_at` 取第一条匹配** | **已修并验证**（M3 证明新用例敏感）。安全相关路径 |
| **A7 中断变体的可重复化** | **已执行**：并入 `smoke/07` 第 8 节（复用其真实 sshd 沙箱），三条契约各自钉住 |
| **A8 C1 队列残留清理** | **已执行**（2026-09-24）。A/B 无需清理；**主机 C 亦已盘查**（队列已空） |

剩余，都需要你：

| 项 | 需要什么 |
| --- | --- |
| ~~**B1 `git init`**~~ | **已完成**（2026-09-29，用户明确授权）：`git init` + `.gitattributes`(`* -text`，护住 canonical 字节) + `.gitignore`(机制挡凭据) + 基线提交与改动提交分离。**B 项至此全部收口** |
| ~~**B2 协议版本协商**~~ | **已选 (b) 并完成**（2026-09-22）：`SKILL.md` 与 `CLAUDE.md` 各写明是决定而非遗漏 |
| ~~**B3 `2` 的机读化**~~ | **已实现**（2026-09-22）：服务端 7 处 `reason=` 行，两端客户端转发为 `remote failure reason:` |
| ~~**B4 覆盖债第一刀**~~ | 已完成：`smoke/13-ps-installer-contract` |
| ~~**C1**~~ | 已执行（三台） |
| **C2–C5** | 平台/Windows/生产/审查的范围授权 |
| ~~**A5b 操作路径退出码通道**~~ | **已修（2026-10-02）**：token 走 **stderr**（客户端本就捕获它，服务端 `reason=` 同路），两份客户端各改一处、`smoke/05`+`smoke/12` 各加回归锁，真机两列双向验证 + 变异 3/3。见 A5b 正文 |
| ~~**A8/B5 主机 C**~~ | **2026-09-24 那次已完成**（队列已空、已重装、端到端通过）。**但 2026-09-25 又落后了一版**：主机 A（Windows）与主机 B（Linux）已升到 `97088c62`，**主机 C（macOS）仍是 `e3b132af`**，即 A12 的 P0 在该机未消除。原因不是拒绝升级，是**该地址在本机网络层不可达**（ARP `incomplete`、同网段网关也不通）。恢复连通性后按同一流程处理（**2026-09-26 已决定不追**，见下行） |
| ~~**原「主机 C」的地址**~~ | **已决定不追**（2026-09-26）：用户指定 macOS 主机以新那台为准，该机已完成全新安装。原那台仍带 A12 的 P0，但**不在当前机群内**——若将来重新启用，先升级 |
| ~~**A16 Windows 客户端认证提示**~~ | **已完成**（2026-09-27）：照 A9 在 `Write-Diagnostics` 里按 class 追加，配 `smoke/12` 双向用例（认证必打且须含主机名，其余 class 必不打），红/绿 + 变异已验证 |
| ~~**A17 脱敏不变量回归**~~ | **已完成**（2026-09-27）：46 处地址等标识清除，并新增 `smoke/16-no-host-identifiers` 把那次一次性扫描变成常设检查；**2026-10-06 跟进**：又清一次（计算机名/账户名/VM 名）并加 `R7`（见 A17 末尾） |
| ~~**A18 密码认证支持**~~ | **已完成**（2026-09-28）：`BatchMode` 条件化 + 三种凭据来源（`AGENTQ_ASKPASS` / `AGENTQ_PASSWORD` / `AGENTQ_PASSWORD_PROMPT`），严格守卫；新增 `smoke/17-askpass-credential`（真实 sshd 端到端）+ `smoke/05`/`12` 各一组 argv 与拒绝用例。**2026-09-29 真机补验**：账户密码登录成功已在真机验证（POSIX 与 Windows 客户端各连一台只有密码的 macOS 主机，完整协议 `Done.result="Success"`）；Windows 客户端已升级到 canonical 并跑通端到端。**2026-10-02 关闭「原生 Windows ssh 未验证」**：专用测试机的客户端 PATH 解析到 `C:\Program Files\OpenSSH\ssh.exe`（`OpenSSH_for_Windows_9.5p1`，**原生**，非 Git Bash MSYS），Windows→Windows 经它跑通完整协议。**唯一仍属边界的**是 `System32\OpenSSH\ssh.exe` 8.1p1（早于 `SSH_ASKPASS_REQUIRE`，且不是客户端默认解析到的构建）。见 A18 |

**A1/A2 之后覆盖债的实际变化，要说准。** 这两个检查覆盖的是**契约**，不是按行数
成比例的覆盖，所以「覆盖债从 12,419 行降到 N 行」这种算法是**错的**，不要用。

准确的说法：12 个零覆盖资产里，现在有 **8 个**各有一份契约检查——

- `client/unix/install-client.sh`（**280** 行）：本地契约 **12 例**（`smoke/21`，2026-10-03 新增；2026-10-07 加 W1 成对原子性用例）。
  **唯一一个成功路径也可测的安装器**（只拷两个文件进沙箱，无网络/无服务管理器/无包管理器），
  故契约与成功路径都覆盖了。真实 `~/.local/bin`、live 目标上的崩溃语义仍未覆盖。
- `windows-git-bash/agentq-launcher.ps1`（430 行，**曾是本仓最大的零覆盖资产**）：**59 例**（`smoke/22`，
  2026-10-03 新增），覆盖在 macOS 上可跑的三块——payload 解码器、路径守卫、env→argv 回环 bash 脚本，
  **外加 `agentq-start-daemon.ps1` 的两个路径守卫**（与 launcher 的守卫近乎逐字拷贝，故一并断言两份行为一致）。
  **Windows API 路径（`WindowsIdentity`+HKLM）仍未覆盖**，摘要行明写 `windows-api=NOT-covered`。
- `windows-git-bash/agentq-durable-move.ps1`（118 行）：参数契约 4 例 + **源码级 access-mask 不变量** 3 例
  （`smoke/23`，2026-10-03 新增）。它是本项目第一个原生 Windows 缺陷的现场；那条 access-mask 常量
  只有真机能注意到回归，故源码级钉住。**move/flush 行为仍未覆盖**（本机死在 kernel32 P/Invoke）。
- `install-agentq.sh`（**2,946 行**，2026-10-07 W5 后）：失败契约 **27 例**（`smoke/11`
  自报 `cases=27`；17→20 的 3 例见 A27——临时路径的可预测名与助手本身的原子性；
  20→22 的 2 例是 curl 自身失败与模板缺占位符；22→27 的 5 例是 W5 崩溃残留两例、
  父目录不可列、恢复指引与 daemon 消息，见「C2 补格」）。
  **成功路径仍是零覆盖**，而成功路径才是它 2,946 行里的绝大部分。
- `client/windows/agentq.ps1`（**2,478** 行，2026-10-07 按当前字节重算）：本地参数契约 **48 例**（`smoke/12`
  自报 `cases=48`，pwsh 下；2026-10-02 在真 PS 5.1 上实跑 `ps51=covered`）。**远端交互、传输、重试、恢复全部仍未覆盖**，
  A18 新加的凭据路径**选项构造**已被断言，且**真机行为已验**（2026-10-02 专用 Windows
  测试机：原生 ssh + askpass 密码，Windows→Windows 完整协议）。

- `windows-git-bash/install-agentq.ps1`（**3,072** 行，2026-10-07 重算）：参数契约 + 平台闸门 + **W5 崩溃残留守卫** 7 例（W5 见上）。
  **这台机器上不可达的 staging/ACL/事务路径仍是零覆盖**，且已实测确认不可达
  （任何参数组合都死在第一条语句上），所以这一份契约检查的覆盖面比前两个更窄。

- `client/windows/install-client.ps1`（**563** 行，2026-10-07 按当前字节重算）：**从「只有源码断言」升级为「有行为执行」**
  （`smoke/25`，2026-10-03 新增，9 例）。此前它只有 `10` 的四条源码不变量——按本表的定义
  那算「执行过」，但**从未被运行过**，与 `install-agentq.ps1` 在 `13` 之前的状态同类。
  现在参数契约（缺值／未知参数／`-Check` 下未知参数）与平台闸门被真正执行，并证明
  **闸门先于任何写入**、`-Check` 也撞闸门。**staging/ACL/原子移动/PATH 更新仍是零覆盖**
  （第一条语句之后的全部，实测在 macOS 上不可达）。**分子不变**（该资产本就被计入
  「已覆盖」），但证据从源码级升到了行为级。

- `client/unix/sshp`（1,207 行）：本地契约 **19 例**（`smoke/19`，2026-10-02 新增）。
  覆盖参数校验、环境变量校验、`--help`、探测分派（含 `--check` **不得安装**）、
  重连策略、实际 argv、TMPDIR 零残留，以及会话名的注入守卫。
  **任何真实远端仍是零覆盖**——桩证明的是 sshp **发出什么**；交互会话本体、
  Windows 路径、远端安装路径都未覆盖（见 `smoke/19` 头注释的边界清单）。

`client/windows/sshp.ps1`（1,153 行，2026-10-07 按当前字节重算）**不再属于「从未被执行过」那一类**：`smoke/20`
（2026-10-02）在 pwsh 里真跑它 `--check`、捕获它实际发给 ssh 的 argv 并断言往返。
但要说准：那是**一条路径**的断言（脚本怎么交给 ssh），不是它的本地契约——
它的参数校验、会话建立、Windows 路径仍未覆盖。

仍然**没有任何检查执行过**的资产（"执行过" = 行为执行或源码断言；只有 `01` 的
语法/结构解析不算；从资产中**抽出单个函数**执行的算覆盖该函数、不算执行过整个
资产）。按行数：`agentq-start-daemon.ps1`（268），
2 个 `.cmd` 薄启动器（8），
2 个 `.plist` + 2 个 `pueue.yml` + 1 个 `.service`（110），以及 `unix/agentq`（5，
只是转发 shim）。合计 **391 行 / 27,028 行 = 1.4%**（分母 2026-10-07 重算：`skill/assets/` 全部 23 个资产 `wc -l` 之和 = 27,028；此前记的 26,264 是 2026-10-06 的数，此后 A28/A13/W5/C2 各轮改动都动了字节。**分子 383 → 391**——多出的 8 行是 `agentq-start-daemon.ps1` 在 A28 收尾里从 260 长到 268，其余三类未变）。
`agentq-start-daemon.ps1`（268 行）**大部分仍零覆盖**：顶层第一条语句就死于 `WindowsIdentity`
（同 `install-agentq.ps1` 的形态），已实测确认不可**整体**执行而非推测；但它的**两个路径守卫、
`Set-AgentQUserEnvironment` 与三处拒绝站点**可跑，已由 `smoke/22` 覆盖（见上）。

**分子连续第三轮变小**：上一版分子 1,216 行里，`agentq-launcher.ps1`（430）、
`install-client.sh`（251）、`agentq-durable-move.ps1`（118）合计 **799 行**
（占旧分子的 66%）那一轮**离开了这张表**——`smoke/22` 覆盖前者在 macOS 上可跑的三块，
`smoke/21` 给中者补上契约+成功路径，`smoke/23` 覆盖后者的参数契约与 access-mask 不变量。
这一轮 `smoke/24` 又拿走两个 Git Bash 启动器（当时 `agentq.bash` 19 + `sshp.bash` 15 = **34 行**；
2026-10-07 按当前字节是 23 + 15 = 38，`agentq.bash` 在 A28 收尾里长了 4 行）
——它们**不是死文件**（`install-client.ps1` 把它们拷成 `.local\bin` 下的无扩展名
`agentq`/`sshp`），此前只有 `01` 的 `bash -n`。剩下的 391 行里，**没有一个资产超过 268 行**，
且其中 268 行的那个（`agentq-start-daemon.ps1`）已实测确认在 macOS 上不可**整体**执行（`smoke/22` 覆盖的守卫等除外，见上）；余下的是
2 个 `.cmd`（8 行，`01` 已有结构断言）与声明式配置（`.plist`/`.yml`/`.service`，110 行）。
分母已于 2026-10-07 重算为 **27,028**（`skill/assets/` 全部 23 个资产 `wc -l` 之和）。
别再引用旧的 25.9%、13.8%、4.8%、1.6%、1.5%、25,536 或 26,264。
