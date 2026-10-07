---
name: agentq
description: 将任意授权命令提交到已配置的远程主机并持久化跟踪进度、日志、结果、失败或取消。用户要求远程执行、后台执行、SSH 断线后继续、获取目标机任务进度或结果时使用；用户需要人类交互 SSH 会话保活和重连时使用随 Skill 提供的 sshp。本地调用端覆盖 Windows CMD、PowerShell、Git Bash 与 POSIX sh、bash、zsh；目标机支持 Windows、WSL、Linux、macOS；不在目标机运行 Codex。
---

# AgentQ Remote Queue

使用 `agentq` 通过 SSH 调用目标主机上的兼容 AgentQ 服务端。任务由远端队列托管；本机终端关闭或短暂断线后，已经提交的任务继续运行。

`sshp` 是另一条人类交互链路：它连接远端 `tmux`、`screen` 或 Zellij 会话，并在确认 OpenSSH 传输断开时重连。不要用 `sshp` 承载 AgentQ 任务，也不要用 AgentQ 模拟交互终端。首次缺少依赖的安装确认必须在本地交互终端中完成；无 TTY 时会明确拒绝，不会静默安装。

## 调用端与终端

- 每个本地登录用户分别安装客户端、保存 SSH 配置和设置默认主机；不要把一个用户的 `~/.ssh`、`~/.config/agentq/config` 或 `~/.local/bin` 当作其他用户的配置。AgentQ 只使用 SSH 认证实际选择的远端登录用户；同一 IP 的不同用户名是不同的服务、任务和会话域。
- macOS、Linux 和 WSL 使用 `assets/client/unix/install-client.sh`。它将 POSIX `agentq` 与 `sshp` 安装到当前用户的 `~/.local/bin`；二者是 `/bin/sh` 脚本，可从 `sh`、`bash`、`zsh` 或其他 POSIX shell 直接执行。使用 `install-client.sh --check [--bin-dir <directory>]` 可只读核对目标目录中的两个客户端是否逐字节匹配 canonical 资产：匹配返回 `0`，缺失或漂移返回 `1`，不安全路径或协议参数错误返回 `2`；该模式不会创建、替换或删除文件。安装器不修改 shell 启动文件；若该目录不在 PATH，先以绝对路径调用或在用户已确认后更新其 shell 配置。
- POSIX `agentq` 客户端需要本机 `jq`（或 `AGENTQ_JQ` 指向可执行解析器）来验证成功响应；缺少解析器时必须显式失败，不能把未校验的 stdout 当成成功结果。
- **Windows 目标的远端终端不止一种（2026-09-22 实测）。**
Windows 上 sshd 用 `<DefaultShell> <DefaultShellCommandOption> "<cmd>"` 解析客户端发来的
命令，而 `DefaultShell` 可以是 `cmd.exe`、`powershell.exe` 或 Git Bash——**每一种都是
不同的解析器**，三者的命令行长度上限不同（实测 8,125 / 8,155 / 8,176），且
`DefaultShell=powershell.exe` 时**外层 PowerShell 会把内层程序的非零退出码压平为 1**
（实测范围是**全部协议码**：`2/3/4/5/6/42/124` 一律变 1，只有 0/1 保留），
使 `42-45`（launcher 契约）与客户端依赖 `3/4/5/6` 的恢复判定都失真。这两点**两条路径都已修**：
**探针路径**不再把脚本放进命令行，改经 stdin 喂给 `powershell.exe … -Command -`（两端命令行
固定 76 字符），退出码由 stdout 末尾的 `agentq-exit:<code>` 带外传递；**操作路径**
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
的 `DefaultShell`。详见 `PLAN.md` A5。

**另一条 Windows 专属机制（2026-10-02 实测）：探针体必须由 `-Command -` 真正执行。**
`powershell.exe -Command -` 把 stdin 当**交互式输入**读：一行若**开启一个块**
（`if {`/`function {`/`try {`）就进入续行，缓冲的语句**只在遇到空行时才执行**，
**EOF 时未终止的缓冲被静默丢弃**（rc=0、无输出、什么都没执行）。Windows 客户端的协议探针
是一段**多行 here-string**，若末尾没有那个空行，**整个探针体被丢掉**、对任何 Windows 目标
都报 `native Windows AgentQ service protocol probe failed`（指向部署而非客户端）。平台探针与
POSIX 客户端的探针都是单行、不受影响，所以**只有「Windows 客户端 → Windows 目标」这一组合**
会踩到。客户端已在 `Add-ProbeExitToken` 末尾追加该空行（见 `PLAN.md` A20）。

