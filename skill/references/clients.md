# 调用端与终端

本文件是 `SKILL.md` 拆分出来的完整原文：本地客户端的环境变量、配置文件、凭据与探针缓存、Windows 终端差异、以及 `sshp` 交互链路的契约。**日常操作读 `SKILL.md` 即可**；排查某一格行为、或要改客户端时再读这里。安装步骤见 `install.md`。

- 每个本地登录用户分别安装客户端、保存 SSH 配置和设置默认主机；不要把一个用户的 `~/.ssh`、`~/.config/agentq/config` 或 `~/.local/bin` 当作其他用户的配置。AgentQ 只使用 SSH 认证实际选择的远端登录用户；同一 IP 的不同用户名是不同的服务、任务和会话域。
- macOS、Linux 和 WSL 使用 `assets/client/unix/install-client.sh`。它将 POSIX `agentq` 与 `sshp` 安装到当前用户的 `~/.local/bin`；二者是 `/bin/sh` 脚本，可从 `sh`、`bash`、`zsh` 或其他 POSIX shell 直接执行。使用 `install-client.sh --check [--bin-dir <directory>]` 可只读核对目标目录中的两个客户端是否逐字节匹配 canonical 资产：匹配返回 `0`，缺失或漂移返回 `1`，不安全路径或协议参数错误返回 `2`；该模式不会创建、替换或删除文件。安装器不修改 shell 启动文件；若该目录不在 PATH，先以绝对路径调用或在用户已确认后更新其 shell 配置。**该默认目标 `~/.local/bin/agentq` 与服务端 wrapper 同路径**：在同时运行 AgentQ 服务端的主机上，安装器会**拒绝**覆盖那个 wrapper 并以 `2` 退出（实测 2026-10-09：此前是静默覆盖、退 0，之后远端 `agentq_run` 执行到客户端自身、所有协议调用以 `2` 与空输出失败）；这类主机要用 `--bin-dir` 把客户端装到别的目录，例如 `--bin-dir ~/.local/agentq-client`。
- POSIX `agentq` 客户端需要本机 `jq`（或 `AGENTQ_JQ` 指向可执行解析器）来验证成功响应；缺少解析器时必须显式失败，不能把未校验的 stdout 当成成功结果。
- **可执行路径必须是「普通文件」，且必须真的起得来**：`AGENTQ_SSH`、`AGENTQ_JQ`（POSIX `agentq`）与 `SSHP_SSH`（POSIX `sshp`）指向**目录**时，两份客户端都退 `2` 并报 `<变量> must be a regular file: <路径>`，**不发起任何 SSH 调用**。这一条是必需的，因为 POSIX 的 `test -x` 测的是**搜索位**、而目录天然带有它——修复前目录会通过守卫，随后以 `126`（契约外退出码）失败且**零输出**；`AGENTQ_JQ` 指向目录时还会把**合法**响应报成 `invalid JSON response`、把本地配置错误指向服务端（实测 2026-10-27）。指向**符号链接**仍被接受（`-f` 跟随链接；`/usr/local/bin/ssh` 常常就是链接），指向非可执行的普通文件仍报 `is not executable`。
  **`-x` 只是权限，不是承诺**：一个 0755 的普通文件仍可能根本执行不了——纯文本文件、解释器不存在的脚本、shebang 行以 CR 结尾的脚本（在 Windows 上编辑过的文件）。这三类都会让 **shell**（不是 ssh、不是 jq）在每次调用时报 `126`/`127`。修复前 POSIX 客户端对它们：`AGENTQ_SSH` 报「无法探测远端平台，请设 `AGENTQ_REMOTE_PLATFORM`」（这个建议救不了它），或（已设该变量时）以 `126/127` 退出且**零输出**；`submit`/`cancel`/`remove` 同样零输出退出；`AGENTQ_JQ` 则把**合法**响应报成 `invalid JSON response` 并泄漏 shell 自己的那行诊断（实测 2026-10-30）。
  修法是**只在这条已经失败的调用上**做一次真实启动探针：带 `-V` 跑一次（ssh 不建连接，jq 打印版本），**只有** shell 的 `126/127` 才判定为本地启动失败，退 `2` 报 `<变量> cannot be launched: <路径>`。其它任何退出码都意味着文件**确实跑起来了**，因此远端命令自己退 `126/127`（例如远端缺 `agentq-server`）仍然照常按远端故障报告。POSIX 没有「exec(2) 会成功吗」的原语，四种廉价判别法都已实测失效（EXIT trap 哨兵在 dash 上会跑、在 sh/bash/zsh 上不会；`set -e` 加哨兵无法区分合法退 255 的 wrapper；重定向在 exec 尝试之前生效，shell 自己的诊断无法与子进程的分离；纯按退出码判定会把**远端**的 126/127 一并误判成本地）。**边界**：一个对 `-V` 答 `126/127`、却在真实调用上正常的 wrapper 会被拒绝——但只在一次**已经失败**的调用上，且会点名变量与路径；真实的 OpenSSH 与 jq 都退 `0`。只有显式设置的环境变量才做这个探针；由 `PATH` 解析到的 `ssh` 与 Windows 孪生一样不探。
  服务端的 `require_executable` 遵循同一规则（目录 → `required executable must be a regular file` + `reason=protocol_error`）。**Windows 客户端额外做一次真实启动探针**（`agentq.ps1` 自 2026-10-21、`sshp.ps1` 自 2026-10-30）：Windows 没有 exec 位，唯一能回答的是「这个文件起得来吗」，所以它用 `ProcessStartInfo`（`UseShellExecute = $false`）带 `-V` 启动一次，起不来就退 `2` 报 `<变量> cannot be launched: <路径>`，**不把本地配置错误报成远端故障**。这条对 `SSHP_SSH` 曾经缺失（实测 2026-10-30：退 `1` 并报 `remote dependency probe failed`，而 POSIX 孪生退 `2` 点名文件）；`UseShellExecute = $false` 也意味着它**不会**像 pwsh 的 `&` 那样在 macOS 上把文件交给 LaunchServices 打开。
