# AgentQ 规划（2026-09-22 重建）

本文件取代 `HANDOFF.md` 的「待办 / 未完成」职能。日常开发看 `CLAUDE.md`，
命令契约看 `SKILL.md`，变更记录看 `CHANGELOG.md`。

**本文件是待办事项的唯一权威清单。** 别处出现的待办（HANDOFF 的历史段落、
CHANGELOG 里的过程记录）都是历史，不是任务。

---

<!-- toc -->
- 一、对设计的判断
- 二、规划原则
- 三、C 类：需要你给范围
- 四、明确取消
- 五、警告清单
- 六、执行状态（正文已拆到 `docs/plan/execution-log.md`）
- 七、各轮审查记录（第九轮起）
<!-- /toc -->



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
2. **一半代码凭什么被相信** —— 现役口径为 **417 行 / 37,426 = 1.11%**
   （2026-11-26 按 0.1.47 的当前字节重算分母；0.1.42 = 37,236、0.1.44 = 37,302、0.1.45 = 37,418、0.1.46 = 37,480 都已过时，见第十二轮节；`docs/verification-status.md` 的覆盖表是它的逐项账本）。
   14.2%（9 个资产 / 3,498 行）是 2026-09-24 的历史口径，**只作对照、不要再引用**；另有更大
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
4. **已取消项不得复活。** 见第四节，它们不是待办、不是门槛、不写进任何 Goal。
5. **不做的决定也要写下来。** 「刻意不做版本协商」和「忘了做」是两回事，
   前者可以接受，后者会在升级时静默咬人。


**节号**：本文件的 「一、二、三、四、五、六」 是它自己的节号；A/B 两类记录的标题
不带节号——它们已归档到 `docs/plan/`，原先在 `PLAN.md` 里的 §三/§四 是拆分前的编号。

**条目记录在哪**：A 类（A1–A34）的完整记录在 [`plan/a-class.md`](plan/a-class.md)，
B 类（B1–B5）在 [`plan/b-class.md`](plan/b-class.md)。本文件保留规划原则、C 类
（需要你给范围，正文仍在本文件）、取消清单、警告清单与执行状态。引用 `PLAN.md A21`
或 `PLAN.md B5` 即指对应记录文件中的那一条——**记录文件里没有待办，只有已归档条目
的正文**；本文件仍是唯一权威清单。

---

## 三、C 类：需要你给范围

这些我无法自己划定边界，需要你明确主机、用户、工作目录、恢复方式和副作用授权。
**在拿到之前它们不是待办，是待定。**

| # | 事项 | 需要你给什么 |
| --- | --- | --- |
| C1 | P1-3 整体操作矩阵（**改为三台**、**真实网络中断**；2026-09-22 用户裁定） | **已执行（2026-09-22）**，结果与两个新缺陷见 `CHANGELOG.md`。**当时**三台里只有一台跑当前版本（此后已多轮追赶，2026-10-10 三台均升到 0.1.2）。**两项遗留均已消解（2026-09-24）**：① 主机 A 的客户端路径——重装后 `status`/`submit`/`wait`/`logs`/`remove` 五项 exit 0（见 B5-执行）；② 缺陷二已修并验证（见 A6，`smoke/03` 有用例、M3 证明其敏感）。**C1 无遗留** |
| C2 | 平台/安装矩阵（WSL、arm64、RHEL、Fedora、Alpine、真实升级回滚） | **已执行容器可覆盖的部分（2026-09-24，用户全权授权）**，见下；**真实升级回滚 2026-10-07 已补验（Linux）**、**2026-10-10 已补验（Windows，专用测试机）**（见「C2 补格」）；**WSL2 2026-10-09 已在真机补验**（容器里仍不可伪造，真机可以）；**RHEL 系 2026-10-10 已补验（Rocky 9 容器）——它暴露并关闭了 A31（jq 1.6 保留字）** |
| C3 | 原生 Windows 其余边界（NTFS reparse 点语义、registry/profile、跨用户安装/服务身份） | **已执行（2026-10-01 与 2026-10-06，专用测试机）**，三项全部关闭，见下。**用户已声明无生产权限**，故不在生产机上做 |
| C4 | 真实服务/生产边界（远端服务生命周期、TLS/shared key、生产凭证、发布回滚） | **不是「不做」，是「用户无权授权」**：用户已声明无生产权限（用户是 AgentQ 的独立创建者，但生产环境不在其可授权范围内），只在私有环境部署测试。此项**不得**记为待办，也不得声称已验证 |
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
| **真实 RHEL 系（Rocky 9）安装 + 协议端到端（2026-10-10 补做）** | `rockylinux/rockylinux:9` + 本地构建的 systemd 镜像（Red Hat 官方 `ubi9/init` 在本网络不可达，故在官方 Rocky 基底上自建 systemd；**刻意不预装 jq/perl**，让安装器真正走 `dnf install -y` 分支），systemd PID 1，普通用户 `aqtest` 经 `su -` 建真实 logind 会话、NOPASSWD sudo，`AGENTQ_PUEUE_SOURCE_DIR=/stage` 预置真实 Linux 二进制（仍走内置 SHA 校验） | **`INSTALLER_EXIT=0`、`AgentQ 0.1.3 installed`**；私有树与二进制 700；unit `active`+`enabled`；`linger yes`；两个二进制哈希与内置常量逐一相符；record/tombstone 零残留；**部署的服务端与仓库当前版本逐字节相同**（`c3628935…`，= 仓库 `skill/assets/unix/agentq-server` 当前字节）。协议面：`status`=0、`submit→wait(Success)`、`logs` 回 `RHEL-OK`+`Linux`、**失败任务 `wait=1` 且 `Failed:7`**、`remove`→`wait`=**5**、`lookup` 连查 3 次均 0、`cancel` 已结束任务=**2**+`reason=task_not_running`、`doctor`=0 且 `agentq=0.1.3`。 **这一格暴露了 A31**（jq 1.6 保留字）——见 `plan/a-class.md` A31 |

**aarch64 与 x86_64 四个二进制哈希全部与安装器内置常量相符**（逐一实测）。

**两格明确不可达，记录以免被当成「已覆盖」**：
- ~~**WSL 无法在容器里伪造**~~ —— **2026-10-09 已在真实 WSL2 上补做并关闭**。原先的结论
  只说了「容器里伪造不了」，这句仍然成立：安装器读 `/proc/version`，而 runc **拒绝**在
  `/proc` 内 bind-mount（`check proc-safety of /proc/version mount`）。但由此推出的
  「WSL 路径没有证据」是错的——真机上跑得到。载体：一台 Windows 主机上的 **WSL2
  Ubuntu 24.04**（systemd 为 PID 1、`systemctl --user show-environment` 正常、sshd 在
  22、linger 已开）。全新安装 `INSTALLER_EXIT=0`、服务 `active`+`enabled`、
  `doctor` 报 `agentq=0.1.0`（**当时的部署版本**；仓库随后升到 0.1.2）；协议面 `submit→wait`=`Success`、`logs` 回读到 token、
  `lookup`、`remove→wait`=**5**/`removed`；失败语义 `Failed:7` 且 `wait`=1；重复
  request ID 被拒；零残留。**WSL 分支两个方向都验**：`is_wsl_environment` 在 WSL 上
  rc=0、在普通 Linux 主机上 rc=1。Unix 客户端安装 + `--check` 退 0，并跑通
  **客户端→ssh→wrapper→服务端**的完整端到端。**这一轮同时暴露并修掉一个真实缺陷**
  （wrapper 路径冲突，见 `CHANGELOG.md` 2026-10-10 条与 `SKILL.md`）。
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
launcher 端到端，见 W5 条目末）。**Windows 侧的升级回滚已于 2026-10-10 在同一台专用
测试机上补验并关闭**（此前只记「仍未单独构造」）：构造 v2——`pueue.yml` 把
`pueue_directory`/`runtime_directory` 指向一个**父级是普通文件**的路径
（`C:\Windows\Temp\aqblocker`，先写成一个文件），`mkdir` 必然失败、daemon 起不来。
实测结果：安装器 **exit 1**、stderr 同时含 `did not become ready` 与
`restoring the previous deployment`；回滚后 **server 哈希逐字回到升级前**
（`10710f70…`）、**config 哈希逐字回到升级前**、**record 数不变（1）**、**Pueue 任务数
不变（1）**、`C:\ProgramData` 下 **零 `.AgentQ.*` 残留**；回滚后的部署**功能正常**——
经受保护 launcher 走完整协议 `submit→wait(Success)→logs(ROLLBACK-E2E-OK)→remove→wait(5)`
全通。**注意一个真实的坑（首次尝试得到的是假结论）**：第一版「坏配置」把路径指向
`C:\NoSuchRoot\...`，而 pueued **会把不存在的目录建出来**，于是安装**成功**、看起来
「回滚没触发」——**必须让路径真的不可建**（父级是文件）才构成回滚触发条件。
**WSL 已于 2026-10-09 在真实 WSL2 上补验并关闭**（见上「两格明确不可达」一节——容器里
仍不可伪造，真机上可以）。

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

**2026-11-15 更正：这个缺口有机器可走了，先前的「只装了客户端」是错的。** 2026-11-14 我
写过「那台 Windows 10 主机只装了客户端、未部署服务端」——**那是盘点错了**：我只看了
`~/.local/bin`。服务端在 `C:\ProgramData\AgentQ`，2026-11-13 就装好并常驻（计划任务
`AgentQ Pueued`、`pueued.exe` 以 `--config C:\ProgramData\AgentQ\config\pueue.yml`
运行）。逐文件核对：`agentq`（`7fd15e2b…`）、`agentq-durable-move.ps1`、`agentq-start-daemon.ps1`
与仓库 0.1.30 **字节相同**，`agentq-launcher.ps1` 只差安装器渲染的 Git Bash 路径与 UTF-8 BOM，
`config/pueue.yml` 只差渲染路径——与专用测试机的部署形态一致。

**所以要做的是「量」而不是「找机器」**：2026-11-15 用本仓 0.1.30 POSIX 客户端经**真实 ssh**
对那台机跑了只读协议——`status --summary` 退 0（291 条任务、全 `Done`、组
`parallel_tasks=1`；request record 是 **286** 条，两个数不是同一个东西，此前被当成矛盾），
`logs 306 --tail 5` 退 0 并回
`\\?\C:\Windows\Temp` 形态的路径与两份日志行。这两条**确实走进了 Windows 上的路径处理与
jq 分支**，是本检查从来没有过的**执行证据**（`08` 仍只是间接证据）。

**仍未覆盖的**：`submit`/`remove`/`cancel`/锁竞争等其余 windows-only 分支在本机没有用例；
「Windows 机器上跑过服务端」是**证据的入口**，不是「已覆盖」。

---

## 四、明确取消 —— 不是待办，不得复活

以下事项已被明确取消，**不得**重新写入 Goal、待办清单或完成门槛：

- 压力测试
- 重启 / 注销 / 物理断电验收
- 历史全量扫描、完整历史 `shasum -c`
- 为每个旧 fixture 重建当前报告

以下需要授权，**默认不做**：

- 未获授权的远端安装、升级、回滚、服务变更、队列 mutation、凭证操作、生产写入
- 触碰真实的 `~/.agentq` 与真实 launchd 域
- 触碰 13 台真实生产 SSH 主机（仅用户在当次会话中点名的那几台获授权）
- 在目标机运行 `codex exec`，或把 Skill 客户端降级为普通前台 SSH
- 打印凭证内容（`shared_secret`、`daemon.key`）——只检查结构

---

## 五、警告清单

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
   是**数千行**无类型 shell：没有编译器、没有类型系统。（**2026-09-29 起有 git**，
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
    AGENTQ_REPO_ROOT=$(git rev-parse --show-toplevel)
    rsync -a --delete "$AGENTQ_REPO_ROOT/skill/" "$SKILL_DIR/"
    diff -rq "$AGENTQ_REPO_ROOT/skill" "$SKILL_DIR"   # 必须无输出
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
- **2026-10-12 全维度审查：已修 6 处、另记 3 处「查实后不改/记为边界」**（审查用 6 个
  并行只读 agent，每条发现均由我复现或证伪）。**已修**见 `CHANGELOG` 0.1.5 条
  （status/doctor 吞 jq rc=5、5 处退出码透传、3 处 trap 窗口/吞码、Windows 注释、
  探针 `\d+`、launcher try/catch）。**不改的三处**：
  1. `agentq-launcher.ps1` 未设 `MOVEFILE_COPY_ALLOWED`——跨卷 `MoveFileEx` 会
     `ERROR_NOT_SAME_DEVICE`，但 record 重命名本就同目录，属预期；未在文档声明前
     不当作缺陷（若要声明，写进 SKILL.md 的 Windows 段）。
  2. `smoke/18` 默认跑法下 13 个 `compare_case` 是同一份资产的两副本自我比较（差分
     测试的固有形态，`AGENTQ_SMOKE_SERVER` 覆写才是其正确用法）——不改设计，只在
     覆盖表里注明「差分用例仅在带 override 时有区分力」。
  3. `smoke/02` 的 reason-gap 静态规则只认字面 `exit 2`，13 处 `return 2` 结构性
     不可见——**刻意不扩**：扩到 `return 2` 会报出全部 13 处、而其中 12 处被调用点
     `if`/`|| return 1`/`fail` 正确折叠，唯一真正到达顶层的锁族已由 `with_operation_lock`
     补 reason 并留注释；报 13 处真缺口会埋掉那 1 处（判据、审计见 `smoke/02` 注释）。

- **2026-10-12 第二轮全维度审查（6 agent）——已修 6 处、另记 1 处未验证边界**：
  修的是 `agentq` 早期 config 窗口 trap 缺 `|| true`（cleanup 返非零会把 130 吞成 1）、
  `sshp` 信号 trap 同缺 `|| true` 且绑在 runtime 创建**之后**（dash 下窄窗泄漏目录）、
  `agentq` 的 `agentq_remote_failure_reason_value` 在中段才清、本地守卫提前 return 时
  残留上次 reason、`run-tests.sh` 分类器不认 `NOT-covered`（第二套「未验证」词汇隐形）、
  文档行数/计数陈旧（`agentq-server` 5,399→5,464 三处、smoke 计数 48/59→49/60、
  `agentq.ps1` 2,478→2,491、`agentq-launcher.ps1` 430→442）。**未验证边界（记录，不改）**：
  **Windows launcher 的 argv 经环境变量传递，payload 上限（`1048576` 字符）远大于
  CreateProcess 环境块上限（32767 字符）**——`agentq-launcher.ps1` 把每个参数写进
  `AGENTQ_ARGUMENT_i` 进程环境变量再起 Git Bash 子进程，故一个参数总量超约 32K 的
  `submit` 可能撞环境块上限。**2026-10-14 已在专用 Windows 测试机实测，env 块理论被
  推翻、真实失效模式比预想严重**（详见下条 B 边界）。`smoke/14` 只钉住**固定脚本**
  的远端命令行长度（≤8125），**不覆盖**用户 `submit` 的任意参数总量。

- **B（2026-10-14 真机实测；缺陷已由 B2 修复，本条保留为实测取证）——大参数 submit 在真 Windows 上间歇挂死，
  `1048576` 契约上限是真机上的空头支票。** 实测环境：专用测试机（Win10 19045、
  OpenSSH for Windows、PS 5.1.19041.3996、AgentQ 0.1.9 全链路）。三类事实：
  1. **stdin 送达挂死（主缺陷）**：客户端把 base64 payload 经 ssh stdin 喂给远端
     wrapper（PS 5.1 `-EncodedCommand`），wrapper 用 `[Console]::In.Read(char[4096])`
     循环读。**payload ≥约 4.5K 字符开始间歇挂死**（同一 payload 同一时刻有时 2-3s
     读完、有时无限挂），**≥约 8.6K 接近必然**（9333 字符：4 次中 2 次挂）。
     **判别实验**：同机器、同 stdin、同 payload，**逐字符 `Read()` 6/6 全部快速读完**
     （9333 与 54K 各测），4096 块读挂、1 字符读在 54K 仍偶挂 1/3——这是 PS 5.1
     `Console.In` 块读在 sshd 管道上的间歇阻塞，与 AgentQ 的 env 传递无关，
     **env 块 32767 理论不是触发器**。挂死的 wrapper 进程在客户端 ssh 被杀后
     （sshd 关管道→EOF）会自行退出，不是永久泄漏；但连续测试中会累积拖慢整机。
  2. **单参数内容截断（约 7K–10K 之间）**：经全链路 `submit` 一个 N 字符单参数，
     7000 → `Success` 且 `logs` 逐字回环 7000 字符；10000 → 任务 `Failed`，
     输出 `/usr/bin/bash: -c: unexpected EOF`——参数在 pueue→任务执行的命令行序列化
     中被静默截断，无任何拒绝报错。（该层与 1 独立。）
  3. **无干净拒绝路径**：wrapper 自身的 1048576 守卫从未触发；客户端对挂死**无
     超时**，submit 可以无限期阻塞；失败形态只有「挂」「截断」两种，都不是契约错误。
  **结论**：`1048576` 上限在真 Windows+ssh 交付链上不可达；真实可用边界在千字符
  量级且随机失效。

- **B2（2026-10-14 第二轮，用户「全部优化好」授权后修复，已真机验证）**——两处
  资产修复 + 一条记录边界：
  1. **stdin 挂死已修**（`agentq` POSIX 客户端 wrapper 单行 + `agentq.ps1`
     here-string，两份同步）：读循环由 `[Console]::In.Read(char[4096])` 块读改为
     `[Console]::OpenStandardInput().ReadByte()` 逐字节流读。判别实验先行：同机
     同 stdin 同 payload，`.NET` 流 4096 字节块读仍挂 4/6，**逐字节 `ReadByte`
     12/12 全部快速读完**（载荷至 53K）。真机回归：修复后 5K/7K/8K 参数各 2 次
     submit 全部成功（此前 5K 间歇、8K 必挂），10K/20K/40K 的 submit 也不再挂
     （stdin 送达成功）；逐字节读无性能问题（53K 约 2-3s）。`smoke/05` 新增静态锁
     （两份 wrapper 必须含 `OpenStandardInput`+`ReadByte`、不得残留 4096 块读
     缓冲），红证明两方向。
  2. **env 块溢出已改为契约拒绝**（`agentq-launcher.ps1`）：单参数 >约 32.5K 字符
     时 `SetEnvironmentVariable` 抛 ArgumentException（此前未捕获 → wrapper 退 1
     + CLIXML 堆栈、无契约错误）；现 try/catch → 消息 + `reason=protocol_error` +
     `agentq-exit:2`，真机实测 33000 字符 → rc=2 + `remote failure reason:
     protocol_error`，32500 仍成功。`smoke/22` 新增结构锁（env 写循环必须包在
     try/catch 且发出 reason 类），红证明两方向（去 catch / 去 reason 行）。
     **该修复把计划文件里预言的 env 块边界坐实**：CreateProcess 32767 上限真实
     存在，只是被缺陷 1 的挂死掩盖。
  3. **记录边界（不修，非 AgentQ 所能）**：约 8.1K–32.5K 区间的单参数，stdin 与
     env 交付都成功，但任务执行被 **cmd.exe 的 8191 字符命令行上限截断**——
     直接 `pueue add` 一个 9000 字符参数的任务，`pueue log` 报「命令行太长」
     （cmd 的经典 cap）。AgentQ 无法消除，SKILL.md 已写明：需要传超大参数时用
     文件承载，不要放 argv。
  **修复后契约形状**：≤约 8.1K 单参数全链路逐字回环；8.1K–32.5K 任务会被
  cmd 截断（stdin/env 层不再失败）；>32.5K 显式 rc=2 + `reason=protocol_error`。

### 2026-11-20 第五轮终审（只读 agent + Orca Codex，审的是 v0.1.35）——修 13 处，外加 1 条本轮自查发现的假阳性

**已修（每条都先在主检出里独立复现，再改，再证明新锁会红）**：

1. **P2：repair 回退循环每次失败泄露一个临时文件。** `repair_removed_request_records`
   的回退循环把读者的 stderr 捕获进 `mktemp` 文件，而读者经 `fail`（`exit 2`）报告，
   函数自己的尾部 `rm -f` 因此被跳过。实测（一条 removed 记录与墓碑冲突 + 一条不可读
   记录，且**前者 id 排序在后**——顺序反过来 `fail` 先触发、泄露不发生）：每条失败命令
   在 `$TMPDIR` 留一个 0600 空 `agentq-repair-guard.*`，无上界。修法：文件名提升为
   **全局**，`cleanup()` 与 `fail()` 都清；读取处先把名字在**子 shell 内**置空再用保存
   的路径重定向，否则 `fail` 在 `$( )` 里把父 shell 随后要 `cat` 的文件删掉（第一版
   实测丢了诊断、泄露用例仍绿）。锁：`smoke/27` 两例（零残留 + 守卫消息仍在 stderr）。