**第三条 Windows 专属机制（2026-10-02）：PowerShell 5.1 会把交给 ssh 的脚本按词切开。**
两个 Windows 客户端都用 `& $exe @argv`（splat 数组）把一段多行 shell 脚本作为**单个参数**
送给 ssh，而 PowerShell 5.1 的 `&` 调用运算符只给**含空格**的参数外包一层双引号、**不转义
参数内部已有的双引号**——于是脚本在 ssh 看到之前就被词分割（实测模型下 `sshp.ps1` 的探针
从 1 个参数裂成 17 个），远端报错会**指向部署而不指向客户端**。现在两个客户端都改用
**base64 `printf %s <b64> | base64 -d | sh`** 把脚本交给 ssh（base64 字母表无需引号，命令行
不受本地 PowerShell 影响；`sh` 在管道末位所以退出码仍是脚本的）。pwsh 7 **不复现**该缺陷，
所以它只在真 PS 5.1（`agentq.cmd`/`sshp.cmd` 都经 `powershell.exe` 调用）上才可达。**一处刻意例外**：`sshp.ps1` 启动交互会话的那条命令（`exec tmux/screen/zellij`）**不**走 base64——该通道让脚本的 stdin 变成**管道**，而多路复用器要求 stdin 是 tty（实测：pty 下 `stdin=tty` 能起 screen，`stdin=pipe` 一律 `Must be connected to a terminal.`）。它裸着安全的前提是**脚本里一个双引号都没有**，所以往那段脚本里加一个 `"` 会让它重新被词分割。见 `PLAN.md` A21。

