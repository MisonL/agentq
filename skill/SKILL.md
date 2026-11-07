---
name: agentq
description: 将任意授权命令提交到已配置的远程主机并持久化跟踪进度、日志、结果、失败或取消。用户要求远程执行、后台执行、SSH 断线后继续、获取目标机任务进度或结果时使用；用户需要人类交互 SSH 会话保活和重连时使用随 Skill 提供的 sshp。本地调用端覆盖 Windows CMD、PowerShell、Git Bash 与 POSIX sh、bash、zsh；目标机支持 Windows、WSL、Linux、macOS；不在目标机运行 Codex。
---

# AgentQ Remote Queue

使用 `agentq` 通过 SSH 调用目标主机上的兼容 AgentQ 服务端。任务由远端队列托管；本机终端关闭或短暂断线后，已经提交的任务继续运行。

`sshp` 是另一条人类交互链路：它连接远端 `tmux`、`screen` 或 Zellij 会话，并在确认 OpenSSH 传输断开时重连。不要用 `sshp` 承载 AgentQ 任务，也不要用 AgentQ 模拟交互终端。首次缺少依赖的安装确认必须在本地交互终端中完成；无 TTY 时会明确拒绝，不会静默安装。

## 调用端与终端

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
预解析路径 + 短 attach 命令的两段式，见下文 `sshp` 一节——**两份 `sshp` 客户端的会话命令形态
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
- Windows 目标的参数 Base64 载荷通过调用端 wrapper 和受保护 launcher 的兼容 stdin 入口按字节流读取（`.NET` stdin 流逐字节 `ReadByte`，实测：PS 5.1 在 OpenSSH 管道上的块读 `Console.In.Read(char[])` 一旦载荷超过约 4.5K 字符会**间歇性无限挂死**、约 8.6K 以上近乎必然，逐字节读在 53K 载荷实测 12/12 无挂死），编码载荷超过 1048576 字符会显式拒绝；该上限只保护参数输入，不限制已接受任务的完整输出。**三条 Windows 平台硬边界（实测 2026-10-14，专用测试机）**：① 单个参数超过约 32.5K 字符时 launcher 的进程环境写入会超 CreateProcess 环境块上限（32767），launcher 会显式拒绝（exit 2 + `reason=protocol_error`），不是静默截断；② 单个参数超过约 8.1K 字符时，任务经 `cmd.exe /c` 执行会被 cmd 的 8191 字符命令行上限**截断**（`pueue log` 报「命令行太长」）——这是 Windows/cmd 的限制，AgentQ 无法消除；需要传超大参数时改用文件承载（写入远端文件、任务里读取），不要把内容放进 argv。③ **`--stdin-script` 对 Windows 目标的上限（20000 base64 字符 ≈ 15000 字节脚本）只考虑了 CreateProcess 命令行，没有考虑边界 ②**：DefaultShell 是 cmd 的目标上，超过 8.1K 的脚本仍会被任务执行层截断。该目标上超大脚本同样走文件承载；Git Bash / unix 目标不受此限。
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

## 发现与前置条件

- 调用 `agentq doctor` 检查默认主机；指定目标时使用 `agentq --host <ssh-host> doctor`。**`doctor` 不是只读的**：它先确保 Pueue 守护进程在运行，若未启动会尝试启动它（服务变更），成功路径还会改写 request record。对真实生产主机跑之前，先确认该机 `pueued` 已在运行，这样第一次请求就返回、永远走不到启动服务那一步。doctor 的 stderr 报告版本与服务形态（`agentq=`、`pueue=`、`pueued=`、平台服务行）——这些是**机器可读的 `key=value` 行**，逐行解析即得值；探针起不来或答不出时（0755 但 exec 失败：纯文本、解释器缺失、CRLF shebang；Linux 上 `systemctl`/`loginctl` 缺失或连不上 bus，或 `id -un` 解析不出用户名；Windows 上 `powershell.exe` 缺失或 `Get-ScheduledTask` 失败；macOS 上 `launchctl` 不认该服务且 `id -u` 起不来）值是 `unavailable`，**不会**把 shell/systemd/PowerShell 自己的诊断混进这一行，也不会把探针的非零退出当成 `doctor` 的退出码（实测 2026-10-30/31，覆盖 `pueue=`/`pueued=`、Linux 的 `systemd_user_service=`/`systemd_linger=`、Windows 的 `scheduled_task=`、macOS 的 `launchd_service=`/`launchd_domain=`）。注意 `systemd_user_service=` 的非零退出**不等于**无答案：按 systemd 的约定，`systemctl --user is-active` 把 `active`/`inactive`/`failed` 写到 stdout、对 inactive 单位退 3，此时该行仍是答案（`inactive`），只有无 stdout 才是 `unavailable`（本轮的环境没有真 systemd，这个 shape 由桩建模并实测：stdout 有答案 + 退 3 → 保留答案）。`scheduled_task=` 相反：`-ErrorAction Stop` 下失败的 cmdlet 把错误记录写到 stderr、stdout 为空，所以只有探针退 0 时该行才是 JSON，其余一律 `unavailable`（人读的告警作为独立行跟在后面，`2>/dev/null` 调用方读不到它）。stdout 的队列区默认是**紧凑摘要**（`{tasks: {...每任务 id/state/result/label...}, group, summary: true}`）；需要逐任务完整元数据时用 `doctor --full`，日常的队列概览更应直接用 `status --summary`。
- 默认目标由调用环境配置；优先在任务中明确使用 `--host <ssh-host>`，避免隐式选错主机。
- 目标机必须已经部署兼容的 AgentQ 服务端。Windows 客户端会先只读检查受保护的 `agentq-launcher.ps1` 是否存在且支持当前参数协议；发现旧/不完整部署时会明确要求升级，而不是把 PowerShell 的文件不存在错误暴露给调用端。若 `doctor` 报缺失或不可用，停止并报告原始错误；不要静默降级成普通 SSH 前台执行。
- `--workdir` 必须是目标主机认可的绝对工作目录。Windows Git Bash 可使用 `/c/Users/name/project` 或 `C:\Users\name\project`；提交前先确认目录存在。`cmd`、PowerShell、Git Bash 只是调用端，目标 Windows AgentQ 统一由 Git Bash 执行队列命令，因此命令本身应写成 Git Bash 可执行的 argv；要运行 Windows 原生命令时使用下一条规则。
- Windows 目标机的 AgentQ 服务在 Git Bash 中执行提交后的命令。守护进程启动器和受保护 launcher 会根据当前 Windows SID 重建 `HOME`、`USERPROFILE`、`APPDATA`、`LOCALAPPDATA`、`USER`、`USERNAME`、`TEMP` 和 `TMP`，因此从 CMD、PowerShell、Git Bash 或 SSH 非交互会话启动都不会继承另一个用户的目录。提交 Windows 原生命令时使用 `-- cmd /c <command>` 或 `-- powershell.exe -NoProfile -Command <command>`；不要把 CMD 或 PowerShell 引号拼进一个未经验证的大字符串。