2. **安装器陈旧操作锁恢复里的 `$?` 取反陷阱。** `elif ! remove_installer_file …; then
   status=$?` 捕获的是**取反**状态的 0（bash/dash 实测：非取反 `else` 分支给 7、
   取反分支给 0），于是失败的删除回答 success、返回 0，调用方的
   `while [ -d "$operation_lock" ]` 在一把永远删不掉的锁上原地重试。改为
   `remove_installer_file … || { status=$?; … }`，并把原 `elif` 链改写为 `else` 分支内
   的 `if`。锁：`smoke/01` 新增**结构性** `negation_captures` 规则（不是行窗口——
   `smoke/10` 规则 G 已在窗口上栽过两次），带四个分支的自检夹具。
3. **非 UTF-8 的 `--label` 与 argv 被静默改写。** jq 的 `--arg` 把非法字节换成 U+FFFD：
   实测 `--label $'q\xff'` 退 0、记录里存的是 `q\xef\xbf\xbd`，随后**同一个 request id**
   换 `$'q\357\277\275'` 再提交答 `reused:true`——两个不同的参数被读成一个；
   `remove --label` 同样过匹配，一次删两个。argv 则是 Pueue 自己会拒，但**在 AgentQ
   落盘 `adding` 记录之后**，那条记录从此不可按原参数重放（实测 `lookup` 永久答 4）。
   修法：`is_valid_text_argument` / `is_valid_argv`（jq `-Rsj` 往返 vs
   `LC_ALL=C od -An -v -tx1`，argv 用 NUL 连接保住元素边界），在**写入任何记录之前**
   拒绝，退 2 `reason=protocol_error`。锁：`smoke/02` 两例 + 无记录断言，`smoke/27` 的
   S6c 钉「不留记录」那半。
4. **`--workdir` 解析结果以换行结尾时静默丢最后一个组件。** `normalize_workdir` 的
   `$( )` 剥掉所有尾随换行，于是任务在**另一个目录**入队；当被剥掉的整段就是那个
   换行时为 `workdir:""`，记录卡在 `adding`、`lookup` 永久答 4。修法：`pwd -P` 后追加
   `Z` 哨兵，剥哨兵再剥一个换行，剩余值含 `\n`/`\r` 即拒。锁：`smoke/27` S6b——夹具
   本身也用哨兵建（`$(printf '…\n')` 会把名字里的换行先剥掉，第一版就这样「测了双胞胎
   目录」）。
5. **任务日志路径不是普通文件时 `logs` 挂死。** Pueue 直接 open 该路径，FIFO 上
   实测 `logs 901` 静默挂 20 秒直到调用方 `timeout` 杀掉（124）。修法：`compact_log`
   在**调用 Pueue 之前**拒绝该形状，按文档的 `6/unavailable` 回答。锁：`smoke/26` V22，
   桩**故意应答而不是阻塞**——断言的是「先拒后读」，复现挂死只能证明夹具带超时。
6. **服务端把 `--tail 00`/`000` 当有效（Codex 报告，已复现）。** 旧
   `is_bounded_line_count` 先剥前导零再判幅值，于是 `000` 归一为 0 并通过、答「0 行」，
   而两份客户端都拒、`--tail 0` 也拒——同一个值在三个实现里三种答案，且服务端已经
   触发了 daemon/status/log 访问。改为直接拒绝零的一切拼写（`0` 与 `0*`）。
   锁：`smoke/02` 三例（`0`/`00`/`0005`，断言码与 `reason`）。
7. **Windows 客户端缓存命中后跳过 launcher 协议探测。** 缓存写的是**平台判定**、
   在 launcher 探测**之前**落盘，所以条目不是「launcher 还答不答」的证明；POSIX 侧命中
   windows 后仍跑探测，Windows 侧直接 `return`。实测同一主机同一缓存：POSIX 退 2 带
   「部署不完整」诊断，Windows 退 0 而 launcher 报 42。修法：命中 windows 条目后仍调
   `Confirm-WindowsAgentQProtocol`，失败即 fail-closed。锁：`smoke/12` 的缓存命中控制例。
8. **Windows 客户端 `remove --label` 批量结果的根形状校验与 POSIX 不等价。** 空文本、
   `[null]`、单元素数组解包、`[]` 在两侧给出不同答案。改为**基于原始文本**判定根是数组
   （`Remove-TrailingNewlines` 后 `TrimStart` 再 `StartsWith("[")`），空数组走「内部为空」
   判据。实测五个形状 D2 全部 SAME（`/tmp/repro-win-d2d6.sh` 的 17 行差分）。
9. **探针退出 token 的读取规则两侧不同。** Windows 的读取器用正则 `(?m)^agentq-exit:…$`
   ——贪婪回溯、接受 4 位数字与前导零、要求行尾锚定；POSIX 取**最后一次出现**的数字串、
   ≤3 位、≤255、且尾随空白宽松。改为镜像 POSIX：`LastIndexOf` + `^[0-9]+` 数字串 +
   ≤3 位 + ≤255，否则**整条忽略、`Output` 原样保留**。`smoke/12` 的读取器普查改为
   「正则读取器 2 个、`LastIndexOf` 读取器 1 个」。
10. **操作路径的 token 读取在 Windows 侧用 `\s*$`。** POSIX 侧先 `tr -d '\r'` 再以
    sed `$` 锚定行尾——Windows 的 `\s*` 会吃掉尾随空格/制表符，同一 stderr 两种答案。
    改 `\r*$`（两处）。锁：`smoke/12` 的 token 后缀循环（tab/nbsp/尾随文本三种）。
11. **Windows 客户端三处标记比较是 `-eq`/`-like`（不分大小写）。** `-clike`/`-ceq` +
    `Remove-TrailingNewlines`（只剥 `\n`/`\r`，不剥空格——`.TrimEnd()` 会把尾随空白也剥掉，
    等于又引入一处与 POSIX 不同的宽松）。
12. **`install-client.sh --check` 对执行位漂移假绿（Codex 报告，已复现）。** 安装把文件
    `chmod 700`，而 `--check` 只 `cmp` 字节：实测装好后 `chmod 600` 两个客户端，`--check`
    退 0 报「match」，直接运行得 126。改为 `--check` 发现目标非可执行即报 drift（退 1）。
    **Windows 孪生不跟**：那边只比哈希，「可执行」对应的 ACL/扩展名状态没有实测，不声称。
    锁：`smoke/21` 模式漂移例（一个 600、另一个可执行，断言只有前者被点名）。
13. **`install-agentq.sh --help extra` 静默成功（Codex 报告，已复现）。** 帮助分支只看
    `${1:-}` 就退 0。改为 `--help` 带尾随参数时退 2 并点名该参数（与非帮助分支同一规则）。
    锁：`smoke/11` 一例。

**本轮自己的修复引入的假阳性（已修）**：`smoke/01` 的 local-hazard 规则把
`| LC_ALL=C od …` 报成未 `local` 的赋值。POSIX 里**纯字面值赋值后跟命令词**是该命令的
环境前缀、不是 shell 赋值——实测（bash 与 dash）被调用函数里的
`: | LC_ALL=C od` 不改调用方的 `local LC_ALL`，而语句形式会写穿。判定键在**值**上
（`[A-Za-z0-9_./:+-]*` 且**从匹配位置**起算——第一版从行首算，行首缩进就满足了
`[ \t]+`，等于豁免全部缩进行的赋值），并新增一个**阴性**自检夹具：规则必须对
`acquire_request_lock: LC_ALL` 保持沉默。

**记为边界（不修）**：
- 两份客户端的 `--stdin-script` 上界在 unix 目标上仍不一致（0.1.31 已记录，本轮未动）。
- `sshp` 的前台 ssh 中断语义（0.1.35 已记录，本轮未动）。
- `ps51=NOT-covered`：本机只有 pwsh 7.5.4，第 7/8/9/10/11 条只有静态与 pwsh 7 执行证据。
- Windows 安装器 `-Check` 不检查「可执行」——没有真 Windows 上的 ACL 证据。
- 非 UTF-8 的 `--label`/argv 只有**服务端**拒绝；两份客户端不做这个校验（POSIX 侧没有
  jq，Windows 侧编码路径不同），绕过客户端外的差异已在 `references/contract.md` 写明。

### 2026-11-20 发布后（v0.1.36）：CI 首轮两处红——一处是我写的夹具，一处是推送时序

1. **windows job：`smoke/12` 的 `.cmd` 桩发出与真实 launcher 不同的 stderr 字节。**
   CI run 44656069440 报 `exit token: expected the LAST token (3), got 1`。桩写的是
   `echo agentq-exit:0 1>&2`：cmd 解析时把重定向摘掉，但**文本与重定向之间的那个空格
   留在 `echo` 的参数里**，真实 stderr 是 `agentq-exit:0 `（尾随空格）。0.1.36 本轮刚把
   操作路径读取器从 `\s*$` 收紧为 `\r*$`（第 10 条），它**正确地**拒绝了这个 token、
   回落到 ssh 的退出码 1——是夹具错，不是资产错，但它把正确行为报成了红。
   修法：三处桩改为重定向在前的 `1>&2 echo …`（去掉分隔空格后 `echo` 只拿到文本）。
   **后缀循环（tab/nbsp/尾随文本）此前是假绿**：尾随空格本身就让读取器拒绝，那三个用例
   在旧桩上**没有真正检验后缀**；修后后缀是数字之后唯一的字节，用例才名副其实。
   锁就是这些用例本身——桩换回旧形态，exit-token 用例立刻红（CI 已实测）。
   **覆盖边界（必须记住）**：`.cmd` 分支只在 `cygpath` 存在时生成（Git Bash），
   macOS 上的 `smoke/12` 绿**不证明**这条分支——本机没有 cmd.exe，修复的证据只能是
   windows CI job 转绿（转换运行号见 CHANGELOG 验证行）。这是「夹具的一支只在
   另一台宿主上执行」的形态：开发机全绿与 CI 红可以同时成立，且都是真的。
2. **linux job：`smoke/31` 报 `version index names v0.1.36, but no such tag exists in
   this checkout`——推送时序，不是资产或检查缺陷。** 索引行随 `main` 先落地，
   tag 推送完成晚 21 秒（CI 起跑早于 tag 到达）。检查读的是 checkout 里的 tag，这是
   它该有的行为。修法不在代码：`CONTRIBUTING.md` 的 Release 规则补「先推 tag、或与
   索引提交用同一条 `git push origin main vX.Y.Z` 推送」。

### 2026-11-20 第六轮审查（6 个只读 agent + Orca Codex，审的是 v0.1.36）——修 8 处，外加 2 条检查/门禁补强，记录 3 条未修边界与 1 条误报

**已修（每条都先在主检出里独立复现，再改，再证明新锁会红）**：

1. **`--workdir` 的非法 UTF-8 没有被拒（0.1.36 只修了三个 `jq --arg` 输入中的两个：
   `--label` 与 argv）。**
   `submit` 里 `normalized_workdir=$(normalize_workdir …)` 之后没有任何文本有效性检查，
   而 jq 的 `--arg` 会把非法字节重编码成 U+FFFD，Pueue 收到的是**原始字节**——它在
   record 已写进 `adding` 之后才拒绝，于是 `lookup` 对这个 request id 永远答 4。
   修法：归一化之后、写记录之前加 `is_valid_text_argument … || fail '--workdir must be
   valid UTF-8'`。`smoke/02` 新增用例（+1 → `cases=46`）；该用例需要能建出非 UTF-8
   文件名（ext4 可以、APFS 拒绝 `mkdir`），本机报 `workdir-utf8=NOT-covered(needs-non-utf8-filename)`，
   名字加入 `smoke/not-covered-known.txt` 与 `ci.yml` 的 Windows 理由白名单。
2. **Windows 分支的 `normalize_workdir` 会被 `$( )` 吃掉目录名尾部的换行。** unix 分支
   早已带 `Z` 哨兵（`$( )` 剥掉**所有**尾随换行），windows 分支没有：`cygpath -aw` 的
   结果若以换行结尾，目录名的最后一个组件就被静默截掉、交给 `pueue add`。改为同一
   哨兵形态，并显式拒绝结果内部含 `\n`/`\r`。
3. **准入清单漏了脚本实际调用的工具。** `ensure_runtime_dependencies` 只查
   jq/base64/date/find/grep/mktemp/stat/tail/tr，而来脚本还调用 cat/head/mkdir/od/rmdir/sed
   （common）与 ln（unix）——缺其中之一时不是「准入清单点名」，而是运行到一半报
   `command not found`，失败点离原因很远。补进清单。
4. **`request_tombstones_states_filter` 把说明文字写在双引号 jq 程序内部。** jq 把 `#`
   当注释，所以一直「能用」；但双引号字符串不是注释：反引号会被 shell 当命令替换执行
   （2026-10-23 实测这条注释差点被执行），丢一个 `#` 就把散文当代码交给 jq。说明移出
   字符串，程序本体不再含注释。
5. **`remove_cancellation_marker_for_task` 的守卫缩进误导（行为无变化）。** 判据行与
   `remove_cancellation_marker` 对齐在 `if` 外面，读起来像「无论 marker 是否属于该实例
   都会删」；实际两条都在 `then` 块内。只改缩进，不改逻辑——如实记录为可读性修复。
6. **`wait` 的「rc=1 + 空 body」被两份客户端重报成 2。** `contract.md` 写明 exit 1 有
   两个来源：任务终态 Failed，以及 `pueue wait` **成功返回（0）**而快照仍未终态——
   后者到达时是**空 body** + 一行 stderr。两份客户端都要求 Done/Failed JSON，于是把这个
   文档化的 1 报成 2（「协议/参数错误」），恰好与调用方被告知要做的事相反。修法：只在
   `ExitCode==1` 且 body **字节为空**时放过；任何非空畸形体仍 fail-closed。`smoke/05`
   （+4 → `cases=120`）与 `smoke/12`（+1 → `cases=226`）的两个方向都钉住。
7. **POSIX 客户端的 token 分支把 250–255 当越界。** 分支是 `2[56789][0-9]`，覆盖
   250–299；250–255 是真实进程退出码（≤255），Windows 孪生接受，POSIX 拒成 1——同一
   `stderr` 两个答案。改为 `25[6789]|2[6789][0123456789]|[3456789][0123456789][0123456789]`
   （两处读者同步），
   `smoke/05` 以 Windows-目标桩钉 250→250、256→1（mod 256 会折叠成 0＝成功）。
8. **`sshp.ps1` 的 `__SSHP_*` 标记比较不分大小写。** 10 处 `-match` 改为 `-cmatch`：
   PowerShell 的比较运算符默认大小写不敏感，而 POSIX 孪生用 `grep -E`（敏感）——大小写
   不同的文本会被 Windows 侧当成命中标记。`smoke/19`（+1 → `cases=153`）用 dot-source
   行为用例钉四个方向，pwsh 缺失时报 `skipped(pwsh-absent)` 而不是静默通过。

**检查/门禁补强（不是资产缺陷，是门禁自身的洞）**：

- **annotated tag 的断言放错了 workflow。** `smoke/31` 的规则 E 检查 `git cat-file -t`
  == `tag`，但它跑在 `ci.yml`（branch push / PR）里，而 tag push 不触发 ci.yml——一次
  轻量 tag 会一路发布绿灯，直到下一次 branch push 才可能被报出来。`release.yml` 是唯一
  在 tag 上运行的 workflow，补一步：同一非注释行必须同时出现 `refs/tags/` 与
  `git cat-file -t`。`smoke/01` 用同一个 `release_gate_reads` 判据（注释行不算读）钉住
  `release.yml`，摘要 `release-gate=checked(8)+annotated=asserted`；红证：删掉该步骤
  `smoke/01` 退 1；实测 `git cat-file -t` 对 annotated 答 `tag`、对轻量 tag 答 `commit`。
- **`run-tests.sh` 的 SKIP 分支不收集 `NOT-covered`。** `ok`/PART 分支都把声明并入
  `NOT-covered:` 清单，SKIP 分支不并——一个**整体 SKIP** 的检查若声明了平台缺口，声明
  随桶一起消失，本地闸门与 CI 的 `^NOT-covered:` 行都看不见。今天没有检查同时满足两个
  条件（潜伏，不是活的假绿），修法就是同样的二次上报；红证用 `/tmp` 夹具（整体刷
  `SKIPPED` 且打印 token）实测旧版清单为空、新版点名。

**误报（核实后不改）**：

- 安装器组报的 `com.agentq.pueued.plist` 只被 `require_file`、从不渲染——刻意保留，
  `smoke/10` 的 scope 注释写明理由（那是一次旧安装路径的遗留资产，安装器只要求它存在、
  从不渲染它）；把它纳入 token 集会把正确代码报成缺陷。不改。

**未修边界（如实记录，不声称已修）**：

- **Windows 安装器对既有二进制的哈希断言比 POSIX 更严。** Windows 安装器在 root 已存在时
  用 `Assert-Sha256` 断言 `pueue.exe`/`pueued.exe` 等于**本次发布**的哈希，不等即 throw；
  POSIX 安装器在同样情形下先比哈希，不等则走 `download_and_verify` 取回期望字节。两侧
  都 fail-closed，Windows 侧是「拒绝修复」而不是「修复」。要改它的行为必须在一台真
  Windows 主机上验证升级路径，本会话没有授权也没有证据，故记为未修。
- **`Get-SshDiagnosticClass` 的 `(?i)` 与 POSIX 的大小写敏感 `grep -E` 不一致**（两份
  Windows 客户端各一处）。审查者自己判定为低影响的孪生分歧、可能是刻意的
  健壮性：只影响人类可读的 `class=` 与「装密钥」提示，不改退出码与协议判定；真实 OpenSSH
  的措辞大小写固定。未改，记录在案。
- **`DateTimeOffset.ToUnixTimeSeconds` 的平台下界**（.NET Framework 的时间纪元边界）只在
  5.1 上可达，本机是 pwsh 7.5.4、专用 Windows 测试机没有为本轮开机，未实测。

**覆盖边界**：`smoke/12` 新增用例在 Windows 宿主上的计数未实测（94 是新增之前的数）；
`smoke/02` 的新用例在本机走 `NOT-covered`，实际执行只在非 macOS 宿主上（CI 的 linux job）。

### 2026-11-20 发布后（v0.1.37）：release 首跑红——annotated 断言在 checkout 里读到的不是 tag 对象

**现象**：release run 44698210515 的 `Require an annotated tag` 步骤退 1，回答
`tag v0.1.37 is not an annotated tag (git cat-file -t answered 'commit')`——而同一个 tag
在本地 `git cat-file -t refs/tags/v0.1.37` 是 `tag`（`git tag -a` 创建，推送日志是
`* [new tag]`）。**不是轻量 tag，是 checkout 的形状。**

**根因（实测，不是推断）**：actions/checkout 在 tag push 上把 **GITHUB_SHA（那个
commit）** 取进 `refs/tags/<name>`，于是该 ref 指向 commit 对象，`git cat-file -t`
忠实回答 `commit`。在一次性克隆里复现（remote 指向本仓）：
`git fetch origin +<commit-sha>:refs/tags/v0.1.37` → `cat-file -t` 答 **commit**；
再 `git fetch origin +refs/tags/v0.1.37:refs/tags/v0.1.37` → 答 **tag**。

**修法**：步骤先取 tag **ref 本身**再问类型——
`git fetch --no-tags --depth=1 origin "+refs/tags/${GITHUB_REF_NAME}:refs/tags/${GITHUB_REF_NAME}"`，
fetch 失败单独报错退出（不把取不到误报成「不是 annotated」）。`smoke/01` 的
release_gate 规则现在要求**两个**构造各自在同一条非注释行上：`refs/tags/` +
`git cat-file -t`，以及 `refs/tags/` + `git fetch`；fetch 半边带双向夹具（注释行不算、
真实 refspec 行算）。红证：把 fetch 块删掉，`smoke/01` 退 1 并点名该原因；还原 → 退 0。
tag 按「当前版本例外」前移到修复提交并重推，release 重跑。

**教训**（与上一条同族）：**断言要在它真正运行的环境里量**。静态规则能钉住
「workflow 里有这句话」，钉不住「这句话在那个 checkout 里看到的是什么」——所以钉法是
先复现 checkout 的取法，再把两个构造一起写进规则。

### 2026-11-20 第七轮审查（全维度：只读 agent + Orca Codex，审的是 v0.1.37）——修服务端并发收敛、协议一致性与检查自身假绿，版本 0.1.37 → 0.1.38

**范围与边界**：安全 agent 只做防御性静态分析，未构造或运行利用载荷；所有发现均在主检出
独立复现后才改。生产主机一台未碰；测试机真远端的既有证据不因本轮扩展。以下区分已实测
与未覆盖，未实测的一律写在边界里。

**服务端（真实并发复现，不是推理）**：
1. **墓碑并发写入把一个正常并发读报成 2**。一个免锁的 `status`/`lookup` 归档 removed
   记录，与另一个持锁的写者同时安装同一墓碑，后者的 rename 被 `install_temporary_file`
   的原子身份检查拒绝，`fail` 退 2；实测 24 个并发 status 中 21 个失败（另一轮：20 个
   orphan `removing` + 24 个 status，20 个退 2）。修法不是「重试用同一字节比较」——
   `removed_at` 按秒生成，两个进程差一秒就有 5/24 仍失败；收敛判据改为
   `jq -cS 'del(.removed_at)'` 语义相等，实测 24/24 rc=0、12 个墓碑、0 残留。