原生 Windows 使用 `assets/client/windows/install-client.ps1`。它把 `agentq.ps1`、`sshp.ps1`、`agentq.cmd` 和 `sshp.cmd` 安装到当前 Windows 登录用户的 `.local\bin`，默认加入该用户 PATH。安装器和 PowerShell 客户端通过当前进程 SID 查询 `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList`，不会信任被 Git Bash、OpenSSH、`runas` 或旧会话污染的 `USERPROFILE`/`HOME`；Windows 用户需要新开终端后再按名称调用；`-SkipPathUpdate` 仅在用户明确不希望修改 PATH 时使用。使用 `install-client.ps1 -Check [-DestinationDirectory <directory>]` 可只读核对 `agentq`/`sshp` 的 `.ps1`、`.cmd` 以及检测到 Git Bash 时的无扩展名 shim 是否逐字节匹配 canonical 资产：匹配返回 `0`，缺失或漂移返回 `1`，不安全 reparse 路径返回 `2`；该模式不会创建、替换、删除文件或更新 PATH。
- Windows CMD 使用 `agentq.cmd` 和 `sshp.cmd`；PowerShell 可调用同目录的 `.ps1` 文件，或在新终端中直接调用 `agentq` / `sshp`；Windows Git Bash 使用安装器生成的无扩展名 `agentq` / `sshp` 启动器。三个入口都读取 `%USERPROFILE%\.config\agentq\config`；Git Bash 的 `$HOME` 不参与 Windows 默认配置定位。该启动器显式关闭 MSYS 路径改写，再调用同目录的 PowerShell 客户端，因而 `/home/...`、`/c/...` 和远端命令参数不会被本机 Git Bash 篡改；安装器也会从当前 PATH、注册表和常见目录发现自定义或便携 Git for Windows。
- Windows 原生 `agentq` 客户端读取 `AGENTQ_HOST` 配置文件时最多接受 4096 字节，并按 UTF-8、UTF-8 BOM 或 UTF-16 BOM 解码；超限、坏编码、目录、文件或其路径链中的 reparse 路径会显式失败，缺失配置仍表示未配置默认主机。
- Windows `sshp` 的临时日志、标准输出和错误输出文件必须是普通非 reparse 文件，且其父级路径链也不得包含 reparse 组件；不安全路径会显式失败并保留原目标。
- Windows `agentq` 与 `sshp` 读取临时日志、标准输出和错误输出时，先用 `Get-Item -Force` 观察路径；真正缺失返回空文本，目录、叶级或断裂链接、父级或更深祖先 reparse 路径必须经过完整 non-reparse 文件路径校验并显式失败，不得用 `Test-Path` 把不安全条目静默归类为缺失。
- Windows `agentq` 与 `sshp` 清理临时文件时，先用 `Get-Item -Force` 观察路径；真正缺失保持安全 no-op，目录、叶级或断裂链接、父级或更深祖先 reparse 路径必须经过完整 non-reparse 文件路径校验并拒绝删除，不得用 `Test-Path` 把不安全条目静默归类为缺失。
- macOS、Linux 与 WSL 的 Unix `agentq` 客户端读取 `AGENTQ_HOST` 配置时只接受非符号链接的普通文本文件，并只探测前 4097 字节；目录、FIFO、设备、套接字、符号链接和其他非普通文件会在读取前显式失败，包含 NUL 字节或超过 4096 字节也会显式失败。客户端会在有界读取前后记录并复核源文件及其路径链每个组件的 device/inode；观察到源路径链改变、符号链接或非普通文件时显式失败。缺失配置仍表示未配置默认主机，Unix 配置保持当前文本解析语义。
- Windows 目标的参数 Base64 载荷通过调用端 wrapper 和受保护 launcher 的兼容 stdin 入口以 4096 字符分块读取，编码载荷超过 1048576 字符会显式拒绝；该上限只保护参数输入，不限制已接受任务的完整输出。
- 输入的引号必须遵循当前本地终端：CMD 中命令参数里的 `&`、`|`、`<`、`>` 和 `^` 需要按 CMD 规则转义；PowerShell 使用 PowerShell 引号；Git Bash、bash 与 zsh 使用 POSIX Shell 引号。跨终端传递 Windows 原生命令时，始终将其 argv 放在 `-- cmd /c ...` 或 `-- powershell.exe -NoProfile -Command ...` 后。
- WSL 是独立的 Linux 用户环境，即使其 Windows 用户相同，也要使用 Unix 安装器和 WSL 自己的 `~/.config/agentq/config`。不要让 WSL 复用 Windows Git Bash 启动器。
- `sudo`、`su`、以“管理员身份运行”的 PowerShell/CMD，或切换 Windows 登录用户，都会进入另一个本地用户域；它们应各自安装客户端、拥有自己的 SSH 密钥和配置。不要把 `AGENTQ_CONFIG`、`AGENTQ_HOST` 或客户端目录做成所有用户共用的系统级设置，除非该共享是有意、已审计且密钥 ACL 合适的。
- 目标机只提供密码认证（没有可用密钥）时，客户端默认**连不上**：ssh 以 `BatchMode=yes` 运行，该选项让 `password` 与 `keyboard-interactive` 两种方法根本不会被选中。要改用密码，配置**三种来源之一**（按优先级）：`AGENTQ_ASKPASS` 指向一个打印密码的可执行程序（**推荐**——客户端只传程序名，从不读取或保存密码本身，因此它可以指向系统凭据助手）；`AGENTQ_PASSWORD` 直接给出密码（环境变量，**无法做权限校验，不受保护**）；`AGENTQ_PASSWORD_PROMPT=1` 让 ssh 在终端上提示（**仅 POSIX**，且必须有终端）。配置后客户端传 `BatchMode=no` 加 `NumberOfPasswordPrompts=1` 并经 askpass 取密码；**没配置时行为与从前逐字节相同**（失败快、绝不等待输入）。来源配置了但不可用（不存在／不可执行／符号链接／是目录／与另一来源同时设置）时客户端**拒绝运行**，不会静默退回密钥认证。密钥仍然先试，密码只是回落。**Windows 客户端只支持 `AGENTQ_ASKPASS`**，取值必须是**一个可执行文件的路径**——ssh 把整个值当作**单个文件名**执行，中间没有 shell、也不做分词，所以**不能带参数、不能加引号**，但**路径里的空格是合法的**（`C:\Program Files\...` 这种形态实测可用；判据是「整个值是不是一个存在的可执行文件」，不是「有没有空格」）。实测真机：`cmd.exe /c helper.cmd` 报 `ssh_askpass: exec(...): No such file or directory`；而指向一个带 shebang 的脚本可以正常执行。`AGENTQ_PASSWORD` 与 `AGENTQ_PASSWORD_PROMPT` 在该平台被明确拒绝——前者没有可挂靠的清理机制，后者会让 ssh 读控制台并在无控制台时**挂死**。**账户密码的登录成功路径已在真机验证（2026-09-29）**：POSIX 客户端经**真实账户密码**（不是口令私钥）在一台只提供密码、没有可用密钥的 macOS 主机上跑通完整协议（`submit`→`wait` 的 `Done.result=Success`→`logs` 回 `Darwin`→`remove`），Linux 目标同样跑通；Windows 客户端也已升级到 canonical 并在真机确认了守卫与 ACL。**经 Windows 客户端发起的端到端也已验证**（Windows → 那台只有密码的 macOS 主机：`wait` 退 0 + `Done.result=Success`、`logs` 回 `WIN-E2E-OK\nDarwin`、`remove` 回 `removed:true`）。**原生 Windows ssh 也已验证（2026-10-02）**：在一台专用 Windows 测试机上，客户端 PATH 解析到的是**原生** `C:\Program Files\OpenSSH\ssh.exe`（9.5p1，非 Git Bash 的 MSYS ssh），Windows 客户端经它连本机 Windows 目标、用 askpass 密码认证跑通完整协议（`submit`/`wait` `Success`/`logs`/`remove` 全 rc=0）。**Windows 上 `SSH_ASKPASS_REQUIRE=force` 是必需的**：Windows 没有 `DISPLAY`，缺了它 ssh 永不调用 askpass、退回读**控制台**的 `readpassphrase`，无控制台时**永久阻塞**；客户端已改为有来源时设 `force`、无来源时**显式清除**继承值（Git Bash 会导出 `SSH_ASKPASS`）。仍属边界的只有 `System32\OpenSSH\ssh.exe`（8.1p1，早于该变量）。本机（macOS 非 root 用户级 sshd）依旧验不了密码登录：读不到密码散列。凭据不得写进仓库、文档或日志。
- 默认主机可由环境变量 `AGENTQ_HOST` 提供，或在当前用户的配置文件写入单行 `AGENTQ_HOST=<ssh-host>`：Windows 是 `%USERPROFILE%\.config\agentq\config`，macOS/Linux/WSL 是 `~/.config/agentq/config`。Windows PowerShell、CMD 与 Git Bash 映射到同一 Windows 用户目录；其他平台各自独立。
- `agentq` 和 `sshp` 会自动探测目标平台：`MINGW`、`MSYS`、`CYGWIN` 只表示 SSH 默认 shell 位于 Windows；客户端仍会用 UTF-16LE Base64 编码的原生 PowerShell probe 复核 Windows 服务入口和工具路径。这样 Git Bash 的 SSH PATH 不能误导 cmd、PowerShell 或计划任务的真实环境。除诊断已知异常外，不要手工设置 `AGENTQ_REMOTE_PLATFORM`。
- AgentQ 的 POSIX 与原生 Windows 客户端对只读平台和 Windows launcher 协议 probe 默认设置 30 秒命令级上限，可用 `AGENTQ_PLATFORM_PROBE_TIMEOUT` 传入正整数调整。超时返回退出码 `124` 并显式报告；Windows 客户端会终止 probe 进程树。不会把探测超时重试或降级为普通 SSH；该上限不作用于 submit、wait 或其他已提交任务的普通操作。
- 客户端缺失时，先说明对应本地安装器和将写入的用户目录；只有用户已授权本机安装时才运行安装器。安装用户客户端不等于在远端部署 AgentQ 服务。