- **Windows 目标的远端终端不止一种（2026-09-22 实测）。**
Windows 上 sshd 用 `<DefaultShell> <DefaultShellCommandOption> "<cmd>"` 解析客户端发来的
命令，而 `DefaultShell` 可以是 `cmd.exe`、`powershell.exe` 或 Git Bash——**每一种都是
不同的解析器**，三者的命令行长度上限不同（实测 `cmd.exe` 8,155、`powershell.exe` 8,125、
Git Bash 8,176），且
`DefaultShell=powershell.exe` 时**外层 PowerShell 会把内层程序的非零退出码压平为 1**
（实测范围是**全部协议码**：`2/3/4/5/6/42/124` 一律变 1，只有 0/1 保留），
使 `42-45`（launcher 契约）与客户端依赖 `3/4/5/6` 的恢复判定都失真。这两点**两条路径都已修**：
**探针路径**不再把脚本放进命令行，改经 stdin 喂给 `powershell.exe … -Command -`（两端命令行
固定 76 字符），退出码由 stdout 末尾的 `agentq-exit:<code>` 带外传递；`sshp.ps1` 的 Windows
探针/安装同型（0.1.16 起，此前 23,210/23,882 字符的 `-EncodedCommand` 会被 sshd **截断**而非
拒绝，表现为误导性的「probe failed」；它的**会话**因 `-tt` 下 stdin 归多路复用器，走的是探针
预解析路径 + 短 attach 命令的两段式，见 [`install.md`](install.md) 的 `sshp` 一节——**两份 `sshp` 客户端的会话命令形态
在 2026-10-29 之前不同，现已统一为同一条 `-EncodedCommand`**）；**操作路径**
（launcher wrapper）把同一个 token 写到 **stderr**——客户端本就捕获远端 stderr（服务端
`reason=` 同路），所以无需在 stdin（被 base64 payload 占）与 stdout（是 JSON 响应本身）
之间取舍。两份客户端各自在**仅限 windows 目标**时以该 token 覆盖 ssh 退出码；unix 目标不发它。
排查 Windows 目标时，先确认该机 `HKLM\SOFTWARE\OpenSSH` 的 `DefaultShell` 是哪一个——
三种的行为不一样。**三列（Git Bash / `cmd.exe` / `powershell.exe`）现在都有真机实测**：
Git Bash 列见 2026-09-21，`cmd.exe` 列见 2026-09-25（那台机器 `DefaultShell` **未设置**，
实测内层 `2`/`5`/`124`/`42` 经 ssh **原样传回**，所以压平问题在它上面不成立），
`powershell.exe` 列见 2026-10-01（在专用测试机上真造出该配置并证明生效后，实测压平范围
是**原生子进程**的非零退出码、客户端恢复逻辑依赖的 `3/4/5/6` 全部失真），**修复后
`3/5/2` 全部恢复**。判断某台 Windows 目标会不会被压平，先读该机 `HKLM\SOFTWARE\OpenSSH`
的 `DefaultShell`。详见 `docs/PLAN.md` A5。