2. **pruner 在 glob 与 `[ -f ]` 之间的「文件已消失」窗口退 2**（三类临时文件：runtime、
   request tombstone、cancellation marker）。原先 220 次零命中，改用 200 个候选文件 +
   延迟 50ms 批量删除后确定性复现（submit rc=2、`invalid AgentQ runtime temporary file
   path`）；消失即收敛 `continue`，对不安全文件仍保留失败。
3. **无法识别的 `.*.json` 名字阻塞所有写操作**。记录目录里一个 `.notes.json` 让 pruner
   `fail`，普通 submit 退 2；改为跳过（`.notes.json`/`.stray.json` 保留、submit 成功）。
   `smoke/27` S6d 的新用例在 HEAD 服务端上实测 rc=2，修复后 rc=0。
4. **`wait` 的 reconcile 歧义答案与可见任务路径相反**。两条记录都声称同一 task id 时，
   旧实现退 2/`protocol_error`（「参数错了」），而同一歧义在可见任务路径上退 6，
   `status --task` 自 0.1.24 起也是 6；统一为 6/`unavailable`，`smoke/26` W4 改期望并在
   HEAD 实测红（got 2）、修复后绿。
5. `write_request_tombstone` 新加的三个变量没有 `local`，写进了调用方的同名局部变量
   （`smoke/01` 静态规则点名）；已补 `local`，两份 canonical 服务端 `cmp=0`。

**客户端与 Twin**：
- Windows `ConvertFrom-Json` 在 pwsh 7 上把 ISO-8601 字符串强制转成 DateTime，令同一
  JSON 在两个 Windows 引擎上不等价；按能力传 `-DateKind String`。**边界**：7.0–7.4 无此
  参数，未实测；5.1 本来不转换；`-AsHashtable` 实测不阻止转换。
- Windows 的 reason 提取取**第一**条，POSIX 取最后一条；同一两行 stderr 给出不同分类，
  改为取最后一条。`$matches` 的赋值撞上 PowerShell 自动变量（`$lastExitCode` 那个 P0
  同族），改名后被 `smoke/01` AST 规则抓到并修掉。
- POSIX `doctor` 默认响应的过滤器接受两种形状，Windows 只接受严格摘要；收紧后发现
  `doctor --full`（ decorated dump，两实现本应同形）被自己误拒，`smoke/05` 实测红，
  补 `doctor_full` profile 后绿。POSIX 平台缓存读不再接受嵌套对象；`sshp` 的 Windows
  标记路由按完全匹配；F9：`wait --timeout` 是第二个 ssh funnel，补上 `run_ssh_logged`
  已有的 Windows 参数临时文件身份复核与 reason 清零（此前该路径的本地守卫失败会转发
  上一次的 reason）。

**检查/门禁自身的假绿（每个都先做空目录或变异红证）**：
- `smoke/16` 的 `*/.claude/*` 在绝对路径工作树下把整树排除，worktree 里 `enumerated 0
  files` 仍 rc=0；锚定 `$root` 后 rc=0、`files=140`。
- `smoke/09` 枚举归零时仍 rc=0（空目录实测）；补 `call_sites=0` 闸门，真实树 `files=7
  call_sites=5`。
- `smoke/22` 的计数把两个函数定义也算进去，删掉一处调用仍 rc=0；改成只数调用，删行后
  `11 vs 12` 红，还原 `cases=88 lastexitcode-guards=12` 绿。
- `smoke/31`：`version_gt` 定义在规则 E 之后（实测 `command not found`，函数上移）；tag
  列表用 `git tag --list` 显式判失败；规则 E 泛化到任意 `vX.Y.Z`；`printf | grep -q` 在
  pipefail 下把找到的匹配报成没找到（`smoke/01` 点名），改 here-string；自校准只打印不红
  的 `cal_bad` 改为失败。
- `smoke/02` 桩的双重 `printf` 把 `%s` 吃掉，`id` 桩输出空行；改 `%%s` 后 `cases=46`。
- `smoke/03` 的排队取消用例在**读路径慢的运行时**上有一个无法赢的时序假设：它依赖「阻塞
  任务仍占着唯一槽位」，而实测（2026-11-21，本仓共享沙箱 224 条记录）`status` ~14s、
  `logs` ~28s——受害者（`sleep 60`）能在「看到 Queued」与 `cancel` 之间真的跑完，于是
  cancel 答 2/`task_not_running`（实测连续两次，`cancel of a queued task exited 2`）。
  修的过程里有一步是错的，必须记下来：我先按「`pueue parallel 0` = 暂停」的假设改成
  「提交后把组置 0」。**Pueue 4.0.4 的 `parallel --help` 原话是
  “Setting this to 0 means an unlimited amount of parallel tasks”**——0 是不限并发，
  不是暂停。实测（2026-11-21，本仓沙箱）：置 0 之后两个 blocker 并发运行
  （327 `02:15:09–02:20:10` 与 328 `02:16:25–02:21:25` 重叠），受害者在提交后直接
  被派发，`cancel` 答 `task_not_running`（日志原话 `task 329 cancel exited 2`）。
  此前看到的「`parallel=0` 旁边任务仍在 Running」我也曾解释成「提交窗口内已派发、
  事后暂停召回不了」——那也是误读，真实原因就是同一个：0 不限制任何东西。
  **最终修法不用暂停**：blocker 提到 `sleep 300`、固定入队两个（并行度 1 下第一个
  结束后第二个立刻接上，槽位连续被占约 10 分钟），受害者提交时必然没有空槽；
  用例开头把组归一到 1 并**断言生效**（`groups.agentq.parallel_tasks == 1`），
  否则整个用例的前提不成立、应当直接红。`submit` 的 `ensure_group` 也会把并行度
  写成 1，归一是幂等的（实测 `parallel 0 -> submit -> parallel 1`）。
  **300 秒 blocker 带来一个新风险并已实测**：第二个 blocker 会一直占着唯一槽位
  直到它自然结束，而队列用例之后还有会提交并 `wait` 的用例（ambiguous identity、
  contains-label 正控、batch round-trip）——它们会被饿住（实测 2026-11-21：
  replay 断言通过时第二个 blocker 仍在 Running，结束时间还有约 4 分钟）。所以
  队列用例的断言一结束就**立即** `cancel`+`remove` 两个 blocker 并等它们从队列
  消失；EXIT trap 里那份登记保留，两条路径都结束它们是无害的。EXIT trap 的
  `restore_agentq_group` 也改了理由：它现在不是「撤销我们降下的并行度」，而是
  保证沙箱回到 `parallel_tasks=1`（服务端 `verify_group` 对其它值一律
  `deployment_state` 拒绝，任何后续命令都会失败）。
- `smoke/03` 的残留守卫认不出它**自己**的主提交记录：`.task_label` 是
  `agentq:<request-id>`，request id 为 `smoke-<pid>-<UTC 戳>` 加用例后缀，而白名单只列了
  `smoke`/`smoke-<case>` 这类裸标签——**一个都匹配不上**。实测（2026-11-20/21：我中断
  一轮套件时留下的 `smoke-47637-…-run.json`）此后**每次**运行都在守卫处退 1，正是这段
  守卫要防的永久自锁。补上按形状匹配（`agentq:smoke-<数字>-<戳>-*`），并实测两种方向：
  遗留记录在 → 丢弃并继续（绿），非本检查形状（`smoke-stale-instance-…`）不被误删。
- `smoke/01` 的 case 判空分支 `*" $tok="|*" $tok= "*` 的第一支不可能匹配（SC2195；
  bash/dash 实测），删死后仍区分空值。**门禁**：ci.yml 的 `reported_count` 按名字去重（合成
  PART+NCOV 日志旧 8 行/6 名，新 6），三处 checkout 加 `persist-credentials: false`；
  release.yml 全量 fetch tag 并在 tag push 上运行 `smoke/31`（F7：此前只在 branch push
  跑）， refuses NOT-covered；`smoke/01` 用双向夹具钉住新门禁。
- 覆盖债数字与失真文档已更正：`docs/verification-status.md` 的 W4 与 27 例数、
  `skill/references/contract.md` 的非 UTF-8 拒绝范围（补 `--workdir`、`remove --label`）、
  `windows-installer-invariants.md` 删掉「32 条每条都有 smoke 守护」的假承诺（实测
  `grep -r 'Get-Item -Force' smoke/` 为 0）。

**新锁的红证（两条）**：`smoke/12` 的 ISO 时间戳用例在去掉 `-DateKind String`
的客户端副本上实测 1 failure（`an ISO-8601 task output is not kept as a string`），
原资产 `cases=227` 全绿；`smoke/01` 的 release-gate 新锁在把 `release.yml` 的
`./smoke/31-changelog-and-tags.sh` 一行注释掉后实测红（点名「does not RUN
smoke/31」），还原后绿。

**未修边界（不声称覆盖）**：pwsh 7.0–7.4 无 `-DateKind`（7.5 之前的任何 pwsh
都会把 ISO-8601 字符串转成 `DateTime`，`-AsHashtable` 实测也不阻止——`smoke/12`
在该引擎上声明 `NOT-covered(engine-has-no-datekind)` 而不是假绿）；POSIX 侧 `wait` 预算路径的
Windows 目标身份复核只做静态/桩验证，未在真 Windows + 真 SSH 上端到端运行；本轮所有
并发与诊断测试都在本机合成运行时上，生产 Pueue/远端/凭证未验证。

### 2026-11-21 第八轮审查（全维度：6 个只读 agent + Orca Codex，审的是 v0.1.38）——修服务端 Windows jq CRLF 与队列语义、客户端形状校验、检查自身假绿，版本 0.1.38 →0.1.39

**范围与边界**：6 个只读 agent（服务端协议/并发、POSIX 客户端、Windows 客户端与安装器、
smoke 检查自身、文档一致性、防御性安全）与 Orca Codex worker 各自出报告；所有发现都在
主检出独立复现后才改，未能复现的写进边界。安全 agent 只做防御性静态分析，未构造或运行
利用载荷。生产主机一台未碰；测试机真远端的既有证据不因本轮扩展。

**服务端**：
1. **原生 Windows jq 的 CRLF 让文本/argv 校验永远判非法**（P0）。`is_valid_text_argument`
与 `is_valid_argv`经仓库自装的 `jq()`过滤（wrapper 会补行尾换行），而原生 Windows jq
写 CRLF——字节级往返校验恒不等，`submit`/`remove --label`在原生 Windows 上 100% 退 2。
改为 `command jq`直读后，CRLF 桩实测 rc=2 → rc=0。
2. **`normalize_workdir`的 `{ pwd -P; printf Z; }`状态取自 `printf`**：`pwd`失败被吞，
空 workdir 通过文本校验并入队；改为显式取 `pwd -P`的状态。
3. **`mark_request_removed`把并发的 record 消失报成失败**：另一个归档者先删了 record 时
 rename 失败被当错误；现在识别 record 已消失并按收敛处理（`recovered:true`）。
4. `ensure_*_directory`补 `chmod 700`；`ensure_group`失败从 `protocol_error`归到
 `deployment_state`。

**客户端与 Twin**：
- **Windows 批量删除接受嵌套数组**：`ConvertFrom-Json`逐层解包单元素数组，`[[{...}]]`解成
 array[1]，与扁平数组不可区分（实测 verdict=True），POSIX 客户端则拒绝。解密后的原文是
唯一保留形状的地方：新增 `Test-JsonBatchElementsAreObjects`原始文本扫描（字符串感知、
深度跟踪），`[[…]]`现在两客户端同拒（smoke/12 两方向用例）。
- **POSIX 的 launcher44/45 与 Windows 孪生分叉**：同一探针输出，Windows 答 2 +专属
消息，POSIX 透传 44/45（这两个码对调用方含义相反）；对齐为 2。
- **`generate_request_id`在 uuidgen 坏时打出 `aq-`**（空后缀），下游误报成「request-id
格式错」；现在校验 uuidgen 输出的字符集与长度，不合格落 `openssl rand -hex 16`，两者
都坏才明确报 `cannot create a durable AgentQ request id`。
- **Windows 安装器的未处理 throw**从 exit 1 +多行渲染块改为一前缀行 + exit 2（脚本级
 trap，两个安装器各一份）；`Test-NonReparseFilePath`现在拒绝目录，锁目录校验按
 `-RequireContainer`转发 `-AllowDirectory`（先打坏锁校验、被 smoke/13 抓到后修好）。
- **token 读取器**先剥 `\r`再匹配 `(?m)^agentq-exit:([0-9]{1,3})$`。边界：interior-CR
形状在 Windows 不可达——PowerShell 原生 stderr 重定向按 CR 拆行（字节级实测），
 POSIX 读原始字节才能看到；记录为架构差异，`smoke/12`不再为该形状保留用例。

**检查/门禁自身的假绿（每个都先做红证）**：
- `smoke/03`：新增 `end_task_and_require_absent`（原清理把失败吞成 0）；直接用 pueue 建的
 blocker 不再走服务端 remove（服务端对它永答 `does not identify its request`，实测 rc=2），
改 pueue 直连 `end_raw_task`；残留守卫补基础 request id 形状（`…Z`与 `…Z-*`）。
- `smoke/05`：44/45 夹具改为背靠背无换行 token（原 fixture 在 marker 后多打换行，正确资产
被报成 44——fixture 凭想象写的一类实测复现）；新增 uuidgen 坏桩用例（断言兜底 request id
以 `aq-[0-9a-f]{32}`到达远端命令且无 'request id'误报）。
- `smoke/12`：空变异体的假绿——budget-disabled mutant 若不产出远端命令，字节比较「证明」
不了比较器能红，现单独报红；**新守卫第一次跑就抓到了它防的那个形状，而且就在 harness
自己身上**：两个 Windows 变异副本（`twin-windows-nobudget`、`twin-windows-plus`）都没有
`.ps1`扩展名，实测 `pwsh -File`对无扩展名副本在 line 4 之前失败（`$script:Program`在
StrictMode 下未设，顶层 trap 再读它时二次报错），exit 1、副本整个没执行——此前
「posix 与 windows 响应不同」的断言因此一直为真，但真因是副本没跑。两份副本改名为
`.ps1`后 mutant 正常产出远端命令。interior-CR 用例删除（fixture 描述传输层不存在的形状）。
- `smoke/13`：`Get-DeadProcessId`的 `'-c exit 0'`单串被 .NET Unix 解析成三参（引号不剥），
改用 `ArgumentList`；平台门槛断言必须 exit 2 +恰一行 + `^agentq-installer: `前缀。
- `smoke/16`：`-path "$root/…"`受检出路径含 glob 字符影响（`./`前缀也打坏了 R4 豁免），
改为在 root 内 `find .`后剥前缀的自枚举函数。
- `smoke/01`：`pattern_matches_under`同因；NOT-covered 扫描不再把整行注释算作「可能打印」。
- `smoke/31`：规则 B 在重跑历史 tag 时要求后续 tag 的索引行，与「最新日志条目」规则冲突；
 `git tag --list --merged HEAD`在本仓 shallow/grafted 检出上只答 1/39 个 tag，改为快照
视界谓词（只检查不晚于 HEAD 版本的部分），四方向自校准。
- `smoke/18`：头部说明订正——占位基线是同一资产的副本，不是独立 oracle，承重的是期望
片段与 rc。
-文档：`release.yml`自 2026-11-20 起有 `Require an annotated tag`步骤（轻量 tag 退 1），
 `CLAUDE.md`/`CONTRIBUTING.md`仍写「轻量 tag 也能过」——已改。

**未修边界（不声称覆盖）**：`AGENTQ_REMOTE_PLATFORM`大小写与平台缓存归一化在孪生间的
分叉；平台缓存 `probed_at`残渣；POSIX 平台探针临时文件在命令替换里的泄漏路径；
`smoke/10`的 D2/规则 B 已知窗口；`smoke/11`的零断言形态；`smoke/02`站点扫描的覆盖
边界；`smoke/16` R4 的路径字面豁免；部分跨文档计数；安全 agent 的 P3-1/P3-3/P3-4
（只读协议即可构造的低价值信息面，未改动）；pwsh7.0–7.4 无 `-DateKind`；生产环境
仍未验证。

### 2026-11-19 第四轮终审（7 个只读 agent + Orca Codex，审的是 v0.1.34）——修 12 处，其中 1 条 P1 是客户端的中断语义（编号里有 13 条：第 3 条是本轮我自己的修复引入的回归，不算独立发现）

**已修（每条都先自己复现，再改，再证明锁会红）**：

1. **P1：在途的「前台」ssh 让 POSIX 客户端对 HUP/INT/TERM 全程失聪。** `run_ssh_logged`
   直接前台起 ssh；shell 只在当前前台命令**返回后**才跑 trap，所以 Ctrl-C 要等 ssh 自己
   结束才生效。实测（桩 `exec sleep 30`）：`kill -TERM` 后客户端 **31 秒**才退 130，期间
   完全没有反应；同一子进程改成后台 + `wait` 后 **1 秒**内响应（bash/dash/zsh 三种都
   实测）。对一个 ConnectTimeout=10 + ServerAliveInterval=15×12 的死连接，这等于三分钟
   不可中断。修法：ssh 一律 `&` + `wait`，pid 记进 `agentq_foreground_ssh_pid`，
   `agentq_stop_background_ssh` 一并 kill。锁：`smoke/28` 第 10 例，**两个独立断言**
   （客户端 10 秒内退出 + 桩 pid 已消失）——只断言 pid 会漏：子进程 30 秒后自己结束，
   pid 也「消失」。红证实测：撤销资产改动即报 `was not acted on until 31s in`。
2. **后台化会吞掉调用方 stdin（同一改动的反向风险，已实测并加锁）。** 非交互 shell 的
   后台作业以 /dev/null 作 stdin（bash/dash 实测），而 `0<&0` 救不回来——dash 上读不到字节，
   必须先把 fd 0 dup 到高位 fd 再 `0<&9`。锁：`smoke/28` 第 11 例，桩把 stdin 读进文件与
   payload 逐字比对；删 `0<&9` 即报 `the backgrounded ssh received no stdin`。
3. **「fd 0 是否可 dup」的探测本身会杀死脚本。** 第一版写成裸 `exec 9<&0 2>/dev/null`；
   fd 0 关闭时 bash 与 dash **整个脚本退出 2 且无 stderr**（实测），在 `smoke/05` 里表现为
   「`AGENTQ_SSH cannot be launched` 不见了、只剩一个光秃秃的 exit 2」——看起来像协议拒绝。
   改为在子 shell 里探测、父 shell 内再 dup 一次（两次之间 fd 0 理论上可关闭，所以第二次
   也放进 `if` 里而不是裸语句）。这一条是本轮我自己的修复引入的回归，`smoke/05` 抓到。
4. **安装器的维护锁对「死持有者」永久拒绝（0.1.28 引入，影响生产）。** 两行把极性写反：
   `[ ! -e pid ] && [ ! -L pid ] || maintenance_lock_fail_unconfirmable`——pid 文件**不存在**
   时右侧触发，于是**死持有者留下的锁永远无法恢复**，只能人工删目录。删掉该分支让控制流
   落到后续 `is_stale` 判断（fail-closed）。原先那条 `unrecoverable stale maintenance lock`
   用例断言的是 `cannot confirm the owner`，**它一直靠缺陷变绿**——已订正期望消息。
5. **安装器静默忽略 argv。** `install-agentq.sh --check` 会**完整安装**一遍：所有路径都由
   环境变量决定，argv 从未被读过。现在 `--help` 打印用法退 0，其余任何 argv 拒绝退 2；
   `smoke/11` 两例（`argv-refused=covered`）。
6. **安装器 `grep` 的 rc 折叠可静默覆盖客户端。** 共址守卫把 rc=2（读不出）与 rc=1（不是
   wrapper）当同一「继续」，一次瞬时读失败就覆盖仍在服务的客户端。改为 rc 0/1/其余三分支。
7. **两份客户端的协议值比较不等价（六处）**：Windows 侧 `"success" -ne "Success"` 为 False
   （`-eq` 不分大小写）、`$x -eq $true` 接受字符串 `"true"`、`PSObject.Properties[…]` 索引器
   与成员访问都不分大小写、探针 token 正则 `\d` 匹配 Unicode 数字、`.Trim() -eq` 与
   `-like "MINGW*"` 同理；`sshp` 的主机空白判定用 `[[:space:]]`（随 locale 变：NBSP 在 C 下
   非空白、UTF-8 下是空白）。分别改 `-ceq`/`-cne`/`-clike`、`-is [bool]`、精确属性遍历、
   `[0-9]`、`LC_ALL=C tr -d ' \t\n\r\f\v'`。锁分布在 `smoke/12` 与 `smoke/19`。
8. **PS 5.1 上平台缓存永不命中**：`ConvertFrom-Json -NoEnumerate` 在 5.1 不存在，参数绑定
   直接抛错，被 catch 吞成 miss。改为按 `Parameters.ContainsKey("NoEnumerate")` 分支。