## 发现与前置条件

- 调用 `agentq doctor` 检查默认主机；指定目标时使用 `agentq --host <ssh-host> doctor`。**`doctor` 不是只读的**：它先确保 Pueue 守护进程在运行，若未启动会尝试启动它（服务变更），成功路径还会改写 request record。对真实生产主机跑之前，先确认该机 `pueued` 已在运行，这样第一次 `status --json` 就返回、永远走不到启动服务那一步。
- 默认目标由调用环境配置；优先在任务中明确使用 `--host <ssh-host>`，避免隐式选错主机。
- 目标机必须已经部署兼容的 AgentQ 服务端。Windows 客户端会先只读检查受保护的 `agentq-launcher.ps1` 是否存在且支持当前参数协议；发现旧/不完整部署时会明确要求升级，而不是把 PowerShell 的文件不存在错误暴露给调用端。若 `doctor` 报缺失或不可用，停止并报告原始错误；不要静默降级成普通 SSH 前台执行。
- `--workdir` 必须是目标主机认可的绝对工作目录。Windows Git Bash 可使用 `/c/Users/name/project` 或 `C:\Users\name\project`；提交前先确认目录存在。`cmd`、PowerShell、Git Bash 只是调用端，目标 Windows AgentQ 统一由 Git Bash 执行队列命令，因此命令本身应写成 Git Bash 可执行的 argv；要运行 Windows 原生命令时使用下一条规则。
- Windows 目标机的 AgentQ 服务在 Git Bash 中执行提交后的命令。守护进程启动器和受保护 launcher 会根据当前 Windows SID 重建 `HOME`、`USERPROFILE`、`APPDATA`、`LOCALAPPDATA`、`USER`、`USERNAME`、`TEMP` 和 `TMP`，因此从 CMD、PowerShell、Git Bash 或 SSH 非交互会话启动都不会继承另一个用户的目录。提交 Windows 原生命令时使用 `-- cmd /c <command>` 或 `-- powershell.exe -NoProfile -Command <command>`；不要把 CMD 或 PowerShell 引号拼进一个未经验证的大字符串。