## 新主机接入

- 先对新主机运行 `agentq --host <ssh-host> doctor`（注意 `doctor` 不是只读的，见「发现与前置条件」段）。
- 若服务端未部署，说明缺少兼容 AgentQ 服务端，并询问用户是否允许自动安装所需依赖和服务；收到明确确认前不得改变目标机。
- **本项目不支持跨版本互操作，这是刻意的决定，不是遗漏。** 服务端与客户端之间没有协议版本协商字段——`doctor` 的 `agentq=` 只是**信息行**，报告这台机上部署的是哪个 AgentQ 版本（用于发现「只升了一侧」这类部署漂移），它**不参与任何协商**；`pueue=`/`pueued=` 则是队列实现的版本。部署单元就是 `skill/assets/` 下那 23 个文件的同一版本；**不得只升级服务端或只升级客户端**，必须整体替换。若将来需要跨版本互操作，先加协商字段再谈。
- 服务端可以使用任意持久化队列实现，但远端受管入口必须保持本 Skill 的命令、JSON 和失败退出码契约。Unix 入口是 `~/.local/bin/agentq`；Windows 的客户端-facing 入口是受保护的 `C:\ProgramData\AgentQ\agentq-launcher.ps1`，由它再执行同目录的 `agentq`。
- 服务端部署完成后，先验证 `doctor`，再提交一个无副作用的短命令，并确认 `submit`、`status`、`logs` 与 `wait` 都符合协议。
- 使用随 Skill 提供的安装资产时，先将对应平台目录完整暂存到目标机，再运行安装器。Windows 使用 `assets/windows-git-bash/install-agentq.ps1`；Linux/macOS 使用 `assets/unix/install-agentq.sh`。安装器只在队列没有活动或非终态任务时更新；历史 `Done` 记录会随数据目录保留。Pueue 二进制必须通过内置 SHA-256 校验后才会启用。
- **非交互会话里装 macOS/Linux 服务端：`sudo -v` 需要 tty，直接跑会失败。** 预热的凭据（先 `sudo -S -v`）在安装器进程里**不被沿用**，实测仍报 `a terminal is required to read the password`；后台刷新时间戳的循环反而会把凭据提前用掉。可行做法是给安装器一个**只带 `-A` 的 sudo 包装**并配 `SUDO_ASKPASS`，安装结束**立即删除**（askpass 脚本含明文密码）：
  ```sh
  mkdir -p "$HOME/.aq-bootstrap" && chmod 700 "$HOME/.aq-bootstrap"
  printf '#!/bin/sh\nprintf "%%s\\n" "<password>"\n' > "$HOME/.aq-bootstrap/askpass"
  printf '#!/bin/sh\nexec /usr/bin/sudo -A "$@"\n'        > "$HOME/.aq-bootstrap/sudo"
  chmod 700 "$HOME/.aq-bootstrap/askpass" "$HOME/.aq-bootstrap/sudo"
  SUDO_ASKPASS="$HOME/.aq-bootstrap/askpass" PATH="$HOME/.aq-bootstrap:$PATH" sh ./install-agentq.sh
  rm -rf "$HOME/.aq-bootstrap"
  ```
  `sudo -A` 是必须的：仅 `export SUDO_ASKPASS` 对安装器内部的**裸 `sudo` 调用无效**，因为 sudoers 的 `env_reset` 会把它清掉。