9. **服务端 `remove_task` 的 request-record 读取 fail-open**：`record=$(read_request_record …)`
   没有 `local record_read_status`，rc=2（读不出）与 rc=1（不存在）走同一分支，一次瞬时
   读失败就把「已移除」报成别的结果。补 `case 0/1/*` 三分支，`*` 即 `fail`。
10. **服务端 `logs --tail` 无上界**：`--tail 99999999999999999999` 被原样交给 Pueue。新增
    `is_bounded_line_count()`（剥前导零、长度 ≤10、≤2147483647），超出按**参数错误**退 2
    （不是误导性的 exit 1）。锁：`smoke/02` 两例，变异（去掉上界）实测红。
11. **五处检查自身的假绿**：`smoke/01` 的 step 级 `continue-on-error`、`.cmd` 的
    `%ERRORLEVEL%` 传播、版本常量重复赋值（`grep -m1` 读第一处而 shell 用最后一处）；
    `smoke/10` 规则 D2（ACL 读回必须被读）；`smoke/31` 规则 E（v0.1.31 起 tag 必须
    annotated）；`smoke/12` 的 exit-token 读取器枚举过窄；`smoke/05` 的 wait 预算耗尽用例。

12. **macOS 上 `sudo -v` 被拒会把安装器永久锁死（Codex 报告，已复现并修复）。** 维护锁在
   `authorize_macos_root` **之前**就已取得，而 `remove_installer_file` 在 macOS 上**一律**经
   `run_as_root rm -f`——包括 `$HOME` 下的锁元数据。于是「用户拒绝 sudo / 没有权限」这一
   完全正常的输入，会让 EXIT trap 的释放失败、把 `.agentq.maintenance.lock/pid` 留下；
   而**陈旧锁的恢复走同一个提权助手**，所以**之后每一次**安装都报
   `cannot recover stale AgentQ maintenance lock`，只能人工删目录。实测（沙箱 HOME +
   拒绝型 sudo 桩，v0.1.34）：第一次 `sudo authorization failed` 且 HOME 留锁，第二次
   `cannot recover stale ...`。修法：只在**目标目录确实需要提权**时才走 `run_as_root`
   （复用既有的 `installer_directory_needs_elevation`），`$HOME` 下的删除回到普通 `rm`。
   锁：`smoke/11` 两例，红证实测 3 处失败、修复后 `cases=46`。

13. **非 ASCII 空白主机名的孪生分歧（本轮复审后自查发现，已修）。** 第 7 条只把 `sshp` POSIX 侧的空白判定改成 ASCII 字节集，
    但同一条规则的两个方向都没对齐：`agentq` 的两处主机判据（`AGENTQ_HOST` 读点、host-shape 守卫）在 POSIX 侧仍是
    `*[![:space:]]*`（**随 locale 变**），Windows 侧是 `IsNullOrWhiteSpace`（**Unicode 集**）；配置文件值的字符类两侧是
    `[^[:space:]]`（LC_ALL=C）vs `[^\s]`（.NET）；`sshp.ps1` 用 `\s`。实测（2026-11-19，同一台 macOS）：
    - `AGENTQ_HOST` = 纯 NBSP 或 U+3000：`LC_ALL=C` 下 POSIX 退 **255**（值真的交给 ssh，可重试类）、`en_US.UTF-8` 下退 **2**、
      Windows 恒退 **2** —— **同一 argv 三个答案，其中两个在同一台机器上**。
    - 配置文件 `AGENTQ_HOST=a<NBSP>b`：POSIX 连到 `a<NBSP>b`（255），Windows 报「no SSH host configured」（2）。
    - `sshp --check <纯 NBSP>`：POSIX 在探针 READY 时退 **0**（完全放行），Windows 退 **2**。
    修法：两侧统一为 **ASCII 字节集 ` \t\n\r\f\v`**（与 0.1.27 给 `--workdir` 定的同一规则）——POSIX 新增
    `ascii_whitespace_only()`（在 `AGENTQ_HOST` 读点之前定义；首个调用者比参数解析早得多），Windows 新增
    `Test-AsciiWhitespaceOnly`；配置行字符类两侧都改为 `[^ \t\n\r\f\v]`；`sshp.ps1` 改为 `-match '[ \t\n\r\f\v]'`。
    锁：`smoke/05` +12 例（3 码点 × 2 locale × 2 路）、`smoke/12` 孪生 host 表 +3、config 表 +3（并去掉
    `ws_env_offenders` 的 AGENTQ_HOST 豁免）、`smoke/19` +4（两码点 × 两 locale 的**接受**方向）、`smoke/20` +2。
    两处变异自测的锚点随之搬家（旧 `case` 分支的 sed 锚点改成谓词里的那行；配置量词的锚点从 `[^\s]` 改成新字符类），
    锚点找不到时自测**报红**而不是静默跳过——实测旧锚点在改名后立刻报「not found」。
    **边界**：`sshp` POSIX 侧仍拒绝**任何位置**的 ASCII 空白而 `agentq` 只拒绝纯空白值，这是两套契约，未变。

**记为边界（不修，理由见下）**：

- **`sshp` 同样前台起 ssh，且有 `-tt` 交互会话**。它不在 `run-tests.sh` 的中断覆盖里，
  而交互会话的中断语义（用户按 Ctrl-C 期望的是**把 SIGINT 交给远端**，不是本地退出 130）
  与客户端根本不同——把客户端的 `&`+`wait` 形态照搬进 `sshp` 会改变交互行为。未在真机
  验证之前不动它。
- **POSIX 信号不 kill 在途 ssh 的远端一侧**：本地 kill 掉 ssh **不会**终止远端命令
  （2026-10-28 实测，真实 sshd）。本轮修的是**本地**失聪，远端仍由 `AGENTQ_WAIT_BUDGET`
  兜底；Windows 目标没有这个兜底，已在 SKILL.md 记为边界。
- **`ps51=NOT-covered`**：本机只有 pwsh 7.5.4，PS 5.1 上的行为（含第 8 条的参数绑定）没有
  执行证据，只有静态规则保证没有用 7 专有 API。

### 2026-11-18 第三轮终审（7 个只读 agent + Orca Codex，审的是 v0.1.33）——修 5 处，订正 3 处文档，3 条发现证伪

**已修（每条都先自己复现，再改，再证明锁会红）**：

1. **repair 回退循环的 `read_status` 跨迭代未清零（Codex P2）。** 回退循环里
   `output=$(…) || read_status=$?` 只在读取**失败**时赋值，`read_status=${read_status:-0}`
   也不清已有值——一条被拒/消失的记录之后，下一条合法 `removed` 记录沿用上一次的状态，
   走「已消失」分支 `continue`，**不归档**。在 0.1.33 上实测：构造「第一条是符号链接记录、
   第二条是合法 removed 记录」，`status` 退出码正常，第二条记录原样留在盘里；只有
   `read_status=0` 放在每次尝试之前才归档。锁：`smoke/26` 的 V6b（注入的 `rm` 计数门控 +
   计数器预置，使消失发生在**快路径**、回退得以运行），旧资产报
   `records=1 tombstones=0, expected 0/1`，修复版 `cases=139`。
   这一条与 0.1.33 的 tombstone 侧死代码是同一段循环的两半，但**可达性不同**：那两行测试
   永不被求值，而这里的过期状态确实决定分支。
2. **平台探测缓存的读取形态两份客户端不一致。** POSIX 用逐行 `sed … | tail -n 1`：JSON
   数组根 `[{…}]` 命中并给出 `unix`，`{…}{…}` 取**最后**一个对象；Windows 侧反序列化对
   数组给出空 `platform`、对尾随内容抛错——同一个缓存文件两侧可能得出不同平台。POSIX 改
   整文件匹配 + 要求 `"platform"` 恰好出现一次 + 拒数组根；Windows 显式拒数组根、
   `-NoEnumerate` 反序列化并检查结果是对象。锁：`smoke/05` 新增一例，**抽取资产里的
   `platform_cache_read` 直接驱动**（旧资产 `HIT:unix HIT:unix HIT:windows`，新资产
   `HIT:unix MISS MISS`）；`smoke/12` 的缓存形态表补数组根与尾随对象两格。
3. **Windows 客户端的 `removed` / `output_encoding` 仍是宽松比较。** 0.1.32 把
   `state`/`action`/`result`/`cancellation_mode` 改成了 `-ceq`，漏了这两处：`-eq` 让
   `"removed":"True"`、`"removed":1`、`"output_encoding":"BASE64"` 全部通过（pwsh 7.5.4
   实测三种都是 `True`），而 POSIX 的 jq 过滤器要求真布尔与精确小写。改为 `-is [bool]` +
   `-ceq`。
4. **`smoke/05` 的块读锁是行级的。** 原断言是 `grep -q 'OpenStandardInput\|\.Read()'`
   与 `grep -q 'ReadByte\|\.Read()'`，**整文件任意位置**命中即可：把 launcher 的
   `$Reader.Read()` 循环换成 `$Reader.Read($block, 0, 4096)`（正是要防的块读）、再在一行
   `param(` 注释里留个 `ReadByte`，三个文件的断言全部通过（实测）。改为锚定读取调用
   （`OpenStandardInput\(\)|Reader\.Read\(\)` 与 `\.ReadByte\(\)|Reader\.Read\(\)`），
   同一变异体现在报 1 条失败。
5. **`smoke/31` 的规则 D 接受空验证行，且临时文件只删主文件。** 单独一行 `  |` 也算
   「验证行」；校准夹具里没有这种形态，所以它一直是绿的。规则改为
   `^[[:space:]]*\|[[:space:]]*[^[:space:]]`，校准补一条 bare-bar 夹具。trap 原来只
   `rm -f "$work"`，`.index`/`.log`/`.tags`/`.newest` 四个派生文件留在 `$TMPDIR`——那是
   仓库内容的整份副本；改为 `"$work".*`。

**文档订正（不改变行为，但原话与代码不符）**：

1. `SKILL.md` 两处与 `contract.md`/`install.md` 各一处说「队列概览请用 `status --summary`，
   它没有 doctor 那个副作用」。实测 `status()` 的第一句就是 `ensure_daemon`——pueued 未
   运行时它同样会 `start_managed_daemon`。正确的说法：**所有**协议命令都不改队列，但都可能
   启动服务，「只读」只指前者。要真正只读，直接 ssh 过去看文件。
2. `SKILL.md` 说 tombstone 保留命令文本。`make_request_tombstone` 只投影
   `version/request_id/task_id/task_created_at/state/removed_at`——不含 `payload`。
   数据留存的说法改为「记录（含 `payload.argv`）在任务移除并归档前一直在；tombstone 不含
   命令文本」。
3. `README.md` 的示例 `--request-id nightly-01`（10 字符）违反自己文档的 16–128 规则，
   改为 `nightly-build-01`。

**证伪、未修（各自实测或读码确认）**：

1. **「`wait --timeout` 的预算在传输重试时重置」**（Codex P2-3，称实测 4.11s 超了 2s 预算）。
   源码里预算取自 `wait_timeout_seconds`，重试循环（`agentq_operation_attempt`）不重置它。
   我实测（桩 ssh 睡 30s、预算 2s、重试 3 次）：exit 6，`--timeout 2` 用时 3–4s，
   `AGENTQ_WAIT_TIMEOUT=2` 两次都是 4s——超出的 1–2s 是本地预算的**整秒轮询粒度**
   （`sleep 1` 后判、加上 kill/wait 与进程启动），不是重试把预算重算了一遍。没有改。
2. **「客户端接受 `lookup` 的 `accepted` 状态」**（协议 agent P2-1）。服务端确实从不产生它，
   但客户端**容忍**一个未定义状态不等于缺陷：拒绝它会让未来服务端新增状态时旧客户端硬失败。
   记录为边界，不改。
3. **「维护锁元数据不可读时静默退出 2、没有 reason」**（服务器 agent P1）。读码：
   `ensure_not_in_maintenance` 的 `unowned)` 分支调 `maintenance_lock_unowned`，后者以
   `deployment_state` 失败；该 agent 自己贴的实验输出也是带 `reason=deployment_state` 的
   退出 2。判为误报，**未实测**（它给的路径需要把维护锁目录做成不可读，本轮只读了控制流）。

另有 **7 条来自 Windows/安全/POSIX 三个 agent 的发现未逐条落地**（PowerShell 5.1 下
`& $script:SshPath` 对含 `=` 结尾的 base64 参数的处理、`sshp.ps1` 的码点与码元上界、
`File.Replace` 的 ACL 继承、Windows 客户端 65536 字符的流读取上限、远端 `~/.local` 可写
即等价于代码执行、`submit --workdir` 的 TOCTOU、响应体无长度上限）：它们要么**只能在
真实 Windows 5.1/真机上验证**（本机 pwsh 7 无法复现参数绑定行为），要么是**设计边界**
（提交者本来就能指定任意目录；能通过 ssh 以某账户登录本来就能执行命令）。记为边界，
不在本轮改——按本仓规则，没有复现证据的改动不进资产。

**我自己的一处错向改动（已撤回，记录以免重犯）**：曾把 Windows 侧七个数值/路径变量的
`![string]::IsNullOrEmpty($env:…)` 改成 `$null -ne $env:…`，理由是「POSIX 的 `${VAR-default}`
把空值当已设置」。`smoke/12` 的 `empty-means-default` 与 `config-empty` 两行**立刻变红**——
这两行就是那条契约的锁：空值在两侧都表示「未设置、用默认值」，`IsNullOrEmpty` 才是对的
一半。改动与随之写下的注释已全部撤回；`smoke/05` 里我一度加进去的「空值必须被拒」用例也
一并撤掉（它会把错误方向钉成契约）。

### 2026-11-17 补红证（0.1.33）——0.1.32 的 ⑯ 无法证伪，还原为 0.1.31 形态，只删死代码

用户要求给 0.1.32 的 ⑯（批量扫描「只有 rc=1 才写占位」）补红证。结论是**它在可达世界里
不产生任何差别**，因此 0.1.33 把它还原成 0.1.31 的形态，并删掉其中两段**死代码**：
写入后从未被读取的 `guards_status`（`if ! cmd; then` 块里的 `$?` 是取反的 0，测试永远不成立，
而 `|| exit 2` 分支又到不了——`fail` 早已结束该子 shell）。其余与 0.1.32 逐字节相同，
`cmp` 可证（除版本常量）。

**试过的、每一个都实测过的形态**（macOS bash 3.2.57，最小复现 + 真实资产上的夹具）：

1. **守卫拒绝 = `fail` = `exit 2`**，在 `$( )` 里的 `for … | jq` 左端执行。`for` 本身在
   `$( )` 的子 shell 里做管道第一段时**并没有**因为 errexit 中止（见 4），所以 `if !` 块里的
   `$?` 测试确实会跑——但它读到的是取反后的 `0`，于是照写 `null` 继续；`|| exit 2` 那条分支
   永远不被求值。把两行换成 `exit 2`、`exit 7`、`true`，同一夹具（record/墓碑路径是目录）
   的答案**完全相同**。
2. **把测试挪出 `if !`**（`st=0; guard || st=$?; [ st -ne 0 ] …`）：这样测试能读到真状态，
   但在单文件读者层（`request_tombstone_is_valid`）与批量层都仍是 5——原因见 3、4。
3. **`wait`/`repair` 的批量结果先被别的检查裁决**：`removing` 记录被 `recover_removing_requests`
   先处理，`lookup` 走的是单文件读者，`wait` 的墓碑扫描之前还有 `ensure_request_marker`。
   构造出不经过它们的夹具后，批量层仍然**走回退**（failing batch → per-file loop），回退路径
   对同一文件本来就响亮失败——所以「批量层修没修」在输出上不可区分。
4. **`PIPESTATUS` 在下一个语句就已经重写**（即便下一个语句是 `printf`），在 `||` 臂里
   `exit` 只结束臂所在的组，再外层的捕获又重推一次；照抄本仓「`exit` 只结束子 shell」
   的教训，在管道上还要再加一层：管道只报**最后一段**的状态。

**结论与决定**：不写一个「永远绿」的锁去假装覆盖它。0.1.33 的资产 = 0.1.32 − 那两段死代码
（版本常量除外），并在 `PLAN`/`CHANGELOG` 里如实记下这次还原与上述实测。**没有**为此新增
用例；`smoke/26` 保持 137 例。若将来有人要给批量扫描加状态守卫，先读这一节：真正要问的
不是「测试写没写对」，而是「测试被执行时 `$?` 是谁的、守卫失败后这颗子 shell 还活着吗」。

### 2026-11-16 终审（7 个只读 agent + Orca Codex）——修 5 处、记 6 条边界

**已修（每条都先自己复现，再改，再拿红证）**：

1. **P0：一次 `jq` 读取失败把仍在跑的任务归档成 removed。** `reconcile_accepted_request` /
   `reconcile_removing_request` 里的 `task_label=$(jq -r '.task_label' <<<"$record")` 无守卫，
   而这两个函数跑在 `if` 条件里（errexit 关闭）。注入一次 `.task_label` 读取失败（rc=5、无输出）
   即可复现：`lookup` 对 Pueue 里仍是 `Running` 的任务返回 `5 / state:removed`，**删掉活记录、
   写入 removed 墓碑、一次 Pueue 都没有动**。修法是两处都改成 `|| fail`。锁：`smoke/26`
   新增 L9/L10（含一条不注入的正控，否则分不清「注入生效」与「夹具本来就坏」），红证跑过——
   回退修复后 L9 报 `expected exit 2, got 5` 并 rc=1。
2. **`install-client.sh` 的共址守卫 fail-open。** `grep -q ... &&` 把 rc=1（不匹配）与 rc=2
   （读不出）当成同一个「不是服务端 wrapper」，一次瞬时读失败就覆盖活 wrapper。改成捕获
   grep 的退出码、只认 rc=1 为「继续」，其余具名拒绝。锁：`smoke/21` 新增一条（PATH 里放一个
   「只把本该匹配的调用变成读失败」的 grep 桩），红证跑过——回退后四条断言各自报错、rc=1。
3. **tombstone 读器缺大小写别名守卫（两个读器对同一 id 给两种答案）。** 大小写不敏感宿主上，
   小写文件名 + 大写拼写的 `lookup` 在 record 侧退 2（有守卫），在 tombstone 侧却**命中别人的
   墓碑并回答 `5 / state:removed`**——一个调用方从未用过的 id 得到「已移除」这个终态答案。
   已把别名检查抽成 `request_metadata_has_case_alias`（两个读器共用），tombstone 读器补上同名
   拒绝。锁：`smoke/26` 的 L8b（只在大小写不敏感宿主上跑），红证跑过。
4. **`smoke/01` 的 `.ps1` 编码臂对「带 BOM」的文件等于不检查。** 原来 BOM 分支是无条件
   `continue`，于是给保留 BOM 的 launcher 末尾追加 `\xff\xfe` 仍报 `ps1_encoding=checked`
   全绿（smoke 审查复现）。现在 BOM 分支继续要求 BOM 之后是**合法 UTF-8**（`iconv` 往返），
   双向校准过：正常资产通过、追加坏字节的副本被拒。
5. **`smoke/12` 的本地命令预算静态锁可由注释满足。** 原来的 `grep -q '32767'` 被文件里多处
   引用该数字的**注释**满足，把真实赋值改成 65535 仍全绿。改为匹配「Win32NT 分支里的独行
   32767」，并加双向校准（出货资产必须通过、把赋值抬高而注释不动的副本必须被拒）。

**记边界、本轮不修（都有实测，都不是「已覆盖」）**：

1. **两份客户端的 `--stdin-script` 上界在 unix 目标上不一致。** POSIX 接受 100000 个 base64
   字符；Windows 客户端把远端命令**再 base64 一次**（PS 5.1 的引号问题所致），同一 argv 元素
   里是二次编码的载荷，因此本地预算更紧：实测 74000 字节脚本 → POSIX 退 0、Windows 客户端
   本地退 2（`base64 length 97756 exceeds 97753`）；而同一个客户端跑在 **Windows 宿主**上时
   本机命令行上限是 32767，可发送量降到约 24000。已把两个数写进 `SKILL.md` /
   `references/contract.md`（并给出可移植的 24000），但**孪生等价性在这条上不成立**——要拉平
   得改 Windows 客户端的传输层（去掉外层编码），那是一次独立的重构，不在本轮范围。
2. **Windows 客户端渲染会去掉模板的 BOM**，非 ASCII 的 Git 安装路径在 PS 5.1（非 UTF-8 ANSI
   代码页）下会被读成另一条路径，安装因此失败（**推断**：渲染与解码两半各自实测，未在真
   Windows PS 5.1 上跑完整安装）。
3. **macOS LaunchDaemon 形态下 `~/.agentq` 的凭据只靠父目录 ACL**；SKILL.md 已在 Windows 侧
   记为 A28 边界，macOS 侧同样记为边界，不另加机制。
4. **POSIX 安装器每次安装/升级都对 `$HOME/.local` 与 `$HOME/.local/bin` 执行 `chmod 700`**
   （`replace_wrapper`），收紧后不回滚；若用户原本是 0755、或其下 `~/.local/share` 被别的
   工具共享，这是可见副作用。改法是「只建不收紧」或「记录原模式、回滚恢复」，属于安装策略
   决定（收紧本身是安全意图），交 owner 定。