**另一条 Windows 专属机制（2026-10-02 实测）：探针体必须由 `-Command -` 真正执行。**
`powershell.exe -Command -` 把 stdin 当**交互式输入**读：一行若**开启一个块**
（`if {`/`function {`/`try {`）就进入续行，缓冲的语句**只在遇到空行时才执行**，
**EOF 时未终止的缓冲被静默丢弃**（rc=0、无输出、什么都没执行）。Windows 客户端的协议探针
是一段**多行 here-string**，若末尾没有那个空行，**整个探针体被丢掉**、对任何 Windows 目标
都报 `native Windows AgentQ service protocol probe failed`（指向部署而非客户端）。平台探针与
POSIX 客户端的探针都是单行、不受影响，所以**只有「Windows 客户端 → Windows 目标」这一组合**
会踩到。客户端已在 `Add-ProbeExitToken` 末尾追加该空行（见 `docs/PLAN.md` A20）。

**第三条 Windows 专属机制（2026-10-02）：PowerShell 5.1 会把交给 ssh 的脚本按词切开。**
两个 Windows 客户端都用 `& $exe @argv`（splat 数组）把一段多行 shell 脚本作为**单个参数**
送给 ssh，而 PowerShell 5.1 的 `&` 调用运算符只给**含空格**的参数外包一层双引号、**不转义
参数内部已有的双引号**——于是脚本在 ssh 看到之前就被词分割（实测模型下 `sshp.ps1` 的探针
从 1 个参数裂成 17 个），远端报错会**指向部署而不指向客户端**。现在两个客户端都改用
**base64 `printf %s <b64> | base64 -d | sh`** 把脚本交给 ssh（base64 字母表无需引号，命令行
不受本地 PowerShell 影响；`sh` 在管道末位所以退出码仍是脚本的）。pwsh 7 **不复现**该缺陷，
所以它只在真 PS 5.1（`agentq.cmd`/`sshp.cmd` 都经 `powershell.exe` 调用）上才可达。**一处刻意例外**：`sshp.ps1` 启动交互会话的那条命令（`exec tmux/screen/zellij`）**不**走 base64——该通道让脚本的 stdin 变成**管道**，而多路复用器要求 stdin 是 tty（实测：pty 下 `stdin=tty` 能起 screen，`stdin=pipe` 一律 `Must be connected to a terminal.`）。它裸着安全的前提是**脚本里一个双引号都没有**，所以往那段脚本里加一个 `"` 会让它重新被词分割。见 `docs/PLAN.md` A21。