- **目标机到 GitHub 慢或不稳时，不要重试下载，改用预置二进制通道。** `AGENTQ_PUEUE_SOURCE_DIR` 是安装器**设计好的**入口，不是绕过校验：它从该目录取 `pueue-<platform>` / `pueued-<platform>`（文件名必须是安装器内置的平台 asset 名），**用同一套内置 SHA-256 校验**，不符即 `sha256 mismatch for staged asset` 拒绝。所以离线/慢网安装是安全的。实测症状与判据：下载卡在 `curl: (16) Error in the HTTP2 framing layer`，或 `Operation timed out ... with N out of M bytes received`。
- **安装失败后先查残留再重试。** 失败可能留下 `$HOME/.agentq.maintenance.lock`（`pid` 文件格式为 `pid<TAB>身份`）。**确认 holder 已死**才能清理；`~/.agentq` 本体若从未创建，说明失败发生在事务之前，清理是安全的。不要用 `rm -rf` 直接扫掉——那会绕开安装器的陈旧锁判定。
- Windows Git Bash 安装器和启动脚本读取受管的 `pueue.yml` 与 `agentq-launcher.ps1` 模板时，按 UTF-8 或带 BOM 的 UTF-16 规则进行有界读取，模板超过 1048576 字节会显式拒绝，不会截断后继续渲染；安装器在接受 staging 根目录、staged 资产和既有二进制前会检查其完整路径链，安装器和启动脚本按当前 SID 解析的 `ProfileImagePath` 及其 profile 祖先也必须是普通非 reparse 目录，legacy 迁移/回滚启动脚本、Pueue 客户端、配置和 daemon binary 在连接探测或执行前也会检查完整路径链，`Start-PueueDaemon` 在调用 `powershell.exe -File` 前也会独立复核 startup path 的完整路径链，所有 Windows 安装器 Pueue connection probes 也会独立校验 client/config 路径链，维护锁与操作锁 helper 也会校验完整祖先路径链并保留缺失/容器语义，安装器加入当前进程 PATH 的目录也必须是普通非 reparse 目录，私有树 ACL helper 与凭据文件 helper 也会独立复核根目录/文件路径链，安装器写入的模板、二进制、状态/诊断临时文件及其目标的每个现有父级和祖先也必须是普通非 reparse 路径，不安全路径会显式拒绝。
- Windows Git Bash 启动脚本在健康查询前必须用 `Get-Item -Force` 观察受管的 `config\\pueue.yml`、`pueue.exe` 和 `pueued.exe`；真正缺失返回明确错误并退出 2，目录、叶级/断链/父级/更深祖先 reparse 路径必须由完整 non-reparse 普通文件路径校验显式拒绝，不得用 `Test-Path` 把不安全条目静默当作缺失。
- Windows 安装器、启动脚本、受保护 launcher、Git Bash 入口 resolver 以及原生 `agentq`/`sshp` 客户端解析当前 SID 的 `ProfileImagePath` 时，先用 `Get-Item -Force` 读取已观察项，再区分真正缺失、非目录和 reparse 路径；缺失或非目录保持 profile unavailable，目录项继续经过完整 non-reparse 路径链检查，不得用 `Test-Path` 把断链或其他 reparse 路径静默归类为缺失。
- Windows client installer 的 `Invoke-CanonicalClientCheck` 读取每个目标客户端时先用 `Get-Item -Force` 观察已存在项；真正缺失仍报告 mismatch，目录或其他非文件项保持 mismatch，观察到的文件、断链或其他 reparse 路径先经过完整 non-reparse 路径链检查，不得用 `Test-Path` 把不安全路径静默归类为缺失。
- Windows client installer 的 `Install-CommitSet` **先把每个客户端文件全部暂存，再统一提交**（成对原子性，`docs/PLAN.md` A28 W4）：逐件「暂存+替换」会在第二个文件失败时留下**新 `agentq` 配旧 `sshp`**，而这一对永远是被一起读的。读取源和目标时先用 `Get-Item -Force` 观察已存在项；真正缺失保持既有缺失或新建语义，目录保持非文件错误，观察到的文件、断链或其他 reparse 路径先经过完整 non-reparse 路径链检查，替换/移动分支使用已观察的目标项，不得用 `Test-Path` 静默绕过路径安全检查。提交阶段内部的失败无法在无事务文件系统上做到原子，但窗口从「剩余每个文件的拷贝+ACL」缩到相邻两次 `[File]` 调用。
- Windows client installer 的 `Resolve-GitBashPath` 对每个 launcher/runtime 候选先用 `Get-Item -Force` 观察；真正缺失或不完整的候选继续作为发现失败处理，但叶级、断链、父级或更深祖先 reparse 路径必须经过完整路径链校验并显式拒绝，不得用 `Test-Path` 把不安全候选静默跳过。
- Windows `agentq.ps1` 与 `sshp.ps1` 的 `Resolve-SshPath` 对环境变量或命令发现的 SSH 可执行文件先用 `Get-Item -Force` 观察；只有普通文件且所有现有父级/祖先均为非 reparse 目录才接受，缺失、目录、叶级/断链/父级/祖先级 reparse 路径必须显式失败，不得用 `Test-Path` 静默归类。
- Windows `agentq.ps1` 与 `sshp.ps1` 在 macOS/Linux PowerShell Core 的 `/var`、`/tmp` 到 `/private` 别名归一化中，必须用 `Get-Item -Force` 观察别名目标并确认其为目录；不得用 `Test-Path` 绕过该文件路径身份检查。
- Windows Git Bash 安装器的 `Test-NonReparseFilePath` 在 macOS/Linux PowerShell Core 的 `/var`、`/tmp` 到 `/private` 别名归一化中，也必须用 `Get-Item -Force` 观察别名目标并确认其为目录；不得用 `Test-Path` 绕过该文件路径身份检查。
- Windows `sshp.ps1` 内嵌的远端 `Resolve-RemoteApplication` 对 `Get-Command` 发现的命令路径和候选路径先用 `Get-Item -Force` 观察；真正缺失继续作为发现失败处理，已观察到的目录、叶级/断链/父级/祖先级 reparse 路径必须经过完整 non-reparse 文件路径校验并显式拒绝，不得用 `Test-Path` 静默跳过。
- POSIX `sshp` 连接 Windows 时内嵌的 `Resolve-RemoteUserEnvironment` 对当前 SID 的 `ProfileImagePath` 先用 `Get-Item -Force` 区分真正缺失、非目录和目录 reparse 路径，再经过完整 non-reparse profile 路径链校验；叶级、断链、父级或更深祖先 reparse 路径必须显式拒绝，不得用 `Test-Path` 静默归类为 profile unavailable。
- POSIX `sshp` 连接 Windows 时内嵌的 `Resolve-RemoteApplication` 对 `Get-Command` 发现的命令路径和候选路径先用 `Get-Item -Force` 观察；真正缺失继续作为发现失败处理，目录、叶级/断链/父级/祖先级 reparse 路径必须经过完整 non-reparse 文件路径校验并显式拒绝，不得用 `Test-Path` 静默跳过。
- POSIX AgentQ 服务端在 Git Bash 上解析当前 SID 的 `ProfileImagePath` 时先用 `Get-Item -Force` 区分真正缺失、非目录和目录 reparse 路径，再经过完整 non-reparse profile 路径链校验；叶级、断链、父级或更深祖先 reparse 路径必须显式拒绝，不得用 `Test-Path` 静默归类为 profile unavailable。
- Windows `agentq.ps1` 内嵌的远端协议探针对 `C:\ProgramData\AgentQ\agentq-launcher.ps1` 先用 `Get-Item -Force` 区分真正缺失与已存在条目；目录、叶级/断链/父级/祖先级 reparse 路径必须由完整 non-reparse 文件路径校验显式判为无效，不得用 `Test-Path` 静默归类。
- POSIX `agentq` 内嵌的 Windows 远端协议探针对 `C:\ProgramData\AgentQ\agentq-launcher.ps1` 先用 `Get-Item -Force` 区分真正缺失与已存在条目；目录、叶级/断链/父级/祖先级 reparse 路径必须由完整 non-reparse 文件路径校验显式判为无效，不得用 `Test-Path` 静默归类。
- Windows Git Bash 受保护 `agentq-launcher.ps1` 在执行前对 server 与 Git Bash launcher 路径先用 `Get-Item -Force` 观察；只有普通文件且全部父级/祖先为非 reparse 目录才接受，缺失、目录、叶级/断链/父级/祖先级 reparse 路径必须显式失败，不得用 `Test-Path` 静默跳过。
- Windows 安装器的 `Get-PrivateTreeItems` 先用 `Get-Item -Force` 读取根项，再区分真正缺失、非目录和目录 reparse 路径；目录根仍需经过完整 non-reparse 路径链检查，`Set-PrivateTreeAcl` 只能在该检查通过后枚举和修改树项。
- Windows 安装器的 `Assert-NonReparseDirectory` 先用 `Get-Item -Force` 读取 Pueue 数据或证书目录，再区分真正缺失、非目录和目录 reparse 路径；目录项继续经过完整 non-reparse 路径链检查。
- Windows 安装器的 `Assert-PueueCredentialFile` 先用 `Get-Item -Force` 读取 credential 项，再区分真正缺失、目录和文件 reparse 路径；文件项继续经过完整 non-reparse 路径链检查后才校验长度。
- Windows 安装器读取 Pueue group、health、status 及 smoke 响应临时文件身份时，各调用点先用 `Get-Item -Force` 区分真正缺失与已存在条目；目录、叶级/断链/父级/祖先级 reparse 路径必须继续经过完整 non-reparse 文件校验并显式失败，不得用 `Test-Path` 静默归类为缺失。
- Windows 安装器 `Invoke-AgentQLauncherSmoke` 在执行 launcher 前先用 `Get-Item -Force` 观察路径；真正缺失保留缺失语义，目录、叶级/断链/父级/祖先级 reparse 路径必须经过完整 non-reparse 文件校验并显式失败，不得用 `Test-Path` 静默跳过。
- Windows 安装器的 `Get-ManagedPueueProcesses` 在进程枚举和路径比较前也会复核 daemon path 的完整路径链；daemon 文件尚未生成时允许安全缺失路径，叶、父或更深祖先 reparse 路径会显式拒绝。
- Windows 安装器的 `Stop-PueueDaemon` 在连接探测和进程枚举前也会复核 daemon path 的完整路径链，并保留安全缺失路径语义。
- Windows 安装器的 `Set-AgentQStartupTask` 在创建计划任务参数前也会复核 startup path 的完整路径链；安全缺失路径仍可构造定义，reparse 路径会显式拒绝。
- Windows 安装器的 `Set-PrivatePathAcl` 在读取和写入 ACL 前也会复核目标项及其完整路径链，缺失或 reparse 路径会显式拒绝。
- Windows 安装器的 `Get-AgentQInstallerFileIdentity` 在读取文件元数据和哈希前也会复核完整路径链，不为缺失或 reparse 路径生成身份。
- Windows 安装器的 `Assert-Sha256` 在计算和比较文件哈希前也会复核完整路径链，缺失或 reparse 路径会显式拒绝。
- Windows 安装器 `Add-CurrentProcessPathEntry` 使用强制项读取 PATH 候选；真正缺失和普通文件仍保持既有 no-op/忽略语义，但断裂或其他 reparse 路径不会因 `Test-Path` 返回 false 而静默跳过安全校验。
- Windows 安装器 transaction 的 backup、staging 和 failed-root 清理即使目标缺失也会调用安全目录 helper；断裂或其他 reparse 路径不会因 `Test-Path` 返回 false 而被静默遗留。
- Windows 安装器的 `Restore-LegacyDaemon` 使用强制项读取识别 legacy 配置、客户端和可选启动路径；断裂或其他 reparse 路径会进入完整路径链校验，不会因 `Test-Path` 返回 false 而静默跳过恢复。
- Windows 安装器的 `Restore-MovedLegacyArtifacts` 使用强制项读取回滚 destination/source；真正缺失保持既有缺失语义，目录、叶级/断链/父级/祖先级 reparse 路径必须经过完整 artifact 路径链校验并显式拒绝，不得用 `Test-Path` 静默跳过恢复。
- Windows 安装器 legacy migration 使用强制项读取枚举待迁移 artifact，并在 `Move-LegacyArtifact` 入口复核源和目标完整路径链；断裂或其他 reparse 源路径不会被静默过滤或移动。
- Windows 安装器 `Copy-AgentQData` 使用强制项读取源目录；真正缺失仍是安全 no-op，但断裂或其他 reparse 源路径不会因 `Test-Path` 返回 false 而静默跳过数据复制。
- Windows 安装器 `Wait-ForAgentQOperationLock` 使用强制项读取识别锁目录；断裂或其他 reparse 锁不会因 `Test-Path` 返回 false 而被当作不存在并放行。
- Windows 安装器安全 transaction cleanup 使用强制项读取确认删除后的路径确实不存在；删除后被替换为断裂或其他 reparse 路径时不会误报清理成功。
- Windows 安装器 `Copy-VerifiedPueueBinary` 使用强制项读取 staged/existing binary 来源；断裂或其他 reparse 来源不会因 `Test-Path` 返回 false 而被静默 fallback 或覆盖。
- Windows 安装器 `Restore-Transaction` 使用强制项读取 candidate/failed/backup/restored root；断裂或其他 reparse 路径不会被 rollback 当作不存在而静默继续。
- Windows 安装器主流程使用强制项读取 existing root、legacy config 与 transaction/legacy-backup 路径；断裂或其他 reparse 路径不会因 `Test-Path` 返回 false 而绕过既有路径链校验或冲突检查。
- macOS 无 GUI 安装使用系统 LaunchDaemon：安装器在交互式 SSH 中请求 sudo，将带 `UserName`、`HOME` 和 `WorkingDirectory` 的 `com.agentq.pueued.plist` 安装到 `/Library/LaunchDaemons`，以目标用户身份运行 Pueued，并在 `system/com.agentq.pueued` 中 bootstrap/kickstart。旧 `~/Library/LaunchAgents/com.agentq.pueued.plist` 只在确认队列没有活动或非终态任务后停用并保留为 `com.agentq.pueued.plist.agentq-disabled.*` 备份（原名保留在前缀里），避免 GUI 登录产生重复服务；**安装期的 sudo 密码**只在 sudo 提示符中输入，不写入命令、环境变量或日志。（这是 sudo 的密码，与下面 ssh 认证用的凭据是两回事。）迁移后用 `agentq --host <ssh-host> doctor` 验证，`doctor` 会报告实际使用的 `launchd_domain=system`。非交互 AgentQ 请求不会自动提示 sudo，也不会把服务降级为前台 SSH。
- Windows 安装器会从 Git for Windows 注册表、PATH 和常见安装目录解析 `bin/bash.exe` 与 `usr/bin/bash.exe`，将实际 runtime 路径渲染进 Pueue 配置，不依赖固定的默认安装目录；发现的 launcher/runtime 文件及其每个现有父级和祖先必须是普通非 reparse 路径。安装启动并建立 `agentq` group 后，会提交无副作用的 `printf` Shell smoke，检查 `wait`、任务结果和日志哨兵，删除 smoke 任务并再次确认没有活动或非终态任务；原有历史 `Done` 记录不会被删除。Pueue data/certificate 目录及其凭据文件的每个现有父级和祖先也必须是普通非 reparse 路径。
- Windows 安装器 `Resolve-GitBashPaths` 对每个 launcher/runtime 候选先做强制项读取；真正缺失或不完整的候选继续作为发现失败处理，但已观察到的 reparse 文件或父级路径会立即进入完整路径链校验并显式拒绝，不会被 `Test-Path` 误判为缺失后静默跳过。
- Windows 安装器 `Test-PueueConnection` 在允许缺失的路径链校验后再次强制读取 client/config；真正缺失仍返回不可连接，已观察到的 reparse 路径会显式拒绝，不会被 `Test-Path` 误判为缺失后静默跳过。
- Windows 安装器 `Require-Path` 使用强制项读取区分真正缺失和已存在的 reparse 路径；缺失仍报告缺失，已存在但不安全的路径进入完整路径链校验并显式拒绝。
- Windows 服务实例由执行安装的 Windows 登录用户持有：其计划任务与私有 ACL 都绑定该身份，启动时还会重新按 SID 注入该用户环境。当前 `C:\ProgramData\AgentQ` 部署一次只支持一个服务身份；另一 Windows SSH 用户不得直接重装或覆盖它。需要切换服务身份时，先确认队列为空、停止原服务并显式迁移或重新部署；这不是客户端的自动动作。
- 人类交互会话使用 `sshp <ssh-host> [session-name]`；先用 `sshp --check <ssh-host>` 只读检查可用的会话工具。Unix 目标优先使用 `tmux`，随后是 GNU screen 或 Zellij；Windows 目标只使用原生 `zellij.exe`。**Unix 目标的就绪判定只看多路复用器是否存在，不看 `uname -s`**：会话命令是 `exec tmux new-session -A -s '<name>'` 这类可移植 shell，一个有 tmux 的 FreeBSD/SunOS 主机同样可用（实测 2026-10-28：旧实现的白名单排在就绪判断之前，`FreeBSD + tmux` 被报成 127「去装 tmux」而该机已经装了）。两份客户端内嵌的探针与安装脚本**逐字节相同**——Unix 目标那一对与 Windows 目标那一对（解析器前奏、探针尾、安装尾三段）各自都是如此，由 `smoke/19` 逐字节 `cmp` 钉住；漂移是**检测**出来的，不是靠共享机制消除的（两份副本仍各自内嵌）。首个连接发现依赖缺失时才询问是否通过受支持的包管理器安装，`--check` 永不安装，安装期间的 SSH 中断也绝不自动重放。Windows 目标的会话是**两段式**：`--check`/连接时的探针在 `__SSHP_READY__` 之后额外上报解析到的 `zellij.exe` 路径，会话命令只携带 `attach --create`（命令行因此很短——远端 `DefaultShell` 的截断上限见上文）。该路径来自远端应答，含引号、换行、控制字符或超过 **1024 个 UTF-16 码元**时客户端**拒绝启动会话**而不是转义拼接（上界按码元计，与 Windows 侧的 `String.Length` 同一个数；**不是**字符数也不是字节数——同一个路径在不同 shell/locale 下这两个数都不同，实测 1220 字节的 CJK 路径是 420 码元）。**会话名本身有同一个上界**（1024 个码元，两份客户端同一个常量、`smoke/19` 从两侧资产读出并比对）：命令行上除路径之外的第二段用户输入，同样受 `DefaultShell` 截断约束；超限时两侧都退 `2` 并报 `session name must be at most 1024 characters`（2026-11-05 修，此前只有字符集守卫，实测 4000 字符的会话名构出 10986 字符的命令行、被 `powershell.exe` 的 8125 截断点静默砍掉尾部）。**两份客户端的会话命令现在是同一条**（2026-10-29 修）：都以探针报回的**绝对路径**构造 `powershell.exe … -EncodedCommand <UTF-16LE base64>` 作为 ssh 的**远端命令**发送，`smoke/19` 把两侧对同一输入的产物逐字节互比，并把该函数从 `sshp.ps1` 里按花括号深度抽出后用 pwsh 真跑一次作独立判据。此前 POSIX 侧是把 `exec zellij attach --create '<名字>'` 写进 FIFO 交给远端 shell——**它假定 `DefaultShell` 是 Git Bash**，而 OpenSSH 的默认是 `cmd.exe`（`exec` 不是它的命令），且**裸名字**会在探针刚用绝对路径绕开的陈旧 PATH 上再查一次（客户端自己的 winget 安装流程正好制造这个状态）。**会话本身的运行时从未在真机上验证过**（`-tt` 下该命令行是否被三种 `DefaultShell` 各自接受）——改的是构造，验的也是构造。**字符集守卫按 ASCII 逐字节判定，与主机 locale 无关**（2026-11-06 修：POSIX 侧曾写成方括号区间 `[A-Za-z]`，而区间按排序规则匹配——bash 在 `en_US.UTF-8` 下把重音拉丁字母（如 `café` 里的 `é`）也算进了 `A-Z`，于是同一 argv 一路走到远端，而 Windows 孪生退 `2`）。现在两侧都把字符集**逐个写出**，非法名一律退 `2` 并报 `session name must contain only letters, numbers, dots, underscores, or hyphens`。