5. **`smoke/01` 另有两条检查质量问题未修**：`zsh`/`xmllint` 只探「在不在 PATH 上」、
   不探「跑不跑得起来」（与 `pwsh-unusable` 同形，但还没踩过）；`[[ ... ]]` 的用法落在所有
   POSIX 静态锁之外（当前 9 个 shell 资产都是 `#!/bin/sh`，`[[ ]]` 在 dash 上是运行时错误）。

**审查做法本身的两条**：① 7 个 Claude agent 全部跑在**独立 worktree**里（历史教训：提示里写
「只读」挡不住 `cat >`，曾有审查 agent 把 222 KB 资产截成 0 字节）；② 每条发现都由我在主
检出里独立复现或证伪之后才落地——本轮里「`TMPDIR` 未设会让客户端退 2」这条就被证伪（实测
`resolve_agentq_temp_directory` 用 `pwd -P` 把 `/tmp` 解析成 `/private/tmp`，未设与设了行为
相同）。

另一类**同形但未修、也未实测**：`AGENTQ_ASKPASS` 指向一个没有执行位（POSIX）/无法启动
（Windows 上的 `.ps1` 之类）的文件时，POSIX 客户端本地退 2（有 `-x` 守卫），Windows 客户端
放行、到 ssh 才退 255。Windows 没有 POSIX 执行位的对应物，要判「能否启动」得照 `AGENTQ_SSH`
那条 10 秒探针再做一份——代价与收益本轮未评估，记为边界而不是定论。（`AGENTQ_PASSWORD` /
`AGENTQ_PASSWORD_PROMPT` 在 Windows 客户端上明确不支持并具名拒绝，那是有意的平台差异。）

### 2026-11-17 第二轮终审（7 个只读 agent + Orca Codex）——审的是 v0.1.31 本身

**这一轮的方法论要点：上一轮的修复本身也要被审。** 7 个 agent 全部跑在独立 worktree 里，其中
一个的**唯一职责**就是审 e1083e0 这个提交，而不是只审产品。

**先记一条我自己的教训**：审到一半我看到 `fail 'cannot inspect Pueue while reconciling …'`
这条消息在有守卫的路径上变得有歧义，就动手改文案——**还没证明有后果就先改**。随即 `git checkout`
撤销：本轮的任务是审查，改动必须建立在复现之上。这条写在这里，是因为它正是本仓反复纠正的
「先伸手、后取证」。

**这一轮的落地（每一条都在主检出里先复现、再改、再反向证明锁会红）：**

- **`logs` 的读取仍是 fail-open（服务端）。** `compact_log` 里四处 `jq` 读取都以 `|| var=''`
  收尾，而 `logs` 由 `if`/赋值上下文调用（errexit 关闭）：一次读取失败只把变量清空，不改变
  控制流——决定走哪个分支的那个变量被静默当成「没命中」。复现：让 marker 读取失败一次，
  **0.1.31 上 `logs` 仍退 0**，把 Pueue 替换进去的文本当成任务输出交了出去（正是 0.1.24/0.1.25
  花了两个版本修的那条路径的**反方向**）。四处改为显式失败。**`fail` 写在赋值里时，它的
  `exit 2` 只结束命令替换的子 shell**——所以父 shell 还必须 `return` 那个状态，否则本轮
  新增的临时文件不会被清理（实测：只写 `) || fail …` 时清理函数不执行）。锁：`smoke/03`
  新增一条基于真实运行时的用例，shim 只让那一条 jq argv 失败一次。
- **`smoke/01` 的「成功行必须插值版本」规则可被行尾注释满足，且只看第一条匹配行。** 复现：
  把成功行改成打印 Pueue 版本、行尾追加 `# … ${agentq_version} …`，旧规则全绿。改为逐行
  判断（剥掉引号外的注释，所有 `installed at` 行都必须插值），并加两种逃逸形态的双向校准。
- **`smoke/12` 的开销常量锁是整文件 grep**，注释掉定义（三处全注释）仍绿。改为匹配
  `$script:LocalCommandLineFixedOverhead = <整数>` 赋值行本身，并加双向校准。
- **`smoke/16` 的自检失败会被 SKIPPED 吞掉。** 该检查在 memory 目录缺失时打印 `SKIPPED`
  并退 0，而 run-tests 取的是**第一行**含 SKIPPED 的输出——自检门的失败行因此永远读不到。
  复现：禁用一处自检 + memory 目录不在 → 退出仍 0、只显示 SKIPPED。修法：自检失败单独、
  先于 memory 状态无条件退 1。
- **`smoke/12` 的 `twin_ws_rows` 只有下限**：把 9 次调用全删、手写 `twin_ws_rows=9` 仍绿。
  **只加了一个上界**（高于合理的用例数即说明计数器被外部写入），因为「计数器只能由
  `twin_ws_case` 递增」这件事 shell 没有原语可钉。
- **`smoke/05` 的小写 `not-covered` 被 run-tests 当成 SKIP 词**（匹配 `SKIPPED` 与 `skipped`
  时都不区分大小写），于是在没有严格 POSIX shell 的宿主上那段用例静默消失且计入 SKIP；
  同时它的候选表只用 `command -v`，磁盘上有 `/bin/dash` 也用不到。两处都改了（绝对路径
  按 `-x` 探测；声明改为 run-tests 能看见的写法）。
- **文档计数**：`verification-status` 里 `26` 的「122 例」是 0.1.31 前的数字（现 137）、
  `21` 的行数 305 与用例数 14 也都是旧值（现 322 / 15）、`22` 的「510 行」未标版本
  （现 517）；`PLAN` 里「291 条任务 / 286 条 request record」被当成矛盾——它们不是同一个
  计数对象，已写明。

**第二批（Orca Codex 的独立审查，15 项；逐条复现后才改）：**

- **服务端持久化字段读取的 fail-open（2 个 P0 + 3 个 P1，同一个类）。** Codex 报的
  八处站点与我这一轮在 `logs` 里修的是同一形状，但后果更重：读失败得到空值后仍走
  状态转换与写入。我全量枚举了服务端里「命令替换里 `jq -r` 且后面不跟 `||`」的站点，
  共 **47 处**，全部加了守卫（`x=$(…) || fail "cannot read the AgentQ …"`），并单独
  处理了三种变体：条件上下文里的 `[ "$(jq …)" = … ]`、`case "$(jq …)" in`、
  多行命令替换里的 `--arg requested_at "$(jq …)"`，以及 `find_request_task` 外层
  `||` 保护不到的内层读取。合成台证据：`submit` 的 `.state` 注入后由「重绑并答复用
  成功」变为退出 2 + `reason=protocol_error`、record 字节不变、`pueue add` 未调用；
  `cancel` 的 marker `.state` 注入后由「重新 kill + 覆写 marker」变为拒绝、marker
  不变；`remove` 的 `.state` 注入后仍在退出 1 之前被守卫拦住。**边界**：这些是本地
  语义验证（合成运行时 + 只失败一次的 jq 桩），不是真实 Pueue 或远端的验收。
- **POSIX 摘要校验缺 key/id 绑定**：修好后 `{"tasks":{"01":{"id":1}}}` 退 2，与 Windows
  孪生一致。
- **Windows 客户端把协议字符串当大小写不敏感比较**：`-eq` 在 PowerShell 里对字符串
  不区分大小写，`"REMOVED"`、`"success"`、`"BASE64"` 因此与规范值等价；`removed` 只判
  `-eq $true`，`"true"` 与 `1` 也通过。改成 `-ceq`/`-ccontains`，并补上 `removed` 的
  布尔类型判据。
- **`smoke/21` 的 rc=2 用例从未进入它声称的分支。** 实测：PATH 桩会被安装器的漂移
  检查那处 grep 先消费成 exit 2，`chmod 000` 又会被安装器自己的可读性预检挡住，所以
  守卫的 `*` 支从没被执行；把守卫的 `0` 与 `*` 两支折叠的变异**全绿**。改法是给安装器
  一个 `AGENTQ_INSTALL_CLIENT_GREP` 间接层（默认 `grep`，不新增 argv），三条分支各一条
  用例，并加「桩真的生效」的正控；折叠变异与「删掉拒绝」变异各自变红（后者 5 处失败）。
- **`smoke/01` 的 `local_hazards` 规则抓到了我自己的新代码**：第一版守卫把变量写成了调用方
  的局部名（`validate_task_removal: record_task_id`），01 退 1 并点名两个孪生文件；补 `local`
  后绿。这正是那条规则的存在理由——它在我身上当场生效了一次。
- **`smoke/03` 的排空槽位循环数学上不可能成功**：`submit` 每次把 agentq 组的并行度
  重置为 1，循环里「加阻塞任务直到有一个排队」永远只会看到 1 个槽位。它此前一直是在
  「运行中的任务被 cancel」这条分支上变绿——`cancel` 的答复里没有 `cancellation_mode`
  时被断言抓到，归因信息也一并补上。
- **同一条用例的第二、第三版都在「我以为的 Pueue 行为」上栽了，是交付前最后一轮
  自测抓到的**（2026-11-17 深夜，均在独立 `pueued` 沙箱上实测）：
  1. 第二版把组降到 `parallel_tasks 0` 就提交——但 **Pueue 4.0.4 会照样分派**：新建组
     降为 0 后 `add -- sleep 3`，任务一秒内进 Running。组设置拦不住新任务。
  2. 第三版改成「每个尝试加一个阻塞任务，等它 Running 再提交」。实测反例：1 个 Running
     阻塞 + 1 个刚 add 的 Queued 阻塞、组为 0 的时候提交，**新加的那个先 Running，
     victim 停 Queued**——这正是本版要的状态；但同一沙箱里 **8 个阻塞在排队、组为 1
     时提交，victim 排在最前面**（组一旦被手动 start 过，整队按顺序一个 tick 内全部
     分派）。也就是说「槽位只有 1 个」这个前提本身不成立，版本三的失败是真实竞态。
  3. 现在的前提按沙箱实测收紧：**提交前组必须为 0、且所有阻塞都是 Running**（提交
     调用本身会经 `ensure_group` 把组抬回 1，这是设计；抬回 1 后的一个 tick 里，
     第一个可用槽位随队列顺序分派——实测 1 Running + 1 Queued 时先起 Queued 那个）。
     一次尝试失败时，把「抢了槽位的那个阻塞」也结束掉，下一次从同一状态起步。
  仍记为**未验证**的边界：本机 `pueued` 与 CI 上的 `pueued` 都按 `parallel 1` 配组，
  其他 `pueue.yml`（例如 `daemon` 段起 worker 数不同）下的分派顺序没有证据。
  **独立沙箱的对照**（2026-11-17 深夜）：同一份配置、同一套二进制，全新 `pueued` 上第一次裸提交
  就会 Queued（组还没被启动过）；而主沙箱那台 `pueued` 已运行两天多，队列里有一批当天更早的运行
  留下的终态任务，裸提交与「一个阻塞」两次都被派发。两者的差别只在 pueued 运行时长与历史队列内容，
  **分派规则本身没有查清**——所以定稿不依赖它，只保证失败时点名「没有一次提交进入 Queued」。
  5. **第五版（定稿）：只信 AgentQ 服务端自己的 `status`。** 第四版仍以 Pueue 的
     Running 作为门槛，而在**重启过的主沙箱**里它直接失败：一个本进程之外的任务已占着
     组里唯一的槽，新加的阻塞排在它后面。沙箱与主沙箱的差别经查是 pueued 的**运行时长**
     （两边的组设置都是 1）。SIGKILL 掉 pueued 再拉起也复现不了「已启动的组整队在一个
     tick 内分派」，那一观察因此**没能复现**，不再作为依据。
     定稿的形态：阻塞任务带 `AGENTQ_SMOKE_BLOCKER=1` 标记（判据只看服务端给出的命令、
     只结束带本标记的任务），先清掉上一次运行留下的阻塞；每次尝试加一个阻塞、用服务端
     `status` 等它 Running、提交 victim、再用服务端 `status` 判它是否 Queued；只有
     victim 仍是 Running 才换一轮重试（它一旦 Done/Failed 就不可能再变 Queued），8 轮
     仍不成就**失败并说明**。EXIT trap 无条件把组并行度恢复为 1（`restore_agentq_group`），
     否则一次中断的运行会让该运行时的新任务永远排队，后续每个用例都以看似无关的方式变红
     ——这是审查 agent 指出的最高优先级问题，已修。
     这一段的代价：`smoke/03` 变长（每次重试一轮 `sleep 60` 阻塞），主沙箱里单次运行
     由约 3 分钟增至约 5 分钟；CI 上的 Pueue 是全新沙箱，通常第一轮就成功。
  6. **第六版（定稿）：先裸提交，必要时再加一个阻塞。** 主沙箱的实测表明「组里只有 1 个
     槽、且每次 `submit` 都会把组抬回 1」这个前提本身不稳定（同一台机器上先后观察到
     「已启动的组整队分派」与「严格 1 个槽」两种行为，差别仅在 pueued 运行多久），所以
     版本五里「等新阻塞 Running 再提交」在组已经被启动过的机器上会等不到。定稿：第一次
     只提交受害者（新建组里它本来就 Queued）；若它跑起来，才加**一个**阻塞、等服务端
     报 Running、把组降到 0 再提交第二次；第二次也跑起来就**收掉受害者并停止**（不再
     加第二个阻塞——已启动的组会整队分派，加也没用）。每次提交后立即把组抬回 1。
     真实队列是 `parallel_tasks 1`，只加一个阻塞，且落在那台机的真实配置下（不是 `0`）。
  7. **第二次尝试必须换 request id。** 沙箱实测两次：第一次的受害者被 `remove` 之后，服务端
     写墓碑、墓碑按保留期保留，而 `submit` 对「有墓碑的 id」一律退 `2` `already consumed`
     ——同一 id 复用是走不通的（契约如此，不是缺陷）。定稿里第二次尝试用 `-queued2`；
     用例要读的 `victim_task_id` / `victim_request_id` 由最后成功的那次覆盖。
     实测状态（2026-11-17 深夜，独立沙箱）：以一条已存在的**墓碑**（上一条运行留下的
     `smoke-…-bin` 等，保留期内不消失）为背景，`smoke/03` 端到端跑通，摘要里
     `cancel-queued=queued_removed/5`——即这次真的走过了 Queued 分支。主沙箱里它仍可能
     失败：那台 pueued 已运行两天多，本进程之外的历史任务占着组里唯一的槽，而本检查只会
     结束带自己标记的任务（不会去动别人的队列）——那时错误消息会点名「没有一次提交进入
     Queued」，**不会假绿**。主沙箱那一次运行的实测还纠正了「先裸提交」这一版：受害者在
     提交后一秒内就跑到 Running（`states: Done`），「跑起来再加一个阻塞」永远来不及——
     最终形态是**两个阻塞在第一次提交之前就位**，第 1 次提交在组为 1 时、第 2 次在组为 0 时。
  8. **「每次尝试换一个新 request id」而不是「第 2 次换」**：主沙箱的整套运行里，受害者在
     提交后一秒内就跑到 Done（`states: Done`），第 1 次尝试以「已结束」收场、需要再试，
     而「第 2 次换 id」的方案在再试时又用了被判定的 id → `already consumed`。现在每次尝试
     都有独立的 `-queued<n>` id，最多 4 次；被派发的受害者先 `cancel` 再 `remove`（只剩
     `remove` 对 Running 任务会被 Pueue 拒绝，实测在 aqsb5 里留下了记录），并等它从服务端
     消失。另：ambiguous 用例的任务若已从服务端消失，它的记录没有任何命令能收尾（`remove`
     要活任务、墓碑路径要 `removing` 记录），此时按形状（本次 request id）直接删并打印一行；
     上一次运行留下的本检查形状的记录（标签是 `smoke` / `smoke-<case>` 之一）在启动时被点名
     清掉，不再拒绝运行。**主沙箱的全量套件**（2026-11-17 06:41 起跑）随后以同一版本走到
     `cancel-queued=queued_removed/5`——即在那台 pueued 已运行两天多的机器上也是真的 Queued。
  9. **推送后的 CI（Linux，GitHub Actions run 43982913615）同一提交 `PASS 31 ran, 1 skipped,
     0 partial, 0 failed`，`smoke/03` 摘要同样是 `cancel-queued=queued_removed/5`**——新的
     queued 用例在 Linux 与全新沙箱上第一次跑就成立；跳过的 1 条是 `16`（CI 上无 memory 目录，
     `NOT-covered`）。macOS job 只跑 `--quick`。
  4. **第四版：基于 `pueue status` 的「Running」门槛在本机沙箱里不成立。** 端到端跑
     `smoke/03` 时报「only 0 of 1 blocker task(s) reached Running」，而队列里那个阻塞
     任务显示 `Done`、耗时近 60 秒——`sleep 60` 被提前结束。此前手工探测时，同样的读取
     给出过 `[0 Running, 1 Running]` 而组写着 `parallel 1`（即 `pueue status` 把没跑过
     的任务也算成 Running），一个阻塞被「当 Running 后」又被 `remove` 的收尾路径同样可疑。
     结论：`pueue status` 的 Running **不能当证据**，门槛删掉。现在的形态不预测 Pueue——
     第 n 次尝试加 n 个 `sleep 60` 阻塞 → 提交 → 用 **AgentQ 服务端自己的 `status`** 判
     victim 是否 Queued；不是就 `remove` 掉 victim（不用 `cancel`，否则会给下面的重放
     用例留下 cancellation marker）与占位阻塞，清掉 record 后加更多阻塞重试；8 次都不成
     则**失败**并说明，绝不假绿。**未复现、未定位**：`sleep 60` 为何提前结束、`status`
     为何给 Running，这两件事本身没有根因，只是不再依赖它们。

**第三批（终审后的复核，2026-11-17 深夜）：** 一个只读 agent 报「`wait`/repair 的批量
扫描把路径守卫的拒绝（exit 2）和文件消失（return 1）折叠成同一件事」。核对到三处调用点
（`repair_removed_request_records`、`wait_reconcile_missing_task` 的 record 与 tombstone
扫描），**其中两处**（wait 的 record 扫描与 tombstone 扫描）被改成了写 `null` 占位的形式；
第三处（`repair_removed_request_records` 的批量扫描）当时**没有**进管道的那种形态，
`request_record_path_guards_or_fail "$path"` 那行是它改到一半时的读法（2026-11-18 复核：
`git diff` 里只有两处新增 `guards_status`，repair 的批量扫描直到 0.1.33 都是原样）。
**2026-11-18 补记**：这个「守卫拒绝被 `2>/dev/null` 吞掉」的缺陷**真实存在**，但可观测性
与当时的说法不同——在 `if ! guard; then …; printf null; continue; fi` 这个形状里，
`| jq` 收到的是 `null` 占位而不是空输入，批量**成功**并把被拒记录当作「没有这个文件」，
批量因此回答 `not found`/`removed`；把它改成 `exit 2` 或 `true` 才逐字节不可区分。
原始说法（「变成这一批没有这个文件」）在 `||` 形状下成立，在 `if !` 形状下不成立。**未写用例（但有变异证据）**：构造「record 被换成符号链接」的夹具要改动运行时数据目录
的形态，本轮没有做。**还没有红证**：符号链接夹具与「回退守卫 → 变红」的变异证明都应当补上，
**2026-11-17 补记**：上面这段的修复在 0.1.33 被还原——补红证时实测它「只有 rc=1
才写占位」的那两行测试写在 `if !` 块里，`$?` 恒为 0、`|| exit 2` 求值不到，换成
`exit 2`/`exit 7`/`true` 同一夹具答案逐字节相同，见本文件 2026-11-17 节。**2026-11-18 再补记**：
wait 的 record 批量扫描（`request_record_path_guards_or_fail "$path" || { guards_status=$?; … }`）
里那两行**仍在**，0.1.33 只删了 tombstone 侧同样的两行；保留的这一侧在守卫拒绝时同样到不了
`exit 2`（`$?` 读到的是取反后的值），行为上与删除前等价，同样只是死代码——这次没有一并删，
以免把这轮「只动 tombstone 侧」的变更面再扩大。以下保留原文作当时判断。

本轮**没有做**，所以这一条按「已修、未证明」记——`smoke/26` 的注入点全部落在
`.task_label` 读取，`repair` 与 `wait` 的批量扫描都不经过那里，不能拿来当它的锁。该 agent 的另一条（`repair` 回退循环预读下一行、`fail` 覆盖前一条
消息）我按「下一行的 id 尚未失败」判断为误报，**未修**，理由记在此处以便复核。

**未修、如实记为边界**：`agents` 那边报的「共享管理员 Windows 主机：服务端在
`C:\ProgramData\AgentQ`、客户端在用户目录，同一台机器上不同用户的客户端看不见彼此的
删改」——那是对部署模型的理解问题，不是资产缺陷，且涉及未授权的另一台主机。

## 六、执行状态

