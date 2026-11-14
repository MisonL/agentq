# Windows 安装器与路径链不变量

这份清单原本挤在 `SKILL.md` 的「新主机接入」里，43 条近乎同构的条目把一个操作文档压成了实现清单。
**它们是实现不变量，不是操作步骤**——每一条都由 `smoke/01`、`smoke/10`、`smoke/13`、`smoke/23`、
`smoke/25` 的静态规则或行为用例守着；改这些 helper 时读这里，日常接入主机不需要。

共同判据只有一条：**先 `Get-Item -Force` 观察，再区分「真正缺失」与「不安全路径」**；
真正缺失保留缺失语义，目录 / 叶级 / 断链 / 父级或更深祖先的 reparse 路径必须经过完整
non-reparse 普通文件路径链校验并**显式失败**，不得用 `Test-Path` 把不安全条目静默归类为缺失。

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
- Windows 安装器 `Add-CurrentProcessPathEntry` 使用强制项读取 PATH 候选；真正缺失和普通文件仍保持既有 no-op/忽略语义，但断裂或其他 reparse 路径不会因 `Test-Path` 返回 false 而静默跳过安全校验。
- Windows 安装器的 `Restore-LegacyDaemon` 使用强制项读取识别 legacy 配置、客户端和可选启动路径；断裂或其他 reparse 路径会进入完整路径链校验，不会因 `Test-Path` 返回 false 而静默跳过恢复。
- Windows 安装器的 `Restore-MovedLegacyArtifacts` 使用强制项读取回滚 destination/source；真正缺失保持既有缺失语义，目录、叶级/断链/父级/祖先级 reparse 路径必须经过完整 artifact 路径链校验并显式拒绝，不得用 `Test-Path` 静默跳过恢复。
- Windows 安装器 legacy migration 使用强制项读取枚举待迁移 artifact，并在 `Move-LegacyArtifact` 入口复核源和目标完整路径链；断裂或其他 reparse 源路径不会被静默过滤或移动。
- Windows 安装器 `Copy-AgentQData` 使用强制项读取源目录；真正缺失仍是安全 no-op，但断裂或其他 reparse 源路径不会因 `Test-Path` 返回 false 而静默跳过数据复制。
- Windows 安装器 `Wait-ForAgentQOperationLock` 使用强制项读取识别锁目录；断裂或其他 reparse 锁不会因 `Test-Path` 返回 false 而被当作不存在并放行。
- Windows 安装器安全 transaction cleanup 使用强制项读取确认删除后的路径确实不存在；删除后被替换为断裂或其他 reparse 路径时不会误报清理成功。
- Windows 安装器 `Copy-VerifiedPueueBinary` 使用强制项读取 staged/existing binary 来源；断裂或其他 reparse 来源不会因 `Test-Path` 返回 false 而被静默 fallback 或覆盖。
- Windows 安装器 `Restore-Transaction` 使用强制项读取 candidate/failed/backup/restored root；断裂或其他 reparse 路径不会被 rollback 当作不存在而静默继续。
- Windows 安装器主流程使用强制项读取 existing root、legacy config 与 transaction/legacy-backup 路径；断裂或其他 reparse 路径不会因 `Test-Path` 返回 false 而绕过既有路径链校验或冲突检查。
- Windows 安装器 `Resolve-GitBashPaths` 对每个 launcher/runtime 候选先做强制项读取；真正缺失或不完整的候选继续作为发现失败处理，但已观察到的 reparse 文件或父级路径会立即进入完整路径链校验并显式拒绝，不会被 `Test-Path` 误判为缺失后静默跳过。
- Windows 安装器 `Require-Path` 使用强制项读取区分真正缺失和已存在的 reparse 路径；缺失仍报告缺失，已存在但不安全的路径进入完整路径链校验并显式拒绝。