## 新主机接入

- 先对新主机运行 `agentq --host <ssh-host> doctor`（注意 `doctor` 不是只读的，见「发现与前置条件」段）。
- 若服务端未部署，说明缺少兼容 AgentQ 服务端，并询问用户是否允许自动安装所需依赖和服务；收到明确确认前不得改变目标机。
- **本项目不支持跨版本互操作，这是刻意的决定，不是遗漏。** 服务端与客户端之间没有协议版本协商字段，`doctor` 报的 `pueue=`/`pueued=` 是队列实现的版本，不是 AgentQ 自己的协议版本。部署单元就是 `skill/assets/` 下那 23 个文件的同一版本；**不得只升级服务端或只升级客户端**，必须整体替换。若将来需要跨版本互操作，先加协商字段再谈。
- 服务端可以使用任意持久化队列实现，但远端受管入口必须保持本 Skill 的命令、JSON 和失败退出码契约。Unix 入口是 `~/.local/bin/agentq`；Windows 客户端应调用受保护的 `C:\ProgramData\AgentQ\agentq`。
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
- Windows client installer 的 `Install-CommitSet` **先把每个客户端文件全部暂存，再统一提交**（成对原子性，`PLAN.md` A28 W4）：逐件「暂存+替换」会在第二个文件失败时留下**新 `agentq` 配旧 `sshp`**，而这一对永远是被一起读的。读取源和目标时先用 `Get-Item -Force` 观察已存在项；真正缺失保持既有缺失或新建语义，目录保持非文件错误，观察到的文件、断链或其他 reparse 路径先经过完整 non-reparse 路径链检查，替换/移动分支使用已观察的目标项，不得用 `Test-Path` 静默绕过路径安全检查。提交阶段内部的失败无法在无事务文件系统上做到原子，但窗口从「剩余每个文件的拷贝+ACL」缩到相邻两次 `[File]` 调用。
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
- macOS 无 GUI 安装使用系统 LaunchDaemon：安装器在交互式 SSH 中请求 sudo，将带 `UserName`、`HOME` 和 `WorkingDirectory` 的 `com.agentq.pueued.plist` 安装到 `/Library/LaunchDaemons`，以目标用户身份运行 Pueued，并在 `system/com.agentq.pueued` 中 bootstrap/kickstart。旧 `~/Library/LaunchAgents/com.agentq.pueued.plist` 只在确认队列没有活动或非终态任务后停用并保留为 `.agentq-disabled.*` 备份，避免 GUI 登录产生重复服务；**安装期的 sudo 密码**只在 sudo 提示符中输入，不写入命令、环境变量或日志。（这是 sudo 的密码，与下面 ssh 认证用的凭据是两回事。）迁移后用 `agentq --host <ssh-host> doctor` 验证，`doctor` 会报告实际使用的 `launchd_domain=system`。非交互 AgentQ 请求不会自动提示 sudo，也不会把服务降级为前台 SSH。
- Windows 安装器会从 Git for Windows 注册表、PATH 和常见安装目录解析 `bin/bash.exe` 与 `usr/bin/bash.exe`，将实际 runtime 路径渲染进 Pueue 配置，不依赖固定的默认安装目录；发现的 launcher/runtime 文件及其每个现有父级和祖先必须是普通非 reparse 路径。安装启动并建立 `agentq` group 后，会提交无副作用的 `printf` Shell smoke，检查 `wait`、任务结果和日志哨兵，删除 smoke 任务并再次确认没有活动或非终态任务；原有历史 `Done` 记录不会被删除。Pueue data/certificate 目录及其凭据文件的每个现有父级和祖先也必须是普通非 reparse 路径。
- Windows 安装器 `Resolve-GitBashPaths` 对每个 launcher/runtime 候选先做强制项读取；真正缺失或不完整的候选继续作为发现失败处理，但已观察到的 reparse 文件或父级路径会立即进入完整路径链校验并显式拒绝，不会被 `Test-Path` 误判为缺失后静默跳过。
- Windows 安装器 `Test-PueueConnection` 在允许缺失的路径链校验后再次强制读取 client/config；真正缺失仍返回不可连接，已观察到的 reparse 路径会显式拒绝，不会被 `Test-Path` 误判为缺失后静默跳过。
- Windows 安装器 `Require-Path` 使用强制项读取区分真正缺失和已存在的 reparse 路径；缺失仍报告缺失，已存在但不安全的路径进入完整路径链校验并显式拒绝。
- Windows 服务实例由执行安装的 Windows 登录用户持有：其计划任务与私有 ACL 都绑定该身份，启动时还会重新按 SID 注入该用户环境。当前 `C:\ProgramData\AgentQ` 部署一次只支持一个服务身份；另一 Windows SSH 用户不得直接重装或覆盖它。需要切换服务身份时，先确认队列为空、停止原服务并显式迁移或重新部署；这不是客户端的自动动作。
- 人类交互会话使用 `sshp <ssh-host> [session-name]`；先用 `sshp --check <ssh-host>` 只读检查可用的会话工具。Unix 目标优先使用 `tmux`，随后是 GNU screen 或 Zellij；Windows 目标只使用原生 `zellij.exe`。首个连接发现依赖缺失时才询问是否通过受支持的包管理器安装，`--check` 永不安装，安装期间的 SSH 中断也绝不自动重放。