按时间顺序的逐轮记录（第五轮审查、A 系列、C 系列、性能折叠等）**已拆到
[`docs/plan/execution-log.md`](plan/execution-log.md)**——那份文件是历史证据，不是现状；
资产与 `smoke/` 里的 `A5`/`A5b`/`A6`/`A21`/`A28` 等编号引用都指向它。

现状只读两处：`docs/verification-status.md` 的覆盖表（每个检查证明什么/不证明什么）与资产本身。
待办只看本文件第三节（C 类）与各轮末尾的「记为边界」段。

## 七、各轮审查记录（第九轮起）

### 第九轮全维度终审（2026-11-22，审 v0.1.39；6 个只读 agent + Orca Codex）



六个只读 agent 分域审源码、三平台安装/使用故事与检查自身；Orca Codex 独立审同一棵树。以下每条都在主检出里先复现/读证据再动手。

### 服务端（`skill/assets/unix/agentq-server`，与 windows-git-bash 孪生逐字节同步）

- **remove 的第二次 record 读取可被并发归档击穿。** `mark_request_removed`先读一次 record（rc=0），随后 `validate_task_removal`又读一次。两者之间 `status`/`logs`/`doctor`的锁外 `recover_removing_requests`可以在任务消失后把该 `removing` record 收敛为 `removed`并归档，第二次读于是答 rc=1，`fail "missing AgentQ request record while removing task"`退 2——一次成功的 remove 被报成失败，且重试只会得到 `unknown AgentQ task id`（0.1.29 修过同一形状的另一半）。修法：`validate_task_removal`接受调用方已读的 record（第二参数），`mark_request_removed`传自己的那份；并把「第一次读就看到 `removed`」当作同一收敛：校验 record 仍指向本任务实例后幂等归档、`removal_recovered_archive=true`退 0。`mark_request_removing`仍让函数自己读（此时状态是 `accepted`，归档路径不可达）。
- **锁恢复的「先验后删」TOCTOU。** `remove_stale_lock`校验 pid/identity 后**按路径** `rm` pid 再 `rmdir`。并发恢复者 A 可以先删掉目录，新持有者随即 mkdir 并写入自己的 pid，此时 B（早已完成校验）的 `rm`删的是**活锁的元数据**；B 的 `rmdir`还可能删掉新持有者的空目录。实测形态不要求两个恢复者「同时」校验——窗口只要覆盖 A 的删除 +新持有者的 mkdir。修法：改用**原子 rename 捕获**。pid 分支把 `pid`原子改名为 sibling `.stale-capture.$$`，对新路径重新 `read_lock_metadata`并与期望值比对；不匹配则 `mv -n`放回、退 2（changed），绝不删除别人的记录。`require_empty`分支把**整个锁目录** rename 到 sibling 捕获名，再检查它仍只含元数据临时文件；不符同样放回。`rmdir`的退出码成为权威判据（成功后重现的目录属于新持有者，不报错）；失败时若路径上是不同的 pid 则退 2。
- **`acquire_operation_lock`把「changed」当致命错误。**读路径早已容忍 `remove_stale_lock`的 rc=2（另一次恢复先动过手），写路径却 `fail`。现两处分支都按读路径处理：rc=2 → `continue`重试，其余非零才 fail。
- **维护锁同一形状（死持有者 /陈旧空目录两分支）。**安装器与 server 的维护锁恢复都是「再确认身份 →删除」。改为同样的 rename 捕获：unix 死分支捕获 `pid`、windows 分支捕获锁文件、empty 分支捕获目录；捕获后重新读身份/空性，不符就放回并让上层按 contention/unowned 回答。**安装器自己的锁恢复未改**（见边界）。
-同步：`cmp skill/assets/unix/agentq-server skill/assets/windows-git-bash/agentq` =0。

### Windows 客户端（`skill/assets/client/windows/agentq.ps1`）

- **`wait`的 stdout 被 64KiB 静默截断。** `Invoke-WaitSshWithTimeout`与平台探针共用 `$maximumStreamCharacters = 65536`；截断后没有标记、没有错误，protocol 校验失败被报成「JSON 协议错误」。POSIX 孪生对操作响应**不设上限**（写临时文件）。修法：wait 的 stdout 改为 `[int]::MaxValue`（平台探针保留自己的有界读取）；stderr 是诊断流，保留 64KiB 但在诊断中显式追加 `[stderr truncated after N characters]` / `[stderr read failed: …]`；stdout 真被截断时（理论上不可达）打印本地点名的消息。
- **非批量响应的顶层数组被接受。** POSIX 用 `jq -s`把 body 读成数组并取 `.[0]`，`[{...}]`于是变成 `[[...]]`，`.[0]`不是对象 →拒绝。`ConvertFrom-Json`把单元素数组**展开成元素本身**，Windows 侧的 `submit`校验于是接受 `[{"task_id":1,…}]`。实测（pwsh7.5.4，抽取校验函数）：object=True / array-of-one=True；修后 array-of-one=False。修法：非 `remove_batch`操作先按**原文**裁掉 JSON 空白字符，要求首字符是 `{`，与 `remove_batch`已有的根形状原文扫描同一手法。
- **`AGENTQ_PASSWORD_PROMPT=0`的平台分歧。** POSIX 把 `0`当「禁用」，Windows 对任何非空值都拒绝（实测 `AGENTQ_PASSWORD_PROMPT=0 agentq --version`：POSIX0 / Windows2）。Windows 不需要支持该变量，但共享环境不该因禁用拼写失败：`0`放行，其余非空仍拒绝。冲突检查（与 ASKPASS/PASSWORD 同设）保持与 POSIX 一致。

### POSIX 客户端（`skill/assets/client/unix/agentq`）与安装器

- **wait 预算耗尽时清理失败会改写 124。** `run_wait_ssh_with_timeout`在超时分支里先清理再 `return 124`，清理返回 1/2 时直接 `return $?`，调用方的 `-eq 124`不再成立，文档化的 exit 6 变成普通失败。修法：清理失败只打印诊断，始终 `return 124`。
- **两处「声称不泄漏」的清理实际泄漏。** Windows 探针脚本临时文件在 identity 记录失败时调用 `windows_argument_remove_file`（空 identity 必拒）后又把变量清空；ssh stderr 捕获同理。修法：这两处按路径 `rm`（路径刚由 `mktemp`在本进程私有临时目录里创建），并订正注释。
- **非 POSIX 的 `local`。** `ascii_whitespace_only`/`workdir_is_blank`使用 `local`（SC3043）；在没有 `local`的 `/bin/sh`（Solaris Bourne、posh、ksh88）上每次调用都会产生 command-not-found 诊断，变量还会泄漏成全局。改为函数唯一前缀的全局变量（两处各一个名字），行为不变。
- **安装器的 `maintenance_lock_empty_grace_seconds`无校验。**非数字值让 `test`打印 `Illegal number`并恒假，陈旧空维护锁永远不被回收，报出的却是「younger than the grace period」。启动时按其它数值环境变量的同一判据校验（仅数字），非数字退 2 并点名变量。

### 检查自身（smoke/、CI）

- **`smoke/31`的规则 D 校准测的是手抄副本。**检查里声称「SAME functions, extracted by sed」，实际校准用了一个复制的 `newest_has_verification`。实测：只把真实判据放宽成 `^[[:space:]]*\|`，校准仍 `ok`、摘要仍 `newest-verified=yes`。修法：抽成 `newest_entry_block` + `newest_has_verification`两个函数，规则与校准都调用它们；红证：把同一判据放宽后运行，校准报 `an empty verification line (" |") passed`并 exit 1。
- **CI 可能静默丢掉 tag/索引门禁（P2）。** `smoke/31`在看不到 tag 的检出里打印 `NOT-covered(no-tags-in-checkout)`并退 0；`run-tests.sh`归入 NCOV，CI 的 PASS 正则与 known-set 都放行，唯一防线是 `fetch-depth: 0`，没有任何断言验证它真的生效。修法：linux job 的断言步增加 `grep -qE '^changelog-and-tags: index=[0-9]+ tags=[1-9][0-9]* ' smoke.log`（成功摘要本来就打印 `index=/tags=`）。
- **`smoke/03`的三处清理/断言缺口。**①记录在每个 id 的 server remove **之前**被删除，服务端 remove 于是因缺 record 答 2，Pueue 任务存活，且 re-remove 循环的 `record_still_active`立刻 break；改为先让服务端尝试、记录最后删。② EXIT trap 对 pueue 直连的 blocker 只能答 2（无 request record），新增自包含的 raw `pueue kill/remove`尽力清理（引用 `${blocker_ids:-}`，早退时为空）。③失败任务的 wait 断言只排除 exit 0 与 `Done.result == "Success"`，2/5/6 也能过；改为必须 `-ne 1`即失败。
- **`smoke/05`的 uuidgen 诊断措辞。**它 grep `'request id'`期望命中的是「被误报成 malformed --request-id」，而客户端的本地校验消息是 `--request-id must be …`（无空格），这个分支永远不会触发；同时正确的 `cannot create a durable AgentQ request id`反而会被误报。改为 grep `-- '--request-id must'`。
- **`smoke/12`的变异锚点随实现改名。**去掉 `local`后，blank-guard 变异锚定 `$stripped`会找不到（自杀式自检）；同步改为 `$agentq_ascii_whitespace_stripped`。cfgpath 的「Windows 诊断必须点名 config path」用例只 `cases++`，不受 floor 保护（整段删掉仍绿）；新增 `twin_cfgpath_diag_rows`计数与 `-ne 1`断言。
- **`smoke/27`的 text-mode-jq 夹具没有阳性对照。** shim 若退化成 LF，服务端不会安装 jq 换行 shim，s10/s11 不经过被测路径也全绿。新增：用合法 JSON 喂 shim，`od -An -c`必须看到行内 `\r`（`grep -qF '\r'`），否则失败并点名夹具。
- **边界（未改）**：`smoke/12`的变异体仍只比较「两侧退出码不同」，没有「变异体确实执行过」的守卫（0.1.39 用 `.ps1`改名修掉了实测到的那次，但形态仍在）；`smoke/01`的 `plutil`不在工具清单里（macOS 自带，缺失时 `plist=N`不触发断言）。

### 记为边界（未验证/未修，不声称覆盖）

- **安装器 `install-agentq.sh`的维护锁/操作锁恢复仍是「再确认后按路径删除」**（server 侧已改为 rename 捕获）。修安装器的恢复路径需要同一组捕获/回滚语义，且只能在一次真实升级里验证；本轮不动，记录为已知窗口。
- **安装器的进程身份探针假设 procps/BSD `ps`**（`ps -o lstart=`、`ps -o command=`）；BusyBox `ps`两者都不支持，依赖门禁只要求 `ps`存在。本机无法验证 BusyBox 宿主，记为未覆盖。
- `smoke/03`的 raw 清理是**尽力而为**：kill 后最多 5s 等 remove；失败不改变检查结论（下一次运行仍会清理），且不覆盖「runtime 被 SIGKILL」的形态。
- 锁捕获崩溃残留：`<lock>.stale-capture.<pid>`可能与锁目录并存；server 的运行时目录清理表不认该名字（维护锁 sibling 也不在清理范围）。正常路径会删掉，只有捕获途中崩溃才留下一个条目，记录为已知残留。

### 第十轮终审（2026-11-22，审 94af63e / v0.1.39）

范围：源码 + Linux/macOS/Windows 安装/使用 +检查自身；6 个只读 agent + Orca Codex。

修复（每条均有红证或修复前/后实测）：
-服务端 UTF-8 校验器：`jq -Rsj`输出的是字符串原样字节（不转义换行），文本模式 jq 会把值内 LF 变成 CRLF，合法多行 label/argv 在原生 Windows 上被判非法（实测 `610a62` vs `610d0a62`，submit 退 2）。改为 hex token 比较 + CRLF 折叠的二次接受；smoke/27 s11b。
- sshp 双端解析器：unsafe（reparse）候选从 `throw`改为 `continue`（与 install-client.ps1 同一契约），否则探针在输出任何 `__SSHP_*`前异常退出、客户端误报部署故障；smoke/19 用真实函数（AST 加载）执行。
- sshp 孪生路由：unix 探针上的 `:Windows`标记必须再跑 Windows 探针；修前 rc0、修后 rc127（实测，跟随探针报 UNAVAILABLE）；smoke/19 新用例。
- Windows 安装器 group 查询改走 `Invoke-AgentQInstallerPueueStatus -CommandArguments "group --json"`（UTF-8 ProcessStartInfo），GBK 主机上非 ASCII 组名不再破坏 JSON。
-维护锁元数据残留（安装器与服务端两侧）：`mkdir`与 `mv pid`之间被杀会留下 `.agentq-lock-metadata.*`；空锁回收判据放宽为同一前缀的正规文件（删除后再 `rmdir`），其他条目仍然拒绝。smoke/11 +2、smoke/27 m2b/m2c。
-文档：Windows `-StageDirectory`必填与 5 个 stage 资产、Pueue 离线通道、升级前提（既有 daemon 可达；Windows 既有二进制必须匹配当前 pin，pin 变更需人工换二进制）、`--check`的执行位语义、残留拒绝顺序；修正过期行数与用例数。

- CI 的 `smoke/31`门禁断言锚点写错：smoke.log 的摘要行带 `ok    31-changelog-and-tags`前缀，`^changelog-and-tags:`从未匹配；v0.1.40 首推（f5e3402）的 linux job 在「Assert the full suite really ran」步无消息退 1，而套件本身 PASS 31/0/0/0。改为锚定 `^ok +31-changelog-and-tags +…`，注释写明；修复提交 2b0937f。
新增覆盖：smoke/11 cases=51、smoke/19 cases=155、smoke/27 cases=164。

边界（未验证，不声称）：
-本轮未触碰任何真实 Windows 主机（用户未在会话中点名）：WinGet 链接/别名是否 reparse、GBK 主机实装、本地化 ACL 名、.NET4.5.2 下 `ToUnixTimeSeconds`、环境块 32767 溢出、`AGENTQ_PLATFORM_CACHE_DIR`的 cygpath 转换，均只有代码级判断。
- Windows 安装器在 pueue pin 变更时的升级/回滚仍会被预检拒绝；这是刻意的防篡改行为，已写入 `skill/references/install.md`。

### 第十一轮全维度终审（2026-11-23，审 c901165 / v0.1.40；4 个只读 agent + Orca Codex）

范围：源码全量 + 三平台安装/使用故事 + 检查自身；每条发现在主检出里先复现/读证据再动手。版本 0.1.40 → 0.1.41。

### 服务端（`skill/assets/unix/agentq-server`，孪生逐字节同步）

- **P1：fail 消息展开未赋值变量 → 子 shell 崩 → 调用方读成「不存在」→ 重复入队。** 复现（`jq -r length` 在 `find_request_task` 内注入一次失败，macOS bash 3.2.57 与 nginx:1.30.7 的 bash 5.2.37 都实测）：`$( )` 里 `set -u` 的 unbound expansion 以 rc=1 终止子 shell，submit 的判据 `[ rc -ne 0 ] && [ rc -ne 1 ]` 把 1 当「无可见任务」，于是对**已可见同标签任务**的 request 调 `pueue add`、退 0、`reused:false`。修前 CONTROL=复用/0 add，INJECTED=add×1。
  - **探针推翻的旧认知（必须先量再修）**：本轮先前记录「同函数裸 `local x` 在两版 bash 下都安全」只对 **bash 3.2**——bash ≥4.4 下同函数未赋值 `local` 的裸展开同样 unbound（实测 `same-52 rc=127`）。所以危险面不是 14 处跨函数站点，而是**全部 90 条 `fail` 里展开 `$task_id` 的行**（多数是自引用 `X=$(…) || fail "…$X"` 形态——失败命令恰恰没来得及给 X赋值）。
  - 修法：90 处统一改 `${task_id-}`（实测 3.2/5.2 与命令替换内均安全、零退出）；复现点改报其真实查询键 `$task_label`（该函数的参数，恒有值）。不改写扫描顺序、不发明新变量——`fail()` 上方加契约注释，smoke/01 加静态规则（见检查自身节），smoke/27 加行为锁 S16。
  - **S16 的教训（断言在正确树上失败 = 它在教你契约）**：第一版 S16 对「armed 失败不改 record」的快照取自 control **之前**，而 control 合法地把 prepared 恢复成 accepted——红的是我的测试假设，不是生产代码。快照改在 control 之后、armed 之前。双向红证：退回裸 `$task_id` → S16 报 4 条（含 `unbound variable` 原文）；还原 → 182 例全绿。
- **静态锁 `fail_msg_vars`（新分类器 `smoke/01-fail-msg-vars.py`）**：同函数视角判「fail 消息展开已 `local` 声明但在该行之前无赋值」；`${x-}`/`${x:-}` 豁免；`x=$(…) || fail "…$x"` 的自引用形态按「同一行且赋值在 `||` 之前」判违规。跨函数动态作用域读是**声明盲区**（无 `local` 声明即不在判定域），由消息形态改造 + S16 行为锁兜底，盲区写进分类器 docstring。
  - **两轮假阳性校准**：第一版把 `if request_id=$(…)`（if 是赋值位！）与 `while IFS= read -r x; do`（read 变量以 `;` 收尾）读成未赋值，真树报 50 行。教训与农场分类器同型：**新静态规则的第一次真树运行就是它自己的假阳性证明**，必须先双向夹具（12 条）+ 真树清零再谈红证。
  - 端到端红证必须是**双侧同步变异**：单侧变异先被 parity 规则拦下，红的是错的规则（本轮真踩过一次，靠 grep 红证输出词才发现）。

### dev 工具 `sandbox.sh`（Codex P0/P1）

- **标记所有权改内容 token**：`down`/`up` 此前只认**文件名** `.agentq-sandbox`，预置空文件 + `AGENTQ_SANDBOX_ROOT=<目标>` 即可让 `rm -rf` 删任意树（Codex P0）。现 token=`agentq-sandbox v1` 由 `up` 写入、`owns_sandbox_root`（常规文件 + 首行精确匹配）在 `down`/`up`/`cleanup_partial` 三个读点统一判定。**兼容性是本机可见的**：旧沙箱留空标记 → 新代码拒收 → 手工 `printf 'agentq-sandbox v1\n' > marker && down` 恢复（本轮实测走过）。smoke/30 的 9 处 fixture 改从被测文件读 token（夹具与实现不双写），新增 planted-marker 双案例（up/down 各一，红证：校验退回 `-f` 只看名字 → 3 条红、哨兵被删）。
- **signal 前复核进程身份（P1）**：`ps` 快照与 `kill` 之间 PID 可被复用。`daemon_is_still_ours` 用**同一 argv 判据**逐 pid 复核，不可读=不 signal。锁是双向的：control（复核仍见 daemon→必须 reap）+ reuse（复核改报无辜→必须放过）。第一版只断言 reuse 方向，对「去掉首道复核」的变异**全绿**（daemon 还活着，两形态都给同一答案）——双向性缺失正是被自己抓到、被 control 方向补上的。
- **curl 夹具的传输模型必须先量**：给 fetch_verified 的清理断言加「失败留部分文件」时，我先在注释里**断言** curl `-f -o` 失败会留文件——本机实测（本地 403 服务器 + curl 8.7.1）恰恰**不留**。注释改为记录实测，fixture 保留种部分文件（更难的状态），并对清理行做删除变异 → case 红，证明断言承重。**「凭想象写 fixture」在本仓是第三次撞钟**（ssh stderr 那次之后）。
- 过程性自纠：本轮用 python 字符串手术删 `rm -f "$cached"` 时把 `until` 循环削断（语法红才暴露）——变异编辑要用**整块替换 + `bash -n` 立即验证**，不用 index 拼接。

### 安装器

- **无 HOME 时先答 `--help`（Codex P2，实测）**：两份 POSIX 安装器第一条 `$HOME` 展开在 argv 处理之前，`env -u HOME sh install-agentq.sh --help` 报 `HOME: unbound variable` 退 1。修法：help/argv 判定整体提到 `$HOME` 依赖之前，安装路径自己答 `HOME is not set…` 退 2。install-client.sh 的 `AGENTQ_CLIENT_BIN_DIR` 默认值**延后到 argv 解析之后**展开，并加 `destination_explicit` 旗标——`--bin-dir ''` 的既有拒绝契约（smoke/21）必须走**显式设置**分支而不是 env 存在性分支；第一版用 `${VAR+set}` 判显式，被 smoke/21 当场抓红（`AGENTQ_CLIENT_BIN_DIR=` 也算已设置）。
- **stage 身份即时记录**：`prepare_service_stage` 在 `create` 成功后**立刻**记录 identity（原来在全部内容渲染之后），失败中断路径因此可清理；结尾改为**比对**重取的 identity 与创建时的记录（中途被换内容即拒，防「重新记录」把替换洗白）。动机：agent B 实测两次中断各留一个 `.agentq-plist.stage.*` 孤儿 + 清理拒绝无身份文件。
- **注释失实修正**：`maintenance_lock_empty_grace_seconds` 的注释声称服务端读同名环境变量——实测服务端 agentq-server:285 **硬编码 30**，只有安装器可 env 覆盖。注释改述实测。
- **未改、记为边界（本轮验证过现状后刻意不动）**：
  - 安装器 `wait_for_operation_lock` 无「仅元数据陈旧」恢复臂（服务端有）。安装器的 `remove_stale_operation_lock` 拒绝无主锁、空锁宽限逻辑只存在于维护锁侧；补这一臂需要给操作锁新建 capture/回滚语义且只能在真实中断下验证——维持「宁可退 2 不可误删」。
  - Windows 目标临时文件的两处「identity 失败→保留不删」泄漏（Codex P2）：这是**策略**（不可归属宁漏勿错删），与 wait-stderr 分支同族，沙箱不可利用（mktemp 名 + 0700 目录），保留现状。
  - `AGENTQ_PLATFORM_CACHE_DIR` 空白/相对值：`skill/references/clients.md:71` 把「空≠未设置、进入正常校验」钉成**三实现一致的实测契约**，收紧校验=破坏文档化契约，需跨两语言协调一轮，本轮不动。