## 协议

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

- 传给 `submit` 的目标命令必须置于 `--` 后；不要将自然语言 prompt 当成命令。**整段脚本不要再拼引号**：`submit --stdin-script` 把 stdin 读入、base64 编码为**单个 argv 参数**，远端按已文档化的 `printf %s <b64> | base64 -d | sh` 模式解码执行——base64 字母表无需引号，payload 逐字节穿越 ssh、远端 shell 与 Pueue 的 argv。脚本须为 **POSIX sh** 文本（远端解释器是 `sh`，Debian/Ubuntu 上是 dash——bashism 会在远端报错、任务失败）；unix 目标的单个 argv 元素受 `MAX_ARG_STRLEN`（128 KiB）约束（客户端上限 100000 个 base64 字符），Windows 目标的上限 20000 受 CreateProcess 32767 命令行约束（客户端上限 20000），而 **DefaultShell 为 cmd 的 Windows 目标实际可用量更小（约 8.1K，见上）**。超出上限的脚本先把文件放到目标机（scp/sshp 均可），再 `submit -- cat /path/script.sh | sh` 之类的方式执行。
- 命令词、选项记号与环境值的大小写折叠按 **ASCII** 判定，与主机 locale 无关（2026-11-07 修：POSIX 客户端曾用裸 `tr '[:upper:]' '[:lower:]'` 折叠，glibc 主机在 `tr_TR.UTF-8` 下不折叠 `I`，`SUBMIT` 被误报成 `unknown command: submIt`；现在 15 处折叠都钉 `LC_ALL=C`，`smoke/01` 的 `tr_fold` 规则守住拼写）。
- 所有成功响应为 JSON。`submit` 返回 `task_id`、`request_id` 和 `reused`。未显式提供 `--request-id` 时，本地客户端会生成一个；将该 ID 连同任务 ID 一起保留，便于恢复失去 SSH 响应的提交。**request id 的字符集是 16–128 个 ASCII 字母、数字、点、下划线或连字符**，两份客户端与服务端都按 ASCII 逐字节校验、与主机 locale 无关（2026-11-06 修：POSIX 客户端与服务端曾用方括号区间 `[A-Za-z0-9]`，在带排序规则的 locale 下会接受 `aaaaaaaaaaaaaaaaé`——服务端甚至退 `3` 而不是参数错误；现在三方对同一 argv 都退 `2` 并报 `request id must be 16-128 ASCII letters, numbers, dots, underscores, or hyphens`）。
- `status` 有三种形态：默认（无参）是全量装饰队列 `{tasks: {...}, group: {...}}`——每个任务带完整元数据，队列大时**很大**；`--summary` 是紧凑摘要 `{tasks: {"<id>": {"id", "state", "result"?, "label"}}, group, summary: true}`（**不**连接 request records，队列再大也只有每任务一行对象，回答「队列里有什么」）；`--task <id>` 返回 `{task: {...}}`，与 `logs`/`wait` 的单任务包装一致。**`--summary`（与 `doctor` 的默认摘要）里的 `label` 是 Pueue 的裸标签 `agentq:<request-id>`**，不是 `submit --label` 给的用户标签——因为摘要刻意不连接 request records；`status`（默认）、`status --task`、`logs`、`wait` 展示的才是用户标签。所以**不要把 `--summary`/`doctor` 里的标签复制去 `remove --label`**：`remove --label` 按**用户标签**精确匹配，而摘要里的每一行是**该任务自己的**裸标签 `agentq:<它的 request-id>`（各任务互不相同）。把裸标签交给 `remove --label` 通常匹配不到（退 `0` 返回 `[]`，看起来像成功）；而只要某个任务的 `--label` 恰好等于这串字符串，删掉的就是**那个**任务，不是摘要里的那一行（实测 2026-11-07）。**0.1.24 起用户标签不得以 `agentq:` 开头**（两份客户端与服务端在提交和批量删除处都拒绝，退 `2` `reason=protocol_error`），所以这种撞名只能来自旧版本创建的任务。轮询单任务用 `status --task <id>`，看全队列用 `--summary`；两者都经过与服务端形状核对的结构校验。**`status --task` 在任务身份歧义（同一数字 id 被多条活动 request record 认领）时与服务端 `wait`/`logs` 一致：输出 `{task_id, state: "unavailable"}` 并退 `6`，不返回 `{task: ...}`**（0.1.24 起；此前它退 `0` 并报 `Done`/`Result`，与 `wait` 的拒绝相反）。
- AgentQ/SSHP 调用端在 SSH 退出码为 `0` 后仍必须验证响应结构；malformed JSON、缺少协议字段或不符合操作契约的日志/状态不得被报告为成功。失败诊断只能保留操作名、错误类别和响应字节数等元数据，禁止回显或持久化原始响应内容。 **stdout 是数据通道、stderr 是诊断通道**：正常结果（JSON、版本行）走 stdout；错误消息与 `Usage:` banner 走 stderr——`--help` 是成功路径，其 usage 走 stdout。这条对两份 `agentq` 与两份 `sshp` 都成立（实测 2026-10-28：两份 Windows 客户端此前把错误路径的 usage 写在 stdout、stderr 留空，`out=$(client …)` 会把 banner 当数据收走）。OpenSSH `-E` 日志和子进程 stderr 同样只在最终调用端显示安全类别与字节数；原始内容只在受保护的短生命周期临时文件中供 transport 分类使用，并在操作结束时清理。SSHP 的交互链路也保留内部原文供分类，但最终用户输出只显示脱敏元数据。
- 用户标签（`submit --label`）**不得以 `agentq:` 开头**：那是 AgentQ 自己的 Pueue 标签前缀，两份客户端与服务端都会拒绝（退 `2` `reason=protocol_error`）。
- 同一个请求 ID 只能对应完全相同的工作目录、标签和命令。重复提交会返回原任务而不会重复入队；参数不同、已移除，或返回 `state: "ambiguous"` / `"removing"` 时必须停止，不得换新 ID 重试同一命令。
- 仅当本地 OpenSSH 的错误日志确认网络传输故障且提交以 `255` 退出时，客户端才会使用同一请求 ID 查询 `lookup` 并有限重试；远端命令的 `exit 255`、认证、主机密钥和配置错误会直接返回。重试耗尽时，运行 `agentq --host <host> lookup <request-id>` 恢复；`not_found` 表示服务端没有该请求记录，`not_started` 表示已有持久化请求记录但尚未观察到 Pueue 任务，两者都不是完成结果且只可用相同参数、相同请求 ID 重试。两者退出码均为 `3`；`ambiguous` 的退出码为 `4`，表示服务端无法安全判断，必须停止；`removing` 同样以 `4` 退出，表示删除意图已持久化但任务仍可见，不得重新提交或报告为已删除，只有再次明确执行 `remove` 才会继续删除；`removed` 的退出码为 `5`，表示该 ID 已移除、在 tombstone 保留期内**可以重复读到**（不是一次性消费）。
- `lookup`、`status`、`logs`、`wait` 与 `doctor` 在同样确认的传输故障下都会有限重试；前四者只读取、等待或完成已持久化的删除归档，绝不新建请求、取消任务或删除仍可见的任务。**但 `doctor` 不是只读的：它会先确保 Pueue 守护进程在运行，若守护进程未启动，会尝试启动它（macOS `launchctl kickstart`、Linux `systemctl --user start agentq-pueued.service`）——那是服务变更，成功路径还会改写 request record。** 要只读地探查一台主机，不要走 AgentQ 协议：直接 ssh 过去看 `~/.local/bin/agentq` 在不在、版本多少。`cancel` 与 `remove` 不自动重试，因为响应丢失后无法把副作用与失败安全地区分；先用 `status`、`logs` 或 `lookup` 重新确认。
- 处于删除恢复中的可见任务会在 `status`、`logs` 和 `wait` 的 `task.agentq.removal_pending` 中标为 `true`。若 Pueue 任务已不存在但 tombstone 尚未写入，后续安全读取会归档为 `removed`；读取操作不会删除仍可见的任务。
- `status`、`logs` 和 `wait` 返回任务状态。`logs` 的常规响应使用字符串字段 `output`；若响应包含 `output_encoding: "base64"`，应先解码 `output_base64`，因为目标任务输出并非 UTF-8。解析 JSON 后再呈现日志，避免把 JSON 转义的 `\n` 原样当日志内容展示。
- 正常的 `wait` 输出 `{task: ...}`；任务失败时，它自身也必须以非零退出码结束（**退出码 `1` 就是任务终态为 Failed**——`wait` 本身成功送达，失败的是任务；据此把「命令失败」与「传输/协议失败」分开报告）。检查退出码和 `task.status.Done.result`，两者均不能省略。`wait --timeout <seconds>`（或 `AGENTQ_WAIT_TIMEOUT`）给等待加**客户端预算**：预算内未到终态时客户端终止等待并以 `6` 退出（stderr 一行 `wait budget ... elapsed`）——语义就是既有的「无法确认终态」：任务**可能仍在跑**，之后用 `status --task <id>` 或 `logs` 继续观察，绝不要把超时当成任务失败。unix 目标上两份客户端都会把预算放进远端命令（`AGENTQ_WAIT_BUDGET=<预算>s`），远端 `timeout`（PATH 上存在时）随之结束服务端 wait——本地 ssh 被杀后不会在远端留下孤儿等待进程；没有 `timeout` 的目标（如 macOS 默认）退化为纯本地预算，孤儿进程会活到任务终态（它不持有 AgentQ 锁——服务端在 `pueue wait` 之前已放锁——占用的是一个进程与一条 pueued 连接）。若任务在等待期间被移除，`wait` 输出 `{task_id, state: "removed"}` 并以 `5` 退出；若服务端无法确认最终状态，输出 `{task_id, state: "unavailable"}` 并以 `6` 退出。这两种状态都不能报告为任务完成。`logs` 在任务身份歧义（无法安全判断该数字 id 归属哪个请求）时同样输出 `{task_id, state: "unavailable"}` 并以 `6` 退出。`logs` 还有另一种 unavailable 形态（2026-11-07 修）：任务**已到终态但其日志文件已不存在**（Pueue 的 `pueue log` 报 `Failed to get log file handle`）时，服务端输出 `{task_id, state: "unavailable"}` 并退 `6`，**不**把 Pueue 的诊断串当任务日志、也不退 `0`；仍在**排队**（Queued）的任务则正常返回 `{task: ...}`、`output` 为空字符串、退 `0`——「此刻还没日志」是它应有的状态，不是错误。判据是 `status`：只有带 `Done` 的任务才报不可用。**默认（编号）tail 还有第二种 Pueue 自述**（0.1.24 修）：日志某行含非 UTF-8 字节时，Pueue 只把**那一行**替换成 `Pueue: Failed to read line.` 并退 `0`——这与任务真的打印该行**逐字节不可区分**。服务端因此不匹配文本下结论，而是把 Pueue 的窗口与**原始文件的同一窗口**对照：不同则按 `--tail all` 的同一 base64 信封返回真实字节（`output: null`、`output_encoding: "base64"`、`output_base64`），相同则说明任务自己打印了该行，原样返回文本。
- 若任务在首次调用 `wait` 前已从 Pueue 消失，服务端先以同一 `task_id` 匹配活动的 `accepted`/`removing` request record；Pueue 状态可读且任务不可见时归档该 request 并返回 `removed`/`5`，状态不可读或任务仍可见但无法解析时返回 `unavailable`/`6`。仅当没有活动 request record 时才使用 tombstone 作为历史 `removed` 证据，并仍先确认 Pueue 中没有同数字的新任务；若多个活动 request record 共享同一数字 task id，必须报告歧义并停止，不能按数字 id 猜测或归档错误请求。多个历史 tombstone 可以共享已复用的数字 task id，因为它们都只证明该 id 曾被移除。
- `cancel` 成功返回 `action: "cancel_requested"` 与 `cancellation_requested_at`。若目标在确认时仍为 `Queued`，服务端使用 Pueue `remove`，并额外返回 `cancellation_mode: "queued_removed"`；随后 `wait` 会以 `state: "removed"`、退出码 `5` 表示已从队列移除，而不是报告任务成功。若返回 `state: "cancellation_pending"` 且退出码为 `4`，说明取消意图已持久化，但服务端无法确认 Pueue 是否接收到了取消；这不是取消成功，也不得自动重试。先读取 `status`、`logs` 或 `wait`。任务仍未结束时，只有在用户再次明确要求取消后才能再次调用 `cancel`；任务已结束而仍为 pending 时，必须报告取消结果无法确认。`status`、`logs` 和 `wait` 会在 `task.agentq` 中分别给出 `cancellation_requested_at` 或 `cancellation_pending_at`，以及 `cancellation_reason: "user_requested"`。最终结果仍以 `task.status.Done.result` 为准：`"Success"` 仍是成功，即使取消请求到达得太晚；带已确认取消字段且非成功的结果可报告为取消；没有该字段的 `Failed` 是普通命令失败，即使其退出码恰好为 `1`。不同系统底层取消结果可能是 `Killed` 或 `Failed`。