## 协议

```bash
agentq [--host <ssh-host>] submit --workdir <remote-directory> [--label <label>] [--request-id <id>] -- <command> [arguments...]
agentq [--host <ssh-host>] lookup <request-id>
agentq [--host <ssh-host>] status
agentq [--host <ssh-host>] logs <task-id> [--tail <line-count|all>]
agentq [--host <ssh-host>] wait <task-id>
agentq [--host <ssh-host>] cancel <task-id>
agentq [--host <ssh-host>] remove <task-id>
agentq [--host <ssh-host>] doctor
```

- 传给 `submit` 的目标命令必须置于 `--` 后；不要将自然语言 prompt 当成命令。
- 所有成功响应为 JSON。`submit` 返回 `task_id`、`request_id` 和 `reused`。未显式提供 `--request-id` 时，本地客户端会生成一个；将该 ID 连同任务 ID 一起保留，便于恢复失去 SSH 响应的提交。
- AgentQ/SSHP 调用端在 SSH 退出码为 `0` 后仍必须验证响应结构；malformed JSON、缺少协议字段或不符合操作契约的日志/状态不得被报告为成功。失败诊断只能保留操作名、错误类别和响应字节数等元数据，禁止回显或持久化原始响应内容。OpenSSH `-E` 日志和子进程 stderr 同样只在最终调用端显示安全类别与字节数；原始内容只在受保护的短生命周期临时文件中供 transport 分类使用，并在操作结束时清理。SSHP 的交互链路也保留内部原文供分类，但最终用户输出只显示脱敏元数据。
- 同一个请求 ID 只能对应完全相同的工作目录、标签和命令。重复提交会返回原任务而不会重复入队；参数不同、已移除，或返回 `state: "ambiguous"` / `"removing"` 时必须停止，不得换新 ID 重试同一命令。
- 仅当本地 OpenSSH 的错误日志确认网络传输故障且提交以 `255` 退出时，客户端才会使用同一请求 ID 查询 `lookup` 并有限重试；远端命令的 `exit 255`、认证、主机密钥和配置错误会直接返回。重试耗尽时，运行 `agentq --host <host> lookup <request-id>` 恢复；`not_found` 表示服务端没有该请求记录，`not_started` 表示已有持久化请求记录但尚未观察到 Pueue 任务，两者都不是完成结果且只可用相同参数、相同请求 ID 重试。两者退出码均为 `3`；`ambiguous` 的退出码为 `4`，表示服务端无法安全判断，必须停止；`removing` 同样以 `4` 退出，表示删除意图已持久化但任务仍可见，不得重新提交或报告为已删除，只有再次明确执行 `remove` 才会继续删除；`removed` 的退出码为 `5`，表示该 ID 已移除、在 tombstone 保留期内**可以重复读到**（不是一次性消费）。
- `lookup`、`status`、`logs` 和 `wait` 在同样确认的传输故障下会有限重试；这些调用只读取、等待或完成已持久化的删除归档，绝不新建请求、取消任务或删除仍可见的任务。**`doctor` 不在这一列：它会先确保 Pueue 守护进程在运行，若守护进程未启动，会尝试启动它（macOS `launchctl kickstart`、Linux `systemctl --user start agentq-pueued.service`）——那是服务变更，成功路径还会改写 request record。** 要只读地探查一台主机，不要走 AgentQ 协议：直接 ssh 过去看 `~/.local/bin/agentq` 在不在、版本多少。`cancel` 与 `remove` 不自动重试，因为响应丢失后无法把副作用与失败安全地区分；先用 `status`、`logs` 或 `lookup` 重新确认。
- 处于删除恢复中的可见任务会在 `status`、`logs` 和 `wait` 的 `task.agentq.removal_pending` 中标为 `true`。若 Pueue 任务已不存在但 tombstone 尚未写入，后续安全读取会归档为 `removed`；读取操作不会删除仍可见的任务。
- `status`、`logs` 和 `wait` 返回任务状态。`logs` 的常规响应使用字符串字段 `output`；若响应包含 `output_encoding: "base64"`，应先解码 `output_base64`，因为目标任务输出并非 UTF-8。解析 JSON 后再呈现日志，避免把 JSON 转义的 `\n` 原样当日志内容展示。
- 正常的 `wait` 输出 `{task: ...}`；任务失败时，它自身也必须以非零退出码结束。检查退出码和 `task.status.Done.result`，两者均不能省略。若任务在等待期间被移除，`wait` 输出 `{task_id, state: "removed"}` 并以 `5` 退出；若服务端无法确认最终状态，输出 `{task_id, state: "unavailable"}` 并以 `6` 退出。这两种状态都不能报告为任务完成。
- 若任务在首次调用 `wait` 前已从 Pueue 消失，服务端先以同一 `task_id` 匹配活动的 `accepted`/`removing` request record；Pueue 状态可读且任务不可见时归档该 request 并返回 `removed`/`5`，状态不可读或任务仍可见但无法解析时返回 `unavailable`/`6`。仅当没有活动 request record 时才使用 tombstone 作为历史 `removed` 证据，并仍先确认 Pueue 中没有同数字的新任务；若多个活动 request record 共享同一数字 task id，必须报告歧义并停止，不能按数字 id 猜测或归档错误请求。多个历史 tombstone 可以共享已复用的数字 task id，因为它们都只证明该 id 曾被移除。
- `cancel` 成功返回 `action: "cancel_requested"` 与 `cancellation_requested_at`。若目标在确认时仍为 `Queued`，服务端使用 Pueue `remove`，并额外返回 `cancellation_mode: "queued_removed"`；随后 `wait` 会以 `state: "removed"`、退出码 `5` 表示已从队列移除，而不是报告任务成功。若返回 `state: "cancellation_pending"` 且退出码为 `4`，说明取消意图已持久化，但服务端无法确认 Pueue 是否接收到了取消；这不是取消成功，也不得自动重试。先读取 `status`、`logs` 或 `wait`。任务仍未结束时，只有在用户再次明确要求取消后才能再次调用 `cancel`；任务已结束而仍为 pending 时，必须报告取消结果无法确认。`status`、`logs` 和 `wait` 会在 `task.agentq` 中分别给出 `cancellation_requested_at` 或 `cancellation_pending_at`，以及 `cancellation_reason: "user_requested"`。最终结果仍以 `task.status.Done.result` 为准：`"Success"` 仍是成功，即使取消请求到达得太晚；带已确认取消字段且非成功的结果可报告为取消；没有该字段的 `Failed` 是普通命令失败，即使其退出码恰好为 `1`。不同系统底层取消结果可能是 `Killed` 或 `Failed`。

