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
   （9 个资产 / 3,498 行，2026-09-24 重算）；另有更大一片是「只有源码断言、没有
   行为执行」。**这一项本质未变**，只靠逐项补契约检查推进（A1/B4 已做 3 个）。
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

**局限（不可省略）**：pwsh **不复现**本项目实际踩过的两个 PS 5.1 缺陷。本检查
**不关闭** PS 5.1 的缺口；那条 Windows 11 VM 实测仍是唯一的 PS 5.1 证据。

### A3. `run-tests.sh` 的 SKIP 语义 —— **已完成**

总结行之后紧跟一行 `NOT A FULL PASS: N check(s) skipped and therefore not verified.`，
并给出如何补跑。退出码仍是 0——SKIP 是环境属性，不是被测代码的失败。

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
`124`（平台探测超时）同理。**未验证**：真实 `DefaultShell=powershell.exe` 的主机
我没碰过，这一条是在现有主机上用外层 `powershell -c` 模拟出来的——结论可靠
（机制是 PowerShell 自身的），但**没有一台真机以该配置跑过**。

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
五个站点：POSIX 协议探针、POSIX 平台探针、launcher wrapper、Windows 协议探针、
Windows 客户端自己的 launcher wrapper（第 5 个是 C5 审查补上的——此前它从未被测量过，
把它撑到 26,538 字符全套检查依然全绿）。

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

**仍未验证**：`DefaultShell` **真的**配置为 `powershell.exe` 的主机——我是在现有主机
上用外层 `powershell -c` **模拟**出来的。机制是 PowerShell 自身的（机制可靠），
但没有一台真机以该配置跑过。也**不能**声称主机 A 经 AgentQ 协议可用（那需要端到端
真机复验，属 C1 的遗留项）。

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

- `agentq-server` 是 4,937 行无类型 shell，本仓 smoke **抓不到行为回归**
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
| 主机 C（macOS） | 全部 15 个任务 | **未能盘查**：端口通但公钥被拒（`Permission denied (publickey,password,...)`） | 待定 |

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
待你授权时可单独跟进。

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
- **基线提交与改动提交分开**：`31d83f3` 是本次会话改动**之前**的状态（由当前树逐处
  回退那 4 处代码改动重建），`d7220c5` 才是本次改动。这样 `git diff 31d83f3` 就是
  「这次会话改了什么」的准确答案。

**顺带纠正一处文档失真**：`CLAUDE.md` 的覆盖边界一节曾写「没有编译器、没有类型
系统、**没有 git**」，git 落地后已改为如实描述。

**`HANDOFF.md` 的「不使用 `git reset --hard`…」那条操作规则已按 B1 原计划改写**：保留那一条是因为
它防的是 `git reset --hard` / `git checkout --` 这类**销毁工作**的操作——本会话真的
因为先删备份再 `git reset --hard baseline` 把工作树回退过，是靠 git 对象
`dcff709` 逐字节恢复的。规则没变，理由写清楚了。

### B2. 协议版本协商：做，还是写成刻意不做

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

### B3. `2` 的机读化（推荐做，兼容）

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

### B5. 三台真实主机的部署版本已落后于仓库 —— 需要你决定何时/是否重装

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

### B5-执行. 三台重装 —— **A、B 已完成；C 待凭据（2026-09-24，用户授权：安装/服务变更）**

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
`SUDO_ASKPASS`）——**但 `SKILL.md` 第 64 行早就写着这件事**，连代码模板、`env_reset`
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
密码提示，所以缺的不是同一个问题）；Windows 两个客户端的分类器已改，但**未在真机验证**
（本机 pwsh 不跑 ssh 失败路径）。

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

**仍未修**：`cancel`/`logs`/`remove` 路径上同一根因的**消息误导**——它们对活着的任务报
`unknown AgentQ task id`（exit `2` 传播是正确的，但把"读不出来"说成了"id 不存在"）。
契约说 exit 2 意味着"改参数"，同一个底层状况在 `wait` 上正确地报 `6`。

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
五条规则覆盖实际泄漏过的五种形状，扫全仓文本文件 + 记忆目录。

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