- 队列操作（`submit`、`cancel`、`remove` 等）在服务端是**独占**的：同一时刻只允许一个。拿不到锁的调用**不是立即失败**——它每 1 秒重试一次、最多 30 次，约 34 秒后才放弃，在 stderr 打印 `AgentQ operation is already in progress` 并**以 `2` 退出**（消息里附持锁者的 pid、启动身份与锁龄，可用 ssh 核实该进程是否还活着）。这个 `2` 是**可重试的瞬时状态**，不是参数错误：被拒绝的调用**零副作用**（无入队、无 request record、无 tombstone、无残留锁），用**同一个 request ID**、相同参数稍后重试即可，绝不能换新 ID。**`status`、`logs` 与 `doctor` 不参与这把锁**（0.1.11 起）：读命令在写操作进行中也能立即返回，代价是可能读到一次 mid-transition 的瞬时旧视图（prepared→accepted 的瞬间）——所有状态过滤器都容忍这一点，最坏情况是短暂滞后，不需要重试策略；维护锁的检查保留，`lookup` 因其自身会写归档仍持锁。
- `remove --label <label> --confirm` 按**用户标签**批量删除：匹配 `status` 展示的装饰标签（payload label），**不是** Pueue 的裸标签 `agentq:<request-id>`（而 `status --summary` 与 `doctor` 的默认摘要**只**能给出裸标签，见 `status` 那条；按标签清理时先从 `status` 默认形态或 `status --task` 读用户标签）。0.1.24 起 `remove --label` **拒绝以 `agentq:` 开头的标签**（退 `2` `reason=protocol_error`）——那是 AgentQ 的裸标签命名空间，不是用户标签。候选 id 取自**一次**队列快照，然后逐个走与单任务 `remove <id>` 完全相同的代码路径，整个批量持有一把操作锁（期间其它写操作照常排队）。输出是 JSON 数组，每项 `{"task_id":N,"removed":true}` 或 `{"task_id":N,"removed":false,"state":"failed"}`；**任一项失败（含身份歧义）不中断其余**，汇总里如实标注——有失败时整批退 `1`，全成（或零匹配，返回 `[]`）退 `0`。失败项用 `status --task <id>` 或单任务 `remove <id>` 复查，不要盲目重发整批。`--confirm` 是硬性要求（两份客户端与服务端都本地拒绝缺它的调用）。
- 退出码 `2` **不止表示参数错误**：服务端把它复用在三类情况上，客户端一律原样透传。**判断类别请读 `reason`，不要匹配消息文本**：服务端在每条以 `2` 退出的失败路径上，都会在 stderr 的消息之后多打一行 `<程序名>: reason=<class>`，`class` 取值只有三个——
  - `protocol_error`：参数/协议错误。改参数。
  - `lock_contention`：队列操作锁竞争（消息含 `already in progress`）。**可重试**，用**同一个 request ID**、相同参数稍后重试。
  - `task_not_running`：对**已经结束**的任务调用 `cancel`（消息含 `task is not running`）。无法取消，先读 `status`/`wait`，不要当参数错误处理。

  消息文本是给人看的、可能措辞调整；`reason` 是机读契约，改动它属于破坏性变更。两个客户端都会把这一行从 SSH 日志里取出来、以 `remote failure reason: <class>` 转发给调用端——**只**转发这个受控标识符（字符集限定小写字母与下划线），远端无法借它注入任意文本，SSH 日志的其余内容仍然只以脱敏元数据（类别 + 字节数）呈现。