- 队列操作（`submit`、`cancel`、`remove` 等）在服务端是**独占**的：同一时刻只允许一个。拿不到锁的调用**不是立即失败**——它每 1 秒重试一次、最多 30 次，约 34 秒后才放弃，在 stderr 打印 `AgentQ operation is already in progress` 并**以 `2` 退出**。这个 `2` 是**可重试的瞬时状态**，不是参数错误：被拒绝的调用**零副作用**（无入队、无 request record、无 tombstone、无残留锁），用**同一个 request ID**、相同参数稍后重试即可，绝不能换新 ID。
- 退出码 `2` **不止表示参数错误**：服务端把它复用在三类情况上，客户端一律原样透传。**判断类别请读 `reason`，不要匹配消息文本**：服务端在每条以 `2` 退出的失败路径上，都会在 stderr 的消息之后多打一行 `<程序名>: reason=<class>`，`class` 取值只有三个——
  - `protocol_error`：参数/协议错误。改参数。
  - `lock_contention`：队列操作锁竞争（消息含 `already in progress`）。**可重试**，用**同一个 request ID**、相同参数稍后重试。
  - `task_not_running`：对**已经结束**的任务调用 `cancel`（消息含 `task is not running`）。无法取消，先读 `status`/`wait`，不要当参数错误处理。

  消息文本是给人看的、可能措辞调整；`reason` 是机读契约，改动它属于破坏性变更。两个客户端都会把这一行从 SSH 日志里取出来、以 `remote failure reason: <class>` 转发给调用端——**只**转发这个受控标识符（字符集限定小写字母与下划线），远端无法借它注入任意文本，SSH 日志的其余内容仍然只以脱敏元数据（类别 + 字节数）呈现。