### B4. 覆盖债的第一刀砍哪

`unix/install-agentq.sh`（2,755 行）和 `windows-git-bash/install-agentq.ps1`
（2,881 行）合计 5,636 行，占全仓 22.8%，是两个最大的零覆盖资产。A1 处理前者。

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

**仍未验证**：Windows 客户端经**原生 Windows ssh**（`C:\Windows\System32\OpenSSH\ssh.exe`）
的行为——那个版本的 `ssh_askpass` 走 win32compat 的 `posix_spawnp`，与 MSYS 版
不是同一实现，可能确实支持带参数形态。**但主机 A 的客户端解析到的是 MSYS 版**，
所以「原生 ssh 下能否用 `cmd.exe /c`」在这台机器上**测不到**，不得声称。

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
`C:\Users\<账户名>\.aq sp\ap.sh` **rc=0 成功**（`C:\Program Files\...` 正是这种形态）；
第一版会把这类合法路径一并拒掉，**把合法配置说成非法**。正确判据是**文件系统**：
整个值作为路径存在且可执行即合法；不存在时**再**诊断形态并说明原因。
（这次纠错本身是本轮最有价值的产出之一：它说明「看起来更严格」的守卫不等于更正确。）

**对照证据**（本机 OpenSSH 10.3p1，独立于 Windows，四组）：裸路径 rc=0、**含空格路径 rc=0**、
带引号 rc=255、带参数 rc=255——即后两者**永远不会成功**，而前两者都合法。

**仍未验证，不得声称**：
**Windows 客户端经原生 Windows ssh**（`C:\Windows\System32\OpenSSH\ssh.exe`，
8.1p1）的 askpass 行为——该机客户端 PATH 上解析到的是 **Git Bash 的 MSYS ssh**
（`C:\Program Files\Git\usr\bin\ssh.exe`，9.9p1，`objdump -p` 确认链接 `msys-2.0.dll`），
两者不是同一实现，所以「原生 ssh 下 `cmd.exe /c` 形态是否可行」在这台机器上**测不到**。
**macOS 本机非 root 的用户级 sshd 仍验不了真实密码**（`getpwnam().pw_passwd`
是 `'********'`、无 `/etc/shadow`、`/usr/sbin/sshd` 无 setuid 位、`UsePAM yes`
明确要求 root）——**但这不再限制结论**：账户密码登录成功已在真机上由上述两台
主机独立验证。

**过程中记录在案的一处自造假绿**：`smoke/05` 的失败检查块原先在凭据断言**之前**，
于是那些 `failures` 计数全被累加却从不被检查——检查照常报绿。是变异测试
（把守卫改成恒假后仍绿）暴露的，已把该块移到断言之后。

---

## 五、C 类：需要你给范围

这些我无法自己划定边界，需要你明确主机、用户、工作目录、恢复方式和副作用授权。
**在拿到之前它们不是待办，是待定。**