- `cancel` 的"取消已确认"重放是**幂等**的：任务已从 Pueue 消失时（`queued_removed` 路径，或 running 目标已被 kill），再次 `cancel` 会返回 `{"action":"cancel_requested","cancellation_requested_at": <原时间>, "reused": true}`、退出 `0`，而**不是** `unknown AgentQ task id`/退出 `2`。重放保证绑定在同一任务实例上（Pueue 复用数字 task id，陈旧 marker 不会被误当成重放）。窗口有限：`wait`/`lookup` 读到终态时会清理该记录，此后对同一已消失的 id 再 `cancel` 会回到退出 `2` `unknown AgentQ task id`。**另有第二种退 `2` 的情形，2026-09-22 实测确认，不要混淆**：若该数字 id 此前被别的任务用过（Pueue 回收 removed 任务的 id），实例绑定检查曾取到最早那个实例的时间戳，重放在取消确认的当下就失败——这是**已修复的缺陷**（见 `docs/PLAN.md` A6，2026-09-22）：判据已改为「是否存在一个 `created_at` 为此值的实例用过这个 id」，修复后这类重放**应当成功**（`smoke/03` 两个方向都有用例）。因此退 `2` `unknown AgentQ task id` 并非只有一种来源——「终态已被读过、marker 已清理」之外，该 task id **从未存在**、或任务经普通 `remove` 移除（无 cancellation marker 可重放）时同样走到这一步（都经 `report_compact_task_failure` 的 rc=4 分支）。共同点是：**此时不存在任何可恢复的取消意图**，所以处置相同——先用 `status`/`lookup`/`wait` 重新确认，绝不据此重新提交。**任何情形下都不得据此重新提交任务**：先用 `status`/`lookup`/`wait` 重新确认实际状态。
- `lookup` 对已移除请求的 `removed`/`5` 在 tombstone 保留期内**可以重复读到**，不是一次性消费；重复查询同一个已移除的 request ID 每次都得到 `5`。