- `cancel` 的"取消已确认"重放是**幂等**的：任务已从 Pueue 消失时（`queued_removed` 路径，或 running 目标已被 kill），再次 `cancel` 会返回 `{"action":"cancel_requested","cancellation_requested_at": <原时间>, "reused": true}`、退出 `0`，而**不是** `unknown AgentQ task id`/退出 `2`。重放保证绑定在同一任务实例上（Pueue 复用数字 task id，陈旧 marker 不会被误当成重放）。窗口有限：`wait`/`lookup` 读到终态时会清理该记录，此后对同一已消失的 id 再 `cancel` 会回到退出 `2` `unknown AgentQ task id`。**另有第二种退 `2` 的情形，2026-09-22 实测确认，不要混淆**：若该数字 id 此前被别的任务用过（Pueue 回收 removed 任务的 id），实例绑定检查曾取到最早那个实例的时间戳，重放在取消确认的当下就失败——这是**已修复的缺陷**（见 `PLAN.md` A6，2026-09-22）：判据已改为「是否存在一个 `created_at` 为此值的实例用过这个 id」，修复后这类重放**应当成功**（`smoke/03` 两个方向都有用例）。因此退 `2` `unknown AgentQ task id` 只应出现在「终态已被读过、marker 已清理」这一种情形。**任何情形下都不得据此重新提交任务**：先用 `status`/`lookup`/`wait` 重新确认实际状态。
- `lookup` 对已移除请求的 `removed`/`5` 在 tombstone 保留期内**可以重复读到**，不是一次性消费；重复查询同一个已移除的 request ID 每次都得到 `5`。

## 执行工作流

1. 先执行 `doctor`，确认指定主机可用。
2. 用短标签提交用户明确授权的命令：

   ```bash
   agentq --host build-host submit \
     --workdir /absolute/project/path \
     --label test \
     -- npm test
   ```

3. 从 `submit` 返回 JSON 取出任务 ID 和请求 ID。耗时任务轮询 `status` 和 `logs N --tail 200`；队列可串行或有限并发，不能假设任务立刻开始。
4. 完成后执行 `wait N`。仅当退出码为 0 且结果为 `"Success"` 时报告成功；若结果非成功且 `task.agentq.cancellation_requested_at` 存在，报告取消；否则读取 `logs N` 并报告失败。
5. 用户明确要求停止时才调用 `cancel N`。任务已结束、日志也不再需要时调用 `remove N`。

## 运行语义

- AgentQ 防护的是调用端 SSH/终端中断，不承诺目标主机或队列服务发生生命周期变化时任务继续执行。Windows 服务由当前用户的交互式计划任务启动；Linux 使用 systemd 用户服务并启用 linger；macOS 使用由 root 注册、由目标用户运行的系统 LaunchDaemon。不要将调用端重连能力等同于目标任务在服务生命周期变化后的继续执行。
- Windows 服务资产位于受保护的 `C:\ProgramData\AgentQ`，不应从共享用户目录调用或修改。Linux/macOS 服务资产位于 `~/.agentq`，通过权限为 `0700` 的 Unix socket 通信；不需要也不应暴露队列网络端口。
- 安装或升级只在目标队列没有活动或非终态任务时执行，历史 `Done` 记录可以保留。安装器会先暂存并校验 Pueue 二进制、验证依赖与服务端语法，再切换服务；Windows 首次启动后还会验证 Pueue 的 TLS 证书、私钥和共享密钥，并重新施加私有 ACL。健康检查失败会恢复上一份部署。运行中的守护进程状态异常时，服务端拒绝擅自干预队列，避免中断未知任务。
- 已移除任务的请求 tombstone 默认保留 30 天，并由后续 AgentQ 操作按日清理。保留期内同一请求 ID 不能复用；过期并清理后它会变为 `not_found`，因此新任务仍应生成新的请求 ID，避免混淆历史结果。
- 不要用它绕过用户确认、安全策略、权限边界或长任务的资源限制。
- 不要在此链路中启动 `codex exec`；它用于执行目标机命令和回收真实进度/结果。