### PowerShell 侧

- **sshp.ps1 补 `[Console]::OutputEncoding` UTF-8 守卫**：agentq.ps1 早已有、姊妹没有——同族「守卫只落一个孪生」缺陷（此前 macOS LaunchServices 探针在同对文件上漏过、活了九天）。锁做成**遍历两个 PS 客户端**（存在性 + 位置双断言），位置判据锚 dispatch 行（`switch ($operation)` / `Prepare-Remote`）——第一版锚 `script:SshPath` 首现，被 agentq.ps1 的 `$script:SshPath = $null` 声明行误伤，锚错对象是检测器自己的缺陷。GBK 真机效果仍不可本机验证，记边界。
- **平台缓存 TTL 计算挪进 try**：`Read-PlatformProbeCache` 的 `ToUnixTimeSeconds` 在 try 外，.NET 4.5.2 宿主（PS 5.1 下界）上**每条 auto 命令**在 dispatch 前 MethodException。第一版修复（epoch 算术改写）被两个自测推翻：`[int]` 强转把 Int64 秒数截进 2038（smoke/12 4054 行的 `probed_at` 契约正是 2026 年的 10 位数），而 4.6+ 上「修一个未证实风险引入一个新风险」不成立；且「移进 try」在 4.5.2 上同样只是把崩退 2 变成走探测路径。最终取**最小形态**：ttl/age 两行移入既有 try，catch 的 `return $false` 语义=「缓存未命中」，pwsh 功能探针四路（fresh hit/未来时间戳拒/过期拒/写读 round-trip 形状）实测不变。4.5.2 真机不存在——**该崩溃路径保持未证实**，PLAN 与代码注释都写明。
- **规则 L：强制杀必须「最后一次查询之后有身份复核」**：`Stop-ManagedPueueProcessTree` 的 descendant 循环在 CIM 枚举+验证之后又按旧 PID `Get-Process` 再 `Stop-Process -Force`，两次 lookups 之间没有身份检查（Codex P1）。锁的判据不是窗口也不是「函数里有检查」（旧代码的验证在**紧邻的上一循环**，任何窗口/函数级判据都放行它）——按文件线性扫：最近 LOOKUP 行 vs 最近 IDENTITY 信号行，`Stop-Process -Id * -Force` 落在 identity<=lookup 即违规。三形态各自验证：修复后的 descendant（同语句 gate）绿、root（Get-Process→StartTime 比对→Stop）绿、**退回旧形态红**。作用域从 `grep -rl Stop-Process` 派生（不是手写清单——规则根从树上派生是既定教训）。rule_sites 计数 10→11；L 的「sites」是**普查到的强制杀语句数**（违例必须为 0 才可绿，sites>0 证其未瞎），这处语义偏差在 smoke/10 注释里写明而不是藏进算术。

### 检查自身