## 执行工作流

1. 先执行 `doctor`，确认指定主机可用（注意：doctor **不是只读的**，见「发现与前置条件」；队列概览请用 `status --summary`，它没有这个副作用）。
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

## 运行语义

- AgentQ 防护的是调用端 SSH/终端中断，不承诺目标主机或队列服务发生生命周期变化时任务继续执行。Windows 服务由当前用户的交互式计划任务启动；Linux 使用 systemd 用户服务并启用 linger；macOS 使用由 root 注册、由目标用户运行的系统 LaunchDaemon。不要将调用端重连能力等同于目标任务在服务生命周期变化后的继续执行。
- Windows 服务资产位于受保护的 `C:\ProgramData\AgentQ`，不应从共享用户目录调用或修改。Linux/macOS 服务资产位于 `~/.agentq`，通过权限为 `0700` 的 Unix socket 通信；不需要也不应暴露队列网络端口。**该「0700 socket」的说法只对 Unix 成立**：Windows 上 Pueue 回落 TCP + TLS（`use_unix_socket` 是 Unix-only 字段），监听回环，其保护来自 `Set-PrivateTreeAcl` 给 `C:\ProgramData\AgentQ` 施加的私有 ACL（只有该用户、SYSTEM、Administrators），而不是文件模式——Pueue 在非 Unix 分支不设置 `shared_secret`/`certs/` 的文件模式（新建文件默认 0644），这是已记录的边界：这些凭据文件的纵深防御依赖父目录 ACL，不依赖 0600 模式（`docs/PLAN.md` A28）。
- 安装或升级只在目标队列没有活动或非终态任务时执行，历史 `Done` 记录可以保留。安装器会先暂存并校验 Pueue 二进制、验证依赖与服务端语法，再切换服务；Windows 首次启动后还会验证 Pueue 的 TLS 证书、私钥和共享密钥，并重新施加私有 ACL。健康检查失败会恢复上一份部署。**两个安装器在启动时都会拒绝「上一次运行在换根中途崩溃」的现场**：若根目录缺失或旁边残留事务目录（Windows 为 `.AgentQ.backup.*`/`.stage.*`/`.failed.*`，Unix 为 `..agentq.backup.*`/`.stage.*`/`.failed.*`——双点），它会停止并报出这些路径（旧队列与凭据就在 backup 里），等你把 backup 移回根目录恢复、或确认放弃后手动清掉再重跑——它不会自动删除、合并或恢复任何东西。Windows 上该残留优先于一切检查被拒（旧的「wrapper 已存在」提示只在无残留时出现，且不描述这一情形）。运行中的守护进程状态异常时，服务端拒绝擅自干预队列，避免中断未知任务。
- 已移除任务的请求 tombstone 默认保留 30 天，并由后续 AgentQ 操作按日清理。保留期内同一请求 ID 不能复用；过期并清理后它会变为 `not_found`，因此新任务仍应生成新的请求 ID，避免混淆历史结果。**数据留存需知**：每个 request record 以明文 JSON 保存**完整的命令文本**（`payload.argv`）与工作目录，tombstone 同样保留命令文本——队列里跑过的每条命令在 30 天内都能从数据目录读回。提交含敏感内容的命令前先想到这一点；删除痕迹需要连 tombstone 一起处理（手工清理数据目录前先确认没有活动任务，且不要绕过安装器的锁语义）。
- 不要用它绕过用户确认、安全策略、权限边界或长任务的资源限制。
- 不要在此链路中启动 `codex exec`；它用于执行目标机命令和回收真实进度/结果。