原生 Windows 使用 `assets/client/windows/install-client.ps1`。它把 `agentq.ps1`、`sshp.ps1`、`agentq.cmd` 和 `sshp.cmd` 安装到当前 Windows 登录用户的 `.local\bin`，默认加入该用户 PATH。安装器和 PowerShell 客户端通过当前进程 SID 查询 `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList`，不会信任被 Git Bash、OpenSSH、`runas` 或旧会话污染的 `USERPROFILE`/`HOME`；Windows 用户需要新开终端后再按名称调用；`-SkipPathUpdate` 仅在用户明确不希望修改 PATH 时使用。使用 `install-client.ps1 -Check [-DestinationDirectory <directory>]` 可只读核对 `agentq`/`sshp` 的 `.ps1`、`.cmd` 以及检测到 Git Bash 时的无扩展名 shim 是否逐字节匹配 canonical 资产：匹配返回 `0`，缺失或漂移返回 `1`，不安全 reparse 路径返回 `2`；该模式不会创建、替换、删除文件或更新 PATH。
- Windows CMD 使用 `agentq.cmd` 和 `sshp.cmd`；PowerShell 可调用同目录的 `.ps1` 文件，或在新终端中直接调用 `agentq` / `sshp`；Windows Git Bash 使用安装器生成的无扩展名 `agentq` / `sshp` 启动器。三个入口都读取 `%USERPROFILE%\.config\agentq\config`；Git Bash 的 `$HOME` 不参与 Windows 默认配置定位。该启动器显式关闭 MSYS 路径改写，再调用同目录的 PowerShell 客户端，因而 `/home/...`、`/c/...` 和远端命令参数不会被本机 Git Bash 篡改；安装器也会从当前 PATH、注册表和常见目录发现自定义或便携 Git for Windows。
- Windows 原生 `agentq` 客户端读取 `AGENTQ_HOST` 配置文件时最多接受 4096 字节，并按 UTF-8、UTF-8 BOM 或 UTF-16 BOM 解码；超限、坏编码、目录、文件或其路径链中的 reparse 路径会显式失败，缺失配置仍表示未配置默认主机。
- 两平台都接受带 UTF-8 BOM（`EF BB BF`）的 `AGENTQ_HOST` 配置——POSIX 端在解析行首时剥掉 BOM，与 Windows 端的解码对齐（实测 2026-11-04）；文件是 UTF-16 时 POSIX（`/bin/sh` 无 UTF-16 解码器的平台边界）会显式拒绝并提示另存为 UTF-8，Windows 端仍按文档解码。
- 配置的字节契约：两平台都按 `\r?\n` 切行（CRLF 与 LF 等价）、都拒绝含 NUL 字节的文件（`text syntax is required`）——POSIX 一直如此，Windows 自 0.1.19 起对齐；主机解析不依赖调用方的 locale（POSIX 端钉 `LC_ALL=C`，实测同一文件在 `LC_ALL=C` 与 UTF-8 locale 下解析出同一主机）。**非法 UTF-8 是平台能力边界**：Windows 的 .NET 解码器直接拒收，POSIX 逐字节处理、不作校验，同一份含非法字节的配置在两侧行为不同。
- Windows `sshp` 的临时日志、标准输出和错误输出文件必须是普通非 reparse 文件，且其父级路径链也不得包含 reparse 组件；不安全路径会显式失败并保留原目标。
- Windows `agentq` 与 `sshp` 读取临时日志、标准输出和错误输出时，先用 `Get-Item -Force` 观察路径；真正缺失返回空文本，目录、叶级或断裂链接、父级或更深祖先 reparse 路径必须经过完整 non-reparse 文件路径校验并显式失败，不得用 `Test-Path` 把不安全条目静默归类为缺失。
- Windows `agentq` 与 `sshp` 清理临时文件时，先用 `Get-Item -Force` 观察路径；真正缺失保持安全 no-op，目录、叶级或断裂链接、父级或更深祖先 reparse 路径必须经过完整 non-reparse 文件路径校验并拒绝删除，不得用 `Test-Path` 把不安全条目静默归类为缺失。
- macOS、Linux 与 WSL 的 Unix `agentq` 客户端读取 `AGENTQ_HOST` 配置时只接受非符号链接的普通文本文件，并只探测前 4097 字节；目录、FIFO、设备、套接字、符号链接和其他非普通文件会在读取前显式失败，包含 NUL 字节或超过 4096 字节也会显式失败。客户端会在有界读取前后记录并复核源文件及其路径链每个组件的 device/inode；观察到源路径链改变、符号链接或非普通文件时显式失败。缺失配置仍表示未配置默认主机，Unix 配置保持当前文本解析语义。
- Windows 目标的参数 Base64 载荷通过调用端 wrapper 和受保护 launcher 的兼容 stdin 入口按字节流读取（`.NET` stdin 流逐字节 `ReadByte`，实测：PS 5.1 在 OpenSSH 管道上的块读 `Console.In.Read(char[])` 一旦载荷超过约 4.5K 字符会**间歇性无限挂死**、约 8.6K 以上近乎必然，逐字节读在 53K 载荷实测 12/12 无挂死），编码载荷超过 1048576 字符会显式拒绝；该上限只保护参数输入，不限制已接受任务的完整输出。**三条 Windows 平台硬边界（实测 2026-10-14，专用测试机）**：① 单个参数超过约 32.5K 字符时 launcher 的进程环境写入会超 CreateProcess 环境块上限（32767），launcher 会显式拒绝（exit 2 + `reason=protocol_error`），不是静默截断；② 单个参数超过约 8.1K 字符时，任务经 `cmd.exe /c` 执行会被 cmd 的 8191 字符命令行上限**截断**（`pueue log` 报「命令行太长」）——这是 Windows/cmd 的限制，AgentQ 无法消除；需要传超大参数时改用文件承载（写入远端文件、任务里读取），不要把内容放进 argv。③ **`--stdin-script` 对 Windows 目标的上限只管到 Pueue 的「存储命令」长度，与前两条命令行边界不是一回事**：实测 2026-11-12（专用测试机，DefaultShell 是 **Git Bash**，不是 cmd）：Pueue 把命令**完整存下**（8256 字符的 `--stdin-script` 命令从 `pueue status --json` 原样读回），截断发生在 **pueued 执行**时，阈值是 8191 字符的存储命令（`cmd.exe` 的上限）——绕开 AgentQ 直接喂 Pueue 也复现：存储 8160 字符正确执行，8200 被切掉，而**任务照样 exit 0**（`printf %s <A×8160> | wc -c` 打印出一串 A 而不是计数）。经 AgentQ 路径的同一个悬崖：base64 8010 执行成功，8040 被切在引号中间（`unexpected EOF while looking for matching` + 一个单引号）。所以 cmd 目标与 Git Bash 目标**都受这一条约束**，与 DefaultShell 无关。0.1.30 起两份客户端对 Windows 目标的上限是 **7800 base64 字符**（解码包装固定占 156 字符，即使 Pueue 不加任何包装，8191 − 156 = 8035 已是上限，7800 留 235 给包装），并且对**普通 `submit -- <命令>`** 同样设防：目标解析为 windows 时，按 Pueue 的转义规则估出的存储命令超过 **8100** 字符即在本地退 `2`、**在发出任何载荷之前**拒绝——此前这种命令会被提交、随后在目标机上被截断而任务仍报成功。超大脚本请走文件承载；unix 目标不受此限。
- 输入的引号必须遵循当前本地终端：CMD 中命令参数里的 `&`、`|`、`<`、`>` 和 `^` 需要按 CMD 规则转义；PowerShell 使用 PowerShell 引号；Git Bash、bash 与 zsh 使用 POSIX Shell 引号。跨终端传递 Windows 原生命令时，始终将其 argv 放在 `-- cmd /c ...` 或 `-- powershell.exe -NoProfile -Command ...` 后。
- WSL 是独立的 Linux 用户环境，即使其 Windows 用户相同，也要使用 Unix 安装器和 WSL 自己的 `~/.config/agentq/config`。不要让 WSL 复用 Windows Git Bash 启动器。
- `sudo`、`su`、以“管理员身份运行”的 PowerShell/CMD，或切换 Windows 登录用户，都会进入另一个本地用户域；它们应各自安装客户端、拥有自己的 SSH 密钥和配置。不要把 `AGENTQ_CONFIG`、`AGENTQ_HOST` 或客户端目录做成所有用户共用的系统级设置，除非该共享是有意、已审计且密钥 ACL 合适的。
- 目标机只提供密码认证（没有可用密钥）时，客户端默认**连不上**：ssh 以 `BatchMode=yes` 运行，该选项让 `password` 与 `keyboard-interactive` 两种方法根本不会被选中。要改用密码，配置**三种来源之一**（按优先级）：`AGENTQ_ASKPASS` 指向一个打印密码的可执行程序（**推荐**——客户端只传程序名，从不读取或保存密码本身，因此它可以指向系统凭据助手）；`AGENTQ_PASSWORD` 直接给出密码（环境变量，**无法做权限校验，不受保护**）；`AGENTQ_PASSWORD_PROMPT=1` 让 ssh 在终端上提示（**仅 POSIX**，且必须有终端）。配置后客户端传 `BatchMode=no` 加 `NumberOfPasswordPrompts=1` 并经 askpass 取密码；**没配置时行为与从前逐字节相同**（失败快、绝不等待输入）。来源配置了但不可用（不存在／不可执行／符号链接／是目录／与另一来源同时设置）时客户端**拒绝运行**，不会静默退回密钥认证。密钥仍然先试，密码只是回落。**Windows 客户端只支持 `AGENTQ_ASKPASS`**，取值必须是**一个可执行文件的路径**——ssh 把整个值当作**单个文件名**执行，中间没有 shell、也不做分词，所以**不能带参数、不能加引号**，但**路径里的空格是合法的**（`C:\Program Files\...` 这种形态实测可用；判据是「整个值是不是一个存在的可执行文件」，不是「有没有空格」）。实测真机：`cmd.exe /c helper.cmd` 报 `ssh_askpass: exec(...): No such file or directory`；而指向一个带 shebang 的脚本可以正常执行。`AGENTQ_PASSWORD` 与 `AGENTQ_PASSWORD_PROMPT` 在该平台被明确拒绝——前者没有可挂靠的清理机制，后者会让 ssh 读控制台并在无控制台时**挂死**。**账户密码的登录成功路径已在真机验证（2026-09-29）**：POSIX 客户端经**真实账户密码**（不是口令私钥）在一台只提供密码、没有可用密钥的 macOS 主机上跑通完整协议（`submit`→`wait` 的 `Done.result=Success`→`logs` 回 `Darwin`→`remove`），Linux 目标同样跑通；Windows 客户端也已升级到 canonical 并在真机确认了守卫与 ACL。**经 Windows 客户端发起的端到端也已验证**（Windows → 那台只有密码的 macOS 主机：`wait` 退 0 + `Done.result=Success`、`logs` 回 `WIN-E2E-OK\nDarwin`、`remove` 回 `removed:true`）。**原生 Windows ssh 也已验证（2026-10-02）**：在一台专用 Windows 测试机上，客户端 PATH 解析到的是**原生** `C:\Program Files\OpenSSH\ssh.exe`（9.5p1，非 Git Bash 的 MSYS ssh），Windows 客户端经它连本机 Windows 目标、用 askpass 密码认证跑通完整协议（`submit`/`wait` `Success`/`logs`/`remove` 全 rc=0）。**Windows 上 `SSH_ASKPASS_REQUIRE=force` 是必需的**：Windows 没有 `DISPLAY`，缺了它 ssh 永不调用 askpass、退回读**控制台**的 `readpassphrase`，无控制台时**永久阻塞**；客户端已改为有来源时设 `force`、无来源时**显式清除**继承值（Git Bash 会导出 `SSH_ASKPASS`）。仍属边界的只有 `System32\OpenSSH\ssh.exe`（8.1p1，早于该变量）。本机（macOS 非 root 用户级 sshd）依旧验不了密码登录：读不到密码散列。凭据不得写进仓库、文档或日志。**主机密钥策略是刻意的边界**：三个客户端（`agentq`、`sshp` 的 POSIX 与 Windows 版本）都**不**设置 `StrictHostKeyChecking` 或 `UserKnownHostsFile`——OpenSSH 的默认行为与用户 `~/.ssh/config` 完全生效，AgentQ 不覆盖也不放宽；需要强校验的用户在自己的 SSH 配置里声明（`docs/PLAN.md` A28 记录为边界，不是缺陷）。
- 默认主机可由环境变量 `AGENTQ_HOST` 提供，或在当前用户的配置文件写入单行 `AGENTQ_HOST=<ssh-host>`：Windows 是 `%USERPROFILE%\.config\agentq\config`，macOS/Linux/WSL 是 `~/.config/agentq/config`。Windows PowerShell、CMD 与 Git Bash 映射到同一 Windows 用户目录；其他平台各自独立。**配置文件里出现多行时以最后一行为准**，且 **`AGENTQ_HOST=`（空值）也算一次赋值**——末尾留一行空值即表示「没有默认主机」（客户端退 `2`，不发起连接），而不是回退到上面那行的旧主机（实测 2026-10-27：两份客户端此前在这一点上答案相反，Windows 会继续连旧主机）。值里含空白（含尾随空格）的行**不算赋值**，被忽略。两份客户端对主机名的取值规则一致：`AGENTQ_HOST` 为**纯空白**视同未设置（回退到配置文件里的主机，而不是把空白串交给 ssh），最终主机名为空白时退 `2` `no SSH host configured; pass --host or set AGENTQ_HOST`、以连字符开头时退 `2` `SSH host must not begin with a hyphen`——两者都是**本地参数错误**，不发起任何 SSH 连接（不是 `255` 那样的可重试传输失败）。主机名**内部**的空白不被拒绝（交给 ssh；`sshp` 比这里更严格，是另一套契约）。空白集随 locale 变化：UTF-8 locale 下 `[[:space:]]` 与 .NET 一致地把 NBSP、U+3000 视作空白，`LC_ALL=C` 下不一致。
- **除 `AGENTQ_HOST` 外，所有 `AGENTQ_*` 环境变量的「是否设置」判据在两份客户端上一致：只有「空」算未设置，纯空白算已设置，进入各自的正常校验。** `AGENTQ_CONFIG`、`AGENTQ_REMOTE_PLATFORM`、`AGENTQ_SSH`、`AGENTQ_JQ`、`AGENTQ_ASKPASS`、`AGENTQ_PASSWORD`、`AGENTQ_PASSWORD_PROMPT`、`AGENTQ_PLATFORM_CACHE_DIR`、`AGENTQ_PLATFORM_PROBE_CACHE` 以及七个数值变量都遵循这一条；`AGENTQ_HOST` 是唯一例外（纯空白即未设置，见上一条）。POSIX 侧由 `[ -n ]` / `${VAR:-默认}` 天然如此；Windows 侧用 `IsNullOrEmpty`（**不是** `IsNullOrWhiteSpace`）。**这是一条实测过的孪生契约**：把「纯空白」当未设置会让同一个环境在两个平台上得到相反答案——最尖的一格是 `AGENTQ_CONFIG=' '`，POSIX 退 `2` 报「没有默认主机」，而把空白当未设置的 Windows 会去读**默认位置的配置**、连上它命名的主机（实测 2026-11-05，同一环境指向两台不同机器）；`AGENTQ_ASKPASS=' '` 同理（POSIX 拒绝这个畸形路径、Windows 静默退回密钥认证），`AGENTQ_SSH=' '`/`AGENTQ_REMOTE_PLATFORM=' '` 也各差一个「拒绝」与「走默认」。数值变量的这一格于 2026-11-04 先修，字符串变量于 2026-11-05 补齐；Windows 侧的空串 `VAR=` 仍表示未设置（与 sh 的 `FOO=` 一致），不是拒绝。**`sshp` 的 `SSHP_SSH`、`SSHP_RECONNECT_DELAY` 适用同一条规则**（同一轮同型修复；这两个变量**没有**任何「纯空白=未设置」的豁免）。
- `agentq` 和 `sshp` 会自动探测目标平台：`MINGW`、`MSYS`、`CYGWIN` 只表示 SSH 默认 shell 位于 Windows；客户端仍会用 UTF-16LE Base64 编码的原生 PowerShell probe 复核 Windows 服务入口和工具路径。这样 Git Bash 的 SSH PATH 不能误导 cmd、PowerShell 或计划任务的真实环境。除诊断已知异常外，不要手工设置 `AGENTQ_REMOTE_PLATFORM`。
- AgentQ 的 POSIX 与原生 Windows 客户端对只读平台和 Windows launcher 协议 probe 默认设置 30 秒命令级上限，可用 `AGENTQ_PLATFORM_PROBE_TIMEOUT` 传入正整数调整。超时返回退出码 `124` 并显式报告；Windows 客户端会终止 probe 进程树。不会把探测超时重试或降级为普通 SSH；该上限不作用于 submit、wait 或其他已提交任务的普通操作。
- 探测结果按主机缓存（0.1.11）：一次成功的平台判定（unix，或 windows 且 launcher 协议验证通过）写入 `~/.config/agentq/platform-cache/`（TTL 7 天），命中后**跳过两次探测**——重复调用同一主机不再各付 30 秒探测成本。`AGENTQ_REMOTE_PLATFORM` 显式指定仍最高优先；`AGENTQ_PLATFORM_PROBE_CACHE=off` 关闭（每次都探测）；`AGENTQ_PLATFORM_CACHE_DIR` 重定向缓存目录。**缓存没有失效路径**：命中即信任到 TTL 过期，所以目标机换平台/重装后要先手工处理——设 `AGENTQ_REMOTE_PLATFORM` 指定，或关掉缓存，或删掉 `platform-cache/` 下对应条目（缓存文件名是主机名的哈希，不必找具体是哪个，整个目录删掉即可）。缓存的 windows 判定会先过 launcher 协议探测、失败即 fail-closed；陈旧的 unix 判定则在响应校验上失败——两种都是显式报错，不会静默跑错。
- 客户端缺失时，先说明对应本地安装器和将写入的用户目录；只有用户已授权本机安装时才运行安装器。安装用户客户端不等于在远端部署 AgentQ 服务。