| # | 事项 | 需要你给什么 |
| --- | --- | --- |
| C1 | P1-3 整体操作矩阵（**改为三台**、**真实网络中断**；2026-09-22 用户裁定） | **已执行（2026-09-22）**，结果与两个新缺陷见 `CHANGELOG.md`。三台里只有一台跑当前版本。**两项遗留均已消解（2026-09-24）**：① 主机 A 的客户端路径——重装后 `status`/`submit`/`wait`/`logs`/`remove` 五项 exit 0（见 B5-执行）；② 缺陷二已修并验证（见 A6，`smoke/03` 有用例、M3 证明其敏感）。**C1 无遗留** |
| C2 | 平台/安装矩阵（WSL、arm64、RHEL、Fedora、Alpine、真实升级回滚） | **已执行容器可覆盖的部分（2026-09-24，用户全权授权）**，见下 |
| C3 | 原生 Windows 其余边界（NTFS reparse 点语义、registry/profile、跨用户安装/服务身份） | 一台可用的 Windows 机器 + 是否允许改系统状态。**用户已声明无生产权限**，主机 A 是生产机，故不主动推进 |
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
| **真实 Fedora 安装 + 协议端到端（2026-09-30 补做）** | `jrei/systemd-fedora`（Fedora 44、systemd PID 1），以普通用户 `aqtest` 身份、`su -` 建真实 logind 会话、`AGENTQ_PUEUE_SOURCE_DIR=/stage` 预置真实二进制（仍走内置 SHA-256 校验） | **`INSTALLER_EXIT=0`**，`AgentQ 4.0.4 installed`；私有树 700/600；unit `enabled`+`active`（`Main PID pueued --config .../pueue.yml`）；linger `yes`；**零残留**；两个二进制哈希与内置常量**逐一相符**。协议面：`status`=0；`submit→wait`=`Success`、`logs` 回 `FED-OK` + `Linux`；**失败任务 `wait`=1 且 result 为 `Failed:7`（未被报成成功）**；`remove`→`wait`=**5**/`removed`；`lookup` 连查 3 次都是 **5**；`cancel` 已结束但仍在 Pueue 的任务=**2**+`reason=task_not_running`；`cancel` queued 返回 `cancel_requested`，**重放 `reused:true`**；`status` 能读到 `cancellation_requested_at`；`doctor`=0 且 stderr 报 `pueue=4.0.4`/`pueued=4.0.4`/`systemd_user_service=active` |

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

#### C5 执行结果（2026-09-24）—— 外部审查

按你的指示派出 **5 个互不知情的独立审查者**（安全 / 正确性 / 测试证据 / 跨资产一致性 /
文档与实现一致性），要求只读、结论必须落到代码行、且**必须先自己试图证伪**。这是本仓
第一次有「不是我自己写、也不是我自己评」的审查。产出见 **A12（P0，已复现）**、
**A13（探针 stderr 通道）**，以及一批文档失准的修正（`CHANGELOG.md` 2026-09-24 条）。

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
   是 **4,937** 行无类型 shell：没有编译器、没有类型系统。（**2026-09-29 起有 git**，
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

10. **改完 `skill/` 必须同步全局 Skill 目录**，否则安装装出旧代码。两者不会
    自动保持一致，忘了就静默分叉：
    ```sh
    rsync -a --delete /Volumes/Work/code/agentq/assets/ \
        /Users/mison/.agents/skills/agentq/assets/
    diff -rq /Volumes/Work/code/agentq/assets \
        /Users/mison/.agents/skills/agentq/assets   # 必须无输出
    ```

11. **`skill/assets/unix/agentq-server` 与 `skill/assets/windows-git-bash/agentq` 必须逐字节
    相同**（硬约束，任何时候 `cmp` 都必须是 0）。

### 已知边界（不是缺陷，是没证据）

- 真实远端服务、队列、TLS/shared key、生产凭证**均未被验证**
- 原生 Windows 上**已实测**：完整协议（submit/wait/logs/remove/cancel 两路径与
  重放/base64 日志/doctor/锁竞争/坏参数退出码/launcher `ArgumentsBase64` 转发）、
  PS 5.1 客户端坏参数路径、`noacl` 挂载下 `chmod` 无效
- 原生 Windows 上**仍未验证**：NTFS reparse 点语义（只确认了文件系统是 NTFS 与
  上述 ACL 实测，未测 reparse 点本身）、registry/profile、跨用户安装/服务身份

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

实测规模因子（2026-09-21，真实 Windows 主机）：272 个 record + 29 个 tombstone
+ 3 个 marker → `status` 1930 次 jq 调用 / 114s。`logs`/`status` 到分钟级是这个
规模因子的结果，不是卡死——**排查时先数元数据文件，再怀疑死锁**。

---

## 八、执行状态

已完成（本会话）：A1、A2、A3、A4（零授权项），A5、A6（零授权、只改 `assets/`），
A7（零授权、只改 `smoke/`），B2、B3、B4（用户已授权），**C1（三台，用户已裁定范围）**。
**A8 已执行（2026-09-24）**：主机 A/B 只读核查后**无需清理**（无可 `remove` 对象），
主机 C 后经用户提供凭据补盘（其队列已空，见 A8 续查）——详见 A8 那节。执行过程中撞出并修复了 A5a 引入的 P0 回归
（POSIX 客户端连不上任何 Windows 主机）。