- **7 个 smoke 的信号 trap 改 `cleanup; exit 130` 双行形态**（Codex P2）：handler 返回后脚本**继续跑**（本机实测输出 `after-signal`），已删工作目录被继续访问。EXIT 行保持 `trap cleanup EXIT`（`$?` 不被改写），HUP/INT/TERM 显式 130。smoke/28 全绿复跑（它本身就是测 trap 的）。
- **smoke/01 校准夹具移出仓库**（Codex P2）：`smoke/_ncov_calibration_fixture.txt` 固定路径 + finally 删除 → SIGKILL 即残留污染工作树；改 `tempfile.mkdtemp`，断言键名随夹具 basename。
- **ci_pin 扩一条：windows 作业子集=声明遵守 `AGENTQ_SMOKE_PWSH` 的检查集合**（agent D P1 的结构化替代）。判据不是猜的：`for check in` 循环解析自 ci.yml，与「扩展了该变量的检查」求差，唯一豁免 `19-sshp-contract` 写死在注释里（它自身会打印 `skipped(pwsh-absent)`，撞上该作业自己的 `grep SKIPPED` 拒绝——这是**读过的行为**，不是推测）。双向红证各一（删豁免条目→报 19；从循环删 22→报 22）。检测器扫全体 smoke/*.sh 含 smoke/01 自己——**规则文档里写出变量形态会被自己扫到**，注释措辞避开扩展形态。
- **三处文档漂移修正（活文档，按日期注记）**：HANDOFF 的 SKIP 清单 4 项→6 项（`15`/`17` 的判据与前四**逐字相同**，逐一 grep 验证后补名）；verification-status 的 `rule_sites_checked 必须为 8`→11 与站点数不再钉死（该数由运行时打印）；CLAUDE.md 权威口径是**五次**损坏，smoke/01 注释里的「twice/两种消息」同步修正。`##第十轮终审` 补空格（blame：2727/2769 两节同批 c4d7455 落地、内容不同，**不是重复段**——本轮先怀疑重复、后以 blame 证伪，只修渲染）。

### 记为边界（未验证/未修，不声称覆盖）

- 本轮未触碰任何真实主机（用户未点名）；Windows 生产、.NET 4.5.2、GBK 真机、PID 复用的内核级竞态全部是脚本模型。
- Codex 的 sandbox P0/P1 修复针对**本机可达面**（文件层、argv 层）；OS 层 PID 复用窗口只能收窄不能消除（复核与 signal 之间仍有理论窗口）。
- `fail_msg_vars` 静态规则看不到跨函数动态作用域读；该家族由 S16 行为锁 + 全量消息改造覆盖现状，新代码若再引入需行为锁跟进。

### 第十二轮（0.1.42，2026-11-24）：交接复核——0.1.41 自己引入的 stage 残留

范围：按第十一轮交接汇总逐条复核（HEAD/tag/CI/覆盖账/修复站点），**只**动复核中实测发现的新缺陷。用户未点名任何主机，本轮未触碰真实主机。版本 0.1.41 → 0.1.42。

### 复核实测通过的部分（不重复记账）

- `HEAD = origin/main = 75a1a45`，annotated tag `v0.1.41` → 75a1a45（`git cat-file -t` = `tag`）；工作树干净、无 stash；五个 review worktree 都是**本地分支**，与远端无关。
- CI run 45134831509 三 job 全 success（windows/linux/macos），linux 日志行 `PASS checks: 31 ran, 1 skipped, 0 partial, 0 failed (728s)`；release run 45134844620 success（`tag v0.1.41 is an annotated tag` + 八处版本记录）。
- 版本常量 8 处（两个安装器、服务端与孪生、README、SKILL.md frontmatter、两个客户端）**全部**是 0.1.41；孪生 `cmp` = 0；`diff -rq skill ~/.agents/skills/agentq` 无输出。
- 覆盖账可复核：`skill/assets` 23 个资产 `wc -l` 合计 **37,227**；分子九项逐项等于 417（294 + 8 + 110 + 5）；`git diff v0.1.40..HEAD -- <分子九项>` 为空。
- 修复站点逐条在树上核对：`${task_id-}` 恰好 **90** 处、`find_request_task` 计数失败消息报 `$task_label`、`marker_token='agentq-sandbox v1'` 且 `owns_sandbox_root` 三处读点、两份 POSIX 安装器无 HOME 时 `--help` 退 0 / 安装退 2（实测）、`sshp.ps1` 的 `[Console]::OutputEncoding` 守卫在位、`Read-PlatformProbeCache` 的 ttl/age 两行在 try 内、smoke/10 规则 L 的 sites=34 violations=0、7 个 smoke 的 `exit 130`。
- **两侧红证复跑**：把 90 处 `$task_id` 在副本里全部退回裸形态 → `smoke/01` 的 `fail_msg_vars` 报 3 条并退 1；只把 `find_request_task` 的计数失败消息退回 v0.1.40 原文（含 `$task_id`）→ smoke/27 S16 报 4 条失败，stderr 里是 `line 4872: task_id: unbound variable` 与「记录在失败路径上被改写」，与交接汇总描述的机理逐字一致。
- 全量套件（本机 macOS + `/tmp/aqsb` 真 pueue 沙箱）：`PASS checks: 31 ran, 0 skipped, 0 partial, 0 failed (4432s)`，`FULL-EXIT=0`。

### 新缺陷（P1）：`prepare_service_stage` 每个平台臂建了**两个** staging 文件，第一个成为永久残留

- **机理与实测**：0.1.41 为「创建后立刻记录身份」插入的块**自带一行** `service_stage=$(create_installer_temporary_file …)`，而原有的创建行仍在——于是两个臂都创建两次：第二次的路径覆盖变量，第一次的文件**没有任何变量指向它**，留在 `$agentq_parent` 里。这不是中断才发生的残留，而是**每一次成功安装**都在制造它，且任何清理路径都够不到：EXIT trap 只认识第二个路径，崩溃残留守卫扫的是 `.${agentq_base}.${crash_kind}.*`（= `.agentq.stage.*` / `.agentq.backup.*` / `.agentq.failed.*`），**与 `.agentq-service.stage.*` / `.agentq-plist.stage.*` 不匹配**（实测 `find -name '.agentq.stage.*'` 对这四个残留零命中）。讽刺之处：同一轮加这段代码的**理由**正是「两次中断各留一个 `.agentq-plist.stage.*` 孤儿」，而修法本身往成功路径上装了同一个孤儿。
- **发现方式**：读 diff 时注意到插入块的第一行与上一行完全相同；随后用**抽取真函数**的夹具复现：v0.1.40 的臂创建 1 次、0.1.41 创建 2 次（两个臂都是），修后回到 1 次、父目录只剩返回的那一个。
- **修法**：删掉两个臂里**重复的创建行**（连同挤在列 0 的注释一并缩进到块内），注释写明「EXACTLY ONE creation per arm」与这次回归的由来。不改任何语义顺序：身份仍在创建后立刻记录、内容渲染后仍**比对**而非重记。
- **锁（smoke/11 +6 例，51 → 57）**：`stage-once` 组从资产里按锚点抽出**真实的 `prepare_service_stage`**（锚 `\n}\n` 定位函数尾；抽不到即报「function was not extracted」，不静默测空脚本），助手全部桩化后逐臂驱动，每臂两条断言：**创建次数恰为 1**、**父目录里 `.agentq*.stage.*` 恰有一个且等于函数返回的 `$service_stage`**。第二条是承重的——「建 2 个再删 1 个」能过第一条。摘要行新增 `stage-once=asserted`。
- **双向红证**：把重复创建行按原位还原到两个臂 → 四条例全红（每臂「created 2 times」+「expected exactly the returned stage file … found 2」），并点名两个残留路径；还原后 57 例全绿。
- **一个必须在注释里说清的邻近事实**：`stage_verified_binary` 与 `assert_existing_queue_has_no_active_tasks` 里也有同名变量多次赋值，但那些是**互斥分支**（`artifact_source_directory` 有/无、离线 gzip 分支）或**已丢弃后重建**，逐个核实过不是同一形态；判定不是「同名赋值多于一次即违规」而是「同一臂内连续创建且前一实例无名字」。

### 覆盖账更新

分母 **37,227 → 37,236**（+9：删掉 2 行重复创建、注释缩进并扩写）。分子**仍是 417**——本轮只改 `install-agentq.sh` 与 `smoke/11`，九项分子资产 `git diff v0.1.41..HEAD` 实测为空。比例 417/37,236 = **1.12%**。

### 记为边界

- 本轮仍未触碰任何真实主机；Windows 安装器侧**没有**同名形态的缺陷（其临时文件创建是单一 `New-AgentQInstallerTemporaryFile` 站点，已核对），但 `.ps1` 侧本轮**未新增**行为锁。
- 真实安装成功路径仍不可在沙箱内跑通（要下载 pueue、写 `~/.agentq`、注册服务），因此 `stage-once` 锁证明的是**该函数被抽取真跑时的创建次数**，不是一次完整安装的现场；两者的差别只在「函数被调用前的状态」，而创建次数在函数内决定，故认为等价——这一推理本身在注释里写明，未当成实测。

### 真机验收（2026-11-24，用户当面点名的两台测试机）

用户在本轮点名两台测试机后执行；**地址不入库**（`smoke/16` 仍是 0 violations）。两台都从 0.1.30 升到 0.1.42，部署单元两侧同版本。

- **Linux 服务端（0.1.30 → 0.1.42）**：把 7 个 unix 资产拷到临时目录，`sh ./install-agentq.sh` 一次成功（`AgentQ 0.1.42 installed at ~/.agentq`，exit 0），pueue/pueued 走**既有二进制复用**分支（哈希与 pin 相符，未联网）。验收：`agentq_version='0.1.42'`、wrapper 仍 60 字节、组服务 `is-active=active`、**队列 261 个任务全部 Done 且仍在**（升级不丢队列，实测计数前后一致）。
  - **本轮缺陷的行为级证据**：安装成功后 `ls -d ~/.agentq.*stage.*` **零命中** —— 修复前每次成功安装都会留下一个 `.agentq-service.stage.*`。这是「抽取函数夹具」之外的**真实现场**，也就是第十二轮 PLAN 里记为边界的那一条，现在有证据了。
- **Windows 客户端（0.1.30 → 0.1.42）**：`install-client.ps1 -SkipPathUpdate` 一次成功，`-Check` 复跑答 `match canonical assets`；`agentq --version` 答 `agentq 0.1.42`，`sshp.ps1` 与 `agentq.ps1` 同步更新。
- **跨主机端到端**（Windows 客户端 → Linux 服务端，**两侧都是 0.1.42**）：`status --summary`、`submit`、`wait`、`logs`、`lookup`、`remove` 全部成功；日志正文逐字回读为 `from-windows-client`；本地 POSIX 客户端对同一台服务端也跑了 `submit/wait/logs/lookup/remove` 全套，日志正文 `real-host-ok`。
- **过程中实测到两条既存行为（都不是本轮改动引起的，记录以免下次误判）**：
  - 从 **Git Bash** 里调 `agentq.ps1` 时，`--workdir /tmp` 会被 MSYS 转成 `C:/Users/.../Temp` 再发给服务端，服务端正确拒绝（`working directory must be absolute: C:/…`，`reason=protocol_error`）。需要 `MSYS_NO_PATHCONV=1` + `AGENTQ_SSH` 用 **Windows 形态路径**（`/tmp/…` 形态会被 `AGENTQ_SSH is not an executable file` 拒，判据是 Windows 侧 `Get-Item`）。这是调用姿势，不是缺陷；`agentq.bash` 启动器已设 `MSYS_NO_PATHCONV=1`，手工直调 `agentq.ps1` 才需要自己设。
  - Windows 侧没有到服务端的密钥/agent 时，客户端会点名 `class=authentication` 并说明 `BatchMode=yes` 不能应答密码——这是 A16/A18 那套提示，按设计工作。
- **清理（已逐项执行并复核）**：测试任务两次 `remove`（队列里按标签筛选为 0），两条请求墓碑（`.tombstones/` 下仅这两个 id，`task_id=842`、`removed_at` 均为本轮时刻）一并删除，墓碑目录 59 → 57、两台临时目录全删、Linux 的 `authorized_keys` 用备份还原到 2 行且 `agentq-e2e-throwaway` 引用为 0、Windows 的 `known_hosts` 回到**测试前的 6 行**——这里有一次我自己的清理过头：测试用 accept-new 新增了 2 条 `.190` 主机键，我的第一遍清理按 `^172\.16\.81\.190 ` 删掉了**全部 3 条**，而其中 1 条（`ssh-ed25519`）在测试前就存在；发现方式是回看 OpenSSH 自己写的 `known_hosts.old`（正是加键前的快照：6 行、含 1 条 `.190`），用它还原后才与测试前逐行一致。**清理必须对着「测试前快照」核对，不能对着「我猜的行数」核对**——按主机名正则删更是会连带删掉用户原有的条目、本机临时 ssh-agent 已收、macOS launchd 自带的 ssh-agent（08:28 起，早于本轮）未动。仓库零改动。
- **边界**：只验证了「测试机」这一层，13 台生产主机一台未碰；Windows 侧仍是**客户端**（该机不是服务端部署点），所以 Windows 服务端安装路径本轮没有真机证据。

### 第十三轮（0.1.43，2026-11-24）：整理与分发（无缺陷修复；资产只删了两处注释行尾空格）

用户指示「更新/补全/精简核心测试用例，清理不再需要的文件、代码，精练/精简过程记录内容，代码风格统一与格式化处理，最后分批提交并推送；再看看能否支持 npm 渠道分发；清理不再需要了的 worktree」。

**结论先说：这一轮没有找到可删的死代码（0 行），也没有找到可删的死文件（0 个）。** 三条只读审计（`smoke/` 重复与缺口、死代码与无用文件、npm 可行性）逐项复核后，可安全删除的行数是 **0**；真正做掉的是「补三处零覆盖出口 + 把格式问题变成机器规则 + 把 1,479 行历史搬出待办文件 + 新增一条 opt-in 的分发通道」。

#### 死代码审计：0 行可删，且「看起来可删」的正是最危险的那批

覆盖面：9 个 shell 资产 615 个函数定义、7 个 `.ps1` 的 224 个 PowerShell 函数、87 个跟踪文件。

- **未调用函数 = 0**（与 `smoke/01` 的 `uncalled=0` 一致）。但审计用**更严的**判据复核了一遍：把 `'…'`、`"…"`、heredoc 内容掩成空格再计数，`smoke/01` 的宽松判据会漏掉「只在字符串里被提到」的函数。掩码后出现 7 个候选，逐个查证**全是真的调用**：`cleanup`（29 行，调用在 `trap 'cleanup || true' EXIT` 的单引号里）、`cleanup_client_runtime`（173 行，两个 trap）、`cleanup_ssh_runtime`（11 行）、`run_as_root`（定义在远端脚本的 here-string 里、由 ssh 发到目标机执行）、`quote_remote`/`quote_shell_word`/`installer_directory_needs_elevation`/`windows_probe_script_with_exit_token`（调用写在 `$( )` 里）。**这 268 行是最容易被误判为死代码的部分**，朴素 grep 会删掉它们。
- **死变量/死参数 = 0**。SC2034 抓不到的四种形态（自引用自增、`LC_ALL=C cmd` 环境前缀、`env VAR=x cmd` 的实参、函数内 `local LC_ALL=C` 的隐式读取）共 62 个站点逐个核过，全部活着。PowerShell 侧用 AST 收 `Param()` 与读取点，`$transactionActive` 等在脚本作用域初始化、读取带 `$script:` 前缀，正则漏而 AST 不漏。
- **无用文件 = 0**。9 个「零文本引用」的文件逐个确认仍被使用：`smoke/02,06,07,08,09,13,15` 由 `run-tests.sh:36` 的 `find smoke -name '*.sh'` **枚举执行**（且 `ci.yml` 的 `expected_checks` 逐名钉住），两个 GitHub 模板由**路径约定**消费（`smoke/16` 还钉住 `bug_report.md` 必须存在）。
- **唯一的真实改进点不是删除而是补覆盖**：`smoke/01` 的 `uncalled` 规则只扫 `skill/assets` 的 shell 资产，`.ps1`（需要 PowerShell AST）与 `smoke/*.sh`/`run-tests.sh`/`sandbox.sh`（夹具里本来就有大量故意的未调用函数，需要允许清单）没有对应检查。今天这三处都是 0（本轮逐个核过），记在这里而不是临时加一条会误报的规则。

#### 测试用例：删 2 条真冗余的**没有做**，改做补口与加锁

审计指出 `smoke/` 里真正可删的重复断言只有 2 处（`smoke/18` 的 `shortname`、`smoke/06` 的 `reused`，合计约 10 行），另有 7 个 fixture 块约 200 行重复（其中两份「文本模式 jq shim」**已经漂移**：`smoke/26` 的 sed 版只给行间加 CR、`smoke/27` 的 perl 版给所有行加 CR，两边都自称忠实，因为各自有实测理由——26 写了「末行 CR 是真实路径不可能产生的形状」、27 则需要过 NUL 而 BSD sed 在 NUL+LF 上崩溃）。

**决定：不删、不抽取。** 理由有三条，都是本仓踩过的形态：① 那 200 行重复的功能是「同一夹具被三个检查各自持有」，抽成共享文件后**一处改错三处一起错**，而本项目的立场是漂移应被**检测**、不该靠共享消除；② 那 2 条冗余各有一个「只有它钉住的 fail-closed 方向」，省 10 行而把该方向变成无人值守，与本仓历史上多次「删掉看似重复的用例后才发现它是唯一守卫」相反；③ 本轮的真实缺口不在这里——审计按服务端 428 个 `fail` 站点反查，找到一批用户可达但零断言的出口，其中两条最值得先补（见下）。**当时记的「19 条」里剩余部分的编号没有落盘，2026-11-25 重新审计后得到 15 条，逐条列在本节末尾。**

补掉的（每一条都先量出修复前的红）：

1. **`submit` 的 argv 面**（`smoke/02` +5，`cases=46→51`）：`--workdir` 缺值、`--label` 缺值、未知选项、`logs --tail 5 extra`、`logs --taill 5`。这四条规则在**三份实现**（服务端 + 两份客户端）里各写一遍，而 `grep -c 'unknown submit option' smoke/*` 修复前是 **0**。变异红证：把消息文本改掉 → 点名 `submit-unknown-option: stderr does not contain unknown submit option: --bogus`。
2. **两份客户端唯一的本地 exit 6**（`smoke/05` +1、`smoke/12` +1）：`wait` 预算耗尽（`wait budget … elapsed`）。`CLAUDE.md` 的退出码表写着「`wait` 的客户端预算耗尽时两份客户端都本地产 `6`」，而此前只测过 `AGENTQ_WAIT_TIMEOUT=0` 的**入参拒绝**，从没让预算真的耗尽——把它改成 1、改成 255、或让它挂死，三件事都不会被发现，其中**挂死**是调用方最晚察觉的形态。红证：`return 6` → `return 1`，POSIX 与 PowerShell 各报 `an elapsed wait budget exited 1, expected 6`。
   - 写这条用例时踩到一个坑并记下：桩 ssh 必须对 `-V` 答 OpenSSH 的版本行。第一版用 `sleep 30` 的纯睡桩，客户端在**启动探针**就把它拒了（`did not exit within 10s of -V`），用例于是断言了错的分支——绿得毫无意义。
3. **「不可见字节」静态锁**（`smoke/01` 新增 `format=` 臂）：尾随空白 / 行首 TAB / 缺末行换行，扫 42 个文件，双向自检 + 盲枚举闸门。它**当场抓到三处真实缺陷**：`agentq-server` 与其 canonical 孪生**同日同形**各一处 `# ` 行尾空格（第 714 行，正是「只有一边被编辑过就会让 `cmp` 分叉」的那类字节）、`smoke/31` 一处。资产那两处已删（因此版本升到 0.1.43——部署单元字节变了）。

**`shfmt` 被评估后否决**：`shfmt -d -i 4 -s` 对 `agentq-server` 报 2,602 行差异、对 `install-agentq.sh` 784 行、对 POSIX 客户端 1,750 行。带 `-ci`（保留 `case` 分支缩进）能降到 565/52/242 行，但剩下的差异仍包括把 `$(cd … && pwd -P)` 拆成四行、把 `-h|--help)` 改成 `-h | --help)`——**那是重排部署资产，不是检查它**。而且本仓的 `case` 分支写法（`''|*[!0123456789]*)` 无空格）是刻意的、被测试反复引用的形状，格式化工具没有「这是故意的」这个概念。所以只锁**客观错误**的三类字节（尾随空白、行首 TAB、末行换行），其余一律不动。同理否决了 prettier（对 shell 无意义）与给 `smoke/` 引入共享格式库。

#### 过程记录精简：`PLAN.md` 2,868 → 1,474 行

`docs/PLAN.md` 第六节「执行状态」1,479 行（第五轮审查、A 系列、C 系列、性能折叠等，最早到 2026-09）整段搬到 **`docs/plan/execution-log.md`**，PLAN 该节只留三句：历史在哪、现状读哪、待办看哪。同时把第九轮起的审查记录归到新的「七、各轮审查记录」并统一标题层级。

**为什么是搬运而不是删减**：`smoke/` 与资产注释里有大量 `A5`/`A5b`/`A6`/`A13`/`A17`/`A18`/`A21`/`A28`–`A32`/`B5`/`C1`–`C5` 编号引用，它们指向的正是这一节里的条目。删掉条目等于让那些引用悬空，而改写编号等于改写历史。搬运后正文逐字未变，只在开头加了一段「这不是现状、也不是待办」。

#### npm 通道：新增，且刻意只是「拿到文件」

用户问「能否支持 npm 渠道分发」。实测结论（全部在 `/tmp` 副本上量，未写仓库）：

- **能**：`npm pack` 的 tarball 内容与仓库逐字节相同（30/30 `cmp` 为 0）、换行不转换、`npx` 可免解包运行、`npx pkg@<version>` 可钉版本、`npm publish --provenance` 能给出「出自哪个 commit」的证明。
- **不能**：目标机通常**没有 node**（npm 只解决「操作者机器上拿到文件」）；`npm install` 写的是 `node_modules`，而 AgentQ 要的是 `~/.agentq`、`~/.local/bin/agentq`、`~/.agents/skills/agentq`；`postinstall` 在本机 npm 12.2.3 上默认**直接被拒**（`strict-allow-scripts=true` → `ESTRICTALLOWSCRIPTS`），所以「装完自动就位」这个形态根本不会执行。
- **三个坑，都已实测并写进代码注释**：① `npm pack` 读的是**磁盘模式**而不是 git 索引模式——本仓工作区里 `client/windows/*.bash` 当时是 700、索引是 755，同一提交两次 pack 的 sha256 不同；② `files: ["skill"]` 是**目录白名单，不受 `.gitignore` 过滤**——种一个 `skill/assets/planted.key` 会被打进 tarball，而根 `.gitignore` 的 `*.key` 拦不住它；③ `npm install` 解包时把 tar 里的模式**再与 umask 相与**（umask 077 下 755→700），所以「装完恰好 8 个 755」这条不变量在 `node_modules` 里不成立，只能断言 tar 内的模式位。

据此落地的最小形态（全部是新增文件，`skill/` 一个字节没动）：

- `package.json` —— `files: ["skill"]`、`bin`、`engines.node >=18`，**无** `postinstall`/`prepare`。
- `bin/agentq-skill.js` —— 无依赖，只做本机拷贝（`--dest`、`--check`、`--list`、`--quiet`），拷贝后重放 8 个 `chmod 755`（因为 umask 会改写），并复验两份 canonical 副本相同。成功行**自己**说明「这不是部署」。
- `scripts/verify-pack.js` —— 发布门禁：文件集与 `git ls-files` 全等、逐字节相同、模式与索引相同、canonical 对相同。四条各有红证（种 key / `chmod 700` 一个资产 / 删清单一行 / 改 tar 内字节）。
- `.github/workflows/npm.yml` —— `on: push: tags: ['v*']` + `workflow_dispatch`（dry-run）；`permissions: contents: read, id-token: write`（provenance，**不用长期 NPM_TOKEN**）；发布前跑 `verify-pack.js`。**刻意不塞进 `release.yml`**：那个文件的注释承诺「no job writes to the repository or calls the API」，为第二个关注点扩权会悄悄废掉那条承诺。
- `smoke/01` 新增 `npm=` 臂：两个 JS 必须 `node --check` 通过，且 copier 的执行位清单必须**等于** `skill_modes_expected_exec`（两份清单一处漂移就红——这是「清单抄两份」的检测，不是共享）。

**发布门禁上线后，第一次真 tag push 就把工作流自己的一个缺陷照了出来**（这一条值得留，因为它是「表达式看起来在做判断、其实什么都没判断」的又一个实例）：`setup-node` 的 `token` 输入默认是 `github.token`，它会把该值导出为 `NODE_AUTH_TOKEN`；于是 `Publish` 步骤的 `if: env.NODE_AUTH_TOKEN != ''` 在**仓库里根本没有 npm 凭据**时也为真，`npm publish` 拿着无效凭据去 PUT，npm 回 **`E404 ... Not found`**——与「这个包不存在」完全同形，我先怀疑包名被占、再怀疑 registry，两轮之后才去读日志里被导出的那个变量。两个 tag 的两次红都是它。修法：`setup-node` 显式 `token: ${{ secrets.NPM_TOKEN }}`（不给它注入的机会），判断挪进 shell（`if [ -z "${NPM_TOKEN:-}" ]`），无 token 时打 notice + 写 job summary + 退 0，dispatch 走 `--dry-run`，否则发布。判断用 shell 而不是表达式还有一个好处：**它能在本地被测试**——本轮实测「空 token → notice + exit 0」「有 token + dispatch → dry-run + exit 0」两条。0.1.43 的 tag push 之后 `npm` 工作流转绿：`verify-pack: 30 files, bytes identical, modes identical, 34 entries`。

写这套东西时被抓到的**三个自己的错误**（都记在代码注释里）：① 目的地链检查拒绝一切祖先符号链接，而 macOS 的 `/var` 与 `/tmp` 就是符号链接，于是它拒绝了自己的测试目录（改为只查叶子）；② `npm pack --json` 在 npm ≥7 答的是**以包名为键的对象**，第一版按数组读，报「读不出报告」；③ `fs.statSync` 在删除临时目录**之后**才读 tarball 大小，成功路径报 ENOENT。

#### 剩余零断言缺口：15 条 → **全部关闭**（2026-11-25）

第一次审计的「19 条」只补了 7 条，剩余编号没有落盘；两轮独立重审得到 15 条并写进本文件（上一版）。**本轮把这 15 条逐条实现**，过程中抓到**两个真缺陷**，所以 0.1.44 不只是补测试。

落地分布：

| 原 # | 出口 | 落地 | 用例数 |
| ---: | --- | --- | --- |
| 1 | `working directory must be absolute` | `smoke/02` | 1 |
| 2 | `submit requires a command after --` | `smoke/02` | 1 |
| 3 | `--request-id requires a value` | `smoke/02` | 1 |
| 4 | `--workdir is required` | `smoke/02` | 1 |
| 5 | `lookup requires one request id`（零参/两参） | `smoke/02` | 2 |
| 6 | `wait requires one task id`（零参） | `smoke/02` | 1 |
| 7 | `working directory does not exist`（**Windows 臂**） | `smoke/02` 抽函数驱动 | 3 |
| 8 | `label must be valid UTF-8`（`remove --label`） | `smoke/02` | 1 |
| 9 | `task id exceeds the exact-integer range`（argv） | `smoke/32` 低精度副本 | 2 |
| 10 | `Pueue task id exceeds the exact-integer range`（Pueue JSON） | `smoke/32` | 2 |
| 11 | `cannot summarise Pueue status for AgentQ` | `smoke/32` | 1 |
| 12 | `cannot inspect Pueue while reading AgentQ status` | `smoke/32` | 1 |
| 13 | `Pueue returned an invalid task identity in status` | `smoke/32`（4 个调用方） | 5 |
| 14 | `Pueue returned an invalid task identity in logs` | `smoke/32` | 1 |
| 15 | `invalid creation time for AgentQ task` | **0.1.46 合并为 `task_creation_time_or_fail`**（不可达的重复守卫，见下） | 0（可达半边由 `smoke/32` 的 `wait-bad-created` 守） |

表里的「用例数」是**代表例**，不是该出口的全部断言：unix 臂的 `must be absolute` 与
`does not exist` 各有**两条**（整程序一次 + 抽函数一次），Windows 臂三条是
「拒绝×2 + 接受×1」。

新增合计：`smoke/02` cases 51 → **66**（+15 = argv 面 9 条 + `normalize_workdir` 两臂 6 条），
`smoke/32` 新建 **26** 例。

**第 15 条是这一轮唯一没能真正关闭的，原因值得记下来**：它不可达，不是因为难造，而是
因为**同一条链上还有第二个守卫**。`wait`（现 6329 行）与 `logs`（现 7371 行）都在
`compact_task "$task_id"` **成功之后**才执行 `jq -er '.created_at | strings'`；而
`compact_task` 自己的 jq 已经要求 `(.created_at | type) == "string"` 且
`length > 0`（5594–5600 行），形状不合格时它先 `error("invalid visible Pueue task
metadata")`。所以那个 `strings` 只会在**第一个守卫被删掉**之后才失败。

这不是「补一条用例」能解决的。硬造的方法是**抽函数直接驱动**（像 `02` 对
`normalize_workdir` 那样），但那会把一段内联在两处、靠外层不变量成立的防御代码
当成独立契约来断言——而它恰恰**不是**独立契约：删掉外层守卫，行为会立刻变成
「畸形快照被当成缺时间」。#15 因此按**不可达的重复守卫**记录，`smoke/32` 里那三条
`created` 用例实际断言的是**可达的那个**（`cannot inspect Pueue while reading
AgentQ task`），文档不再声称它们覆盖了 `invalid creation time`。

**0.1.46 的处置：合并成一个函数，而不是删掉。** 这段判定在服务端写了两遍（`wait` 与
`logs`，缩进不同），外面还各有三个措辞不同的兄弟消息（`cannot read the AgentQ task
creation time` / `... observed task creation time`）。现在是一处：
`task_creation_time_or_fail`，两个调用点都是
`task_created_at=$(task_creation_time_or_fail "$task" "$task_id") || return $?`。
**为什么不是删掉**：外层判据若哪天被放松，空 `created_at` 会流进**取消 marker 的实例
绑定**——那里一次不匹配会让一个**活着**的 marker 被判成陈旧并删除。**为什么不是硬造
用例**：它是同一条规则的消费者半边，不是独立契约；`smoke/32` 的
`wait-bad-created` 断言的是**可达的那半边**。也就是说 #15 的处置结论是
「**合并掉重复**，并用现有可达用例守住同一条规则」，不是「补一条抽函数的用例」。

**同时补掉表外那几条低可达项**：非规范持久化 marker 文件名、损坏的 marker 内容、损坏的 request record、损坏的 tombstone，各有用例，并各自带「文件移除后同一命令必须成功」的对照（一个「永远拒绝」的服务端能通过拒绝用例）。

**两个真缺陷（由这些用例逼出，不是补测试的副产品）**：

1. **`wait` 把「读不懂」说成「你参数错了」。** `compact_task` 的返回码里只有 4 表示「Pueue 答了、这个 id 不可见」；1（读失败）、2/5（形状不可解）都表示**不知道**。`wait` 把它们全折进 `wait_reconcile_missing_task`，最终打印 `unknown AgentQ task id` —— 而 `logs`/`status --task`/`remove`/`cancel` 早就用 `report_compact_task_failure` 分开了。实测（本机 pueue 4.0.4，任务 `created_at` 非字符串）：`wait 1` → exit 2 + `unknown AgentQ task id: 1`。现在按 4 / 非 4 分开。
2. **六处 jq 校验器的原始诊断泄漏到 stderr。** `jq` 在本仓经常是**校验器**：它 `error(...)` 退出 5，调用方随即打印受控消息。但 jq 自己的 `jq: error (at <stdin>:1): invalid visible Pueue task metadata` / `jq: parse error: ...` 会**排在 `reason=` 之前**落到 stderr，而两份客户端正是扫描这个流去找 `reason=`。实测：损坏的 record/marker/tombstone 各打印一行 `jq: parse error`。六处（Pueue task 形状、Pueue log 形状、summary 聚合、log 聚合、marker 聚合、单 marker、record、tombstone）全部改为 `2>/dev/null`，受控消息保留。

**我自己被规则抓了一次**：第一版 `wait` 修法写成 `if ! task=$(compact_task ...); then st=$?`，`$?` 取的是**取反结果**的 0（`smoke/01` 的 `negation_captures` 规则当场报红）。改成 `task=$(...) || st=$?` 的显式捕获形态——这条规则这轮第一次真的挡住了一个人写的缺陷。

**边界**：`smoke/32` 需要真 pueue 运行时（`AGENTQ_SMOKE_HOME`），CI 的 linux job 有，本地没有时整条 SKIP 并如实打印。低精度 jq 分支靠**给副本打补丁**进入（本机 jq 1.7 保留全部数字），补丁点断言恰好一处，函数改名会让检查失败而不是静默。

#### 本轮修复的第三个缺陷：管道里的 `fail` 折成 exit 1

写「非规范 marker 文件名」用例时撞到的：`load_cancellation_markers` 的循环体在
`{ ... } | jq ...` 的管道左端，`fail` 的 `exit 2` **只结束那个子 shell**，管道状态
变成非零，调用方 `prepare_request_metadata_files` 把它折成 `return 1`——于是 stderr
上是**一行 `reason=protocol_error` 配 exit 1**，码与类别自相矛盾，而 exit 1 在契约里
只是「一般失败」，调用方会当成可重试。

**同一棵树给出三个答案**（实测，本机 pueue 4.0.4，一个 `0001.json` 的非规范 marker）：
`status` 1、`remove --label` 1、`status --summary` **0**（它的路径根本不加载 marker）。
`load_request_records` 是**同一个形状**，只是一直没人测过它的文件名臂。

**修法**：两处生产者都从 `| jq` 改成 `} > "$raw"` 加 `jq ... < "$raw"`。重定向让循环体
留在**当前** shell，`fail` 就是进程真正的 exit 2；代价是每次加载多一个临时文件。
`smoke/32` 新增 6 条用例（marker 与 record 各 3），断言**严格 2**——第一版写的是
「1 或 2」，那等于把缺陷留在绿灯底下。

**顺带把这套审计的缺口补上了**：`smoke/02` 的 `return2-sites` 审计
（`reason-gaps=0`）只覆盖「每条 exit 2 都带 reason」，**不覆盖**「冒了 reason 却没退 2」。
本轮先是用人工读管道语义发现的，随后把它做成了 `smoke/02` 的**第四条静态规则**
`pipe-fail`（下节）。

#### 第四条静态规则：管道左端的 `fail`（2026-11-26，0.1.46）

判据不是消息文本，是**语法形状**：`{ ...; } | jq …` 的左端跑在子 shell 里，所以块内的
`fail` 永远不是进程的 exit 2。规则扫「关闭行带单个 `|` 的块」（`} |` 与 `done |`），
**反向**找最近的开启行（`{` 或 `do`），把块内每个 `fail` / `exit 2` 报出来。

三次自我纠错都在写规则的过程中发生，都值得记：

1. **`break` 写在函数收尾的花括号上**：识别 `}` 为 closer 后立刻 `break`，于是在第一个
   函数后就停了，自检报 `regions=0 / sites=0`。自检救的，不是真机救的。
2. **`pending` 忘了清空**：续行合并后 `pending` 未置空，第一处续行把**此后每一行**都
   永久前缀化，于是真实服务端读作「没有任何管道块」。这正是这条规则要防的「静默空转」，
   而它自己先犯了一次。
3. **`||` 被当成管道**：第一版用 `\|` 匹配，把 `) || {` 判成「关闭进管道」，把
   `compact_log` 里四个**正确**的站点报了出来。`||` 是逻辑或、留在当前 shell。
   自检的夹具里当时没有 `||` 形状，所以自检没抓到——是**逐条读那四条报告**发现的。

   **夹具补了两次才对，第一次补的是个空跑**（2026-11-26 复查时发现）：先补成
   `) || {`，可当前规则只把 `}` 与 `done` 当 closer，`)` 根本进不了判定，那一行
   对规则来说是死的——把规则改回 `\|` 匹配，它照样报 0。改成真正的 `} || {` 形状后
   才有判别力：正确规则报 `__PIPED__0`，变异回 `\|` 的规则报 `__PIPED__1`。
   **教训：自检夹具的形状必须落在规则真的会看的那组 closer 上**，否则「补了自检」
   这句话本身就是假的。

最终形态的判据只有单 `|`（`^}[[:space:]]*\|[^|]`），且**正向控制是「扫到了几个管道块」
而不是「报了几个站点」**：真实服务端现在是 `piped-blocks=4 pipe-fail-sites=0`，四个
`done | jq` 里都没有 `fail`；一旦某天这些块被删光，`piped-blocks=0` 会让规则自己红，
而不是安静地绿。

**红证**（`v0.1.44` 的 server 副本）：`piped-blocks=6 pipe-fail-sites=13`，点名的正是
本轮修掉的两处加载器（marker 与 record 各有文件名臂与路径臂）。修复后 4/0。

#### 边界（不声称的）
#### 边界（不声称的）

- **npm 包从未发布过**：本轮只做到「能打包、门禁能拦、`npx` 本地路径实测可用」。`npm publish` 需要账号与凭据，**未执行**；`agentq-skill` 这个包名在 registry 上当前 404（看起来可用），但**404 不保证可注册**；provenance 需要公开仓库 + OIDC，本会话到 github 不通，**未验证**。
- **格式化只覆盖「客观错误」三类字节**：缩进风格、`case` 分隔符空格、`$( )` 单行与否都没动，因为那些要么被工具要求重排部署资产、要么是刻意形状。`smoke/` 与文档的 Markdown 也没有跑任何格式化器。
- **两个未合并的分支仍在**（`worktree-agent-ac6dc963db10520d7`、`MisonL/aq-r6-codex`，各 237/243 个独有提交）。worktree 已全部清掉（`git worktree list` 只剩主检出），分支**保留**：它们相对 main 的 `git diff --diff-filter=A` 是 0 个文件（不提供 main 没有的文件），但删分支是删历史的动作，用户没点名，本轮不做。