**B5 已执行（2026-09-24，用户授权）**：主机 A（Windows）与主机 B（Linux）**均已重装
并完成端到端验证**，验证任务都已清理；主机 A 撞出本仓第 7 个真实 Windows 缺陷
（`AccessRulesProtected` → `AreAccessRulesProtected`，见 B5-执行）。**主机 C 亦已重装并完成端到端验证**（2026-09-24，用户授权凭据操作，见 B5-执行 与 A11）。
**B5 无遗留项。**

**C5 外部审查已执行（2026-09-25，用户指示「按正规工程审查做、使用 agents」）**：5 个互不
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

**C2 容器矩阵已执行（2026-09-25）**：本仓**首次跑通 Linux 成功路径**（真实 systemd + 真实
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
**⑤ A5b 仍不做，且理由更强**：该机 `DefaultShell` **未设置** = 默认 `cmd.exe`，
实测 `2`/`5`/`124`/`42` 原样传回——A5b 的压平只在 `DefaultShell=powershell.exe`
时出现，而那列**仍无真机**。改一条无法验证的路径属于「凭想象写」，不做。

**C4 已重定性**：用户**无生产权限**（上游才有；用户是 fork 贡献者、只在私有 CF 部署测试），
故 C4 不是「不做」而是「**用户无权授权**」——不得记为待办，也不得声称已验证。

**A9 已执行（2026-09-24，零授权）**：修两个「报错把人指错方向」的缺陷——ssh 诊断分类器
在四个资产里因缺 `user@host: ` 前缀而**永远漏判认证失败**，以及失败提示把人引向
`AGENTQ_REMOTE_PLATFORM`（那个变量救不了缺密钥）。全量 suite **14 ran 0 skipped 0 failed
(777s)**，套件窗口内 `assets/`+`smoke/` mtime 快照无差异；变异 2/2 被抓。

验证（最近一次）：`AGENTQ_SMOKE_HOME=/tmp/aqsb/home/.agentq ./run-tests.sh` →
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
| ~~**B1 `git init`**~~ | **已完成**（2026-09-29，用户明确授权）：`git init` + `.gitattributes`(`* -text`，护住 canonical 字节) + `.gitignore`(机制挡凭据) + 基线提交与改动提交分离。**B 项至此全部收口，没有未决的 B 了** |
| ~~**B2 协议版本协商**~~ | **已选 (b) 并完成**（2026-09-22）：`SKILL.md` 与 `CLAUDE.md` 各写明是决定而非遗漏 |
| ~~**B3 `2` 的机读化**~~ | **已实现**（2026-09-22）：服务端 7 处 `reason=` 行，两端客户端转发为 `remote failure reason:` |
| ~~**B4 覆盖债第一刀**~~ | 已完成：`smoke/13-ps-installer-contract` |
| ~~**C1**~~ | 已执行（三台） |
| **C2–C5** | 平台/Windows/生产/审查的范围授权 |
| **A5b submit 退出码通道** | 零授权、可做，但要先解决通道冲突（submit 的 stdin 已在传 base64 payload，token 只能走 stdout）。**不是回归**，是 A5b 记录的未验证范围 |
| ~~**A8/B5 主机 C**~~ | **2026-09-24 那次已完成**（队列已空、已重装、端到端通过）。**但 2026-09-25 又落后了一版**：主机 A（Windows）与主机 B（Linux）已升到 `97088c62`，**主机 C（macOS）仍是 `e3b132af`**，即 A12 的 P0 在该机未消除。原因不是拒绝升级，是**该地址在本机网络层不可达**（ARP `incomplete`、同网段网关也不通）。恢复连通性后按同一流程处理 |
| ~~**原「主机 C」的地址**~~ | **已决定不追**（2026-09-26）：用户指定 macOS 主机以新那台为准，该机已完成全新安装。原那台仍带 A12 的 P0，但**不在当前机群内**——若将来重新启用，先升级 |
| ~~**A16 Windows 客户端认证提示**~~ | **已完成**（2026-09-27）：照 A9 在 `Write-Diagnostics` 里按 class 追加，配 `smoke/12` 双向用例（认证必打且须含主机名，其余 class 必不打），红/绿 + 变异已验证 |
| ~~**A17 脱敏不变量回归**~~ | **已完成**（2026-09-27）：46 处地址等标识清除，并新增 `smoke/16-no-host-identifiers` 把那次一次性扫描变成常设检查 |
| ~~**A18 密码认证支持**~~ | **已完成**（2026-09-28）：`BatchMode` 条件化 + 三种凭据来源（`AGENTQ_ASKPASS` / `AGENTQ_PASSWORD` / `AGENTQ_PASSWORD_PROMPT`），严格守卫；新增 `smoke/17-askpass-credential`（真实 sshd 端到端）+ `smoke/05`/`12` 各一组 argv 与拒绝用例。**2026-09-29 真机补验**：账户密码登录成功已在真机验证（POSIX 与 Windows 客户端各连一台只有密码的 macOS 主机，完整协议 `Done.result="Success"`）；Windows 客户端已升级到 canonical 并跑通端到端。**仍不得声称**：Windows 客户端经**原生 Windows ssh** 的行为（该机 PATH 上是 Git Bash MSYS ssh，非同一实现）。见 A18 |

**A1/A2 之后覆盖债的实际变化，要说准。** 这两个检查覆盖的是**契约**，不是按行数
成比例的覆盖，所以「覆盖债从 12,419 行降到 N 行」这种算法是**错的**，不要用。

准确的说法：12 个零覆盖资产里，现在有 3 个**各有一份契约检查**——

- `install-agentq.sh`（2,755 行）：失败契约 **15 例**（`smoke/11` 自报 `cases=15`）。
  **成功路径仍是零覆盖**，而成功路径才是它 2,755 行里的绝大部分。
- `client/windows/agentq.ps1`（**2,327** 行，本轮 A18 新增 121 行）：本地参数契约 **40 例**（`smoke/12`
  自报 `cases=40`，pwsh 下）。**远端交互、传输、重试、恢复全部仍未覆盖**，A18 新加的凭据路径
  也只有**选项构造**被断言，真机行为未验。

- `windows-git-bash/install-agentq.ps1`（2,881 行）：参数契约 + 平台闸门 6 例。
  **这台机器上不可达的 staging/ACL/事务路径仍是零覆盖**，且已实测确认不可达
  （任何参数组合都死在第一条语句上），所以这一份契约检查的覆盖面比前两个更窄。

仍然**没有任何检查执行过**的资产（"执行过" = 行为执行或源码断言；只有 `01` 的
语法/结构解析不算）。按行数：`client/unix/sshp`（1,190）、`sshp.ps1`（1,092）、
`agentq-launcher.ps1`（430）、`agentq-start-daemon.ps1`（260）、
`client/unix/install-client.sh`（251）、`agentq-durable-move.ps1`（118），
4 个 `.bash`/`.cmd` 薄启动器（42），2 个 `.plist` + 2 个 `pueue.yml` +
1 个 `.service`（110），以及 `unix/agentq`（5，只是转发 shim）。
合计 **3,498 行 / 25,354 行 = 13.8%**（2026-09-30 重算。**分子仍未变**——那 9 个资产
至今没被改过；分母从 24,285 一路长到 25,354，全是**已被覆盖**的资产在长大：
`agentq-server` 4,727→4,937（×2，canonical pair；末次是折叠逐条重复的 jq，+127 行）、
`client/unix/agentq` 3,293→3,523、`client/windows/agentq.ps1` 2,074→2,327（A18：两端各 +203 / +121 行）。
所以比例略降而债务未减。别再引用旧的 25.9%——那个分母是改动前的
24,180，且当时 `install-agentq.ps1` 还没有 `13`）。
