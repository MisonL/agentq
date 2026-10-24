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
- 六、执行状态
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
2. **一半代码凭什么被相信** —— 没有任何行为检查的资产占 **14.2%** 的代码量
   （9 个资产 / 3,498 行，2026-09-24 重算；**这个口径此后未再重算**，逐轮补检查已使
   其缩小——见第六节的现役口径，2026-10-14（晚，0.1.10 后）复核为 391 行 / 27,821 = 1.4%）；另有更大
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

没有 Windows 机器就无法关闭这个缺口。它不是新发现的缺陷，是**已知的证据形状
局限**，写在这里以免被当成「已覆盖」。

---

## 四、明确取消 —— 不是待办，不得复活

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
   是 **5,561** 行无类型 shell（2026-10-14 复核）：没有编译器、没有类型系统。（**2026-09-29 起有 git**，
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

## 六、执行状态

**第五轮全维度审查（2026-10-16，用户「使用agents进行全维度全场景审查」）——
7 个并行只读 agent 覆盖服务端 / POSIX 客户端 / Windows 客户端 / smoke 质量 /
协议一致性 / 安全面 / 安装器与 launcher；1 个 agent 中途 API 超时，其半成品
线索本人复核后确认为真 P0。每条发现均先复现或证伪再动手。**

**P0：`wait --timeout` 在两个客户端上完全不可用（0.1.11 首发即坏，且无任何用例
覆盖成功路径）。** 三处独立成因，全部实测：
1. **两端都把 `--timeout` 转发给服务端**，而服务端 `wait)` 是 `[ "$#" -eq 2 ]`：
   实测 `agentq-server wait 5 --timeout 60` → `wait requires one task id` +
   `reason=protocol_error` + exit 2。用桩 ssh 捕获到两端实际发出的远端命令：
   POSIX `…agentq_run 'wait' '5' '--timeout' '60'`、Windows 解码后的 base64 相同。
2. **POSIX 的远端 `timeout <N>s` 前缀是语法错误**：unix 远端命令以函数定义开头
   （`agentq_run() { … }; agentq_run 'wait' '5'`），而 shell 只允许函数定义出现在命令
   位置——实测 `/bin/dash -c 'timeout 5s f() { echo hi; }; f'` → `Syntax error: "("
   unexpected`，bash 同样报错。远端**什么都没执行**，wait 以空响应退 2。修法：预算改为
   前置赋值语句 `AGENTQ_WAIT_BUDGET=<N>s; <命令>`（赋值语句可在任何位置），由
   `agentq_run` 读取并用 `timeout` 包裹；`command -v timeout` 缺失时退化为纯本地预算
   （macOS 默认没有 coreutils `timeout`）。
3. **Windows 客户端 `Invoke-WaitSshWithTimeout` 从不读 ssh 的管道**：
   `New-SshProcessStartInfo` 把 stdout/stderr 重定向到**管道**，而该函数从**从未被
   写入的空临时文件**读 Output。实测（桩 ssh 打印合法 Success JSON）：客户端报
   `response was empty`、退 2——**带 `--timeout` 的 wait 在该客户端永远不可能成功**。
   同源第二面：不读管道时，响应超过管道缓冲（Windows 匿名管道约 4KB）会让 ssh 阻塞在
   写、永不退出，被截止循环误判为超时。修法：照搬同文件探针路径
   （`Invoke-SshLoggedWithTimeout`）已验证的异步 `Read-BoundedProcessStreamChunk` 排水。
**回归锁（均先证能红）**：`smoke/05` 新增桩 ssh 的 `agentq_run wait` 分支（**镜像服务端
的参数契约**——收到 `--timeout` 就退 2，否则这条用例在坏客户端上也会绿）、
`wait 3 --timeout 60` 必须退 0 + 远端命令不得含 `--timeout` + 远端命令必须过 `sh -n`
+ 远端包装必须真用 `timeout` 包住服务端；变异证明三个方向各自能红（重新转发 → 2 处红；
恢复 `timeout` 前缀 → `sh -n` 红；删掉包装里的 exec → 红）。
> 一处自身的弱锁教训：远端包装那半最初写成 `grep -q AGENTQ_WAIT_BUDGET`，而变量名在
> 赋值与注释里也出现，**删掉处理逻辑仍绿**——实测后改为断言确切的 exec 形式才承重。
`smoke/12` 新增行为用例：桩 ssh 回合法响应，直接驱动 `Invoke-WaitSshWithTimeout`，
断言 ExitCode 0 + Output 非空 + 过 wait 校验器；变异（把 `Output` 改回空串）实测红。

**其余已修（全部先复现）**：
- **Windows `status --task` 不传 expected task id**：`Test-TaskIdMatch` 因 Expected 为空
  直接放行，远端返回**另一个**任务 id 也会被接受；POSIX 侧对照着传了
  `$status_expected_task_id`——典型的「同一机制两份拷贝只修一份」。已补传。
- **Windows `--timeout`/`AGENTQ_WAIT_TIMEOUT` 的 `[int]` 强转无上界**：实测
  `wait 5 --timeout 99999999999` → 未捕获 `InvalidArgument`、退 **1** + 堆栈，而非契约
  的 2。改用文件内既有的 `Convert-ToPositiveInt32`。
- **POSIX 同类**：`AGENTQ_WAIT_TIMEOUT=99999999999999999999` 过 `is_positive_integer`
  后在 dash 下 `[ … -ge … ]` 报 `Illegal number`、判定恒假 → **本地预算永不触发 = 无限
  等待**（实测 rc=2、读作 false）。新增 `is_bounded_positive_integer`（当时取 ≤9 位，2026-10-21 放宽到 int32 上界以与 Windows 客户端一致，见第十九轮），用于
  `--timeout`、`AGENTQ_WAIT_TIMEOUT` 与新增校验的 `AGENTQ_PLATFORM_PROBE_CACHE_TTL`
  （后者此前完全未校验，`abc` 会让 TTL 比较在 stderr 报错并静默失效）。
- **服务端 `status --task` 解析期不校验**：`--task ""` → `status_mode=''` → `[ -n "" ]`
  假 → **打印全量队列并以 0 退出**；`--task summary` → 静默返回摘要。调用方按
  `{"task":…}` 解析拿到的是另一种形状的「成功」。dispatch 处补 `is_task_id`。
- **服务端摘要的 label 守卫比全量严格**：全量 `compact_status` 不查 label，摘要却要求
  `type == "string"`，于是队列里出现一个**无 label 的任务**（`pueue add -g agentq` 直接
  加）会让 `doctor`/`status --summary` 退 2，而 `doctor --full`/`status --task` 正常——
  默认视图严格弱于 `--full`。已放宽为允许 null。
- **POSIX 平台缓存的多处缺陷**（P5 的核心实现）：① **`shasum` 缺失 → 所有主机共用
  一个缓存文件**：管道状态取 `cut` 的 0，哈希为空 → 路径塌缩为
  `<dir>/platform-cache/.json`（实测空哈希 + rc=0），且 `shasum: not found` 未经脱敏
  直接打到 stderr。改为 shasum → sha256sum → openssl 回退，都没有就**放弃缓存**。
  ② **先 sanitize 再哈希 → 不同主机碰撞**：实测 `a-b`/`a@b`/`a:b`/`a b` 的 sanitized
  哈希**完全相同**（`d44362d6…`），而原注释宣称「distinct hosts never collide」。改为
  哈希**原始**主机串（实测四者各不相同）。③ **未来时间戳永不失效**：`now - probed_at`
  为负 → `-le ttl` 恒真。补 `probed_at <= now`。④ 写入改为 `umask 077` + 临时文件 +
  `mv`（原为默认 umask 直接 `>`，会跟随预置符号链接），Windows 侧同样补 reparse 点
  拒绝与原子写。⑤ `AGENTQ_PLATFORM_PROBE_CACHE=off` 改为大小写不敏感。
- **SKILL.md 与代码注释宣称缓存「失配会自动回落到重新探测」——代码里没有任何失效
  路径**。诚实修正为「命中即信任到 TTL 过期；换平台需显式处理」，并在 usage 里补上
  此前完全没列出的 `AGENTQ_PLATFORM_PROBE_CACHE_TTL` 与 `AGENTQ_PLATFORM_CACHE_DIR`
  （两个客户端都补）。
- **POSIX `wait` 的 stderr 捕获未登记进运行时清理**：`Ctrl-C`/SIGTERM 只走
  `cleanup_client_runtime`，漏登记会在 `$TMPDIR` 留下 `agentq-wait-stderr.*`。已登记并
  在两处删除点清空。
- **服务端读路径的陈旧锁恢复会把「输掉清理竞争」当致命**：两个并发读同时清理同一把
  陈旧锁时，后到者拿到 `remove_stale_lock` 的 2（「changed during recovery」，本身已
  打印一行 stderr）→ `fail` → **读命令退 2**，而读根本不需要这把锁。改为对 2 继续执行
  （1 = 真实删除失败，仍致命）。
- **launcher 的第三个 4096 块读**：`Read-AgentQBoundedText`（`-ArgumentsBase64 -` 的
  stdin 入口）仍用 `[char[]]::new(4096)` 块读——0.1.10 已从两份 wrapper 修掉这一形态，
  launcher 这份漏了（当前无调用方传 `-`，属潜伏）。改为逐字符 `Read()`，并把 `smoke/05`
  的既存静态锁从两份拷贝扩到**三份**（变异实测能红）。
- **Windows 客户端 `--stdin-script` 对所有目标都用 Windows 上限 20000**：同一个客户端
  可驱动 Linux 主机（上限 100000），却按本机平台拒绝并指出错误的理由。改为按**目标**
  平台选择（新增 `StdinScriptLimitUnix`/`Windows`）。
- **POSIX `--stdin-script` 的读取无上界**：先把整个 stdin 读进 shell 变量再检查长度。
  改为 `head -c <上限×3/4+1>` 截断读取（多留 1 字节使超限仍可检出），实测 120000 字节
  输入被正确拒绝（b64 100004 > 100000）。
- **SKILL.md 的 Windows 边界自相矛盾**：①「单参数 >约 8.1K 会被 cmd 截断」与
  ②「`--stdin-script` Windows 上限 20000」并存——DefaultShell 为 cmd 的目标上，8.1K
  以上的脚本仍会被任务执行层截断。已把 ③ 作为显式边界写入（不改上限：真机未测，不
  猜测），并把脚本要求由「UTF-8 文本」更正为「**POSIX sh** 文本」（远端是 `sh`）。

**审查发现（S2–S13 + 竞态 + fail-open + nits + 安装器占位符）：已于 2026-10-16 全部修复，落地为 0.1.13。** 原描述与修法如下：

- smoke 质量 agent 的 S2/S4/S5/S6/S7/S8/S11/S12/S13：多为**断言过弱**而非假绿。**全部加固，且每条新锁都先证能红**：
  - **S3**（`smoke/05`）：`expect_mode_ok 'agentq_run status'` 是子串匹配，裸 `status` 若错误地加发
    `--summary` 不会被发现 → 改为从**原始 argv**（`modes.argv` 末行）取出 `agentq_run ` 之后的**精确**
    参数串比对（顺带关掉 S12：桩的 `tr -d "'"` 不是 `quote_remote` 的逆，原始串无歧义）。**变异
    `--summary` 转发被删 → 红**（`expected exit 0, got 2`）。
  - **S7**（`smoke/12`）：authhint 探针的「点名 host」断言在无 host 时**恒真**（`[regex]::Escape("")`
    空模式匹配一切），且非 hermetic（读开发机自己的 config）→ 探针里显式钉 `$script:TargetHost`
    与 `$script:CredentialSource` 为字面量，调用方加 `AGENTQ_CONFIG` 与 `env -u` 凭据变量。**变异
    「提示不再点名 host」→ 红**。
  - **S8**（`smoke/12`）：`\d{1,3}` 静态锁是「至少一处存在」语义，删掉 probe 路径那一处不会被发现 →
    改为**逐读取器**不变量（3 个 `[regex]::Matches` 读取器，`exit_readers == exit_readers_bounded`
    且计数钉为 3）。**变异 ① 把 probe 读取器改成 `\d+` → 红；② 删掉该读取器 → 红**。
  - **S2**（`smoke/12`）：良构 askpass 用例只断言 stderr 缺两条拒绝消息，客户端在守卫**之前**就死
    （缓存目录不可解析、或探针退 2）也照样绿，且 `status=0` 是死变量 → 改为指向一个**记录调用**的
    ssh 桩并断言**桩被调用过**（正命题：真到了传输阶段）+ 强制 `AGENTQ_REMOTE_PLATFORM=unix`。
    **变异「守卫后立即停、不到 ssh」→ 红**。
  - **S4**（`smoke/12`）：validator 探针缺 doctor 方向的负例；把 `{doctor, doctor_full}` 并进
    `status` 臂全绿 → 加 `status-full-ok` 与 `doctor-rejects-full`。**变异「合并两臂」→ 红**。
    （反向负例 `doctor_full` 拒摘要**不**断言——实测 `Test-JsonTaskMap` 接受摘要 map，断言它会钉住一个
    客户端没有的行为。）
  - **S5**（`smoke/03`）：新批量块失败路径不清理真实 runtime，任一早于末尾断言的失败都留下两个 task 与
    两条 record → 加 EXIT trap（与临时目录清理组合），`cleanup_task_ids` 登记批量 id，失败即
    cancel+remove 到 record 消失。**实跑 sandbox 全绿**。
  - **S6**（`smoke/03`）：doctor 断言过弱（`{"summary":true,"tasks":{}}` 即通过、`--full` 只查
    summary 不为真、stderr 丢 /dev/null）→ 断言批量 task 真出现在两种形态里、`--full` 带装饰 map、
    捕获 stderr 并复验版本行。
  - **S9/S10**（`smoke/12`）：成功行打印在失败门**之前**（tail 单看 stdout 读成绿）；`AGENTQ_PASSWORD`
    用例缺 `status=0` 复位（上一条用例留下的 status 可掩盖失败）→ 均修。
  - **S11**（`smoke/02`）：坏元数据用例的 `grep -q 'reason=protocol_error'` 未锚定 → 改
    `grep -qxF 'agentq-server: reason=protocol_error'`。
  - **S13**（`smoke/10`）：`mv <` **整行**排除过宽 → 换成**引号奇偶**判定（真实 move 的 `mv` 在任何
    引号之外，文本提及的 `mv` 在一个打开的 `"` 之内）。**变异 ① 真实 move 去掉复核 → 红；② 真实
    move 行尾加 `mv <x>` 提及且去掉复核（旧排除会漏掉）→ 红；③ 关掉排除 → 资格行被报为无复核 move
    （证明例外承重）**。
  - **S1**（`smoke/06`）经本人 A/B 复核后**降级**：第 3 节复用的 `add.entered` 是第 1 节留下的陈旧
    标记，使就绪检查失去意义（死守卫）——已修（第 1 节末尾删除标记，0.1.12）；但用「读仍取锁」的变异
    服务器做 A/B 时**两侧都红**，即**未能造出可观测的假绿**，故这是夹具健壮性缺陷而非已证的假绿。
- **服务端记录消失竞态**（已修）：`load_request_records` 的 `[ -e ]` 与随后的读取之间记录被并发归档
  → 读命令退 2 并报 `invalid AgentQ request record`（像数据损坏）。根因是**父 shell 预收集的 id 列表
  与 aggregate jq 实际读到的记录数失配**：跳过一条却不发占位符，位置绑定把后一条记录挪到前一条的 id
  上，绑定检查随即报错。修法：跳过时发一个 `null` 占位符（每条 glob 项对应一个 JSON 值），
  `request_records_filter` **在绑定之后**丢弃它；`recover_removing_requests` 的
  `records=$(load_request_records)` 补 `|| return $?`（条件上下文里 `set -e` 失效，原先无声吞掉失败）。
  用确定性合成运行时复现（4s 窗口内删记录），修后 stderr 噪声消失。
- **`--stdin-script` 的远端解码失败会退 0**（已修）：管道末段是 `sh`，远端缺 `base64` 时 `sh` 读到空
  输入退 0 → 任务 Done/**Success** 而脚本从未执行；客户端的 `command -v base64` 检查的是**本地**。
  修法：守卫移到**目标端**且**在管道之前**（管道状态是其末段命令的状态，追加在后的检查永不触发）——
  `command -v base64 >/dev/null 2>&1 || { echo ...; exit 2; }; printf %s <b64> | base64 -d | sh`，
  保持 SKILL.md 记录的形态与 smoke/05 的提取正则。**posix 与 ps1 两份客户端同步**（ps1 的 stdin-script
  臂从此前无守卫改为同形态）。**ps1 的另两处 `base64 -d`（`Convert-ToPosixScriptCommand`/`New-UnixRemoteInvocation`、
  sshp 的探针/安装）刻意不加**：那两条路径的客户端会校验 JSON 响应/哨兵标记，`sh` 读空 → 空输出 →
  校验失败，是 **fail-closed**，与 `--stdin-script`（空输出=任务成功执行了空脚本）不同。
- `doctor_with_operation_lock` 未转发 `"$@"`、`result_lines` 的 jq 赋值缺 `|| fail`、锁龄可能为负
  ——**三处 nits 均已修**（前两者当前不可达，但都是给第一个调用者/第一次到达埋的陷阱；锁龄加
  `[ "$lock_holder_age" -ge 0 ] || lock_holder_age=0`）。
- 安装器残留指引里的 `<the .backup directory>` 占位符不可直接粘贴（shell 里 `<` 是重定向）——**已修**：
  指引改为从**真实**残留路径构造（新增 `quote_shell_word`，单引号引用），实测带单引号的路径可粘贴运行；
  `smoke/10` 的 `mv <` 整行排除随之换成引号奇偶判定（见 S13）。

**Agent-UX 优化 P1–P7（2026-10-15 完成，用户对计划文件 `greedy-forging-moore` 的
「全部优化好」授权）**：基于全量历史会话挖掘确认的七项真实摩擦，一次性落地为
**0.1.11**（偏离原计划的 0.1.11–0.1.14 分四版：七项改动交错在同一批文件里、
无法拆成各自可验证的中间提交，故合并为一版）。

- **P1 `wait --timeout <s>`**（客户端两份）：后台 pid + 截止轮询；到预算 kill 本地
  ssh、stderr 一行 `wait budget of Ns elapsed, task <id> still running`、退 `6`
  （复用「无法确认终态」语义，不新增退出码）；响应已到达则照常按 0/1/5/6 契约。
  `AGENTQ_WAIT_TIMEOUT` 提供默认值。
- **P2 读免锁 + 锁报错增强**（服务端）：`status`/`logs`/`doctor` 改走
  `*_with_read_lock`（免操作锁，保留维护锁检查与陈旧锁恢复）；争用报错带
  `held by pid <pid> (started <ts>), lock age <N>s`。`lookup` 保持持锁。
  **smoke/06 新增第 3 节钉读免锁**——先证能红：把三个读改回互斥锁的变异服务器上
  `status --summary` 在锁持有下退 2 `lock_contention`，真实服务器全绿。
- **P3 `status --summary` / `status --task <id>` + doctor 双形态**（服务端 +
  客户端两份的转发与按 profile 校验）：summary 为单次 jq 聚合
  `{"tasks":{…},"summary":true}`；`--task` 复用 `compact_task`（`{"task":…}`）；
  doctor 默认 summary、`--full` 保留全量。`smoke/03` 真运行时钉形状，
  `smoke/05`/`12` 钉客户端转发与校验器。
- **P4 本地防呆**（客户端两份）：`--version`（第四处版本常量，`smoke/01` 同步钉）；
  usage 加 `doctor` 副作用警示；`status <id>` 等本地拦截提示 `logs <id>`。
- **P5 探针缓存**（客户端两份）：`~/.config/agentq/platform-cache/`、TTL 7d、
  `AGENTQ_PLATFORM_PROBE_CACHE=off` / `AGENTQ_PLATFORM_CACHE_DIR`；五个 smoke 套件
  加隔离导出（曾实测污染真实 HOME，已清）。
- **P6 `submit --stdin-script`**（客户端两份）：stdin → base64 → 单 argv 元素；
  unix 上限 100000（MAX_ARG_STRLEN 余量）、Windows 20000（CreateProcess 32767）；
  `smoke/05` 行为钉（payload 解码逐字节回环）。
- **P7 `remove --label <l> --confirm` + 安装器残留指引**：服务端从一次
  `compact_status` 快照按装饰后 label 收集 id、单锁内逐个走既有 `remove_task`
  （`$( )` 隔离使单项失败不中断批次），输出 JSON 数组、exit 0/1；安装器残留
  拒绝消息补具体人工命令（语义不变）。`smoke/02` 钉三个参数拒绝、`smoke/03`
  真运行时钉批次结果。
- **本轮测试侧自身修的两个假绿**：① `smoke/12` 的 failures 闸门原先位于文件中部，
  其后追加的检查（0.1.11 校验器块、静态锁）失败仍打印「checks passed」并 exit 0
  ——闸门移至末尾、注入失败实测退 1；② 同套件暴露 ps1 `Test-JsonBatchRemoveResult`
  对空数组拒真（`@($null)` 是单元素数组、元素为 null，pwsh 7.5.4 实测），加
  `if ($null -eq $Response) { return $true }` 修复，十个直接调用用例全过。

已完成（本会话）：A1、A2、A3、A4（零授权项），A5、A6（零授权、只改 `assets/`），
A7（零授权、只改 `smoke/`），B2、B3、B4（用户已授权），**C1（三台，用户已裁定范围）**。

**A29 公开仓库标准化（2026-10-08，用户指示）**：用户选定「薄壳加装」路线、公开仓库、
MIT、四子项全做。①②④ 已完成（版本 0.1.0 与 Pueue 4.0.4 拆开并加 `smoke/01` 版本一致性
规则；`LICENSE`/`CONTRIBUTING`/`README`/`CHANGELOG` 头部/`.github` 模板与 `SECURITY.md`）；
③ 的 `ci.yml`/`release.yml` 已实跑：`ci` 三平台全绿（run 37894054291，2026-10-09；首跑三平台全红，
三次失败全是 fixture 的可移植性问题、无一是资产缺陷，逐条见 A29 ③），`release` 在 tag `v0.1.0` 上成功。
**A30（`doctor` 报 AgentQ 版本）已完成**（服务端常量 + doctor 的 `agentq=` 行 + `smoke/03`
逐字断言 + `smoke/01` 扩为四方 + 四份文档同步）。
**A31（jq 保留字被当作标识符）已修（2026-10-10）**：C2 的 RHEL 格首次实跑时暴露的**真实
缺陷**——jq 1.6（el9/RHEL/Rocky、Debian 11、Ubuntu 20.04–22.04 的系统 jq）把 `label` 等词
词法为关键字，服务端 `request_payload` 的 `--arg label`/`$label` 与 `status` 压缩过滤器的
`label,` 简写在 1.6 上**编译失败**：该主机上 `submit` 退 0 却写 `payload:null`，`status` 退 3，
其余读命令全退 2。修两处 + 新增 `smoke/29`（argv 桩判形状，本机 jq 是 1.7 看不见）+ 版本
`0.1.2 → 0.1.3`。详见 `plan/a-class.md` A31。
**A32（`smoke/03` 清理只对运行中的 blocker 调 `remove`）已修（2026-10-10）**：`962207b` 的
linux job 偶发报 `cleanup left an active request record for task(s): 5`——根因是**测试脚本**：
清理对仍在 Running 的 `sleep 60` blocker 只调 `remove`，而 Pueue 拒绝删除运行中的任务，
重试预算又按**次数**（40）而非秒计。修法是清理前先 `cancel`（`SKILL.md` 工作流的顺序），
A/B 承重证明：预算缩到 3 轮时旧代码逐字复现该原话、新代码通过。**`skill/` 零改动**，
详见 `plan/a-class.md` A32。
**性能折叠（2026-10-11，零授权，`skill/assets/` 两处同步改）**：用户指示「优化好」。
计划文件里那条「折叠 `repair_removed_request_records` 的逐条 jq」**2026-10-04 就已完成**
（A25/A26），故先按本仓纪律实测**当前**热点：`status` 在 N=272 上仍随记录数增长
（本机中位 1.3s@N=0 → 6.7s@N=272），而 shim 计数显示**子进程恒为 45**、与记录数无关——
成本在 **bash 内部**。用 jq 时间戳桩测出 9 次 jq 之间服务端**空转 7.5s**，定位到三处
**逐文件路径守卫循环**。**根因**：`request_metadata_file_is_safe` 内含
`path_chain_is_safe`，后者**逐级 `[ -L ]` 遍历整条路径链**。**两处折叠**（`1cebf19`、
`7d3e572`）：① `load_request_records`/`request_record_path_guards_or_fail` 对**同一路径**
在**相邻位置**调它 **4 次**，改为保留探针前后各 1 次；② `load_request_records` 与
`load_cancellation_markers` 各有一处**独立**的 `path_chain_is_safe`，紧随其后的守卫
**内部会再走同一条链**，故删除。**合计**：生产者循环 1696ms→1083ms、4 次守卫
1040ms→263ms、独立 chain walk 724ms→510ms、端到端 `status` 7875ms→6134ms（A/B 中位），
输出**逐字节相同**。**先补锁再改**：现有覆盖**抓不到**守卫被删（实测删光全部记录路径守卫
仍 `cases=27` 全绿，因为没有用例种子化符号链接记录），故 `smoke/18` 先加 `symrecord`
用例并**证明它能红**（`exit code differs (baseline 2, variant 0)`）再改代码。**已量过但
不改**：`read_request_record` 里 4 次守卫同样是冗余的，但它的调用点全是**单文件**路径
（不在逐记录循环里），省 2 次约 **2.6ms/调用**，相对 N=0 的 1.3s 可忽略——记为「量过、
不值得改」，不是遗漏。**同日再折一处孪生**：墓碑批量守卫 `request_tombstone_path_guards_or_fail`
（供 `wait` 的 reconcile 扫描逐墓碑调用）此前仍是 4 守卫，与记录侧同名孪生同形但未折——
本轮折到 2 守卫（58 墓碑 305ms→94ms，省 211ms），四场景逐字节 IDENTICAL；`smoke/26` 新增
`w2b`（符号链接墓碑）作回归锁，**先证明能红**（删光墓碑守卫报 `expected exit 2, got 5`）再折。
**同日评估后否掉 `load_cancellation_markers` 的标记循环**：`cancellation_marker_is_valid`
内部本身就跑「守卫→探针→守卫」，循环体那对外部守卫看似冗余，但删掉全部守卫后
`status` 仍因循环体自己的 `[ -f ] && [ ! -L ]` 拦住符号链接 marker，**不可观测**且
marker 实测 0–3 个，故**保持原样**（理由记入 `docs/performance.md`）。**未提版本号**（纯性能折叠，与 `0418da3`/`76b9cfe` 同类）。
**A8 已执行（2026-09-24）**：主机 A/B 只读核查后**无需清理**（无可 `remove` 对象），
主机 C 后经用户提供凭据补盘（其队列已空，见 A8 续查）——详见 A8 那节。执行过程中撞出并修复了 A5a 引入的 P0 回归
（POSIX 客户端连不上任何 Windows 主机）。

**B5 已执行（2026-09-24，用户授权）**：主机 A（Windows）与主机 B（Linux）**均已重装
并完成端到端验证**，验证任务都已清理；主机 A 撞出本仓第 7 个真实 Windows 缺陷
（`AccessRulesProtected` → `AreAccessRulesProtected`，见 B5-执行）。**主机 C 亦已重装并完成端到端验证**（2026-09-24，用户授权凭据操作，见 B5-执行 与 A11）。
**B5 首轮无遗留项**（仓库此后又前进，三台再次落后）。**第二轮重装已于 2026-10-08 完成**
——三台均升到当前 `9721403c`/5,332 行并各自端到端验证，主机 A 的 Windows 客户端同批补齐
（见 B5-执行 与「真机实验」，后者三项已全部执行）。**第三轮已于 2026-10-10 完成**：三台
升到 **0.1.2**（服务端哈希三台一致 = `10710f70`，等于仓库资产），各自端到端验证
（Windows 走受保护 launcher、macOS 走 system LaunchDaemon、Linux 走 systemd user unit），
过程中在真机上暴露并修掉两个缺陷（wrapper/客户端路径冲突、原生 Windows jq 的 CRLF，见
`CHANGELOG.md` 2026-10-10 两条）。**第四轮（2026-10-10 晚，A31 之后）**：仓库升到 **0.1.3**
（A31 的 jq 1.6 修复）后，**两台可达主机已升级并端到端验证**——Windows 主机（受保护 launcher，
`INSTALLER_EXIT=0`、`updated_atomically:true`、`scheduled_task` State=3）与 Linux 主机
（systemd user unit，`INSTALLER_EXIT=0`）均报 `agentq=0.1.3`、服务端哈希 `c3628935…` = 仓库资产、
协议面 `submit→wait(Success)→logs→lookup→remove→wait(5)`、失败任务 `wait=1/Failed`、
`cancel` 已结束任务 `2/reason=task_not_running` 全通；两台的**客户端本已是仓库字节**
（Linux `client/unix/agentq`、Windows `client/windows/*` 哈希逐字相符），故仅服务端侧替换即达
同一部署单元。**第三台本轮从本机网络不可达**（ssh 超时），**其身份未从历史推断**（按操作边界），
故**未升级、状态未知**——需要时由用户当次点名该主机

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
`sshp --check` 重试预算（`smoke/19` 当时 19 例）、POSIX `HOME` 守卫（`smoke/05` env=16）、
start-daemon 三处 `exit 2` 死代码（`smoke/22` 当时 59 例）、`sshp.ps1` 自毁
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
补做成功**，见 `PLAN.md` C2 一节与 `CHANGELOG.md`；**WSL 已于 2026-10-09 在真实 WSL2
上补做成功**——容器里仍不可伪造，但真机可达，见上「两格明确不可达」一节）。

**2026-09-25 真机补测（用户点名一台 Windows 主机，地址不入库）**：三件事全做。
**① PS 5.1 契约**：`smoke/12` 新增 `AGENTQ_SMOKE_PWSH` 覆盖点后，在真
**Windows PowerShell 5.1.19041** 上跑通全部 **31 个用例**（`ps51=covered`）——
本仓第一次在 PS 5.1 上执行该客户端契约（此前只有「Win11 实测 13 例」的文字记录）。
过程中修了两处**只在 PS 5.1 下暴露的检查移植问题**：PS 5.1 不接受 POSIX 路径作
`-File`（pwsh 7.5 接受），须经 `cygpath -w`；`ps51=` token 改为反映实际解释器。
**② `smoke/09` 的 CRT 模型获真机证实**：5 组校准值逐条复现、argv 逐字一致。
**③ 性能**：`status` 5m47s 的根因是 jq 走了 chocolatey 的 .NET 壳（单次 167ms vs
真 jq 23ms，**7.1 倍**；1930 次调用累积成 **3.1 倍**端到端）。**不是缺陷，是环境**；
`docs/performance.md` 记的 114s 用的是真 jq，两者都对。**④ 该机已升级**（见 B5）。
**⑤ A5b 当时仍不做**：该机 `DefaultShell` **未设置** = 默认 `cmd.exe`，
实测 `2`/`5`/`124`/`42` 原样传回——A5b 的压平只在 `DefaultShell=powershell.exe`
时出现，而那列当时无真机，改一条无法验证的路径属于「凭想象写」，不做。
（**2026-10-01/02 更新**：`powershell.exe` 那列已在专用测试机上造出真机，
A5b 随之修复并经两列双向验证——见 A5b 正文与本节 A5b 行。）

**C4 已重定性**：用户**无生产权限**（用户是 AgentQ 的独立创建者，但生产环境不在其可授权范围内；只在私有环境部署测试），
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
| **C2 余格** | 平台矩阵的范围授权（原生包管理器组合）。C3/C5 已执行关闭（见 C 类表），C4 用户已明令**不得记为待办**——本行 2026-10-13 更正：原把已关闭的 C3/C5 与明令排除的 C4 一并挂在这里，与自家 C 类表矛盾 |
| ~~**A5b 操作路径退出码通道**~~ | **已修（2026-10-02）**：token 走 **stderr**（客户端本就捕获它，服务端 `reason=` 同路），两份客户端各改一处、`smoke/05`+`smoke/12` 各加回归锁，真机两列双向验证 + 变异 3/3。见 A5b 正文 |
| ~~**A8/B5 主机 C**~~ | **2026-09-24 那次已完成**（队列已空、已重装、端到端通过）。**但 2026-09-25 又落后了一版**：主机 A（Windows）与主机 B（Linux）已升到 `97088c62`，**主机 C（macOS）仍是 `e3b132af`**，即 A12 的 P0 在该机未消除。原因不是拒绝升级，是**该地址在本机网络层不可达**（ARP `incomplete`、同网段网关也不通）。恢复连通性后按同一流程处理（**2026-09-26 已决定不追**，见下行） |
| ~~**原「主机 C」的地址**~~ | **已决定不追**（2026-09-26）：用户指定 macOS 主机以新那台为准，该机已完成全新安装。原那台仍带 A12 的 P0，但**不在当前机群内**——若将来重新启用，先升级 |
| ~~**A16 Windows 客户端认证提示**~~ | **已完成**（2026-09-27）：照 A9 在 `Write-Diagnostics` 里按 class 追加，配 `smoke/12` 双向用例（认证必打且须含主机名，其余 class 必不打），红/绿 + 变异已验证 |
| ~~**A17 脱敏不变量回归**~~ | **已完成**（2026-09-27）：46 处地址等标识清除，并新增 `smoke/16-no-host-identifiers` 把那次一次性扫描变成常设检查；**2026-10-06 跟进**：又清一次（计算机名/账户名/VM 名）并加 `R7`（见 A17 末尾） |
| ~~**A18 密码认证支持**~~ | **已完成**（2026-09-28）：`BatchMode` 条件化 + 三种凭据来源（`AGENTQ_ASKPASS` / `AGENTQ_PASSWORD` / `AGENTQ_PASSWORD_PROMPT`），严格守卫；新增 `smoke/17-askpass-credential`（真实 sshd 端到端）+ `smoke/05`/`12` 各一组 argv 与拒绝用例。**2026-09-29 真机补验**：账户密码登录成功已在真机验证（POSIX 与 Windows 客户端各连一台只有密码的 macOS 主机，完整协议 `Done.result="Success"`）；Windows 客户端已升级到 canonical 并跑通端到端。**2026-10-02 关闭「原生 Windows ssh 未验证」**：专用测试机的客户端 PATH 解析到 `C:\Program Files\OpenSSH\ssh.exe`（`OpenSSH_for_Windows_9.5p1`，**原生**，非 Git Bash MSYS），Windows→Windows 经它跑通完整协议。**唯一仍属边界的**是 `System32\OpenSSH\ssh.exe` 8.1p1（早于 `SSH_ASKPASS_REQUIRE`，且不是客户端默认解析到的构建）。见 A18 |

**A1/A2 之后覆盖债的实际变化，要说准。** 这两个检查覆盖的是**契约**，不是按行数
成比例的覆盖，所以「覆盖债从 12,419 行降到 N 行」这种算法是**错的**，不要用。

准确的说法：12 个零覆盖资产里，现在有 **8 个**各有一份契约检查——

- `client/unix/install-client.sh`（**296** 行，2026-10-10 重算）：本地契约 **13 例**（`smoke/21`，2026-10-03 新增；2026-10-07 加 W1 成对原子性用例；2026-10-10 加 1 例——目标路径上是服务端 wrapper 时必须拒绝）。
  **唯一一个成功路径也可测的安装器**（只拷两个文件进沙箱，无网络/无服务管理器/无包管理器），
  故契约与成功路径都覆盖了。真实 `~/.local/bin`、live 目标上的崩溃语义仍未覆盖。
- `windows-git-bash/agentq-launcher.ps1`（**466** 行，0.1.10 env 块 try/catch 后，453→466；**曾是本仓最大的零覆盖资产**）：**61 例**（`smoke/22`，
  2026-10-03 新增；此后各轮增至 **74 例**、510 行，实时计数以 `docs/verification-status.md` 为准），覆盖在 macOS 上可跑的三块——payload 解码器、路径守卫、env→argv 回环 bash 脚本，
  **外加 `agentq-start-daemon.ps1` 的两个路径守卫**（与 launcher 的守卫近乎逐字拷贝，故一并断言两份行为一致）。
  **Windows API 路径（`WindowsIdentity`+HKLM）仍未覆盖**，摘要行明写 `windows-api=NOT-covered`。
- `windows-git-bash/agentq-durable-move.ps1`（118 行）：参数契约 4 例 + **源码级 access-mask 不变量** 3 例
  （`smoke/23`，2026-10-03 新增）。它是本项目第一个原生 Windows 缺陷的现场；那条 access-mask 常量
  只有真机能注意到回归，故源码级钉住。**move/flush 行为仍未覆盖**（本机死在 kernel32 P/Invoke）。
- `install-agentq.sh`（**2,970 行**，2026-10-10 重算）：失败契约 **29 例**（`smoke/11`
  自报 `cases=29`；17→20 的 3 例见 A27——临时路径的可预测名与助手本身的原子性；
  20→22 的 2 例是 curl 自身失败与模板缺占位符；22→27 的 5 例是 W5 崩溃残留两例、
  父目录不可列、恢复指引与 daemon 消息，见「C2 补格」；27→29 的 2 例是 wrapper 路径
  被 AgentQ 客户端占用——升级必须拒绝且不动那个文件，反向断言内容不同的旧 wrapper
  不得被拒，见 `CHANGELOG.md` 2026-10-10 条）。
  **成功路径仍是零覆盖**，而成功路径才是它 2,970 行里的绝大部分。
- `client/windows/agentq.ps1`（**2,522** 行，0.1.10 stdin 读循环重写后）：本地参数契约 **49 例**（`smoke/12`
  自报 `cases=49`，pwsh 下；2026-10-02 在真 PS 5.1 上实跑 `ps51=covered`）。**远端交互、传输、重试、恢复全部仍未覆盖**，
  A18 新加的凭据路径**选项构造**已被断言，且**真机行为已验**（2026-10-02 专用 Windows
  测试机：原生 ssh + askpass 密码，Windows→Windows 完整协议）。

- `windows-git-bash/install-agentq.ps1`（**3,077** 行，2026-10-10 重算）：参数契约 + 平台闸门 + **W5 崩溃残留守卫** 7 例（W5 见上）。
  **这台机器上不可达的 staging/ACL/事务路径仍是零覆盖**，且已实测确认不可达
  （任何参数组合都死在第一条语句上），所以这一份契约检查的覆盖面比前两个更窄。

- `client/windows/install-client.ps1`（**563** 行，2026-10-07 按当前字节重算）：**从「只有源码断言」升级为「有行为执行」**
  （`smoke/25`，2026-10-03 新增，9 例）。此前它只有 `10` 的四条源码不变量——按本表的定义
  那算「执行过」，但**从未被运行过**，与 `install-agentq.ps1` 在 `13` 之前的状态同类。
  *（该行数是 2026-10-07 的快照，不是当前值；文档里的行数陈述已从 0.1.18 起逐步删除，见本文件末轮记录——它们不构成断言，只会在下次改动后失真。）*
  现在参数契约（缺值／未知参数／`-Check` 下未知参数）与平台闸门被真正执行，并证明
  **闸门先于任何写入**、`-Check` 也撞闸门。**staging/ACL/原子移动/PATH 更新仍是零覆盖**
  （第一条语句之后的全部，实测在 macOS 上不可达）。**分子不变**（该资产本就被计入
  「已覆盖」），但证据从源码级升到了行为级。

- `client/unix/sshp`（**1,235** 行，2026-10-14 复核未变）：本地契约 **21 例**（`smoke/19`，2026-10-02 新增；2026-10-07 加 `--check` 重试预算，2026-10-12 加两条 trap 位置锁）。
  覆盖参数校验、环境变量校验、`--help`、探测分派（含 `--check` **不得安装**）、
  重连策略、实际 argv、TMPDIR 零残留，以及会话名的注入守卫。
  **任何真实远端仍是零覆盖**——桩证明的是 sshp **发出什么**；交互会话本体、
  Windows 路径、远端安装路径都未覆盖（见 `smoke/19` 头注释的边界清单）。

`client/windows/sshp.ps1`（1,179 行，2026-10-14 复核未变）**不再属于「从未被执行过」那一类**：`smoke/20`
（2026-10-02）在 pwsh 里真跑它 `--check`、捕获它实际发给 ssh 的 argv 并断言往返。
但要说准：那是**一条路径**的断言（脚本怎么交给 ssh），不是它的本地契约——
它的参数校验、会话建立、Windows 路径仍未覆盖。

仍然**没有任何检查执行过**的资产（"执行过" = 行为执行或源码断言；只有 `01` 的
语法/结构解析不算；从资产中**抽出单个函数**执行的算覆盖该函数、不算执行过整个
资产）。按行数：`agentq-start-daemon.ps1`（268），
2 个 `.cmd` 薄启动器（8），
2 个 `.plist` + 2 个 `pueue.yml` + 1 个 `.service`（110），以及 `unix/agentq`（5，
只是转发 shim）。合计 **391 行 / 27,821 行 = 1.4%**（分母 2026-10-14（晚，0.1.10 后）重算为 27,821；0.1.9→0.1.10 的变更：`agentq.ps1` 2,516→2,522（stdin 读循环重写 +6）、`agentq-launcher.ps1` 442→466（env 块 try/catch +24）、POSIX 客户端 3,815（单行 wrapper 等长替换）；分母 0.1.8 后为 27,782。更早：`skill/assets/` 全部 23 个资产 `wc -l` 之和 = 27,415（2026-10-12 **第二轮**全维度审查修复使客户端 `agentq` 3,712→3,725、`sshp` 1,215→1,223（trap 形态与 reason 清零共 +21 行，四处版本常量 0.1.5→0.1.6）；同日**第一轮**修复使 `agentq-server` 5,399→5,464（净增 65 行修复注释与折叠）、客户端与两个 `.ps1` 亦增；同日早些时候的 dash/POSIX 修复与死变量清理曾使客户端 3,688→3,697）；此前为 27,394（2026-10-12 第一轮）、此前 27,216（2026-10-12 早些时候）、此前 2026-10-11 为 27,207、2026-10-10 为 27,199（`agentq-server` 随**路径守卫折叠**等改动在 5,395↔5,399 间小幅变动，折叠本身**净增 4 行注释**（4 守卫折到 2 守卫各留一段说明），故 27,199 → 27,207）；再往前 A31 使 `agentq-server` 由 5,388 增至 5,395，wrapper/客户端冲突修复（`install-client.sh` +16、`install-agentq.sh` +22）与原生 Windows jq 的 CRLF 修复（`agentq-server` +56）亦推高过它。**分子仍是 391**——这几处改动都不在这张表里，故未变）。
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
分母已于 2026-10-14（晚）重算为 **27,821**（0.1.10 落地后：`agentq.ps1` 2,516→2,522、launcher 442→466、stdin 读循环与 launcher try/catch；此前为 27,782，0.1.8 落地后）（`skill/assets/` 全部 23 个资产 `wc -l` 之和）。
别再引用旧的 25.9%、13.8%、4.8%、1.6%、1.5%、25,536 或 26,264。

**0.1.13 修复之后的平行实现清查（2026-10-16，用户「继续」）**：0.1.13 修了 POSIX 安装器的
不可粘贴占位符；两份安装器是平行实现，Windows 侧按同一类缺陷清查，**查实同类缺陷仍在**
并连带发现两处 0.1.13 的锁根本没锁住，落地为 **0.1.14**：

- **Windows 安装器残留指引仍是 `Move-Item <the .AgentQ.backup directory> $RootDirectory`**
  （`Assert-NoCrashLeftoverTransactions` 的 missing-root 分支）——与 POSIX 侧修掉的同一缺陷。
  修法对齐 POSIX 侧：`$restoreCommands` 从**扫描到的真实路径**构造，
  `Convert-ToPowerShellSingleQuotedString`（本文件既有 helper）整路径单引号引用，
  每个 backup 一条 `Move-Item '<residue>' '<root>';`；无 backup（如只有 `.stage`）时走独立分支
  明说「没有可恢复的 backup 目录」（POSIX 侧同形态）。present-root 分支措辞不变（本就带真实路径）。
- **smoke/13（Windows 安装器 W5 锁）此前只断言消息片段**，占位符回归不会被抓住——新增可粘贴性锁：
  断言角度占位符不存在、恢复段**用 PowerShell 解析器实际解析**（oracle 是解析器，
  **不是**安装器自己的 quoting helper——用它自证会放过坏 helper，变异 M6 证之），解析出的
  串常量必须含真实残留路径与 root。残留目录名故意带**单引号**（`.AgentQ.backup.Smoke'AbC`）：
  变异 M4 实测，普通名字下「裸拼接 + 内层引号」与正确输出逐字节相同、全部检查绿，
  有了单引号才解析出**不同的路径**、当场红。五个变异全红（M1 占位符回归、M2 无命令、
  M3 stage 分支措辞、M4 裸拼接、M5 backup/stage 过滤翻转、M6 弄坏 quoting helper）。
- **smoke/11（POSIX 安装器）同样只断言片段**：0.1.13 修了资产，但**没有锁**钉「可粘贴」——
  把 `mv $(quote_shell_word …)` 改回 `mv <the .backup directory>` 占位符，该文件 29 例照旧全绿
  （实测）。新增**行为锁**：从 stderr 抽出 `Restore it with:` 到 `then restart` 之间的命令，
  断言无 `<`，然后**原样执行**并断言 backup 真的回到了 root（残留名带空格+单引号，
  P2 变异去掉 quote_shell_word 即红）。P1（占位符回归）/P3（backup/stage 过滤翻转）均红。
- **`--stdin-script` 的 0.1.13 守卫同样没有锁**：smoke/05 的提取正则匹配
  `printf %s <b64> | base64 -d | sh`，**守卫删掉也照样绿**（实测 Q1：38 例全绿）。
  smoke/05 新增**行为锁**：捕获客户端发出的**真实远端命令串**，在一个**只有 sh、没有 base64** 的
  PATH 上原样执行——无守卫时退 0（正是 0.1.13 修的那个 fail-open），有守卫必须退 2 且报错点名
  base64；再在 base64 **存在**的 PATH 上跑一遍断言脚本真执行了。变异 Q1（删守卫）红、
  Q2（守卫追加在管道之后）红、Q2b（守卫挂成管道恢复子句 `| sh || { … }`）红。
  **实测修正一处认知**：Q2 的「无条件追加在管道之后」形态**能通过**该锁（它使任务失败、
  不再 fail-open，终态等价），故锁断言的是**终态**（base64 缺失时不得静默成功）而非 token 位置。
- **smoke/12（ps1 客户端）的 stdin-script 静态锁升级为结构锁**：原 `grep -q -- '--stdin-script'`
  连解码命令都不检查。ps1 侧不能复用 smoke/05 的行为锁（那是 POSIX 客户端发出的串），
  改为断言**同一条串里**「守卫块 → `;` → 管道」的形状（注释行排除，防止留注释删真守卫）。
  变异 W1（删守卫）/W2（追加在管道后）/W3（恢复子句）全红；W2/W3 落在
  「守卫块直接接管道」检查上——该检查按位置否定恢复子句形态，与 smoke/05 的终态锁互补
  （一个测资产形状、一个测行为，两层各承重）。
- 资产注释随之更正：三处「a check appended after it would never fire」的说法**过强**——
  追加的**无条件**检查在 base64 缺失时确实会触发（任务退 2）；永不触发的是**恢复子句**
  形态（`||` 只在管道已退 0 后才轮到它）。已按实测改写。

**两路独立审查（2026-10-17，用户「继续找」）：launcher 三件套 + sshp 双实现。** 一路由我逐行核对安装器/服务资产/文档契约/CI（未发现新缺陷），两路并行子代理分别审 Windows launcher 三件套与 sshp 双实现。**每一条都经我本人复现或复核后才行动**。结果落地为 **0.1.15**：

- **launcher 未捕获 throw 族（已修，0.1.15）**：`agentq-launcher.ps1` 只有 payload 解析一处有 catch；其余全部 throw 站点——顶层两个 required-file 断言（**服务端文件缺失可达**：客户端协议探针只检查 launcher 本身、不检查 `agentq` 服务端文件，所以该状态能过探针、随后在每个操作上现形）、`Get-CurrentWindowsUserEnvironment` 的 5 处 throw、`New-AgentQLauncherRuntimePath` 耗尽、`WriteAllText`/Git Bash 启动失败（在无 catch 的 try/finally 里，throw 穿过 finally 继续）——在 `-File` 脚本顶层未捕获即**退 1 + CLIXML 堆栈**，wrapper 的 `agentq-exit` 令牌永不执行，客户端报**无分类的 1** 而非契约的 2（实测复现：launcher throw → wrapper 退 1、stderr 零令牌；正常 `exit 2` 则令牌正常）。这正是 2026-10-12 修 payload 解析、2026-10-07 修 start-daemon 时各只闭合一个站点的「同一机制抄多处只修一处」病灶第三次现形。修法：**顶层 trap**（message + `reason=protocol_error` + `agentq-exit:2` + exit 2）——实测 trap 不拦截 `exit`（两个既有 catch 站点的形态不变、无双重发射）、不影响成功路径，还顺带把 macOS 上的平台不兼容崩溃（退 1 + CLIXML）变成干净的契约 2。锁在 `smoke/22`：静态（trap 的 message/reason/token/exit 2 四件套）+ **行为级**（真 launcher 子进程、无服务端文件 → 必须 exit 2 + reason + token）。变异 T1（trap 关键字改名）/T2（reason 行删除）/T3（token 行删除）/T4（=T1+行为级同报）全红。
- ~~**start-daemon 探针的 StrictMode LASTEXITCODE（如实记录，未修）**~~ **2026-10-20 更正：标题已过时**——紧随的下一行（2026-10-17 第七轮）就是「已修」，标题却仍断言未修。原记录内容保留如下，划掉的只是标题：`agentq-start-daemon.ps1` 探针在 `& $clientPath` **启动失败**（AV/策略拦截等 CreateProcess 失败，非终止错误、不设 `$LASTEXITCODE`）时，`if ($LASTEXITCODE -eq 0)` 在 StrictMode 下抛「variable cannot be retrieved」、进程退 1（实测复现）。影响有限：唯一调用方把非零折叠为 `fail`（退 2），方向正确，损失的是诊断信息。**未修的原因**：该文件顶层第一条语句在 macOS 上死于 `WindowsIdentity`，任何修改都无法在本机行为级验证；留待真机会话处理。
  - **2026-10-17 第七轮：已修。** 探针改为本仓其余 PowerShell 资产同款的 `Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue` 守卫；变量未设（CreateProcess 失败）时打出 `AgentQ Pueue client could not be executed: <path>` 并**受控退 2**，不再让 StrictMode 的 throw 把进程变成退 1 + PowerShell 错误。实测依据（pwsh 7.5，本机可直接量）：`Set-StrictMode -Version Latest` 下直接读 `$LASTEXITCODE` 抛「The variable '$LASTEXITCODE' cannot be retrieved」，`Get-Variable` 形式返回 `$null` 而不抛。**锁是静态的**（`smoke/22` 两条：可执行行里不得出现裸 `$LASTEXITCODE`——注释行豁免，因为修复注释本身会点名该变量；且必须存在 `Get-Variable -Name LASTEXITCODE`），理由与本文件既有的两条路径守卫相同：该文件顶层在本机死于 `WindowsIdentity`，行为级不可达。为让静态锁可被证明红，`smoke/22` 补了 `AGENTQ_SMOKE_START_DAEMON` 覆盖钩子（红证：还原成裸读 → 2 failures）。真机行为（AV 拦截下的实际退出）仍属未验证边界。
- **launcher 两条 exit-2 路径的 reason 不对称（标题已过时：实测现已全部闭合**——`agentq-launcher.ps1` 第 395/473/499 行三处 exit-2 路径都带 `reason=protocol_error`，正文末句「三条路径统一」才是现状；「闭合一半」是 0.1.15 修 trap **之前**的中间态。**2026-10-20 更正，标题原样保留**）**：解析 catch 无 `reason=` 行、env 溢出 catch 有——修 trap 时三条路径统一为都带 reason；`smoke/22` 对两个既有站点的锁不变。
- ~~**sshp 双实现审查（如实记录，未修——需要单独一版）**~~ **2026-10-20 更正：标题已过时**——紧随的下一段「0.1.16 落地」就是把这两条记录（P1 + 八处行为分歧）变成代码与锁的过程：P1 已改走 stdin 通道、八处分歧已逐条修并配锁。原记录内容保留如下，划掉的只是标题：
  - **P1（最重要）**：`sshp.ps1` 的三条 Windows 远端命令（探针 23,210 / 安装 23,882 / 会话 22,274 字符，实测）把整个脚本（17.4K 的 Zellij resolver 为大头）经 `-EncodedCommand` 放在**命令行**上；本仓真机实测的 powershell.exe 截断上限是 **8,125** 字符（`smoke/14` 头部），超限**不是响亮失败**而是 base64 腰斩 → `TerminatorExpectedAtEndOfString` → 误导性「probe failed」。POSIX 侧同路径是 76 字符命令 + stdin——这正是 `agentq.ps1` 已修过（stdin 通道 + `smoke/14` 站点 4）而 `sshp.ps1` 没跟上的同一缺陷。**无任何检查覆盖**（`smoke/14` 只量 sshp.ps1 的两条 unix 脚本；`smoke/19` 只跑 POSIX）。未修原因：探针/安装两条可本机验证，但**会话**命令要 `-tt` 下把脚本从 stdin 喂进去且随后保持用户 tty 输入（POSIX 用 FIFO `cat file -` 拼接；ps1 无等价物，需要 `Start-Process -RedirectStandardInput` 级别的改造），真机才能验证——留待 0.1.16 与真机会话一起做。
  - **八处行为分歧**（各有桩实测退出码）：空会话名 POSIX 接受/ps1 拒（smoke/19 钉了 POSIX 侧）；`-h extra` 与 `--check --help` 的 help 语义两向镜像分歧；Windows 探针失败退出码 POSIX 透传/ps1 塌成 2；probe 标记匹配 POSIX 只看标记/ps1 要求标记与状态一致（若真机发生 A5b 式码压平，ps1 会把「可装」误报成 probe failed）；`SSHP_SSH` 各缺对方的守卫（exec 位 vs 非 reparse）；`SSHP_RECONNECT_DELAY` 大数值 POSIX 校验放行、断线后死在 `sleep` 退 1 / ps1 启动即拒（反向 `+5` POSIX 拒/ps1 收）；纯空白主机名 POSIX 放行/ps1 拒；probe 标记锚定 glob vs 行锚定正则（注入面形状不同）。均为真分歧、均为小改，但没有一条独立可达 P 级——与 P1 一起放进 0.1.16 的 sshp 主题处理，避免一版里混入无法真机验证的改动。

**0.1.16 落地（2026-10-17，用户「要」）：sshp 主题。** 把上面那两段记录变成代码与锁，**并如实记录三条没修的东西**。

- **P1 已修：`sshp.ps1` 的探针与安装命令改走 stdin 通道。** 新增 `Get-WindowsScriptInvocation`，返回 `{Command, Input}`：`Command` 是 76 字符的 `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command -`，`Input` 是脚本本体加尾部空行。实测命令行 **76**（原 23,210 / 23,882），载荷 8,729 / 8,926 字节。`Invoke-SshLogged` 加 `[AllowNull()][string]$InputPayload`，非 null 时用管道喂给 ssh（`$InputPayload | & $script:SshPath @sshArguments`）。两个 builder（`Get-WindowsProbeCommand` / `Get-WindowsInstallCommand`）都改为 `return Get-WindowsScriptInvocation -ScriptText (...)`，`Prepare-Remote` 的调用点相应改成 `.Command` / `-InputPayload .Input`。
  - **`-Command -` 的 EOF 语义是这版的第一个坑**：PowerShell 读 stdin 是 INTERACTIVE 模式，一个 pending 块只在**空行**终结时执行，EOF 处**静默丢弃**。所以 `Input` 末尾必须追加 `"\n\n"`（与 `agentq.ps1` 的 `Add-ProbeExitToken` 同一条规则）。`smoke/20` 的新桩 `stub-ssh-win` 用 `cat > file` 真读 stdin，载荷断言（含 `Resolve-RemoteZellij` 与 `__SSHP_ZELLIJ__`）能红——只验「命令行短」的检查对空 stdin 无感。
  - **会话命令不能走这条通道**：`-tt` 下 pty 的 stdin 归多路复用器，脚本喂不进去；而命令行又装不下 resolver（同一条 8,125 截断）。所以会话改成**两段式**：探针（刚跑过、同一台主机）在 READY 标记后多报一行 `__SSHP_ZELLIJ__:<路径>`，`Get-WindowsProbeOutcome` 解析它、`Prepare-Remote` 存进 `$script:ResolvedZellijPath`，会话命令只剩 `& '<path>' attach --create '<session>'` 的 EncodedCommand。实测最坏 **3,646** 字符（按从资产读出的 1024 路径上限算），原 22,274。
  - **路径是远端提供的文本，上命令行前必须收紧**：单引号/换行（会终结字符串字面量）、控制字符（同上）、> 1024 字符（会把命令行推过预算）三类一律**拒绝而非转义**——合法解析结果不会含它们，含了就说明 resolver 有缺陷或应答是敌意的，两种都不该被允许重塑命令。
  - **锁**：`smoke/14` 站点 8（抽 `Command` 常量：≤ 预算、无 `-EncodedCommand`、有 `-Command -`；awk 钉两个 builder 仍路由经助手、探针仍上报 `__SSHP_ZELLIJ__`）与站点 9（会话最坏长度，上限**从资产读**）；`smoke/20` 的行为锁（真子 pwsh、桩路由、命令行 ≤200、载荷含 resolver 与标记）。
  - **两个变异教了两件事**：M3 把路径上限从 1024 抬到 16384 时站点 9 仍绿——提取器把 1024 硬编码了，测量必须跟着契约走；M4 删掉探针的 `__SSHP_ZELLIJ__` 上报行时长度站点全绿——长度量不到内容，才补了那条 awk。
- **已修的分歧（POSIX 侧）**：纯空白主机名拒绝（`*[[:space:]]*`）；`SSHP_RECONNECT_DELAY` 改为 32 位有界（新增 `is_bounded_nonnegative_integer`：digits-only + 去前导零 + ≤2147483647），此前 20 位数会在断线重连时以裸 `sleep` 用法错误、**exit 1**（契约未定义）现形。`smoke/19` 新增 3 例（空白主机、2147483647 接受、2147483648 与 `+5` 拒绝），21 → 25 例。
- **已修的分歧（ps1 侧）**：`Convert-ToReconnectDelay` 先 digits-only 再 `TryParse`（`TryParse` 单独会接受 `+5` 与 ` 5`，实测）；`Get-WindowsProbeOutcome` 改为**标记优先、状态次之**（READY 仍要求 exit 0，因为零退出配 READY 之外的标记仍是客户端契约失败；INSTALL_REQUIRED/UNAVAILABLE 只认标记——`DefaultShell=powershell.exe` 的 A5b 式码压平会把「可装」答成 1，旧实现要求精确的 (42,REQUIRED) 对，于是把可装误报成 probe failed）；探针失败不再塌成 2，改为透传远端退出码（0 例外，保持 2）；`-h extra` 与 `--check --help` 按 POSIX 语义在第一枚 token 上识别 help；空会话参数回退默认值（对齐 POSIX `${2:-ghostty}`）。
- **如实记录，未修**：
  - ~~**`agentq-start-daemon.ps1` 的 StrictMode `$LASTEXITCODE` 边界**（0.1.15 记录）——仍缺真 Windows 才能验证，不动。~~ **2026-10-20 更正：已过时。** 该条是同一版内后续自查（第七轮）落地修复的：资产第 253 行已是 `$probeExitCode = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue`，未设时打 `AgentQ Pueue client could not be executed` 并受控退 2，锁在 `smoke/22`（静态 + 行为）。本清单当时没跟着改，于是「唯一权威的待办清单」里挂着一条已经做完的事——**改 PLAN 的待办清单要和改资产同一趟做**，否则清单本身就是误导。
  - ~~**POSIX sshp 的探针标记匹配是未锚定的 glob**（`*__SSHP_READY__:Linux*` 一类）……留待给 sshp 的标记匹配单独写一组对抗用例时一起做。~~ **2026-10-20 更正：已过时。** 同一版的 sshp 主题里就修掉了：POSIX 侧新增 `probe_reports_marker`（`tr -d '\r' | grep -E -q`，ERE 两端锚定，12 处调用全部改走它），`smoke/19` 也补上了那条对抗用例——三条 `mid-line … marker is not …`（READY / INSTALL_REQUIRED / WINDOWS_SHELL 各一，喂的行形如 `banner: __SSHP_READY__:Linux is a phrase`，断言两侧一致的「both shells」判定）。与上一条同一个教训：**「如实记录，未修」的清单要看资产，不能只看当时写下的字。**
  - **`SSHP_SSH` 的两侧守卫不同**（POSIX 查 exec 位、ps1 查非 reparse）：两侧的**威胁模型**本就不同（Windows 无 exec 位），不是同一属性的两个实现，记为平台差异而非缺陷。
- **这一版刻意没做的事**：会话路径**没有**在真机上验证过。两段式的正确性由静态长度与桩行为锁（含自查补上的会话命令锁）支撑；`-tt` 下 `& '<path>' attach` 能否接住用户的 tty 输入、Windows 目标上 Zellij 的 attach 语义，都需要真机会话——**不要**把 `smoke/14`/`20` 的绿灯读成「会话可用」。
- **0.1.16 发布后自查发现并已修的覆盖空洞（同日）**：两段式的**后一段**（会话命令）此前零行为覆盖——`smoke/14` 只量长度、`smoke/20` 的 Windows 用例只跑到 `--check`（`--check` 在会话命令之前就 exit 0）。三个性质都没有检测器，两个变异实测逃逸：**M1**（把 `__SSHP_ZELLIJ__` 的解析结果强制成空串）→ 14/20 全绿，而真实效果是每台 Windows 主机的会话都会以「no resolved Zellij path」拒绝；**M2**（把引号守卫改成恒假）→ 全绿，而实测会话命令发出 322 字节、里面嵌着 `C:\Users\O'Brien\zellij.exe`——守卫要防的正是这个（单引号提前闭合字面量，后续内容成为远端 PowerShell）。**这是本项目反复纠正的「修了没锁」第三次在 sshp 上现形**（前两次：0.1.14 的三组锁、0.1.15 的 launcher trap）。补的锁在 `smoke/20`：真子 pwsh 跑**完整会话**（不是 `--check`），桩把 EncodedCommand 记到文件，断言 ① 探针报的路径**逐字**嵌进 `& '<path>' attach --create '<session>'`、② 会话退出码透传、③ 引号路径与 >1024 路径各退 2 且**零会话命令发出**、④ `--check` 从不产生会话命令。实测真实资产 cases=21 全绿，M1 → 4 failures、M2 → 3 failures。
- **第二轮自查：0.1.16 的五处 ps1 侧语义修复全部没有锁（同日，已修）。** 把每处修复各还原成缺陷原型（reconnect delay 退回 `TryParse`-only、标记匹配退回 `(42,REQUIRED)` 对、探针失败码塌回 2、help 退回只认单 token、空会话名退回赋空串），**五个变异在全部 29 项检查下全绿**——`smoke/20` 此前一条语义用例都没有，`smoke/14` 只量长度，其余检查根本跑不到这个客户端。同一版里 POSIX 侧的两处（空白主机、32 位上界）`smoke/19` 都能红（实测：还原 `is_bounded_nonnegative_integer` → `reconnect delay one past the 32-bit maximum is refused: expected exit 2, got 0`），**ps1 侧却是裸的**——「同一属性两个实现必须两边都有锁」，又只锁了一边。补的锁在 `smoke/20`（13 例，cases 21 → 34）：`parity_run` 驱动真子 pwsh 穿过按形态路由的桩（ready / flattened-required / failing），五条语义各一组断言——`+5` 启动即拒（exit 2）、**A5b 压平的可装主机**（`1+REQUIRED`）必须由标记解出、`--check` 下退出 127 且 ssh 调用数 ≤3（不装）、探针失败透传自己的码（7 而非 2）、`-h extra` 与 `--check --help` 退 0 且输出 usage、空会话参数不被拒。红证：五变异分别 1/2/1/2/2 failures。**注意 message 级断言故意只用在「该消息是契约本身」的三处**（拒绝消息、usage、missing-dependency），其余断言落在退出码与调用数上——退出码是契约，措辞是表面。
- **第三轮自查：新加的三块锁在 Windows CI 上会红（同日，已修）。** `smoke/20` 同时跑在 POSIX job（pwsh 7）与 `windows-latest` job（真 PS 5.1，`AGENTQ_SMOKE_PWSH=powershell.exe`），而**该文件自己的头部就写着**：Windows 上原生 PowerShell 既解析不了 MSYS 路径（客户端在 `SSHP_SSH is not an executable file` 处停）也执行不了 `#!/bin/sh` 文件，所以它的桩在 Windows 上必须是 **csc 编译的原生记录器**——这是第一次真 CI 跑红（run 37810470283）后加的机制，我加锁时**没有读懂自己文件的注释**，三块新用例（Windows 探针、两段式会话、五处 parity）全部手写 sh 桩并把 POSIX 路径直接交给客户端：本机（无 cygpath，走不到 Windows 分支）全绿，**推 CI 即整块红**。修法：把路由契约移进既有的 C# 记录器（`PS_STUB_MODE=sshp-win/sshp-parity` 两臂，镜像两个 sh 桩的应答形状），两个桩路径与所有捕获文件路径经 `cygpath -w` 转换；Roslyn 编译校验过 C# 源（`Add-Type` 通过），POSIX 分支与全部 11 个变异在本机复验不变（五语义 1/2/1/2/2、两会话 M1=4/M2=3）。**边界如实记录：Windows 分支在本机不可达，下一次 CI 的 windows job 是它的第一次执行**——与这个文件里其它 Windows 分支同一条注记。教训与 `e74761c` 相同、方向相反：那次是「Windows 分支第一次执行才发现」，这次是「加锁时忘了该文件已有双形态机制」——**在一个自带跨平台桩的文件里加用例前，先读它的桩，不要新写一个。**
- **第四轮自查：CRLF 的探针输出会让 0.1.16 在每台真 Windows 客户端上不可用（同日，已修）。** 0.1.16 把 Windows 探针的应答从单行改成了**两行**（`__SSHP_READY__:Windows` + `__SSHP_ZELLIJ__:<路径>`），而客户端的读取路径是「ssh stdout 重定向到文件、读回、按行锚定正则匹配」。**实测（2026-10-17，pwsh 7.5 里直接量 .NET 语义）**：`(?m)^__SSHP_READY__:Windows$` 对 `…Windows\r\n…` 返回 `False`——多行模式下 `$` 的位置在 `\n` 之前，而那里紧挨着的是 `\r`，不是行尾；`.Trim()` 只吃掉**尾部**的 CRLF，**内部**的那个原样留下。**0.1.16 之前的单行探针能活下来纯属侥幸**：应答只有一行，`.Trim()` 恰好把末尾 CRLF 去干净。对照实测：CRLF 桩 → 客户端 exit 2 `remote dependency probe failed for the Windows shell`；LF 桩 → exit 0、READY。**这条不是理论可达**：PowerShell 5.1 的 `>` 重定向经 Out-File 按平台换行重发，`smoke/20` 自己的 C# 记录器用 `Console.Out.WriteLine`，在 windows-latest 上两者都产出 CRLF——也就是说下一轮 CI 的 `sshp-win`/`sshp-parity` 各例（以及真实 Windows 客户端）都会整块红。**修法**：在唯一的汇聚点加 `ConvertTo-MarkerText`（把 `CRLF` 归一成 `LF` 后再 `Trim`），三处标记匹配器（`Get-ProbeOutcome`、`Test-WindowsShellMarker`、`Get-WindowsProbeOutcome`）全部改走它——`grep '\.Output'` 实测恰好这三个读取点，没有漏网的第四处。**锁**：`smoke/20` 的 CRLF 块（2 例，cases 34 → 36）——`--check` 必须到达 READY，完整会话必须走到桩的 `-EncodedCommand` 臂（退出码 7 透传、会话命令落盘）；后一条是**正向断言**，路径若仍带 `\r` 会被引号/换行守卫拒绝（exit 2、零会话命令），探针若失败也到不了那一步。红证：M3（`return $Text.Trim()`，只删 CRLF 归一）→ 两例全红、2 failures，真实资产随即还原并 `cmp` 复核。**这一轮我自己又踩了第三轮同一条**：CRLF 块的第一版手写 `#!/bin/sh` 桩、直传 POSIX 路径给原生客户端，本机绿、Windows job 必红——提交前发现，改为复用 `stub_win_ssh`/`sshp-win` 的双形态接线（Windows 上记录器的 `WriteLine` 本来就是 CRLF，等于原生复现该属性）。**「加用例前先读这个文件的桩」这条教训写下来才一轮就重犯了，说明它不是知识问题是流程问题：改 `smoke/20` 的任何新块，先确认 `stub_windows` 分支怎么接。**
- **第五轮自查：三处「一侧修了、另一侧没修」与一条两侧都没锁的承诺（同日，已修）。** 前三轮都在 `smoke/20` 的覆盖与形态上，这轮回到**两个客户端的行为对照**——把每个解析与守卫按输入逐个对拍（`' '`、`foo bar`、tab、NBSP、`--check --help`、`--check --check`、piped-`y`），量出三处分歧与一处无锁承诺：
  - **空白主机名：POSIX 拒、ps1 放行（真分歧，已修）。** 0.1.16 在 POSIX 侧加了 `*[[:space:]]*`，ps1 侧只有 `IsNullOrWhiteSpace`（只覆盖**全空白**）。实测 `sshp.ps1 --check 'foo bar'` **exit 0 并跑完探针**（对一个 ssh 必须加引号才能用的名字），POSIX 同输入 exit 2。修法：ps1 在空判定**之前**加 `-match '\s'`（NBSP 也覆盖——实测两侧对 `foo\u00a0bar` 都拒），保证空白优先于「empty」消息，与 POSIX 同一条。锁：`smoke/19` 两条（嵌入空格、嵌入 tab——只测 `' '` 区分不了 `[[:space:]]` 与字面空格判定）+ `smoke/20` 两条 parity。红证：M5（ps1 守卫退回 `IsNullOrWhiteSpace`）→ 4 failures；POSIX 侧删守卫 → 3 failures。
  - **`--check --help`：POSIX 拒、ps1 出 usage（真分歧，已修）。** 0.1.16 把 ps1 的 help 改成「`--check` 后的第一枚 token 也识别」，PLAN 当时写成「按 POSIX 语义」——**但 POSIX 的 `case` 只跑一次**，`--check --help` 在那里落到 host 位置被拒（exit 2）。实测两侧一 0 一 2。修法：POSIX 在 `--check` 分支 `shift` 后加内层 help 判定（与 `-h extra` 的「help 胜出」一致），并把注释里「按 POSIX 语义」的说法改成两侧共享的契约。锁：`smoke/19` 两条（`--check --help` 必须 0；`--check --check` 必须非 0——只测前者的话，一个「吞掉 `--check` 后所有 token」的守卫也会绿）。红证：POSIX 删内层判定 → `--check --help` 红。
  - **「无 TTY 拒绝安装」两侧都没有行为锁（无锁承诺，已补）。** SKILL.md 写着「首次缺依赖会在本地交互终端确认；无 TTY 时明确拒绝，不会静默安装」，但 `smoke/19` 只测了 `--check` 不安装、`smoke/20` 的 parity 也只测 `--check`。补的锁用**更强的形态**：stdin 是**装着 `y` 的管道**（不是空 stdin）——只检查「stdin 有数据」或「无 tty 就直接读答案」的实现都会安装。断言三条：exit 1、拒绝消息、ssh 调用数恰为 1（POSIX）/≤1（ps1，只计 `-Command -` 形态）。红证：POSIX 删 `[ ! -t 0 ]` → 3 failures；ps1 删 `IsInputRedirected` → 2 failures。
  - **M6 第一次逃逸暴露的锁形态错误（值得单独记）**：ps1 的这条用例最初用 `-NonInteractive` 跑，删掉守卫的 M6 **全绿**——因为 `-NonInteractive` 下 `Read-Host` 直接抛异常，catch 兜底打出**同一条**拒绝消息，守卫与兜底不可区分。而真实的 `sshp.cmd` 与 `sshp.bash` **都不带** `-NonInteractive`（`agentq.cmd` 带），真实路径上 `Read-Host` 会消费管道、安装真的会执行（实测 M6 无 `-NonInteractive` 时 3 次 ssh 调用、零拒绝消息）。**锁必须照抄启动器的 argv，不能用一个更严的形态**——这是「fixture 必须建模真实传输」在调用形态上的又一次现形（2026-09-24 的 `-E` 日志桩、0.1.11 的 `--timeout` 桩同族）。
- **第六轮自查：PLAN 挂着的两条「未修」在本轮落地（同日）。**
  - **POSIX 的 Windows `INSTALL_REQUIRED` 仍要求精确 `42`（真缺陷，已修）。** 0.1.16 把 ps1 的探针改成「标记优先、状态次之」以容忍 A5b 码压平（`DefaultShell=powershell.exe` 把原生子进程的 42 压成 1），**POSIX 侧没有跟**：同一应答（`1`+`REQUIRED`）在 ps1 上退 127（可装、不装），在 POSIX 上退 2 `invalid Windows install status`——把可装主机误报成协议错误。实测 2026-10-17。修法：删掉精确 42 检查，与 ps1 同一条标记优先路径；`0`+标记不可能到这里（成功分支在上方且拒绝未识别的成功应答），无标记的 255 在更早的分支就重连。锁：`smoke/19` 新例（`43` MINGW 后跟 `1`+REQUIRED → 127 且报可装消息）。红证：M8 把精确 42 检查放回去 → 1 failure。
  - **POSIX 的标记匹配是未锚定 glob（PLAN 挂着的「留待对抗用例」，本轮修）。** ps1 一直是 `(?m)^…$`；POSIX 用 `*__SSHP_READY__:*` 一类 glob 匹配**整个输出**，于是任何**行中出现**该短语的诊断行（banner、motd、shell profile 回显）都会被当成协议应答。实测 2026-10-17：`banner: __SSHP_READY__:Linux is a phrase` → POSIX exit 0「persistent remote session: …」，ps1 exit 2。修法：新增 `probe_reports_marker`（`printf | tr -d '\r' | grep -E -q '^…$'`，两端锚定、先剥 CR——与 ps1 的 `ConvertTo-MarkerText` 对齐；**不用 `while read` 管道**，那会开子 shell 丢结果，本项目已三次踩过），四处路由（Unix 成功、Unix 失败、Windows 成功、Windows 失败）全部改走它。锁：`smoke/19` 三条对抗用例（行中 READY / 行中 INSTALL_REQUIRED / 行中 WINDOWS_SHELL 各一条，断言落到「both Unix and Windows shells」而非 READY 或 Windows 措辞）。红证：M7（Unix 成功分支还原成 glob）→ 1 failure；M7b（失败分支还原）→ 2 failures——**两个变异各覆盖一部分，因为四处路由里有两对**，只还原一处会漏掉另一半的用例。这正是「同一个匹配机制抄了四处」的教训。
  - 教训：PLAN 里「未修，留待 X」的条目是**债务清单**，不是免责声明；一旦 X 的 fixture 能造出来（本轮的行中标记桩），就该还——而还的时候必须数清**同一个机制的副本数**（本轮四处），否则只锁一半。
- **第八轮自查：第七轮自己的锁只钉了守卫的「存在」，没钉它的 fail-closed 分支（同日，已修）。** 把第七轮的修复按「删一半」拆成变异：**M2** 只删 `if ($null -eq $probeExitCode) { … exit 2 }` 整块、保留 `Get-Variable` 赋值与 `[int]$probeExitCode.Value` 读取——**smoke/22 全部 65 例全绿**，而该形态在 StrictMode 下的真实行为正是修复前的原缺陷（`$null.Value` 抛 `PropertyNotFoundException`，进程退 1 + PowerShell 错误）。第七轮的两条静态锁一条查「可执行行无裸读」、一条查「存在 `Get-Variable`」，M2 两条都满足。**「守卫存在」与「守卫守住了」是两回事**——这是本项目「修了没锁」病灶在锁自身上的现形：锁也可以只覆盖机制的形状而不覆盖它的语义。修法：`smoke/22` 的静态锁升级为**结构锁**（awk）：`Get-Variable -Name LASTEXITCODE` 赋值之后，任何 `$var.Value` 读取之前必须有一个 `$null -eq $var` 判定，且判定分支内 6 行内必须出现 fail-closed token（start-daemon/launcher 是 `exit 2`，installer 是 `return 1`）。红证：M2 → 1 failure、M3（null 分支改为 `exit 0`，即 fail-open）→ 1 failure、M1（还原裸读）→ 3 failures。
- **同一机制在全仓 PowerShell 资产里还有 19 处（同日，已修）。** 按 M2 的形态逐个资产扫 `$LASTEXITCODE` 的裸读：`agentq-launcher.ps1` 在 `& $gitBashPath --noprofile --norc $runtimeScriptPath` 之后有 **1 处**——CreateProcess 失败时契约码仍是 2（外层 trap 兜底），但诊断会把「Git Bash 起不来」误报成脚本自身失败，属**归因错误**；已改为 `Get-Variable` 守卫，未设时打 `agentq: Git Bash could not be executed: <path>` + `reason=protocol_error` + `agentq-exit:2` 后受控退 2。`install-agentq.ps1` 有 **18 处**裸读、三种形状（`if ($LASTEXITCODE -ne 0)` ×13、`return ($LASTEXITCODE -eq 0)` ×1、`$exitCode = $LASTEXITCODE` ×4）——**全部**改为经新助手 `Get-NativeExitCode`（`Get-Variable` 取值，未设返回 **1**，即 fail-closed：每个调用点都把非零当失败）。**为什么 installer 的未设值是 1 而不是 2**：它的调用点语义是「原生命令失败了没有」，不是退出码契约，1 是这些调用点的失败答案；而 launcher/start-daemon 的未设值是「受控拒绝」，走契约 2。
- **锁的形态**：`smoke/22` 把第七轮的两条 start-daemon 专用锁泛化为 `assert_last_exitcode_guard <file> <label> <token>`，对**五个**资产各跑一遍（start-daemon / launcher / installer / `agentq.ps1` / `sshp.ps1`），并新增 `AGENTQ_SMOKE_INSTALLER`、`AGENTQ_SMOKE_PS_CLIENT`、`AGENTQ_SMOKE_SSHP_PS_CLIENT` 覆盖钩子（与 `AGENTQ_SMOKE_START_DAEMON` 同理：锁在硬编码路径上无法被证明红）。**两个 Windows 客户端本来就有正确的 fail-closed 守卫、但同样没有锁**（`Get-LastExitCodeOrFailure` 助手 + wrapper 尾部各一处），横扫时一开始只数了服务端三个资产——这正是「数副本数」漏掉的那一半。客户端每个文件有**两个** `Get-Variable` 站点，而 awk 首版只跟踪**最后一个**赋值点：删掉**第一个**站点的 null 分支（保留第二个）时锁仍然全绿，与上一段 M2 同族的「至少一个 vs 每个」。现改为逐站点校验（新站点出现时若上一站未闭合即失败，END 再校验最后一站），token 支持 `|` 分隔的多值（客户端两站的 fail-closed 出口不同：助手 `return 1`、wrapper 尾部 `exit 1`）。红证：`client-m1`（删助手 null 分支）→ 1 failure、`client-m2`（删 wrapper null 分支）→ 1 failure、`sshp-client-m1` → 1 failure；`smoke/22` cases 70 → 74。另加一条**行为锁**：从 installer 资产里抽出真实的 `Get-NativeExitCode` 函数体，在子 pwsh 里用 `sh -c "exit 0"` / `"exit 7"` 的原生子进程驱动，断言 未设=1、零=0、七=7——**这是本轮唯一能抓住「助手函数本身写坏」的用例**：变异 installer-M2（助手恒取 `.Value`、不判 null）在静态锁下只报 1 个 failure，行为锁把它变成 2 个，且 stderr 里能看到真实的 `PropertyNotFoundException`。不用 `$env:COMSPEC`：任何原生子进程设 `$LASTEXITCODE` 的语义相同，而 `COMSPEC` 在 macOS 上不存在（首版就是这样写的，会在这个 POSIX CI job 上直接红）。**shell 路径由 bash 侧 `command -v sh` 解析后作为参数传入**，不在驱动里写字面 `/bin/sh`——这个检查也跑在 `windows-latest` job 的**真 PS 5.1** 上，字面 POSIX 路径在那里解析成 `\bin\sh`、抛 CommandNotFound 必红，与本文件第三轮踩过的坑同族（「加用例前先读这个文件的双形态机制」）。
- 教训：**数「同一机制的副本数」时，副本不只存在于资产之间，也存在于「修复」与「锁」之间**——第七轮把守卫加对了地方，但锁只断言了守卫的写法；第八轮才发现同一个机制的另外 19 个副本连守卫都没有。
- **第九轮自查：第八轮的锁又漏了一个维度——token 的「邻近」不是「包含」（同日，已修）。** 第八轮把规则改成「null 判定后 6 行内出现 fail-closed token」。构造 M4：null 分支只写一句无用赋值、**不退出**，随后一个 `exit 2` 落在 6 行窗口内（但在分支块外，且其后的 `.Value` 读取才是真正的逃逸路径）——**74 例全绿**。而 M4 的真实行为与 M2 完全一样：变量未设时 null 分支什么也不做、直接落到 `.Value` 抛 `PropertyNotFoundException`。**「离得近」与「在分支内」是两个性质**；这一轮已经是同一教训的第三次现形（第七轮：守卫存在 ≠ 守住了；第八轮：最后一个站点 ≠ 每个站点；本轮：token 邻近 ≠ token 在分支内）。修法：awk 改为**花括号深度追踪**——从 `$null -eq $var` 行起算 depth，token 只在 depth > 0 时计数；同时把两个方向的错误都钉死：null 分支**内**出现 `.Value` 读取是缺陷（那里变量必为 null），null 判定**之前**出现 `.Value` 读取也是缺陷。红证：M4 → 1 failure；第八轮的九个变异全部仍红（逐条重跑，见 CHANGELOG）。
- 教训升级：**静态锁每放宽一次形状（行窗口 → 深度追踪），都要问「这个规则能不能被一个仍然错误的程序满足」**——M4 就是能被满足的那一个。行为锁（`Get-NativeExitCode` 的 unset=1）在本轮是唯一不受形状影响的那一层。
- **本轮还抓到一次「红证本身是假的」**：编辑 awk 时注释里写了一个撇号（`assets'`），提前终止了 awk 的单引号字符串，`bash -n` 因为后面恰好还有配对引号而通过，脚本实际在解析 `scan()` 时崩溃。而我的变异循环先是用 `set -- $m` 分词（zsh 默认不按空白 split，`$2` 为空 → `env` 直接报错），后用 `printf | grep` 判别（管道与 `set -e` 交互导致分类失真）——两次都报「12 个变异全红」，**红的全是环境错误与脚本崩溃，不是断言**。是全量把 `22-launcher-contract` 判成 `FAIL syntax error` 才暴露。修好引号后，红证改为：显式两参数调用 `prove <mutant> <hook>`、输出落文件、**先排除 `syntax error`、再要求输出里出现 `failure(s)`**，并打印断言消息条数。最终 12/12 均为 assertion（1 条或 3 条消息），m1 类变异同时触发裸读与结构两条断言所以是 3 条。**教训：变异证明必须能区分「断言红」「脚本崩溃」「调用错误」三种退出，否则一次编辑失误就能让整组红证失去意义**——这与本仓「旧套件假绿」同族，只是方向相反（假红）。
- **「inside 不是 near」这条本仓 2026-10-05 就在 `smoke/10` 规则 J 里学到过**（该规则注释原文：「Inside is decided by brace depth, not by line order… Depth is the only thing that tells the two apart」）。第八轮写 LASTEXITCODE 锁时没有读仓里已有的同类锁，从「行窗口」重新发明了一遍并踩回同一个坑。**写静态结构锁前，先 grep 仓里已有的同类锁**——这与「加 `smoke/20` 用例前先读它的双形态桩」是同一条流程教训的第二个实例。
- **第十轮自查：守卫变量名与自动变量同名，脚本作用域下会把 `$LASTEXITCODE` 覆盖成 PSVariable（真 P0，已修）。** PowerShell 标识符**不区分大小写**，所以 `$lastExitCode` 与 `$LASTEXITCODE` 是**同一个变量**；`${LASTEXITCODE}` 也是同一变量（实测 pwsh 7.5）。于是「先 `Get-Variable -Name LASTEXITCODE` 再判 null」这个惯用法有一个作用域陷阱：**函数内**赋值只遮蔽全局（安全，`Get-NativeExitCode` 一类助手正是这样写的），**脚本作用域**下赋值会**穿透到自动变量本身**，把它从 `Int32` 换成 `PSVariable` 对象，下一行 `[int]$x.Value` 抛 `Cannot convert System.Management.Automation.PSVariable to System.Int32`。实测复现（pwsh 7.5，launcher 的 try/finally 形态原样）：`finally` 跑完、顶层 trap 接住、退 2——契约码碰巧对，**但真正的 Git Bash 退出码丢失了**，所有 Windows 任务都会被报成 2。两处真实站点：`agentq-launcher.ps1` 顶层 try 内、`sshp.ps1` 生成的远端安装脚本顶层（heredoc 里，跑起来就是脚本作用域）。**两处都是本轮自查系列自己引入的**（第八/九轮加守卫时把变量命名为 `$lastExitCode`）——「改名看着像纯风格改动，其实不是」。修法：五处守卫变量统一改名为不与自动变量同名的名字（`$spawnProbe` / `$installerProbe` / `$nativeProbe`），并新增**作用域无关**的静态规则 `assert_last_exitcode_alias`（`smoke/22`，5 个资产各一例，cases 74 → 79）：一个名字在两个作用域都正确，比「这个名字在这里行、那里不行」更容易维持正确。红证：M9（launcher 还原成 `$lastExitCode`）→ 1 failure 并点名行号、M10（sshp 同上）→ 1 failure。
- **顺带修掉的锁缺陷：大小写敏感扫描漏掉两个真实写法。** 第九轮之前的 `bare_last_exitcode_lines` 用字面 `$LASTEXITCODE` 匹配，而 `$LastExitCode` 与 `${LASTEXITCODE}` 是同一变量——实测 M7（`$LastExitCode` 裸读）与 M8（`${LASTEXITCODE}` 裸读）**74 例全绿**。现在扫描先 `tolower()` 再匹配，并单独识别 `${…}` 形式；结构化规则同样改为小写匹配（`get-variable`/`-name`/`.value`/`exit`/`return` 都大小写不敏感）。红证：M7 → 1 failure、M8 → 1 failure。**教训：「按名字找代码」的锁必须先问「这个名字有几种写法」**——大小写与 `${}` 是 PowerShell 的两种等价拼写，SQL 式的大小写敏感假设在这里是错的。
- **第十一轮自查：引入一个独立的静态分析器，它报出两条我自己的规则看不见的东西。** 用本机已有的 **PSScriptAnalyzer 1.25.0**（此前从未在本仓用过）跑全部 7 个 `.ps1`，`PSAvoidAssignmentToAutomaticVariable` 与 `PSUseBOMForUnicodeEncodedFile` 各命中：
  - **`sshp.ps1` 含一个 UTF-8 em dash 且无 BOM（真缺陷，已修）。** 本仓自己在 `smoke/22` 的驱动注释里就记着这条实测：**PS 5.1 把无 BOM 的 `.ps1` 按 ANSI 代码页解析**（windows CI job 的 `run 37810470283`：字面量 `任务` 变成 `ä»»åŠ¡`）。本次那个字节落在**注释**里，实测不破坏解析（`pwsh -File` 退 0）——但「注释 vs 字符串字面量」正是后续编辑能改变的东西，而 Windows job 与真实 Windows 客户端都用 5.1。修法：改成 ASCII `--`。**锁是字节级的、在 `smoke/01`**（与 pwsh 是否可用无关）：任何无 BOM 的 `.ps1` 只要含非 ASCII 字节就红，带 BOM 的豁免（launcher 本就带 BOM，已验注入非 ASCII 后仍绿）。红证：给 `sshp.ps1` 追加一行 em dash 注释 → 1 failure 并点名文件；还原后 `cmp` 0、复绿。摘要行新增 `ps1_encoding=checked`，CI 既有的 `ps1=7 .*tool_full=6/6` grep 仍匹配。
  - **六处 `$profile` 赋值（判定为可接受，不改）。** `$profile` 是 PowerShell 自动变量（当前用户配置脚本路径）。六处**全部在函数内**（`Get-CurrentWindowsUserEnvironment` / `Resolve-CurrentWindowsUserProfile` / `Resolve-RemoteUserEnvironment`），赋值只遮蔽全局；仓库内**没有任何地方读 `$PROFILE`**（grep 确认），所以没有可观察的行为差异。**这与第十轮的 `$LASTEXITCODE` 不是同一类**：那里赋值发生在**脚本作用域**且紧接着读 `.Value`，是真的会炸；这里只是名字撞了自动变量、作用域安全、无读者。记录判定理由而不是默默忽略——分析器的输出需要人判，不能全盘照改。**（2026-10-24 第十五类推翻这一条并修掉：见下。当时只按 `.ps1` 扩展名枚举、且只信「函数作用域安全」这个推断，没有量过脚本作用域行为，也没有发现同样六处之外、3 个 shell 资产内嵌载荷里的另外 43 处。）**
- 方法教训：**自查写出的锁只覆盖「我已经想到的形态」；引入一个从不同假设出发的检测器能补上这一类盲区。** PSScriptAnalyzer 的两条命中，一条是我漏掉的真实规则（编码），一条是需要人判的良性告警（`$profile`）——**独立检测器的价值在于提出候选，不在于给出裁决**。
- **同一个独立分析器的 shell 侧输出又抓到一条真缺陷：`$?` 指的是 `[` 测试的状态（SC2319）。** `client/unix/agentq` 的 wait 路径在清理 stderr 捕获失败时写 `if [ "$wait_ssh_status" -eq 0 ]; then wait_ssh_status=$?; fi`——**`$?` 此时是 `[` 的退出码（恒 0）**，不是删除命令的。后果：ssh 成功、清理失败时状态被改回 0，**失败被静默吞掉**。修法：该分支里写契约的通用失败码 1（清理失败在契约里没有专属码）。红证：还原成 `$?` 后 `shellcheck -s sh -i SC2319` 报出、`smoke/05` 报 1 failure。同一趟还清掉一个死变量 `agentq_operation_validated`（只赋值、从不读，而注释仍把它描述成活机制——**注释描述一个不存在的变量，是死机制看起来还活着的方式**）。保留 `ulimit -c 0` 的 SC3045：那是刻意的凭据安全措施（禁 core dump），且 `|| :` 已是最佳努力语义。
- **锁的形态**：本仓此前**没有任何检查跑 shellcheck**（此前只有行为锁：smoke/05 在 dash 下执行客户端）。`smoke/05` 新增一条**限定规则的** shellcheck 锁（`-i SC2319,SC2034`，缺工具则跳过并在摘要行标 `shellcheck=absent`）：限定规则 ID 是为了让新版 shellcheck 的新规则不能自己把 CI 弄红，而这两个 ID 是稳定的。cases 39 → 40。
- 方法教训（与上一段同一句话的两面）：**独立检测器提出的候选必须由人裁决**——`$profile` 六处判定为安全、`ulimit -c` 判定为刻意、SC2319 与 SC2034 判定为真缺陷。全盘照改和全盘忽略一样错。
- **第十二轮（0.1.16，2026-10-18）：把第十一轮的 shellcheck 锁从「一个客户端文件」扩到全部 9 个 shell 资产，锁一扩就抓到服务端一条真缺陷。** 第十一轮的两条 SC 命中（SC2319、SC2034）分别在 **POSIX 客户端**与**服务端**里，而锁当时只跑客户端——**同一机制抄多处只锁一处**，本仓第 N 次以这个形态出现。扩锁（按 shebang 分 `bash` / `sh` 两套方言，资产数入摘要行）后立刻报出 `skill/assets/unix/agentq-server` `remove_task` 里的 `removal_status=$?`：**赋值后从不读**（函数走的是紧邻其下、注释完整的 `return 1`——「pueue 的退出码不是 AgentQ 契约码」）。它不是无害死代码：一个紧跟 `run_pueue remove` 的 `$?` 捕获读起来像「状态即将被使用」，而旁边的注释正好在解释那个退出码为何不外传——**死机制与其注释互相掩护，是这个仓库里死代码能长期存活的方式**。修法：删掉赋值与 `local` 声明，`else` 分支一并去掉（`if ... then ... return 0; fi` 即可）；服务端与 `windows-git-bash/agentq` 字节孪生同步改，`cmp` = 0。
- **本轮另外三条独立扫描的结论都判为「非缺陷」，记录以免日后重扫重复判断**：① 客户端 6 处 SC2086 是 `$ssh_credential_option_lines` 的**刻意无引号展开**——`-o BatchMode=yes` 必须拆成两个 argv，值来自 `ssh_credential_options` 的常量 printf，无 glob 面；② 服务端 5 处 SC2016 是 jq 过滤器字符串里的 `$id`，shellcheck 对单引号内 jq 变量的误报；③ 全部扫过的资产里 SC2155 = 0，`dash -n` 对四个 POSIX 资产通过（服务端是 bash，`dash -n` 不适用），无重复函数定义，jq 调用中出现的路径变量全是重定向输入（`< "$path"`）而非位置参数——符合 `smoke/08` 的契约。红证：把 `removal_status` 变异回去后 `smoke/05` 报 **2 failures**（服务端 + 其字节孪生各一处），还原后 `cases=40 ... shellcheck=checked(9)`。
- **第十三轮（0.1.16，2026-10-18）：把第十一轮的 PSScriptAnalyzer 扫出的「真命中」的同类形状写成结构性规则，落进 `smoke/01` 已有的 AST 遍历里。** 本轮先复核第十一轮 PSScriptAnalyzer 的产出：`Invoke-ScriptAnalyzer -IncludeRule PSUseDeclaredVarsMoreThanAssignments` 在全部 7 个 `.ps1` 上**只命中一处**——`install-agentq.ps1` 的 `$health = Get-PueueHealthFromTemporaryFile ...`（赋了值从不读）。它不是死代码：那个调用是**校验**（payload 缺失/畸形即 throw），`$health` 本身确实多余，但**不能简单删掉赋值**——安装器的成功流就是它的 JSON 响应（顶层 try 末尾的 `ConvertTo-Json`），裸调用返回值会排在响应前面。修法用 `[void](...)` 并注明；实测 `[void](函数调用)` 在 `Set-StrictMode -Latest` 下正常求值、异常照常传播。
- **同一轮里另找到一条 PSScriptAnalyzer 结构上看不见的真缺陷：`2> $smokeLogErrorPath`。** 该名字在 `Assert-PueueSmokeLogContainsToken` 里作重定向目标读，但**只**在**调用方** `Invoke-PueueShellCommandSmoke` 里赋过 `$null`——PowerShell 的动态作用域让这次读解析到调用方的 `$null`，于是实际重定向一直是 `2> $null`，而紧随其后的清理分支 `if ($null -ne $smokeLogErrorPath)` 永不执行。三条实测（本机 pwsh 7.5）：`2> $null` 丢弃子进程 stderr 且不建文件；`2> <值为 $null 的变量>` 与前者行为完全一致（不建文件、不抛、变量保持 `$null`）；`[ref]$x` 才会让被调方写回调用方的变量，普通形参不会。**所以这不是「行为被改变」的缺陷，而是「代码声称在捕获 stderr 到文件并会清理它，两件事都没发生」**——与第十二轮 `removal_status` 同形：死机制与其旁边的注释互相掩护（原注释写着「stderr is routed to its own file where the redirect still captures the bytes」，那句话是假的）。修法：写成它一直是的东西 `2> $null`，删掉死变量与死清理分支。
- **锁：把这两条形状写成 `smoke/01` 的 `ps1_vars` 规则，跑在它已有的 pwsh AST 遍历里**（不引入新工具，`pwsh_state=usable` 的三态门原样复用）。规则一：**只被赋成 `$null` 的变量不得被读**（`[ref]` 实参豁免——被调方写入正是它初值为 `$null` 的原因）；规则二：**在某处被赋值的变量必须在文件里某处被读**。规则二刻意做成**文件级**而非函数级：动态作用域允许被调方读调用方的变量，函数级读集会产生假阳性；代价是对「一个函数写、另一个函数读」的形态失明——方向是安全的，漏读只意味着漏一次警告，不会误报。**两条都不是 `PSUseDeclaredVarsMoreThanAssignments`**：它完全看不见规则一（名字确实被读了），且会把 `[ref]` 出参报成未用。豁免清单写死在脚本里：运行时读的偏好变量（`$ErrorActionPreference` 等 10 个）、`env:` 写入（写环境本身就是副作用）、`_` 前缀。**红/绿实测**：把 `install-agentq.ps1` 换回 HEAD 版本 → 规则报 4 条（`$smokeLogErrorPath` 三处读 + `$health` 一条）且 `syntax-and-parity: 1 failure(s)`、rc=1；还原修好版 → `ps1_vars=ok files=7`、rc=0，摘要行新增 `ps1_vars=ok`（CI 既有的 `ps1=7 .*tool_full=6/6` 正则仍匹配）。
- **判为「非缺陷」并记录**：① 全部 7 个 `.ps1` 里**没有任何一条跨作用域读**（除已修的 `$smokeLogErrorPath` 外）——我用 AST 收集「脚本级 + 各函数声明集」，再报未命中的读，全树 0 命中；唯一一条是指向 `install-client.ps1:277` 的 `$SourcePath`，而 PowerShell 变量名**大小写不敏感**（实测 `$sourcePath="aaa"; $SourcePath="bbb"` 后两者都是 `bbb`、`-ceq` 为真），是我的检测器按大小写敏感比较造成的假阳性——**顺手把它统一成 `$sourcePath`**，因为一个函数里同一个变量两种拼写正是第十轮 `$lastExitCode`/`$LASTEXITCODE` 那类陷阱的温床（那次的教训是大小写不敏感标识符会真的撞车）。② 我另写了一个「被调函数会往成功流写东西、而调用处丢弃了它的输出」的检测器，想抓「裸调用返回值泄漏进响应」这一类；**它不可用，如实记录**：判定「函数是否向成功流输出」需要类型信息（`Copy-Item`/`Set-Acl` 返回 void、`Get-X` 返回对象，纯语法看不出来），第一版对所有语句级命令一律判为「会输出」，在 7 个文件上报出 200+ 处，读了几处全是假阳性；改为「仅递归判定本地函数、且只认 `return <表达式>`/裸变量/裸字面量/`Write-Output`」后仍因互相递归（memo 在递归返回后才填）栈溢出崩溃（exit 134）。**结论：这类检测在本仓靠语法做不干净，不做锁；已修的两条形状由上面的规则一/二覆盖。**

- **第十四轮（0.1.16，2026-10-19）：用户把支持面说成「不仅 ps5.1，还要 7.x 以上」，据此做了一次双引擎专项清查，并修掉一条只在 5.1 上炸的 .NET API。** 清查覆盖两个方向：
  - **方向一：7.x 独有语法（5.1 解析器直接拒绝）。** 用 AST 规则扫描了三元 `? :`（TernaryExpressionAst）、空合并 `??`、管道链 `&&`/`||`（PipelineChainAst）等形状——**7 个资产 0 处**，即 5.1 的解析器对现有代码是安全的。（对使用者：这一方向此前一直靠「没坏」而不是靠锁。）
  - **方向二：.NET Core 独有 API（5.1 上解析通过、运行时绑定失败）。** 这是真命中：`Write-PlatformProbeCache`（`client/windows/agentq.ps1`）用 `[System.IO.File]::Move($temporary, $path, $true)` 覆盖写探针缓存，三参重载**只有 .NET Core 3.0+ 有**（pwsh 7.5.4 实测 `GetMethods()` 里列出 `Move(String, String, Boolean)`），而 .cmd/.bash 启动器用的是 **Windows PowerShell 5.1（.NET Framework）**——那里抛「cannot find an overload」，被函数自身的 catch 吞掉，**探针缓存自首次写入起就是静默的永久 no-op**：每次调用重新探针、30s 开销照付、零报错。修法：目标存在走四参 `[System.IO.File]::Replace($temporary, $path, $backupPath, $true)`（.NET 2.0+，随建随删备份），不存在走两参 `File.Move`；两条分支保持与 POSIX 孪生 `mv -f` 同量级的小读写窗口。
- **为什么本地套件此前看不见它：pwsh 7 上这个调用本来就能跑。** smoke/12 的行为锁在 pwsh 7 上对三参变异**全绿**——一个行为锁无法看见「只在一个未安装的引擎上失败」的东西，这是本仓「沙箱绿 ≠ 真机对」的又一次具体化（与 smoke/13/22/23 的 NOT-covered 声明同族）。**所以这次是两条锁一起上**：
  - **行为锁（smoke/12 新用例，cases 52→53）**：dot-source 客户端、`AGENTQ_PLATFORM_CACHE_DIR` 指到临时目录、`$env:AGENTQ_PLATFORM_PROBE_CACHE='on'`，真调 `Write-PlatformProbeCache` 断言首次写成功、覆盖写生效（platform unix→windows）、且目录里除缓存文件外无任何残留（临时 `.tmp`/备份 `.bak` 都算残留）。
  - **静态锁（smoke/01 新增规则三）**：遍历 `InvokeMemberExpressionAst` 中 `Static=true` 且 receiver 是类型的调用，按「类型+成员+参数个数」对照 Core-only 清单：`File.Move` 三参、`String.Contains(String,StringComparison)`、`Path.Join`、`Directory.Move`、异步文件 API——每条 Why 写明可移植替代（修法是机械的）。**（后经同日复核：`Directory.Move` 与两参 `File.Move` 两条是反的、已删；类型名改为先解析；实例形态改按第二个参数判定——见下方「第十四轮的独立复核」。）****规则三自带校准**：合法夹具（含两参 Move、四参 Replace、`[string]::Join`、`IndexOf(StringComparison)`、splatting、env 写、`[ref]` TryParse、foreach 变量）必须 0 条、缺陷夹具必须恰 3 条，不达标即退 2——否则一条悄悄停止匹配的规则读起来就是一棵干净的树（本仓已为这个形态付过两次学费：smoke/01 的 config-patterns、smoke/10 的规则 A）。
- **规则一/二的自校准也补上了（本轮顺手）**：给 smoke/01 的 `-Calibrate` 模式补了合法/缺陷夹具与同样的大门（legal=0/defects=3），并且校准夹具当场抓到过我自己规则一的一个假阳性——`$e = $null; foreach ($e in ...) ` 是**合法**代码（每次迭代赋真值），而 `ForEachStatementAst` 不是 `AssignmentStatementAst`，null-only 图把 `$e` 看成了「永远是 null」；修法是把 foreach 变量记为真声明并豁免其作为读父节点。**这条假阳性没有落在任何真实资产上（全树 0 潜伏实例），但它是夹具本可以钉住的形状**——校准的真正价值在规则上线前暴露它，而不是上线后由用户报错。
- **红证（全部走已发布的检查本身，不是临时脚本）**：换回 HEAD 版 `install-agentq.ps1` → `smoke/01` 报 4 条（规则一/二）+ rc=1；换回三参 `File.Move` 的客户端（`/tmp/aqmut/r13/corepre/agentq.ps1`）→ 报 `agentq.ps1:1655` 1 条（规则三）+ rc=1；还原后 `ps1_static=ok`、rc=0。三个校准变异（删 foreach 记录 → 合法夹具红；删规则一 → 缺陷夹具红；删偏好变量豁免 → 真实树假阳性）也各自红过。
- **shellcheck 全量重测（0.11.0）与空 catch 审计**：9 个 shell 资产全量跑（不限定规则），命中与既有裁决一致：客户端 SC2016=1（行 2823，单引号 PS 探针串）、SC2086=6（刻意无引号）、SC3045=1（刻意 `ulimit -c 0`）；服务端 SC2016=4（jq 过滤器内 `$id`）。**注意到一处与本文件第十二轮记录的出入：那里写的是「服务端 5 处 SC2016」，0.11.0 全量实测 4 处**——两个版本对同一过滤器的计数口径不同，按实测口径更正为 4，全部仍是 jq 误报类。7 个空 catch（PSAvoidUsingEmptyCatchBlock）逐个人工审过，全为合法（缓存尽力写、注册表探测、进程路径探测、staged 二进制回退、陈旧锁清除 ×2 模式）——catch 的空是刻意的 best-effort，不是吞错。
- **摘要行改名 `ps1_vars` → `ps1_static`，CI 断言正则同步收紧**：`grep -qE 'ps1=7 ps1_static=ok .*tool_full=6/6'`——规则集现在有三条而不是两条，名字不再只属于变量规则；正则要求 `ps1_static=ok` 字面出现，一条改成 skipped 的规则会让 macos job 红，而不是读成绿。
- **对使用者的行为影响**：Windows 客户端在 PS 5.1 下探针缓存从「静默从不生效」变为生效（缓存 TTL 24h 内重复调用不再付 30s 探针开销）；其余资产无行为变化。**未验证边界**：5.1 行为锁仍未在真 5.1 引擎上跑过（本机只有 pwsh 7.5.4；CI 的 windows job 用 5.1 跑 12/20/22/23，smoke/01 不在其中——macOS/Ubuntu job 的 ps1_static 用 pwsh 7 跑静态规则，这正是设计使然：静态规则只需要解析器，不需要 5.1 运行时）。

- **第十四轮的独立复核（同日，用户问「还有其他问题吗」后）：用 PSScriptAnalyzer 的 5.1 兼容 profile 当第二意见，结果推翻了我自己规则三的四处判断。** 该 profile（`win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework`，随 PSScriptAnalyzer 1.25.0 发布）用微软自己采集的 5.1 命令/类型清单做比对，与我手写的 deny-list 假设不同——正是本仓反复强调的「独立检测器提出候选、人裁决」。四条结论：
  - **① 规则三有逃逸形态（已修）。** 它用 `-ieq` 比对**书写形式**的类型名，于是 `[IO.File]::Move($a,$b,$true)`——合法的短命名空间写法、同一个 .NET 类型——匹配不到任何条目。实测：规则报 0 条，而我用同样的三参调用改写成 `[IO.File]` 后它一声不吭。修法是先**解析**再比较：`$n.Expression.TypeName.GetReflectionType().FullName`（PowerShell 自己解析 `[IO.File]` 用的就是它），解析失败再退回书写名。实测 `[IO.File]`/`[System.IO.File]`/`[string]`/`[String]`/`[System.String]` 全部解析到同一类型；`[File]`（只有 `using namespace` 才合法）解析为空、退回书写名。**一个只看书写形式的规则，恰好在「换个写法就逃逸」上最脆弱**——而规则的全部价值就是覆盖开发机上没有的那个引擎。
  - **② 规则三里有两条是反的（已删）。** `Directory.Move` 与 `File.Move` 两参被列成 Core-only，实际两者都是 BCL 从 2.0 就有——**这是把可移植代码报成违规**，与漏报同一个病：读者会因此学会忽略规则。删掉两条，并把「两参 File.Move」写进合法夹具，这样它们回来时校准会红。
  - **③ `String.Contains(String, StringComparison)` 的实例形态此前完全没覆盖（已补）。** 原表只在静态分支里比，而它是实例方法；`[string]::Contains(...)` 则是任何运行时都不存在的成员（实测 `Method invocation failed because [System.String] does not contain a method named 'Contains'`）。现在两张表：静态表比「解析后的类型+成员+参数个数」，实例表比「成员+参数个数 **+ 第二个参数是 `[System.StringComparison]` 成员访问**」，且静态分支同时查两张表——因为 `[string]::Contains` 就是同一个不存在成员的静态写法。**实例表的判据换过一次，这一处值得记下来**：第一版按「成员+参数个数」匹配，随即被合法夹具抓出假阳性——`HashSet<T>.Contains(item, comparer)` 是**两参**、**可移植**、而这仓已构造八处 `Generic.List[string]` 集合，所以「两参 .Contains」既可能是缺陷也可能是正确代码。先试过「解析接收者类型」，但那条路依赖接收者写成 `[T]::new()`，而资产里全是 `$变量.Contains(...)`，接收者类型在静态分析里不可知——只能做到「不知道就跳过」，覆盖率为零。**最终判据是第二个参数**：只有 `String` 的 Core-only 重载收 `StringComparison`，集合的 `Contains` 收 comparer 或元素本身，内联 `[System.StringComparer]::OrdinalIgnoreCase` 时类型不同、可区分。**已知盲区（如实记录）**：把 `StringComparison` 存进变量再传不会被识别（静态不可解析）；内联 `[StringComparison]::Ordinal` 的写法仍然抓到。合法对照：`$list.Contains(x)`（一参）、`$s.Contains("x")`（一参）、`HashSet.Contains(x, comparer)`（两参但非 StringComparison）、`StartsWith/EndsWith(StringComparison)` 全部不报——集合那条已写进校准夹具，删掉第二个参数的判据会立刻让校准红。
  - **④ PSScriptAnalyzer 对 `File.Move` 三参是盲的（如实记录）。** 负控实测：只有三参 `File.Move` 的夹具，5.1 profile 报 **0 条**；`Path.Join` 却能报出。也就是说第十四轮修掉的那个真缺陷，**PSScriptAnalyzer 抓不到**——两条独立检测器各有盲区，互为补充而不是互相替代。同理 `DateTimeOffset.ToUnixTimeSeconds` 实测 0 条（文档 moniker 明确 `netframework-4.6+` 有它，即 4.6 以下没有；5.1 自带 4.6+，故可用，但这是文档证据不是本机实测）。
- **同一趟把「5.1 上没有的 PowerShell 参数」也查了：`ConvertFrom-Json -Depth` 是 PS 6+ 参数，两处调用靠运行时守卫才安全。** 5.1 profile 报出 `agentq.ps1:1948` 与 `2154`（`The parameter 'Depth' is not available for command 'ConvertFrom-Json' by default in PowerShell version '5.1...'`）。资产里两处都写成 `if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey("Depth")) { ... -Depth 100 ... } else { ... }`——**守卫是对的，但此前没有任何锁**。`smoke/12` 新增第 54 例：AST 结构锁，要求每个带 `-Depth` 的 `ConvertFrom-Json` 命令都落在条件里测过该参数的 `if` 之内（按**祖先**判定，不是行窗口或 grep 计数），并自带校准夹具（一个受保护、一个裸调用 → 期望恰 1 条）。红证：删第一处守卫 → 报 `line(s): 1946`、rc=1；删第二处 → 报 `2153`、rc=1；**A/B 证明锁是承重的**：HEAD 版 `smoke/12`（无此锁）对同一个 M1 变异**全绿 rc=0**，新版报红。 **该锁的第一版把参数用 `$args` 传**——`-Command "$probe"` 与 `-File` 的 `$args` 语义不同，而 `-Command` 里两个 POSIX `/tmp` 路径在 5.1 下也不解析（`-File` 参数只给客户端路径做了 `cygpath` 转换）；改为 `-File` + 命名参数（`param([string]$FixturePath, [string]$ClientPath)`）后两个引擎语义一致。
- **另外把服务器端与 POSIX 客户端里「藏在 shell 字符串里的 PowerShell」也扫了**：服务端 3 段 `-Command '...'` 字面量（6,609 / 719 / 425 字符）、1 段双引号单行、POSIX 客户端 2 段探针脚本（80 / 3,216 字符）——用 5.1 与 7.0 两个 profile 各跑一遍，**全部 0 条**。这一步值得单列的理由：`smoke/01` 的规则只解析 7 个 `.ps1` 资产，这些内嵌脚本**不在其中**，而它们同样在 5.1 上执行。当前结论是「没发现」，不是「锁住了」——没有为内嵌脚本建锁，如实记录。

- **同一趟复核还修了 `smoke/29` 的捕获格式：它的两个计数器会给出不同的数。** 全量套件里有且仅有一次报出 `jq_invocations=133 programs=135`，其余 3 次全量与 30+ 次单跑都是 134/134。差值方向（记录 −1、程序 +1）只有一种形状能产生：**两条调用被合并成一条记录**。合成流实测证实：把两条单程序调用的分隔符抹掉，解析结果正是 1 条记录、2 个程序。成因是 shim 的编码——argv 以 NUL 分隔、调用间以双 NUL 分隔——**空参数自己就会产生一个双 NUL**（空值的终止符紧跟下一个值的），两个写入者的追加交错时也会丢掉分隔符。第一个形态在本地可构造（把一份真实捕获喂给旧解析器：1 条调用于是变成 2 条记录），第二个无法在本机稳定复现。**修法只加了两样东西**：shim 多写一条「每次调用一个字节」的独立计数（单次 write），脚本要求两者相等，不等就拒绝报告（与分类器自检同一立场：一个说不清自己输入从哪来的检查没有资格下判断）。**删掉了我中途写的一个「重新拼接」启发式**——实测它对熔断流无效（熔断记录的后半段同样以 flag 开头），留着只会是一段自认为在修问题的死逻辑。**教训与第十二/十三轮同族但方向相反：那两轮是「删掉一行让锁失效」，这一轮是「计数本身的来源不可靠」——凡是把「看到了多少次」写进摘要的检查，都必须能独立数清。** **补一条更强的判据（同日）：逐记录断言「恰好一个 jq 程序」。** 实测 134 条真实记录每条恰好 1 个程序，而熔断形态（两条调用被并成一条）会让某条记录出现 2 个——这正是 133/135 的算术来源。这个不变量比「两个记录器数量相等」更强：即使两个记录器同时少一条（无法区分「少了一条」与「多了一条」），逐记录判据仍会点名那条记录。红证：合成流 8 条调用丢一个分隔符 → 计数文件同步改成 7（两个记录器一致）→ 逐记录判据仍报 `index:count 0:2` 并退 1；只把计数文件保持 8 时由前一道闸门先报 `recorders disagree`。 **同一节还纠正了一句我自己刚写错的诊断文案**：第一版说「或 jq 现在拿到 FILE 参数」——实测 `jq -f prog.jq input.json` 仍然只解析出 1 个程序（`-f` 的文件不吃程序位），真正会触发「>1」的是**位置参数形式的输入文件**（`jq -r .a input.json` → 2 个）；而「0 个」是另一种形态（`jq -n -e` 这类纯 flag 调用）。文案改为按实测分别说明。

- **同一轮还修了一处「环境故障被报成资产故障」的复发：六个 PowerShell 检查只判断 pwsh 存在、不判断能用。** 2026-10-20 本机 pwsh 启动缓存第五次损坏（本次消息是 `Stack overflow`，此前四次分别是 `String cannot have zero length` ×2、`Stack overflow`、`FileLoadException`），全量套件跑到 `smoke/12` 时它开始每次启动都 `Abort trap: 6`：**`smoke/12` 报 exit=134、`smoke/13` 报 exit=1，两条都像是资产缺陷**——而 `smoke/01` 在同一趟里已经把自己的 pwsh 判成 `unusable` 并正确退出。`smoke/01` 的三态探针是 2026-09-28 为同一形态加的，但**当时只加在 01 一处**：`12/13/20/22/23/25` 六个检查都只有 `command -v` 的存在性判断。这正是本仓的老形态——同一机制抄多处只修一处——这次方向是「修了检测器，没修被它保护的其余六处」。修法统一：六个检查在存在性守卫之后各加一次 `pwsh -NoProfile -NonInteractive -Command 'exit 0'` 探针，失败即打出**契约未执行的说明 + 缓存修复命令**并退 1（不是 skip：解释器在 PATH 上却跑不起来是环境故障，绝不能读成「这个平台没有 pwsh」）。红证：`AGENTQ_SMOKE_PWSH=/tmp/.../fakepwsh.sh`（`exit 134`）驱动六个检查，**六个都退 1 并各自点名自己的契约未运行**；恢复真 pwsh 后六个全绿。A/B：改前的 `smoke/12` 用同一个假解释器只会打出 `POSIX probe … exited 134` 之类的失败，把环境故障说成探针行为不对。

- **第十五轮（0.1.16，2026-10-20，用户「全部优化好」）：把第十二轮扩过的那把 shellcheck 锁再扩一层——从「9 个资产」扩到「仓库自己的脚本」。** 扩完立刻报出 **12 处 SC2034**，全部在 `smoke/` 里，没有一处是资产缺陷。
  - **为什么第十二轮没看见它们**：那把锁的枚举是 `find "$root/skill/assets"`。第十二轮扩的是**方言覆盖**（一个文件 → 九个资产），枚举根没动。于是「锁看见了资产的每一处、看不见检查的每一处」——而**悄悄停止断言的检查比资产缺陷更难发现**：一个 `probe_status=$?` 被赋了值却从不读，读起来正像「状态即将被判定」，下一个人（包括我）会以为这条检查验过退出码。
  - **12 处的形态**（全部实测，无一处是误报）：`smoke/05` 三处死状态捕获（探针伪造、认证分类、凭据提示，断言全在 stderr 上）+ 一处 `launcher_op` 循环变量；`smoke/06` 的 `read_doctor_output`（断言是「读命令不争锁」，退出码就够）；`smoke/07` 的 `notstarted_again`（第二次 lookup 只验退出码 3）与 `cancel_target="$workdir"`（**名字说的是取消目标，值是工作目录，且从未被读**——真正的目标是下一行的 `cancel_target_id`）；`smoke/10` 的 `read -r lineno text`（规则只报行号，文本从未用）；`smoke/15` 的 `probe_output` 与 `probe_logs`（断言在 stderr / 退出码）；`smoke/18` 的 `base=`（路径由构造决定，只 `variant` 可覆盖）；`smoke/20` 的 `check_roundtrip` 第二参数 `client`（**文档注释里写着它，函数体里从不读**）。
  - **修法分两类，不是一律删**：能表达成「明确丢弃」的用 `|| true` / `>/dev/null`（05/06/07/15），并在旁边写清**为什么不需要这个值**；纯粹没用的名字直接删或改 `_` 前缀（10/18/20；`_` 前缀是 shellcheck 认可的「有意不用」）。两类都**不改变任何断言**——退出码与 stderr 的判定原封不动。
  - **锁的形态**：`smoke/05` 的 lint 主体抽成 `lint_shell_file <path> <label>`（在本 shell 里跑，不是子 shell——`shellcheck_bad` 必须累加），然后两个枚举共用它：`skill/assets`（原样）与 `{ smoke/*.sh; run-tests.sh; sandbox.sh; }`。**两个集合各自 0 枚举即判失败**（沿用第十二轮「0 个资产意味着枚举失败，不是没有东西可查」的理由），摘要行追加 `scriptcheck=checked(31)`。代价实测：整趟多约 **40s**（`smoke/05` 从 ~6:10 到 6:52）。
  - **红证（走已发布的检查本身）**：往 `smoke/04-degraded-contracts.sh` 末尾植入 `mutation_dead_variable=1` → `smoke/05` **rc=1**，报 `shellcheck found SC2319/SC2034 in smoke/04-degraded-contracts.sh … mutation_dead_variable appears unused`、`1 failure(s)`；还原后 `git status` 干净、全绿。
  - **本轮判为「非缺陷」、记录以免重扫**（`shellcheck` 全量跑 repo 脚本时的其余命中）：SC1087（`$out[^/]*` 一类，bash 对「变量名后紧跟 `[`」的歧义，不是数组）、SC1007（`local glob=$1 out= i=0` 的多变量声明形态）、SC1078（`'"…"'` 的混用引号，`smoke/12` 有意为之）、SC2209（`*)` case 模式被读成「赋值」）、SC2016（单引号里的 jq/PS 变量，与资产侧的同类命中同一裁决）。
  - **顺带更正一处失真**：`docs/PLAN.md` 的「如实记录，未修」里仍挂着 `agentq-start-daemon.ps1` 的 StrictMode `$LASTEXITCODE` 边界，而它**在同一版的第七轮就已修复并加锁**（资产第 253 行的 `Get-Variable` 守卫、`smoke/22` 静态+行为锁）。唯一权威的待办清单里挂着一条已经做完的事，本身就是误导——已划掉并注明更正日期。

- **同一轮的 CI 缺口：工具门控的锁在 runner 上降级成 `absent` 时，没有任何闸门读那个 token。** `smoke/05` 的 shellcheck 锁从第十二轮起就是工具门控的（`command -v shellcheck` 不成立就跳过），降级时打印 `shellcheck=absent` 并 **exit 0**——退出码与 `PASS checks:` 行**都区分不出「lint 过」与「没 lint」**，而 linux job 的断言当时只读 PASS 行的形状与 NCOV 名单。这与第十四轮为 `ps1_static` 定下的规则（「一条悄悄降级的规则必须让 job 变红，不能读成绿」）是同一句话，只是当时只应用在了 macos job 对 01 的断言上。修法：linux job 的 apt 列表加 `shellcheck`，并断言 `shellcheck=checked\([1-9][0-9]*\) scriptcheck=checked\([1-9][0-9]*\)`——两个枚举都要**非零且真的跑过**；`[1-9]` 而不是 `[0-9]` 是刻意的：`checked(0)` 意味着枚举坏了（检查自己也会报 failure），那不该被这道正则当成绿。四种日志形态实测：正常绿跑 MATCH，`absent` / `checked(0)` / `scriptcheck=checked(0)` 三种降级全部 NO-MATCH。macos job **不**断言：它跑 `--quick`，只执行 01，05 根本不在其中。

- **真机验证（2026-10-20，用户点名 ESXi 上的 `aq-win10-test`）：在真实 Windows PowerShell 5.1 上跑 `smoke/13/23/25`，抓到一个「检查依赖英文 UI 语言」的缺口，并修掉。** 这台机是 **zh-CN** 的 Windows 10（`qdm-20240612wef\qdm`，PS 5.1.19041.3996），`smoke/23` 第一次跑就报 4 failures；逐条实测后确认**资产与检查的实质都正确**，错的是断言语言：
  - PowerShell 的参数绑定器把消息**本地化**：同一句在中文机上是 `找不到与参数名称"Bogus"匹配的参数`、`无法对参数"SourcePath"执行参数验证`。检查断言的是英文原文，于是四条全部不匹配——**一台正确的资产在非英文 Windows 上会被报成坏了**。CI 的 `windows-latest` 是英文镜像，所以这个缺口从 2026-10-13 加锁起一直隐形。
  - **实测证明是环境差异而非资产缺陷**：在真机上于同一进程内把 `[Threading.Thread]::CurrentThread.CurrentUICulture` 设为 `en-US` 后，四条消息与检查期望的英文**逐字一致**（`Cannot process command …`、`Missing an argument for parameter 'SourcePath'.`、`Cannot validate argument on parameter 'SourcePath'.`、`A parameter cannot be found that matches parameter name 'Bogus'.`）。
  - **修法（`smoke/13` `23` `25` 各一份，按本仓「一文件一份定义」的惯例）**：启动时探一次 UI 语言；英文 → 原样直接调用资产（**CI 路径零变化**）；非英文 → 经一个临时 wrapper 先设 `en-US` 再调用，并在摘要行报 `binder=en-US-via-wrapper(host=zh-CN)`。wrapper 收**参数数组**而不是拼接的字符串——实测：把每个参数加引号拼进 `-Command` 会把 `-SourcePath` 变成字符串值而不是参数名，绑定错误会**挪到另一个参数**，看起来正像资产缺陷（这正是我这轮驱动脚本踩的坑）。
  - **边界如实记录（2026-10-20 当时）**：`smoke/13`/`25` 的「平台门禁」用例只在非 Windows 上有意义，因此**不能**在 Windows 真机上跑；真机能补的是 `smoke/23` 的绑定器契约与 `12`/`20`/`22` 的客户端契约。**（2026-10-21 更新）**：现在两个检查**可以**在 Windows 上跑——闸门用例按宿主跳过并声明（`platform-gate=NOT-covered(needs-non-Windows)`），其余用例照跑（真机 `cases=5`）；「闸门先于 staging 校验」这条顺序在 Windows 上仍无覆盖。`23` 的 `behaviour=NOT-covered(needs-Windows)`（真实的 MoveAndFlush 行为）仍未被覆盖——它需要的是这台机的**部署**，不是它的 PowerShell。

- **同一轮真机验证的两个驱动层坑（如实记录，避免下次重踩）**：① `-EncodedCommand` 与「把每个参数加引号拼成 `-Command`」**都会改变目标脚本的绑定结果**——实测在真 PS 5.1 上，`& $asset @array`（数组 splat）把 `-Bogus` 变成**位置值**，于是拒绝消息点名的是另一个参数（`A positional parameter cannot be found that accepts argument 'C:\t\b'`），看起来**正像资产缺陷**；只有逐字重组命令行（`-` 开头的 token 原样、其余单引号加 `''` 加倍）才复现 `-File` 解析器的行为。② 这台机的 sshd 在 **2222**（`known_hosts` 记的就是它），22 端口是别的东西；VMware guest operations 不可用（`Failed to authenticate with the guest operating system`），可用通道是 SSH。

- **同一轮真机验证的第三、第四个缺口（都已修）**：
  - **`smoke/22` 的输出编码**：该检查用 `任务` / `ünïcode` 做 UTF-8 往返夹具，输入侧早有 BOM（注释写明是 CI 红出来的），但**输出侧没有 pin**，旧注释还写着「none was measured broken」——那只在英文 CI 镜像上成立。实测 zh-CN Windows 10（PS 5.1.19041）：stdout 默认控制台代码页（GBK），`任务` 到 bash 一侧变成 `????`，两条断言失败而**解码器本身是对的**。修法：driver 顶部 `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`，注释按实测改写。
  - **八个检查对 `python3` 毫无守卫**（`08` `10` `11` `12` `14` `20` `22` `29`）：这台机的 `python3` 是 Microsoft Store 别名，跑脚本直接失败；`smoke/12` 在第 995 行的第一处 Python 步骤上以 **exit 49、零输出**终止，`run-tests.sh` 只能报一句没有原因的 FAIL。这与之前 pwsh 那轮是同一形态、同一个方向：**探测「名字能解析」不等于「能执行」**。修法：八个检查各加一次 `python3 -c 'import sys'` 探针，跑不起来就打出「<契约> NOT run」并退 1。红证：`PATH=/tmp/aqprobe/pybin:$PATH ./smoke/29…`（假 python3 退 49）→ 明确报 NOT run、rc=1。
  - **边界（2026-10-20 当晚已解除）**：当时这台机没有真实 Python，所以真机上能完整跑的是 `smoke/23`；`12`/`20`/`22` 会明确声明未执行。**随后把 Python 3.12.10 embeddable zip scp 进 `C:\py`（`cp python.exe python3.exe`）**，三个检查在真机上全部跑通：`smoke/12 cases=54 RC=0`、`smoke/20 cases=43 RC=0`、`smoke/22 cases=79 RC=0`（均为 `pwsh=5.1.19041.3996`）。所以「Windows 上跑过 12/20/22」现在**已验证**，但依赖的是**人工装进去的 Python**，不是这台机上原本就有的。


- **第十七轮（2026-10-20 夜，用户「继续」）：真机上跑 `smoke/13/25` 暴露出的**两个**「检查把宿主环境当成前提」的缺陷，其中一个是**破坏性的**。这一轮没有改任何资产——改的全是检查本身。
  - **`smoke/12` 的「缺 launcher」用例依赖宿主上没有 `C:\ProgramData\AgentQ\agentq-launcher.ps1`。** macOS 上成立，**任何已部署 AgentQ 的机器上不成立**。实测（该机装的是 0.1.8）：launcher 存在，探针**正确地**走到 `ready`，而用例断言 `missing`+42，于是报 **6 条读起来全像资产缺陷的失败**（`POSIX probe (missing launcher) produced agentq-windows-launcher-readyagentq-exit:0` 等）。修法：提取阶段把那**一个**路径字面量改写到夹具目录下一个不会被创建的位置，其余 body（每个退出点、每次改写）仍是**资产自己的文本**；`retarget()` 在字面量出现次数 ≠ 1 时直接失败，防止资产改版后夹具静默失配。**红证（同机）**：`git show HEAD:smoke/12-ps-client-contract.sh` 推回真机 → 6 failures 复现；推回修复版 → `cases=54 RC=0`。
  - **`smoke/25` 在 Windows 宿主上真的执行了安装。** 该检查的「平台闸门」用例断言「合法调用在**非 Windows** 上必须失败」，而**闸门在 Windows 上不会触发**——于是安装器继续往下走：客户端安装器**装了客户端**，并因为没传 `-SkipPathUpdate` **改写了用户的 PATH**（实测 `HKCU\Environment\Path` 从 `…\WindowsApps` 变成 `…\WindowsApps;/tmp/agentq-smoke-psclientinstaller.2gPph8/destination`；检查结束时临时目录被 trap 删掉，那条路径成了死条目）。**已把 PATH 还原为原值并核对**（`reg query` → 只剩 `…\WindowsApps`），`.local/bin` 与 `/tmp/agentq-smoke-*` 均无残留。**`smoke/13` 是同一形态，但后果我实测过、没有推断**：服务端安装器在 Windows 上确实不撞 `Resolve-GitBashPaths` 的闸门（那句 `Windows Principal functionality is not supported` 在 Windows 上根本不成立）。**实测（同日，真机，空 stage 目录）**：它停在 `Required AgentQ path is missing: C:\aqe\empty-stage\agentq`（`Require-Path`，install 脚本第 219 行）——**在任何写入之前**失败，因为 `Require-Path` 在 staging 校验与安装之前。所以 13 原本那条「空 stage 必须报平台错误」的用例在 Windows 上也会红（消息不符），守卫生效是承重的。**但「给满 stage 目录就会接着装 daemon」是推断、不是实测**：这一轮没有在真机上跑那个组合（那正是我们要避免的），所以按本仓规矩记为**推断**。13 的修复与 25 同批落地，`smoke/13` 没有在真机上执行过任何合法调用组合。
  - **修法（不是「让环境满足前提」——前提在 Windows 上永远不成立）**：`smoke/13` `25` 按 `uname -s` 判定宿主；Windows 上**跳过闸门用例并如实声明**（`platform-gate=NOT-covered(needs-non-Windows)`），非 Windows 上照旧跑并报 `platform-gate=covered`。另外**所有**合法调用都补上 `-SkipPathUpdate` 作纵深防御：即使将来某次改动让闸门失效，写的也只是临时目录，**改不动用户的 PATH**。**硬要求只有一条：检查绝不能成为「往开发者机器上装 AgentQ」的那个东西。** 覆盖率是其次。
  - **CI 的 windows job 补齐 `13` 与 `25`**（此前只跑 `12/20/22/23`）——正是这两个检查在 Windows 上的行为需要被持续执行，因为**只在非 Windows 上验过的守卫等于没人跑过的守卫**。同时新增两条断言：每个 `NOT-covered` 都必须带**具名平台理由**（`needs-Windows` / `needs-non-Windows`），且 `13`/`25` 在该 job 上**必须**报 `platform-gate=NOT-covered(needs-non-Windows)`——一个在 Windows 上声称 `platform-gate=covered` 的检查是在断言它根本没执行的用例。
  - **顺带修掉一个真缺陷：`smoke/13` `23` `25` 的 UI 语言探针写着 `''|en|en-*|'')`，第二个 `''` 是永不匹配的死分支**（shellcheck SC2221/SC2222）。上一轮引入时整套检查全绿，因为死分支不改变行为——但**永不执行的分支与死变量是同一类缺陷**：断言悄悄不跑了。修法：删掉重复模式，并把 **SC2221/SC2222 纳入 `smoke/05` 的 shellcheck 锁**（此前只 pin SC2319/SC2034）。**红证**：把重复模式改回 `smoke/23` → `smoke/05` rc=1，报 `shellcheck found SC2319/SC2034/SC2221/SC2222 in smoke/23-durable-move-contract.sh`；改回修复版 → 全绿。锁覆盖整个仓库的 shell 脚本（31 个），不只自己读过的那一个。
  - **本轮自己引入、又被自己的红证抓出来的一个假绿（记下来，它是这类缺陷的标本）**：`smoke/12` 的「缺 launcher」夹具最初把 `C:\ProgramData\AgentQ\agentq-launcher.ps1` 当**字面量**写在检查里。我拿「只改 Windows 资产调用行」去证夹具会失配——**全绿**。查证后有两件事，都对：
    （a）字面量匹配 `ProgramData\AgentQ\*.ps1` 的**规范名**，改成 `…-M1.ps1` 自然不命中；
    （b）更根本的是，**这个路径在两个客户端资产里共出现 10 处**（POSIX 4：探针、launcher wrapper 的真实调用、两条诊断；Windows 6：探针、调用、四条诊断），**没有任何锁**要求它们一致。只改调用行时，探针仍读旧路径——而探针是这些用例唯一驱动的路径，于是**探针检查了一个客户端永远不会调用的文件**，全绿。
    修法分两步：① 夹具不再写字面量，改为**从资产推导**（`LAUNCHER_PATH_RE` 匹配任意 `ProgramData\AgentQ\*.ps1`，每资产必须恰好一个值）；② 新增第 55 例**跨资产一致性锁**（同上判据，两资产的值必须相等）。红证三向：只改调用点 → `names 2 distinct launcher paths`、rc=1；只改 ps1 内部一处 → 同样、rc=1；**两资产一致改名 → 绿**（正确：一致改名不是缺陷，夹具随之推导）。
    **教训**：检查里的**每一个**「资产已知的常量」都是第二个真相源；它能漂移，而且漂移时最可能的症状是**绿**，不是红。

  - **驱动层的两个坑（如实记录）**：① 把 `C:\Windows\System32` 放在 Git 的 `/usr/bin` **之前**会让 Windows 的 `find.exe` 遮蔽 GNU find，`smoke/13` 报 `FIND: 参数格式不正确`——这是**我的驱动命令**的问题，不是检查的问题（CI 与支持入口都显式 `export PATH="/usr/bin:$PATH"`，注释写明原因）。② Git Bash **不带 `shasum`**（只有 `sha256sum`），而 `smoke/13` 原先用 `find … -exec shasum -a 256 {} +` 做 staged 资产哈希——**这是检查在 Git-Bash-for-Windows 上的真实可移植性缺口**，而且**必须修**：这一轮把 `13` 加进了 windows CI job，不修它 CI 会直接红。**已修（同轮）**：抽出 `stage_digests()` 按工具分发——`shasum -a 256 FILE` 与 `sha256sum FILE` 的参数形态**不同**（实测 `sha256sum -a 256` 报 `invalid option -- a`，我第一版 helper 正是这么写的、会直接弄红 CI），两条分支的输出已逐字节比对一致；两者都不存在时退 127 并说明检查无法运行（不静默）。


- **第十八轮（2026-10-21，用户「确认，继续」）：把真机升级到 0.1.16，并在升级后的部署上跑端到端；升级过程本身又暴露一个「检查依赖控制台宽度」的间歇性假失败。**
  - **升级**：目标机 0.1.8 → 0.1.16，走官方安装器 `install-agentq.ps1 -StageDirectory C:\aq-upgrade\stage`（staged 五件与仓库逐字节一致、`sha256sum` 核对；pueue/pueued 哈希与安装器钉的一致，无需外网）。结果：`INSTALLER_EXIT=0`、`updated_atomically: true`，耗时 27s。升级前队列只有 1 个已结束任务（id 55 Failed），无活动任务；升级后 `agentq_version='0.1.16'`，三个通用资产哈希与 staged 一致（launcher/pueue.yml 含占位符替换，哈希不同属设计），`shared_secret`/`certs`/`state.json.gz`/`task_logs` 全部保留，**无事务残留**（`C:\ProgramData\.AgentQ.*` 不存在），pueued 以新 PID 运行，计划任务 "AgentQ Pueued" 存在。
  - **升级后协议端到端（Mac POSIX 客户端 → Windows 服务端，经 askpass 凭据通道 + 2222 端口 wrapper）**：`status --summary` → `{"tasks":{}}`；`submit` → `task_id=56`；`lookup` → `reused:true`；`wait 56 --timeout 60` → `Done.result=Success`；`logs 56 --tail 5` → `AGENTQ-E2E-OK`；`remove 56` → `removed:true`；清理后 `status --summary` 回到 `{"tasks":{}}`。临时 askpass/ssh wrapper 用完即删，磁盘上无明文密码残留（实测 grep）。
  - **升级后重跑 PS 侧契约**：`12 cases=55`、`13 cases=5`、`20 cases=43`、`22 cases=79`、`23 cases=7`、`25 cases=5`，全部 RC=0（zh-CN + 真 PS 5.1.19041.3996）。
  - **但 23/25 在升级后的第一次批量运行里报了 3 条失败，重跑即绿——间歇性。** 形态：`stderr does not contain Cannot process command … missing …` / `… 'Bogus'`，而检查打印的原始 stderr 里是**带文件前缀、在第 119 列被折断**的 `SourcePa` / `th`、`B` / `ogus`。逐项实测：wrapper 路径连续 5 次稳定输出**单行 124 字符**（catch 正常）；控制台宽度稳定 120；逐字复刻 wrapper 也稳定单行。也就是说那次运行里错误**逃出了 wrapper 的 catch**、由 PowerShell 按 120 列格式化并硬折行——**触发条件未能隔离**（重跑不复现），如实记录为「形态已定量、触发未隔离」。
  - **修的是可确定的那一半**：`flatten_err` 原先 `tr '\n' ' '`，硬折行处会变成 `missi ng`，让**正确的资产间歇性报坏**——断言依赖控制台宽度本身就是环境前提。现探测 `$Host.UI.RawUI.BufferSize.Width`，长度 ≥ 宽度-1 的行视为硬折行、与下一行**无分隔**拼接，其余用空格。A/B 用真机取回的原始字节：旧实现 `OLD_MISMATCH`、新实现 `MATCH_OK`；本机三个检查 RC=0；真机 13/23/25 RC=0（升级后的部署上）。
  - **边界**：触发「错误逃出 catch」的条件未复现，因此没有声称已修根因；宽度重接消除的是**这一类**失败形态（任何来源的硬折行都不再劈开单词）。
- **第十九轮（2026-10-21，用户「深度研究分析，全部优化好」）：四个独立审查代理的候选逐条裁决。** 每一条都先证能红再改；不能证的如实记边界，不改。
  - **服务端（两份 canonical 资产同步，`cmp`=0）**：
    - `archive_removed_request` 的 `tombstone=$(make_request_tombstone …)` 改为 `|| return 1`。该函数运行在 `if !`/`||` 上下文（errexit 关闭），失败的 `$( )` 会留下**空墓碑**，随后删掉活 record——request id 可被复用。与 2026-10-06 的 `--workdir` 同一 fail-open 类。
    - `cancel_task` 的 `created_at=$(jq -er …)` 改为 `|| fail …`。空值会被写进 cancellation marker，而 `valid_marker` 要求非空——该 task id 之后每次读 marker 都 fail-closed，直到手工删文件。
  - **POSIX 客户端**：
    - **后台 ssh 孤儿（真缺陷，已证红）**：`wait --timeout` 是唯一把 ssh 放后台的路径；HUP/INT/TERM 处理器只 `exit 130`，不杀子进程，于是客户端退了、远端 `wait` 继续持操作锁。修法：`cleanup_client_runtime` 先调 `agentq_stop_background_ssh`。红证（`git show HEAD:` 版 vs 新版，同一 stub）：旧版 `the backgrounded wait ssh (pid …) survived the client exit`，新版通过；`smoke/28` 新增用例（stub 记录自身 pid 且 `exec sleep 30`，3s 内必须死；该检查的摘要现为 `cases=9`（HEAD 时实为 8：3 个信号 + 1 个对照 + 4 条静态锁；`verification-status.md` 里写的「6 例」是 2026-10-13 加 EXIT 锁之前就没再更新的陈旧数字，本轮一并改正））。
    - **数值环境变量只有字符集校验**：`AGENTQ_SUBMIT_RETRY_ATTEMPTS/DELAY`、`AGENTQ_OPERATION_RETRY_ATTEMPTS/DELAY`、`AGENTQ_PLATFORM_PROBE_TIMEOUT` 五处用 `is_positive_integer`（无上界）。它们全部喂 `[ … -ge/-gt … ]` 或 `sleep`，而 dash 对超出整数范围的值打印 `Illegal number` 且比较读作**假**——探测期限永不触发、重试上限永不触发。改用 `is_bounded_positive_integer`（≤9 位），并删掉因此不再被引用的 `is_positive_integer`。`smoke/05` 的 env 循环从「每个变量只测 `0`」扩到「`0` + `99999999999999999999`」，`env=16 → 24`。
    - **`cancel` 的 exit 4 被降级成 2**：4 的契约含义是「服务端无法安全判断，**停止**，不得自动重试」，而 2 读作「参数错，改完重试」。旧实现在 `cancel_pending` 响应体校验失败时把 4 覆盖成 2，并且「不打印未校验响应体」只是降级带来的副作用。现在保留 4，用独立标志 `mutation_body_suppressed` 抑制输出。红证：同一 stub（exit 4 + `{"task_id":1,"state":"bogus_state"}`），旧版 `exit=2`、新版 `exit=4`；`smoke/05` 两向各一例（未校验体 → 4 且 stdout 空；已校验体 → 4 且转发）。Windows 孪生同修，`smoke/12` 用覆盖 `Invoke-SshLogged` 的方式钉住。
    - **死传输上跑两轮完整探测**：本地探针返回 255（ssh 自身失败码；恢复循环只重试分类为 transport 的 254，耗尽后也是 255）后，旧实现仍跑 Windows 探针，在同一堵墙上再花一整轮预算（默认 6 次 ≈ 70s）。现在直接返回 255。**124（超时）刻意不短路**——慢主机不代表不是 Windows。红证（缓存关闭、`AGENTQ_OPERATION_RETRY_ATTEMPTS=1`）：旧版 4 次调用、新版 2 次；`smoke/05` 用计数 stub 钉住。
    - **三处「清空路径后再用空路径删除」**（探测 output/log 的 identity 失败分支、Windows 编码 in/out 的 identity 失败分支）：`platform_probe_remove_file "" ""` 只会打印一条**不带文件名**的 `unsafe … temporary file:` 并且什么也删不掉。现在消息里点名被保留的文件，删掉那条永不成功的调用（identity 未知时保留文件是既有 fail-safe 语义）。
  - **Windows 客户端 / 资产**：
    - `[Console]::OutputEncoding` 未固定：PS 5.1 用控制台代码页解码原生子进程 stdout，zh-CN 上是 GBK，而 ssh 发的是 UTF-8——本仓已实测过同一形态（`任务` → `????`）。现在启动时固定 UTF-8（带 try/catch），并给 `New-SshProcessStartInfo` 的 `StandardOutputEncoding/StandardErrorEncoding` 显式设 UTF-8（服务端安装器早已这样做）。**真机未复验**（本机无 PS 5.1）。
    - `Start-Process -ArgumentList @("--config", $path)`：PS 把数组用空格拼且不加引号，路径含空格就被拆成两个参数。两处（`agentq-start-daemon.ps1`、`install-agentq.ps1` 的 legacy 恢复路径）改为显式加引号。**真机未复验**。
    - `install-client.ps1` 的 launcher ACL 只在 **Prepare**（替换前）应用一次；`File.Replace` 的安全描述符语义不该被依赖——若被替换文件的 ACL 生效，收紧会被静默撤销，而 `Set-ClientLauncherAcl` 自己的校验跑在 staged 路径上、仍会通过。现在 Prepare + PostCommit 各应用一次（函数幂等）。**真机未复验**。
  - **检查侧**：
    - **被测物来自环境（真缺口，已修）**：`smoke/03` 直接跑 `$runtime_home/agentq-server`，`04/06` 复制同一份——那是 `sandbox.sh` **建沙箱时**的快照。实测沙箱里是 247276 字节（上一提交的资产），仓库资产 248213，三个检查照绿。`04/06` 改为复制 `${AGENTQ_SMOKE_SERVER:-$root/skill/assets/unix/agentq-server}`（`02` 早有的钩子），同族的 `07`/`15`/`17` 一并改（`07`/`17` 用 `repo_root`：这两个脚本后面把 `root` 复用作远端 bin 目录）；`03` 因为服务端从 `$0` 所在目录解析根、且拒绝符号链接的 data 目录，只能在 runtime 里**原位换入**仓库资产并在 EXIT trap 还原。另：`sandbox.sh up` 的幂等分支（daemon 已在跑）现在也会刷新 `agentq_home/agentq-server`，免得沙箱里那份一直是建沙箱那天的构建——检查已不依赖它，但人手用 `$AGENTQ_SMOKE_HOME/agentq-server` 敲命令时不该跑到另一个版本。第一次红跑抓到一个次生事实：`$program` 是 `basename $0`，换名（`.smoke-under-test`）会让所有 `agentq-server: reason=…` 断言失败——换入文件必须就叫 `agentq-server`。
    - **`smoke/01` 的 `.cmd` 规则可被注释欺骗**：`grep -q -- '-NonInteractive'` 会命中 `rem` 行，于是删掉真实参数、留一句注释仍然全绿。现在先剔除 `rem`/`::` 注释行再匹配；目标 `.ps1` 的 `Read-Host|ShouldContinue|ReadKey` 也剔除 `#` 行（否则一句注释会把规则**反转**）。红证：变异文件（真参数删除 + `rem -NonInteractive`）在 HEAD 的检查下**全绿**、在新检查下报 `cmd FAILED`。
  - **裁决为「不是缺陷」并记录**：探测超时不会写缓存（`platform_cache_write` 只在成功判定后调用）；sshp 无 `expect` 时 stdin 经 fifo + `cat` 正常转发；sshp 的 `-E` 日志只收 ssh 自身诊断（远端 stderr 走通道，交互式 `-tt` 下并入 stdout），不构成无界落盘面；PS 客户端成功时打印 `SSH diagnostic omitted for safety` 与 POSIX 孪生一致，属刻意行为。
  - **同族复查（PLAN 记完之后又查了一遍）**：`07`/`15`/`17` 也在复制 `$source_home/agentq-server`，同一处修法一并补上——不是「我只改了读到的那几个文件」；按「被测物从哪来」逐个文件问，才把这个族找齐。
  - **补记（用户问「还有其他问题吗」后新发现的一族）**：六项数值环境变量的**上界在两个客户端之间全部不一致**——POSIX 取 ≤9 位、Windows 取 int32 上界（`Convert-ToPositiveInt32`），于是 `=1000000000` 与 `=2147483647` 在 Windows 收、POSIX 拒；反过来 `=05` / `=007` 前导零 POSIX 收、Windows 拒（`^[1-9][0-9]*$`）。全矩阵实测 6 变量 × 5 值，逐格记录。修法是**双向收敛**：`is_bounded_positive_integer` 改成与 Windows 完全同形（拒前导零、上界 2147483647），错误消息从 `of at most nine digits` 改为 `of at most 2147483647`（八处）。为什么不用 shell 自己的 int64 上限：Windows 侧的 `Start-Sleep` 收 `[int]`，收窄没有风险而放宽会让两边再次分叉——**边界的分歧本身就是缺陷**，这与本轮最早修的 `CACHE_TTL` 静默回落是同一类。锁：`smoke/05` 的 env 循环加测 `05`（env 24→30），`smoke/12` 的单个 `=0` 用例换成 4 个值（`0`/`05`/`2147483648` 拒、`2147483647` 收），后两个一起把「不能悄悄收紧上界」钉住。第二批（同一轮复查）：`--tail` 也是同一类——POSIX 的 `is_positive_integer_or_all` 只查字符集，接受 `05`/`007` 并原样转发，Windows 的 `Test-PositiveIntegerOrAll` 用 `^[1-9][0-9]*$` 直接拒（实测 `logs 1 --tail 05`：POSIX 255 走到 ssh、Windows 2）。两边收敛到拒绝前导零；`all` 与普通整数仍收，`smoke/12` 用 5 行表（拒 3 / 收 2）双向钉住（该检查现为 68 例，`smoke/05` 为 45 例 / env=30）——只钉拒绝的话，一个「什么都拒」的校验器也能全绿。任务 id 本身**没有**这个分歧（两边都接受 `05` 并交给服务端 `canonical_task_id` 归一），已实测确认，未改。
  - **第三批（用户「能处理的全都处理完」之后）**：把「同一输入两套实现给不同答案」当成一条规则，做**系统差分**而不是逐项看代码。方法：把同一组 argv / 同一组环境变量分别喂给两个客户端，比退出码。结果：30 种 CLI 形态零分歧；环境变量面查出 4 处真分歧，全部已修：
    1. **`AGENTQ_REMOTE_PLATFORM` 大小写**：Windows 的 `switch` 按语言规则不分大小写，POSIX 的 `case` 分——`AUTO`/`Unix` 在 Windows 走正常分支、在这里退 2。修法是在读取处 `tr` 成小写（统一归一，下游全部看到一种形式），不是把 `case` 模式逐个写全。
    2. **launcher 协议探针失败的状态码**：POSIX 透传探针真实状态（`return "$windows_protocol_status"`），Windows 一律 `Stop-AgentQ`（固定 2）。实测 `AGENTQ_REMOTE_PLATFORM=windows` + 死传输：POSIX 255、Windows 2——而 255 会被调用方当传输故障重试、2 被当参数错误，**含义相反**。修法是 Windows 也透传（0 且载荷不匹配仍折成 2，与 POSIX 同形）。
    3. **死传输后的平台探测**：POSIX 有「255 直接短路、不再跑 Windows 探针」，Windows 只在日志**含**传输错误行时才短路——不写日志的失败会再花一整轮预算，最后报 2。实测同一 stub：POSIX 2 次调用 / 255，Windows 4 次 / 2。修法是 Windows 也按 255 短路并以 255 退出。
    4. **（同一族的空值形态）** 扫描时我自己的脚本把 `VAR=` 与 `VAR` 混用，制造了一次假分歧——记录在这里是因为它正好是本仓反复强调的那类：**检测器本身也要被怀疑**。用 `env "$var=$val"` 且跳过空串后，环境面零分歧。
    锁：`smoke/05` 加平台大小写 6 行 + 非法值 1 行（env=30 → 37，实测确认），`smoke/12` 加同样的 7 行（68 → 75 例，实测）。两处都用「不是参数错误」而不是「必须是 255」作判据——`windows` 值还要过 launcher 探针，把实现细节钉死会误伤。（我一度又写了一个「死传输」用例，检查后发现上一轮那条已经在测同一件事，已删——**加锁之前先查有没有**，否则计数会虚高、失败也会报两遍。）
  - **未修、如实记录**：`sshp.ps1` 的 `Test-NonReparseWindowsFilePath` 拒绝父链上任一 reparse point，某些重定向配置文件（junction）或 WinGet 布局下会拒绝可用的 ssh——这是既有的安全姿态，**没有真机测量就不放宽**；`smoke/09` 的 base64 通道证明仍是**文件级**（要求存在 `$var = … base64 -d | bash` 且变量名匹配，但不做数据流），静态分析边界。
- **第二十轮（2026-10-21，接第十九轮收尾）：检查侧的两类「假红」与两个客户端缺口的补锁。**
  - **`printf VAR | grep -q` 在 `pipefail` 下会把「匹配到了」读成「没匹配到」**：`grep -q` 命中即退出并关闭管道，`printf` 若仍在写就收 SIGPIPE(141)，整条管道非零——`if !` 于是把 PRESENT 读成 ABSENT。**这是全量套件里实测到的**：`smoke/01` 的 `.cmd` 规则报 `sshp.cmd`「delegates to a non-interactive script but omits -NonInteractive」并伴随 `printf: write error: Broken pipe`。`sshp.cmd` 本来就刻意不带该参数，所以出错的是**目标谓词**——`sshp.ps1` 第 903 行确有 `Read-Host`，那条管道却报没匹配。**触发无法隔离**：同一管道同一字节流单独跑 500 次全绿，8 个 CPU 占用下再跑 200 次仍全绿；唯一能稳定复现的形态是「负载 > 64 KiB 管道容量」——`seq 1 20000`（约 108 KiB）+ 首行匹配 → `rc=141`，所以记「机制已实测、触发率未测得」。修法不是调管道，而是**取消管道**：`smoke/01` 的两条谓词改单进程 `awk`（注释行同时被排除，`[Rr][Ee][Mm]` 是因为 BSD awk 没有 IGNORECASE），其余 **37 处** `printf … | grep` 统一改为 `grep … <<< "$VAR"`（here-string 无并发写者；实测各规模 100 次、含 200 KiB，零失败）。**修法本身踩了两次坑，都记在这里**：第一次替换正则把标志位粘到了 here-string 词上（`grep <<< "$x"-qE …`，grep 收到零参数），第二次修复用的过宽正则把 `[ ! -e … ]`/`[ ! -d … ]` 改成了 `[ ! grep -e … ]`——两次都是先 `git checkout` 回退、再写一个**引号感知**的扫描器（输出 37 条 before/after 逐条人工核对）才落地。锁：`smoke/01` 新增静态规则，扫 `smoke/*.sh` + `run-tests.sh` + `sandbox.sh`，命中未注释的 `printf … | grep` 即失败（摘要报 `repo_scripts=31 repo_pipes=0`）；诊断文案刻意不含字面管道符，规则不会扫到自己的文件。红证：往副本的 `smoke/23` 末尾注入一行该形态 → rc=1 并点名文件行号。
  - **`smoke/12` 两个用例补回并各自修正了夹具**（此前在会话中断时丢失、从会话记录恢复）：
    - **不可启动的 `AGENTQ_SSH`**：HEAD 版在 macOS pwsh 上对 644 普通文件退 **1、零输出**（`Start-Process` 的异常从 `Invoke-SshLogged` 逃出，脚本无顶层 trap），POSIX 孪生同一配置退 2 并有受控消息。新资产在 `Resolve-SshPath` 里做一次**真实启动**探针（`-V`，不建连接、不触远端），失败即 `Stop-AgentQ "AGENTQ_SSH cannot be launched: …"` 退 2。红证：同一夹具 HEAD 版 `rc=1` 无输出、新版 `rc=2` + 受控消息。
    - **ASKPASS + PASSWORD_PROMPT 同时设置**：POSIX 退 2「set only one」，Windows 此前接受并静默用 askpass——同一环境在两个平台含义相反。新资产加同一守卫。**夹具修正**：文件形状守卫在歧义守卫**之前**，最初用不存在的 askpass 路径做夹具时，两条版本都以「not a regular non-reparse file」退 2，用例会**在没走到目标规则的情况下变绿**（实测确认）；改用存在且可执行的 askpass 文件后，HEAD 版一路跑到 ssh（255）、新版命中「both set」退 2。
  - **`smoke/12` 计数**：75 → 77 例（两个新用例）。
  - **补一（2026-10-21，套件通过之后把锁的判据重定到消费者侧）**：第一版锁只匹配 `printf … | grep`，套件通过后按「这把锁的覆盖就是它的模式」自查，发现它漏掉两类**同一机制**的站点：函数写者（`flatten_err … | grep -qF` ×6，含 `strip_ansi`）与绝对路径（`printf … | /usr/bin/grep -qF` ×4，`smoke/12`）。危险的是**消费者**而不是写者：`grep -q`（以及 `-m`）在读尽 stdin 前就退出，任何上游阶段都可能收 SIGPIPE，pipefail 下整条管道非零，`if !` 把「匹配到了」读成「没匹配到」。**最终判据**：禁止任何「管道末端是 quiet grep」的形态，无论写者是谁、无论命令怎么拼；`grep -c` 刻意**不**匹配——它必须读完全部输入才能计数，造不成这个竞态；`(^|[^|])` 排除 `a || grep -q file` 这类兜底调用。按最终判据度量：改动前（`637c6fb`）**39 处**，第一版锁之后仍剩 **10 处**（正是上面两类），现在 **0**；here-string 站点合计 **51 处**。红证两向：注入「函数写者」与「`sort -u | /usr/bin/grep -q`」两个变异都被点名，同一文件里 `| grep -c .` 控制组不被误报。**这条的教训是判据选错了对象**——把锁写在「我见过的那种写法」上，而不是「造成后果的那个行为」上，就会留下一个刚好装得下下一类写法的洞。
  - **补二（同日）**：顺手发现注释里写死的行号会漂移——`.cmd` 规则注释里的「sshp.ps1 Read-Host (line 903)」不点行号，改成由 `smoke/01` **每次从资产现场数**（`grep -n` 第一个未注释命中；`agentq.ps1` 无命中记 `n/a`），加进现有的 `repo_pipes` 汇总。**锁锚在资产上，注释不许锚在易碎坐标上。** 红证：给注释造一行假命中 → 计数错 → 报红。
  - **补三（同日）**：CHANGELOG 第二十轮条目曾把第十九轮整行覆盖（插入 `anchor+1` 时 `anchor` 含了目标行），行数一度回落到 HEAD 的 692；用 `git show HEAD:CHANGELOG.md` 取回第十九轮原文、重插成 693 行，diff 才回到 1 行新增。同一族教训的文档侧版本：**替换断言前先确认 anchor 确切包含你替换的边界**；顺带，amend 是对的但别忘了重打 tag（本地 `v0.1.16` 已重指向 amend 后的提交，origin 最高只到 `v0.1.10`，未改写已发布历史）。

- **第二十一轮（2026-10-22）：八代理全维度审查，14 条落地。** 用户要求「使用 agents 对项目进行全维度全场景审查」，随后「全部优化好」。八个只读代理分面（服务端、POSIX 客户端、Windows 客户端、sshp 双实现、安装器、smoke 套件、协议/文档、安全面），**每条发现我都独立复核过**，剔除 3 条过度声称（D-F5「两个客户端对同一台机行为不同」——两个客户端各消费自己的探针输出，`__SSHP_ZELLIJ__` 只存在于 ps1 内部；H 的 ACL 注释——注释后半段已准确描述实际行为；E 的 `updated_atomically` 硬编码——该字段只在无回滚的成功路径到达，语义无误，改名反而破坏历史文档的可对照性）。
  - **P1：`cancel` 的重放证据在 Pueue 不可读时是空的（第一版修法过宽，被 smoke/15 打回，最终按证据强度分层）。** `cancelled_task_replay` 原本在 `raw_compact_task` 的**任何**失败下都执行，包括 rc=1/2/5（读不出来）。而实例绑定 `task_instance_created_at_is_recorded` 只问「是否存在 created_at 相符的记录或墓碑」——旧实例自己的 accepted record 恰好满足，于是绑定在不可读路径上是**自满足**的，没有鉴别力。后果：对一个可能仍在运行的任务返回 `reused:true`/exit 0。同一函数里 pending 分支在 rc≠4 时**明确拒绝**下结论（注释写着「we do NOT know that」），两种 marker 门控不对称，说明这是漏洞而非设计。**第一版修法把重放整体挪进 rc=4 分支，全量套件当场打回：`smoke/15` 的两条断言同时变红**——它测的正是「Pueue 不可读时，一个**已确认**的取消仍必须能重放」，注释里还写着「replay 检查在 rc=4 门控之前，只有 rc=4 才能声称任务已消失」。那两条断言是对的：**墓碑**（`state:removed`）证明 AgentQ 已经移除过这个任务，它不可能回来，所以不可读时重放是安全的；**accepted record** 只证明「这个 id 上曾有过某个实例被跟踪」，而 Pueue 复用 id，**更早实例的记录同样满足实例绑定**——绑定在那里没有鉴别力。所以最终修法是**按证据强度分两级**：rc=4 接受任意一级，Pueue 不可读时只接受墓碑。`smoke/15` 保留墓碑方向并新增 record 方向（同一 marker、同一 created_at，只把墓碑换成 accepted record，断言**不得** `reused:true`、**不得** exit 0）。A/B 实测：变异体（无条件 `any`）→ `rc=0` + `reused:true`；修复版 → `rc=2` + `cannot inspect Pueue`。**同一轮里我还把 rc≠4 的 reason 改成了 `lock_contention`，也被 smoke/15 打回**——它对 `logs`/`cancel`/`remove` 三者统一要求 `protocol_error`，而「Pueue 读不出来」对三个命令本就是同一类状态，单独给 `cancel` 换一套词汇只会让调用方更难判断。已回退（维护锁那处的 `lock_contention` 保留：那是所有命令共用的入口，改则一致）。**教训：一个「更正确」的语义改动，如果让同一个状态在不同命令上有了两种描述，那它多半是错的。**
  - **P1：Windows 客户端的 MINGW 分支把探针状态折叠成 2。** `Confirm-NativeWindowsPlatform` 用 `Stop-AgentQ`（固定 2），POSIX 孪生 `return "$windows_platform_status"`。这正是第十九轮在隔壁 `Confirm-WindowsAgentQProtocol` 上修过的同一类，**只修了一个函数**。死传输时两个客户端给调用方相反的指令（「可重试」vs「改参数」）。锁：`smoke/12` 新增一例（判据「不是 2」，因为 launcher 探针的码也合法）；红证用变异体确认只触发这一例、其余 77 例全绿。
  - **P1：`smoke/28` 的三个信号用例是同一个 TERM 用例跑三遍。** 桩里硬编码 `kill -TERM`，循环变量 `$signal_name` 从未传进去。而且 INT 用例结构上不可能成立——非交互 shell 启动的后台作业**以 SIGINT 忽略开始**，被忽略的处置无法被 trap 接管。修法：桩读 `SMOKE_SIGNAL`；INT 经一个「恢复 SIG_DFL 再 exec」的 perl 启动器（exec 保持 pid，桩仍能信号到正确的进程）；无 perl 时报 NOT-covered 而不是静默通过。红证：把两处 trap 改成「只清理不退出」→ 三个信号全部报红（含 INT），静态锁也独立报出。
  - **P2 群（服务端）**：`submit` 对 `removing` 改发 `4`+JSON（退出码表本就把 removing 归 4，而 `lookup` 同状态就是 4；原先是 2 无 body）；维护锁在位时也带 `lock_contention`；`doctor` 的两条 `--version` 折成 `unavailable`（坏二进制不再让服务端退出非契约码）；`managed_daemon_is_active` 去掉 quiet-grep 管道（pipefail 下会把「运行中」读成「未激活」，进而 kickstart 一个已加载的服务）。
  - **P2 群（客户端）**：POSIX 的参数校验**前移到平台探针之前**（与 Windows 孪生同序）——此前本地拼错要先付一次完整探测，在死主机上还退 255 而不是 2；Windows 的 auto 分支 124 不再短路、两探针皆失败时按 POSIX 透传本地码；`Write-PlatformProbeCache` 的 `$temporary` 前置声明（catch 里读未赋值变量在 StrictMode 下自己抛错，把成功的命令拖死）；`Resolve-SshPath` 的 `-V` 探针改异步读+有界等待；平台缓存时间戳用 `is_bounded_positive_integer`（前导零在 dash 下 `Illegal number`，每条命令都崩——A/B 实测：旧版 `Illegal number`+rc2，新版 rc0）；`AGENTQ_PLATFORM_PROBE_CACHE` 与命令/选项 token 归一化（Windows 的 `-eq` 不分大小写，POSIX 的 `case` 分；8 种大小写只列了 7 种）。
  - **P2 群（sshp / 安装器 / 检查侧）**：`sshp` 的 `-Command -` 输入补**尾部空行**（EOF 处未以空行结束的块被静默丢弃，PS 孪生早已如此，POSIX 侧只有一个结尾换行）；参数 token 归一化；`install-client.sh --check` 目录缺失改退 1（SKILL.md 契约，Windows 侧本就是 1）；Windows 安装器的陈旧维护锁恢复补「删除前重读元数据再判死」（第三份拷贝，另两份早已如此）；Windows 客户端安装器的 backup 临时文件登记进清理；`smoke/03` 删除向真实 `$HOME/.agentq` 的回落（它是唯一这么做的 runtime 检查，而它会 submit/cancel/remove）；`smoke/05` 的 `shellcheck=absent` 改 `skipped(...)` 以进 PART；`run-tests.sh` 对子检查关闭 fd 3、PART 与 NOT-covered 双报；`smoke/22` 的 `lastexitcode-guards` 改派生计数；`smoke/24` 补 `AGENTQ_ASKPASS` 三个方向与 `SSHP_SSH` unset。
  - **本轮最重要的检查侧收获：把 quiet-grep 锁的扫描根从 31 个脚本扩到 38 个（加 `skill/assets/` 的 shell 资产），扩面当场抓出 5 处真实漏判**——`agentq` 2 处、`sshp` 3 处，全部是「`tr -d '\r' < file | grep -E -q`」。A/B 实测：80 KiB 输入上旧实现把**存在的** marker 判为不存在（`OLD: MISSED` / `NEW: found`）。这不是风格问题：`probe_reports_marker` 决定是否认一个协议应答，`ssh_transport_error` 决定死传输是否重试，认证分类器决定是否打印「装密钥或起 ssh-agent」的提示。修法是 `grep -c` + 算术判断（`-c` 必须读完全部输入，写者不会被提前杀死）。**中途我错误地把 `tr -d '\r'` 一并删掉**，`smoke/05` 立刻抓到——这些行确实带 CR（Windows 侧写、本仓库的桩照抄真实行为），而所有模式都锚在 `$`，不剥 CR 就静默失配（`class=ssh` 而非 `transport`，重试消失）。**`tr` 必须保留，`-q` 必须换成 `-c`**——两件事不能混。
  - **一个我自己引入、被套件抓到的回归**：把 `ReadToEnd()` 改成 `ReadToEndAsync()` + `WaitForExit(10000)` 之后，`-V` 探针没有关闭子进程 stdin，而本仓库 `smoke/12` 的 ssh 桩首行是 `cat > /dev/null`（读到 EOF 才继续）——于是探针永久阻塞、10 秒预算触发，把一个**完全可启动**的 `AGENTQ_SSH` 判成不可用。修法：`RedirectStandardInput = $true` + `StandardInput.Close()`。这是本轮「修一个缺陷引入另一个」的唯一一例，靠行为用例而非读码发现。
  - **文档侧（G 代理，部分落地）**：README「the smoke suite … does not prove that any branch behaves correctly」与覆盖表直接矛盾（`03`/`07`/`12`/`17`/`22` 都是行为级证据）；`verification-status` 与 `CONTRIBUTING` 仍写「四方」版本一致性（实际六方，0.1.16 起含两个客户端常量）；多处资产行数断言漂移（`install-agentq.ps1` 3077→3154 且已不是「全仓第二大」、`agentq-server` 5561→5985）。**本轮只改了版本索引与条目，这三处文档订正未做**，如实留在这里。
    **0.1.18 已全部完成**：README 那句改为「按覆盖表的逐项列读」（不再声称任何分支都不能证明）；`smoke/01` 的注释改为六方；`verification-status` 与 `PLAN.md` 里的**当前行数**陈述直接删除——它们不是断言、只有失效风险，且实测已全部失真（`install-client.ps1` 563→586、`install-agentq.ps1` 3077→3182 且「全仓第二大」已不成立、`agentq-server` 5561→6120）。

- **第二十二轮（2026-10-22）：把上一轮列出的 8 项遗留全部修掉。** 用户先问「本项目还有没有问题」，我复核后报出 8 项（4 处代码/检查、3 处文档、1 处边界），并**明确否掉了 3 条代理发现**（附证据）；用户随后说「要全部优化好」。本轮逐项落地，每项都做了 A/B 或变异红证。
  - **A-F2：记录读取路径把「消失」误判成「不安全」。** 这是本轮唯一的**资产缺陷**，而且有**两份拷贝**。
    - **第一处**：`load_request_records` 的三道守卫（守卫、精度探针、读）任一失败都 `fail`。但读路径是**免锁**的，而归档器（remove 恢复、wait 对账）会在同一时间删记录——于是「守卫已接受、文件被删」这个竞态会把一次无关的 `status` 变成 exit 2。窗口是**每条记录几微秒**：40 + 25 次定时试验**零命中**（`printf` 是 bash 内建、`validate_task_id_precision_in_file` 在正常 jq 下立即返回，循环里没有任何可挂钩的外部命令），所以**端到端撞不出来**。
    - **第二处**（写用例时才发现）：`repair_removed_request_records` 走的是**另一套**守卫 `request_record_path_guards_or_fail`，同一个竞态在那里同样致命——V2 用例第一次跑就报了它（悬空符号链接被那条路径判为致命）。
    - **修法**：新增 `request_record_vanished`（`[ ! -e ] && [ ! -L ]`——「既不是普通文件也不是符号链接」才算消失，**悬空符号链接不算**：它是个对象，坏的是它的目标），两处共用；消失时发 `null` 占位符，**存在但不安全仍致命**。
    - **占位符不是可选项**：`load_request_records` 与 `request_removed_records_filter` 都按**位置**把记录绑到 id，裸 `continue` 会让后面每条记录错位到前一条的 id 上，然后被绑定校验整批拒绝——这正是 2026-10-16 记录过的同一个坑。两个过滤器都改成容忍 `null`（`load_request_records` 的过滤器早就这么做了）。
    - **红证用变异，不用定时**：把同一个 `rm -f` 注入到 0.1.17 与 0.1.18 服务端的**同一位置**（守卫接受之后、精度探针之前），0.1.17 报 `invalid AgentQ request record path` + `failed to recover removing AgentQ requests` + exit 2，0.1.18 exit 0 且输出正常。`smoke/26` 的 V4/V5 就是这个变异，两个方向都断言。
    - **我自己踩的 `$( )` 陷阱（第四次）**：修回退循环时写成裸 `output=$(read_request_record_state_and_body …)`，而 `set -e` 下命令替换非零会**直接杀掉整个服务端**——于是「消失」这一支根本到不了，`read_status=$?` 永远不执行，症状是 exit 2 且**零 stderr**（比改之前更糟：原来至少有两条消息）。改法是 `output=$(…) || read_status=$?`。这是本仓记过三次的同一个陷阱，每次的表现都不一样。
    - **判据也修了一处**：`read_request_record_state_and_body` 里 `fail` 退出码是 2，而「消失」是 1——`|| return 1` 会把两者折叠掉，所以改成 `|| return 2`。
  - **C-F6：Windows 客户端顶层没有 trap。** 未捕获的 throw 退 1、无输出——1 在本仓的契约里是「一般失败」，但调用方拿到的是一句 PowerShell 的原始报错，没有 `agentq:` 前缀、没有受控形状。A/B 实测：有 trap → exit 2 + `agentq: <msg>`；无 trap → exit 1。
  - **C-F3：Windows 客户端没有本地命令行预算。** CreateProcess 的命令行上限是 32767 字符，而客户端把 base64 后的脚本整体塞进 argv：实测 20 KB 脚本 → argv 36302 字节，**在 Windows 上必然被截断**。修法：`$script:LocalCommandLineLimit`（Win32NT 取 32767、其它取 131072）+ 固定开销 734（实测：8 字节脚本 → 17 个 argv 元素 / 750 字节），超限时受控拒绝；submit 侧的预算同步收紧到 3/4。
  - **F-3：CI 不钉检查数量。** `ci.yml` 的断言是 `[0-9]+ ran`，而 `run-tests.sh` 自己比的是「跑了几条」对「**找到**了几条」——删掉任一 smoke 文件，两个数同步变小，**所有门照绿**。修法：CI 侧持有一份**独立的**检查名清单（29 个名字），比对「上报的集合」与「钉住的清单」，并同时钉住行数；缺一个、多一个、改名都红。
  - **F-5：`smoke/02` 的裸调用规则只认零参形态。** 规则二判的是「函数里有 `printf >&2` + `return 2`，而该函数在某处被**裸调用**」，但「裸」的判定是 `^[[:space:]]*[a-z_]+[[:space:]]*$`——**带参数的裸调用整个逃过**。注入证明：一个打消息并 `return 2` 的函数被裸调用成 `mutant_check jq`，规则二**没有报**（只报了运行时那 26 条，与本规则无关）。修法：识别带参数的裸调用，同时**排除被 `return $?` 折叠的调用**（`cleanup_temporary_file_after_make_failure` 里正是这个形态——第一版扩面把它误报了，是规则把「折叠」当成了「裸」）。实测：当前资产零误报，注入变异精确命中。
    - **顺带一个本仓的老坑**：awk 程序在 shell 单引号里，注释里一个撇号（`cleanup_temporary_file_after_make_failure's`）就闭合了引号，脚本当场语法错——与 smoke/10 规则 J 记的是同一类。
  - **smoke/01 的 quiet-grep 锁漏掉跨行管道。** 规则是**逐行**正则，`cmd | \` 换行 `grep -q` 这种排版完全逃过（实测：单行形态被抓、两行形态零命中）。修法：先把逻辑行拼起来再匹配，两种续行都拼（行尾 `\` 与行尾 `|`——后者同样续接命令）。实测两种形态现在都被抓到，仓库内 `repo_pipes=0` 不变。
  - **G-F1/G-F2/G-F3：文档订正。** README 那句「does not prove that any branch behaves correctly」与覆盖表直接矛盾（`03`/`07`/`12`/`17`/`22` 都是行为级证据），改为「按覆盖表的逐项列读」；版本一致性在 `CONTRIBUTING.md` 与 `smoke/01` 注释里仍写「四方」，实际六方（0.1.16 起含两个客户端常量）——代码早已是六方（`smoke/01` 的报错信息就写着 six records），只有注释和文档没跟上；资产行数陈述（`install-client.ps1` 563、`install-agentq.ps1` 3077 且「全仓第二大」、`agentq-server` 5561）**实测已全部失真**（现为 586 / 3182 / 6120，且「全仓第二大」早就不成立），这些不是断言、只有失效风险，直接删除；历史条目里的行数作为当时的快照保留并加注。
  - **0.1.18 发布后自查（用户再问「还有没有问题」），又找到四处，全部进了 0.1.19——前两处是 A-F2 的同族，第三处是我自己的修法打回，第四处（wait 回退）在同一天第三次核查中才浮现。**
    - **回退循环里同一个折叠错（我 0.1.18 当天引入）**：`read_request_record_state_and_body` 写成 `request_record_path_guards_or_fail … || return 2`，理由是「`fail` 退 2、不能与消失(1)混淆」——但 `fail` **永不返回**，它直接在子 shell 里退出，所以这个 `||` 能看到的只有 1。也就是说每一个「消失」都被我变成了「失败」。强制造一次消失（计数门控，只在回退那一次删文件）实测：报 `missing AgentQ request record during recovery` + exit 2，点名的正是**刚消失的那条**。改 `|| return 1`，V6 钉住（判据是「被点名的必须是那条真正不安全的目录记录，不是消失的那条」）。
    - **第三份拷贝：cancellation marker 循环**。`load_cancellation_markers` 的两道守卫失败同样 `fail`——强制造消失实测 **exit 1**——1 本身是契约里的「一般失败」，问题在于它**把一次瞬态竞态报成了硬失败**，并且 stderr 同时写着 `reason=protocol_error`，于是按文档「读 reason、别匹配消息」的调用方会把一次并发删除当成**参数错误**。这正是我在 0.1.17 修 `submit --workdir` 时见过的同一形状（`$( )` 里的 `fail` 只终结子 shell、管道整体却按 pipefail 失败），当时只修了那一个点。marker 不像 record 那样按位置绑定 id，所以**直接跳过**即可（`load_cancellation_markers` 两处 `&& continue`，`cancellation_marker_is_valid` 两处 `&& return 1`，两个调用方各自接住 1）。V7 钉住（exit 0 + 不报 invalid）；`read_cancellation_marker` 的调用方本来就把非 0 当「没有 marker」，零改动。
    - **顺带**：`request_record_vanished` 改名 `tracked_path_vanished`（它现在也用于 marker；名字仍是行为名「这条被跟踪的路径消失了」，不承诺文件类型），`smoke/26` V3 的站点数 5→9。
    - **一条我差点做反的分支（A/B 定案）**：marker 循环拿到非「消失」的失败（jq 拒绝坏 body，rc=5）时，我加了一条 `fail` 分支把它报响，随后怀疑自己——`fail` 在子 shell 里退出、左管道的 2 会被末尾的 jq(0) 盖掉，怀疑它会把 `status` 从「安静继续」变成硬失败。做 A/B 才发现**前提就错了**：0.1.16/0.1.17/0.1.18 的实测都是 `exit 1` + `invalid AgentQ cancellation marker` + `reason=protocol_error`（fail 确实到了顶层，机制我未完全归因——如实记）；而我「按推断撤掉分支以求与原版一致」的版本反而变成 **exit 0 + 只有裸 jq 报错**——因为 `marker_status` 捕获本身就改变了控制流（原版 `|| fail` 直接退出、不打印空行，我的撤版跳过 fail、打印空行、聚合放过）。**教训：「恢复到原样」也必须靠 A/B 测，不能靠读码推断控制流**——这正是本仓反复记过的那类错误，这次发生在我自己身上。最终态与 0.1.17 的 stdout/stderr/退出码逐字一致（proof11 对照），消失方向仍由 V7 钉住。
    - **第四份拷贝（同一天第三次自查）**：`wait_reconcile_missing_task` 的**回退**逐文件循环也是 `$()` + `|| fail`，同一折叠。A/B 实测（把 rm 计数门控到 wait **快路径**那一次，让回退才看到文件已消失）：0.1.18 答 `missing AgentQ request record during wait recovery`，修复后答 `unknown AgentQ task id`（扫描收敛）。`smoke/26` V8/V9 两个方向都钉（消失要跳过、目录仍要响）。**这一处的竞态是真的可达**（不像 V4/V5 只能靠注入逼近窗口）：`wait` 持操作锁，而**免锁的读路径**（`status`/`logs`/`doctor`）的 `migrate_removed_request_records → repair_removed_request_records` 会**在没有操作锁的情况下**归档记录，两者可以真正重叠——持锁不能防止一个不持锁的写者。
    - **墓碑（tombstone）方向查过、判为不可达，未改**：同样注入「读到一半被删」，`wait` 回退答 `missing AgentQ request tombstone during wait recovery`（0.1.18 与修复版**一致**，所以不是本轮引入的）。为什么不像记录那样修：**删墓碑的唯一路径是 `prune_request_tombstones`，它只在 `ensure_request_record_layout` 里被调用，而后者只在 `acquire_operation_lock` 内**；`wait` 全程持操作锁，所以修剪器与它互斥。记录不同：`repair_removed_request_records` 会删记录，而它经 `migrate_removed_request_records` 被**免锁**的 `status`/`logs`/`doctor` 调用——持锁挡不住一个不持锁的写者。这是推断+代码路径核对，没有并发实测；若将来有别的路径在锁外删墓碑，这条结论就要重算。
    - **同类扫描：`read_request_record` 是第五份拷贝，已修（2026-10-22 第四次自查）。** 我上一版在这里写的是「这些单文件读都在持锁路径上，归档器也持锁，所以不可达——推断，不是实测」。**那个推断是错的**，错的不是「持锁」这个事实，而是「归档器也持锁」：`repair_removed_request_records` 确实会在 `acquire_operation_lock` 里跑，但它**同时**经 `migrate_removed_request_records` 被**免锁**的 `status`/`logs`/`doctor` 调用（`status_with_read_lock` / `logs_with_read_lock` / `doctor_with_read_lock` 三个函数体里都直接写着 `migrate_removed_request_records`）。于是 `lookup`/`submit`/`wait`/`remove` 持锁调 `read_request_record` 时，一个**不持锁**的 `status` 可以同时归档记录——持锁挡不住不持锁的写者，这正是同一段里给 `wait` 回退写下的结论，我当时没有把它推广到单文件读。
      - **窗口边界**：能在这条竞态里消失的记录，只可能是**已处于 `removed` 状态**的——归档是唯一的删记录点，而它要求 `state == removed`；`accepted`/`removing` 的记录不会被删。所以受害的调用是「对一条已 removed 的记录做 re-read」。
      - **原来的判据是错的**（不只是「未覆盖」）：0.1.18 对消失答 `invalid AgentQ request record path` + `reason=protocol_error` + exit 2，等于告诉调用方「改你的参数」，而真相是「它已经没了，去看墓碑」。A/B 实测（把 `rm` 注入到存在性检查之后、守卫之前）：0.1.18 → exit 2 + `invalid AgentQ request record path`；修复版 → exit 3 `not_found`（收敛答案），**stderr 一个字节都没有**。
      - **修法**：`read_request_record` 改走共享的 `request_record_path_guards_or_fail`（`|| return 1` 透传消失），读文件改成「先静默 `cat` 进变量、再喂 jq」而不是 `jq < "$path"`——后者在文件消失时会把 bash 自己的 `<path>: No such file or directory` 打到 stderr，而**客户端会把远端 stderr 抓去解析 `reason=`**，于是一次良性竞态仍会在成功调用上留下无法解释的噪音。V10 专门断言「消失时 stderr 必须为空」。
      - **顺带折掉第三份守卫拷贝**：`request_record_is_valid` 是守卫序列的第三份拷贝，且它自己两道守卫 + 调用方两道 = 对同一路径连走四次 `path_chain_is_safe`（每道都逐组件 `[ -L ]`）。它的唯一调用者就是 `read_request_record`，现已并入共享助手并删除该函数；`request_tombstone_is_valid` 同样并入，`read_request_tombstone` 里那对重复守卫一并去掉。站点数 9→12（新增三处读臂：记录、墓碑、`read_request_record_state_and_body`），`smoke/26` V3 同步。
      - **`read_request_record_state_and_body` 的守卫→读窗口也补了**：它原先 `jq … < "$record_path"` 直读，守卫与打开之间的缝隙仍会退化成 `missing AgentQ request record during recovery`——正是守卫的消失臂要消除的那个症状，只是更窄。现在同样先静默 `cat` 再喂 jq。
      - **第六、第七份拷贝（2026-10-23，用户第三次问「还有其他问题吗」时的自查）**：上一轮我写了「墓碑方向不可达，但 `read_request_tombstone` 也用同一套判据」——**那个「也用了」是假的**，代码里并没有。
      - **`request_tombstone_path_guards_or_fail` 的第一条是裸 `fail`**：`[ -e ] || [ -L ] || fail "invalid ... path"`。于是「文件不在」根本到不了调用方，两条下游全部成了死代码——`read_request_tombstone` 的消失臂，以及 `wait` 批处理里我刚加的 `null` 占位符（我加它时没有验证它能被执行到）。A/B 实测（把 `rm` 结构性注入到存在性检查之后）：0.1.18 **和当时的修复树都**答 `invalid AgentQ request tombstone path` + exit 2。补上消失臂后答 exit 3 `not_found`。
      - **`read_cancellation_marker` 的两行直守卫挡在容错校验之前**：它的注释写着「消失即无标记」，但那两行 `request_metadata_file_is_safe ... || fail` 先执行，所以这句话对它自己不成立。这一处**比墓碑那处更严重**：marker 由 `archive_removed_request → remove_cancellation_marker_for_task` 删除，而归档器从**免锁**的 `status` 进来，所以竞态真实可达。A/B：注入消失后 `status` 答 exit 2 + `invalid AgentQ cancellation marker path`（0.1.18 与 0.1.19 一致），修复后 exit 0、记录与 marker 都正常归档。
      - **我在这一轮自己造了一个 bug 并当场抓到**：往 `request_tombstones_states_filter` 里加注释时写了反引号，而那个过滤器是**双引号**字符串（记录侧的是单引号，所以我没警觉），shell 于是去执行 `null` 与 `continue` 两条命令——`smoke/26` 立刻报 `null: command not found`。教训：**jq 过滤器写在双引号 shell 字符串里时，注释不能含反引号或 `$`**。
      - **V14 的注入锚点又一次返工**：第一版锚在修复版才有的 `marker_status` 上，回退到修复前形状时报「夹具打不进去」。改为结构性锚点（存在性检查的 `fi` 之后）后，变异实测为**断言红**。这与 V10 是同一个教训，本轮第二次踩到——**夹具锚点必须落在「所有版本都有」的结构上**。
      - `smoke/26` 83→96 例（V13 墓碑消失、V14 marker 消失、V15/V16 两个反向锁：目录仍要响）。站点数 12→14。
    - **第八、第九处（2026-10-23，同一轮继续扫「读一次、报错去哪」）**：这两处**不会把竞态报成失败**，而是**在成功的调用上往 stderr 泼噪音**——同样有害，因为客户端抓远端 stderr 找 `reason=`。
      - **`cancellation_marker_is_valid` 自己的守卫→读缝隙**：调用方 `read_cancellation_marker` 修好了，但被调用方结尾仍是 `jq ... < "$marker_path"`。注入实测：`status` **exit 0**、stderr 却是 `<path>: No such file or directory`。修法同一套「静默 `cat` 进变量再喂 jq」。V17 钉（exit 0 **且 stderr 必须空**）。**教训：消失臂要修在「每一个打开该文件的点」上，修了调用方不等于修了被调用方。**
      - **精度探针 `grep` 直读文件**：`validate_task_id_precision_in_file` 用 `grep ... "$json_path"`，文件消失时 grep 打自己的错误（实测 rc=2 + stderr），而该函数的循环**不看 grep 的状态**——控制流不变，只多一行噪音。改成「静默读一次、喂 `printf | grep`」，读不到就 `return 0` 交给调用方判「消失/不安全」。V18 钉，且**必须先强制低精度分支**：该函数在 jq ≥ 1.6.3 上**第一行就 return**，本机 jq 1.7.1，不强制则这段代码一次都不会执行（夹具里 `jq_preserves_integer_digits() { return 1`）。变异证明：改回 `grep "$path"` 后 V18 报泄漏。
      - 站点数 14→15；`smoke/26` 96→102 例。
    - **一处查清楚但没有问题**：`task_instance_created_at_is_recorded` 的快路径 `$(<"$path")` 也会被 bash 的重定向错误污染，但整段包在 `{ … } 2>/dev/null` 里、判定只看聚合 jq 的布尔值——消失只让「证据少一条」。A/B 实测 `cancel` 在 0.1.18 与修复树上都是 `unknown AgentQ task id`/exit 2，行为一致，**未改**。
    - **第十二处（同一天第六次自查）：`compact_log` 的非 UTF-8 分支。** `logs` 不是记录读取路径，但它是少数**自己打开文件交给别的进程**的地方，而且**两条分支都错**：`base64 < "$log_path"` 是重定向（消失时 bash 自己报 `<path>: No such file or directory`）；`tail ... | base64` 在 `set -o pipefail` 下让整条管道失败，而唯一的消息是 `cannot encode non-UTF-8 task log`——**把「文件没了」说成「编码失败」**。A/B 实测（0.1.18 与改动前的树一致）：exit 2、stderr 先 `tail: <path>: No such file or directory` 再那条编码消息。现在先捕获 base64 的状态，用 `tracked_path_vanished` 区分「消失」与「编码失败」，各给一条受控消息。V21 钉（判据三条：不得出现 `No such file or directory`、不得把消失说成编码失败、必须带 `reason=`）。站点数 15→16。
      - **退出码的选择**：两条失败分支（消失 / 编码失败）都走 `fail`，即 exit 2 + `protocol_error`——与紧邻上一行的既有条件「raw log 不可用」完全一致（那是同一件事早一行的版本）。没有为「消失」新造退出码：`logs` 的契约里非 0 只表示「日志取不到」，调用方读消息即可，新造码会让相邻两条分支用两种词汇描述同一状态。`smoke/02` 的规则也要求任何 `exit 2` 都带 `reason=`，`fail` 天然满足。
      - **`pipefail` 下的状态捕获，实测过而不是假定**：`out=$(cat -- "$f" 2>/dev/null | base64) || st=$?` 在 `$f` 不存在时 `st=1`（cat 失败经 pipefail 传到整条），空文件时 `st=0`、`out=""`。所以「空」不能当失败信号（合法的空日志也是空串），**状态才是**——这一点写在代码注释里。
      - **V21 的夹具锚点也返工了一次**：第一版锚在修复版才有的 `log_encoded=$(tail ...)` 上，回退到修复前分支时报的是「夹具打不进去」。**这是同一轮里第三次**（V10、V14、V21）。规律已经很清楚：**夹具锚点只能落在「所有版本都有的结构」上**（存在性检查、`fi`、循环体），不能落在修复引入的变量名或语句上；否则变异证明测的是夹具而不是资产。
    - **把这一类钉成规则，而不是逐个修（2026-10-23）**：`smoke/01` 新增一条**构造级**静态锁——资产里不得出现 `cmd < "$f" 2>/dev/null`（`2>` 写在重定向上）。判据是**写法本身**，不依赖「某个文件会不会被删」，所以对还没被跑到过的路径同样有效；判据带 `(^|[^<])`，把 here-string（`<<<"$body" 2>/dev/null`，不是文件重定向、也不会打不开）排除在外。**这条规则第一版有两个错，都是「先跑再信」抓出来的**：一是把 here-string 误报（真阳性假象）；二是命中集为空时 `while read` 仍执行一次、报出一条「没有文件名也没有行号」的违规——空集要先判空。现在 `redir_noop=0`，且植入一处 `cat < "$f" 2>/dev/null` 后规则准确报出**文件:行号**。
    - **收尾核查：另外四处 `$(<path)` 与客户端的一处「疑似同形」，都查清楚了，结论是「不用改」——理由各自不同。**
      - **服务端剩余四处**（repair 快路径、wait 的两条批扫描、`task_instance_created_at_is_recorded` 的快路径）都**整段**包在 `{ … } 2>/dev/null` 里。实测区分过两种写法：`cmd < missing 2>/dev/null`（重定向上的 `2>`）**兜不住**，而 `{ cmd < missing; } 2>/dev/null`（整段包起来）**兜得住**——前者是 shell 在应用重定向之前自己报的，后者把那段 stderr 整体重定向了。四处逐一注入并跑真命令验证：`repair` / `wait-record` / `wait-tomb` / `probe` 全部 **clean**（无 `No such file or directory`）。所以它们的 `exit 码 + 无噪音` 由**外层分组**保证，不需要第五条消失臂；V3 的站点数也因此保持 15。
      - **服务端自己的临时文件（`raw_status_file` / `compact_log_raw_file`）**：`validate_pueue_task_shape_in_file` 等也用 `jq ... < "$path"`，但调用点前面紧跟着 `require_runtime_temporary_file`，而这些文件**只有本进程会删**；跨进程的 `prune_runtime_temporary_files` 按 `process_is_confirmed_dead` 判断，**本进程活着就不会被删**。所以窗口需要「自己的 pid 被判死」——只有本进程已死才成立，而那时也不再有调用。**不改，记为构造上的边界。**
      - **客户端平台缓存**：我一度按同一类缺陷改了 `platform_cache_read`（`sed ... "$file"` 直读），随后核查发现**前提不成立**——该缓存文件**没有任何删除点**（写入是 temp + `mv -f`，rename 原子替换，读者只会看到旧值或新值，永远不会看到「不存在」），所以那个窗口不存在。改动**已撤回**（`git checkout`），客户端保持原样。**教训与上一条同源：改之前先问「谁会在什么条件下删掉这个文件」，没有删除点就没有消失竞态。**
    - **第十一处（同一天第五次自查）：`load_request_records` 的**读**臂。** 这是 0.1.18 最早修的那一处，`null` 占位符也早有覆盖——但覆盖的是**守卫**那一半。读本身仍是 `record=$(<"$record_path")`：替换失败得「正确」（消失臂随后跳过），**bash 的重定向错误照样写到顶层 stderr**。实测 `status` exit 0、记录正确跳过、stderr 多出 `<path>: No such file or directory`。改成 `cat -- "$path" 2>/dev/null`（`cat` 的错误是它自己的 stderr，被重定向吃掉）。V20 钉。**教训**：同一个文件的一处修好，不代表这个文件的**每一个**读点都修好了；而 `$(<path)` 与 `jq < path` 在这一点上同罪。
    - **第十处（同一天第四次自查收尾）：`task_instance_created_at_is_recorded` 的回退循环。** 我先前把它记为「被外层 `{ } 2>/dev/null` 包住、没问题」——**只对快路径成立**。它的**回退**逐文件循环用的是 `created_at=$(jq ... < "$path" 2>/dev/null) || continue`，那个 `2>/dev/null` 写在**重定向**上，兜不住 bash 自己的打开错误。A/B 实测（用一条畸形 tombstone 逼快路径失败、从而走到回退，再把记录在回退读取前删掉）：0.1.18 stderr 多出 `bash: <path>: No such file or directory`，而**退出码与最终消息完全相同**（`unknown AgentQ task id`/2）——所以它不影响判定，只污染 stderr，而客户端正是从这段流里取 `reason=`。改成「先静默 `cat`、再喂 jq」。V19 钉，判据是「不得出现 `No such file or directory`」。
    - **一条关于 `2>/dev/null` 的实测**：`jq -r . < "$f" 2>/dev/null` 在 `$f` 不存在时**仍然**打印 `bash: …: No such file or directory`——重定向错误发生在应用重定向**之前**，那个 `2>/dev/null` 是给 jq 的、不是给 shell 的。这直接推翻「有 `2>/dev/null` 就安全」的直觉；`{ …; } 2>/dev/null`（把整段包起来）才有效，两者是不同层次的。
    - **墓碑方向的结论不变**（删墓碑的唯一路径 `prune_request_tombstones` 只在锁内跑），但 `read_request_tombstone` 现在也用同一套判据——不是因为测到了竞态，而是**两个孪生读者不能对「消失」给出不同答案**；注释里如实写明这是防御性一致，不是实测竞态。
  - **第十三类（2026-10-23，用户第五次问「还有其他问题吗」）：bash 的动态作用域让「少写一个 `local`」变成跨函数写。** 前十二类都在「打开一个文件」这条线上，这一类比它更安静——它不改退出码、不写 stderr，只是让一个函数的值被另一个函数改写。
    - **机制（实测，不是推断）**：bash 的函数没有词法作用域，一次**不带 `local` 的赋值**会沿着调用栈向上找同名的 `local`——找到就写进去，找不到就写全局。两函数探针（`A` 调 `B`，`B` 里裸写 `X`，`A` 里 `local X`）在 **bash 与 dash 上都**证明：`A` 看到的是 `B` 写进去的值。所以「这个变量只在这个函数里用」是一个**只有加上 `local` 才成立**的断言。
    - **扫描**：写了一个扫描器，列出「在函数内被赋值、但该函数没有 `local` 它、而**别的**函数声明过同名 `local`」的全部站点。HEAD 上共 **8 个**（其中 `probe` 只有补齐 `if NAME=` 形态后才现形，见本类最后一段——那条补的是**规则**，但同一轮里也把这个站点修了）。**然后逐个用调用图问第二个问题**：这个函数会不会真的被一个声明了同名 `local` 的调用者压在栈上？——**只有 3 个可触达**：`acquire_operation_lock` 的 `current_epoch`（调用者 `prune_request_tombstones`、`request_tombstones_need_pruning` 都声明了 `local current_epoch`）、`cancelled_task_replay` 的 `marker_created_at`（调用者 `cancel_task`）、`request_tombstone_is_valid` 的 `tombstone_body`（调用者 `read_request_tombstone`）。另 **5 个是全局写、不是跨帧写**：`main` 的 `task_id`/`status_mode`/`doctor_mode`（`main` 是入口、无调用者，调用图上 0 个祖先）、`acquire_operation_lock` 的 `lock_mtime` 与 `task_instance_created_at_is_recorded` 的 `probe`（后两个的调用链上都没有声明同名 `local` 的函数——`probe` 有 3 个祖先，没有一个声明它）。**这一步是必须做的**：只数扫描器命中会把「全局写」说成「跨帧写」，而两者的后果不同——前者污染全局、后者改写调用者的值。
    - **为什么 8 个仍然全部补 `local`**：全局写在函数日后被别的函数声明同名 `local` 时就会**变成**跨帧写，而 `main` 那三个名字尤其容易——`task_id` 在资产里有 30 个函数声明了 `local`，`main` 只要调一个就中。也就是说 4 个不是「没问题」，是「今天没问题、明天可能有问题」。
    - **同一次扫描还找到 10 个规则从不会报的全局写**（`launch_output`、`lock_holder_age`、`log_encoded`/`log_encode_status`、`maintenance_lock_pid_path`、`operation_lock_holder`/`operation_lock_message`、`replay_evidence`、`request_lock_holder`/`request_lock_message`）——它们从未在任何函数里被 `local` 化，规则结构上看不见（`probe` 不算在内：它由规则抓到，属于上面那 8 个）——它们今天只污染全局（只在本函数内读、别处没人声明同名 `local`），一并收紧为 `local`。**这些不是被规则抓到的**，是扫描器的另一张表；如实记在这里，免得 `local_hazards=0` 被读成「全局写都没了」。
    - **唯一的合法例外是 `read_lock_metadata` 的 `lock_pid`/`lock_identity`**：它的契约就是**出参**（每个调用点读完立刻用），在函数头上写了注释说明，静态规则按「函数名 + 变量名」精确豁免。
    - **锁：`smoke/01` 新增第四条静态规则（`local_hazards`）**——扫描服务端资产，凡是「函数内赋值、该函数未声明 `local`、而另一函数声明过同名 `local`」即失败（出参对豁免）。**这条规则自己死了两次**，两次都是「先跑再信」抓出来的：① `split()` 用空白分隔时，缩进行会产出**空的首元素**，而 `local` 本身也是一个字段，第一版从 `i=2` 起算，于是 `declared[]` 里只有字符串 `"local"`，规则在**含违规的文件上**报 0；② 取变量名时 `sub(/.*[^A-Za-z0-9_]/,"")` 是贪婪的，而匹配段以 `=` 结尾，整个名字被吃掉、`seg` 恒为空。修好后红/绿五向实测：活树 0 命中；植入 `acquire_request_lock` 里裸写 `maintenance_lock_pid_path` → 点名；同函数补上 `local` → 静默；把 `main` 的 `local task_id` 还原掉（真实的修复前形状）→ 报 `main: task_id`；关掉豁免行后活树恰好只报那 2 个出参，等于量出了豁免清单的宽度。**另一条路我也试过并撤回**：把赋值判定改成「前一个字符是分隔符即为赋值」，结果把 `LC_ALL=C ps` 这类**命令前缀赋值**和 `if probe=$(...)` 一并报出——它比原判据**更宽**，不是更可移植，当场撤回。
    - **规则自带自检**：因为上面两次「静默全绿」正是这类规则的典型死法，`smoke/01` 现在**每次运行都往一份临时副本里植入一处违规**，要求同一个 awk 程序报出来；植入点锚在 `acquire_request_lock() {` 这个**函数头**（每个版本都有），不锚在任何修复引入的语句上——否则锚点漂移时报的是「夹具打不进去」，而那是另一种假绿。自检还顺手堵住了另一类：把规则改坏（模拟上面两种死法）后，自检报「the detector itself is broken」，而不是静默通过。
    - **边界**：这条规则只认 `name=` 形态的赋值（`for`/`read`/`printf -v` 等赋值形态不在内——实测资产里 `for` 循环变量与 `read` 目标都已有 `local` 或不受此规则影响，但这是**本资产**的事实，不是规则的保证），且只在「同名在别处声明过 `local`」时才报。规则是静态的：它证明的是「这个写法不存在了」，不是「运行时的值一定正确」。**它不覆盖**「全局写」那一类（上面那 10 个）——要覆盖就得配一张豁免表把 `IFS`、环境变量、`trap` 变量全排掉，锁会退化成一张随时失真的表，所以刻意不做。
  - **第十三类的补锁（同日晚些，用户「全部优化好」）：静态规则的解析器看不见嵌套函数，扫描根只有一个文件——两个都补上。**
    - **嵌套函数盲区**：服务端在 `install_jq_line_ending_shim` 里嵌着定义了一个 `jq()` 包装（缩进 4 格）。规则的函数头正则只认**列 0**的定义，于是嵌套函数体被算进外层函数——里面的一次无 `local` 赋值会被**归错函数**。变异实测：在 `jq()` 里植入 `tombstone_body=/tmp/planted`，旧解析器报 `install_jq_line_ending_shim: tombstone_body`（外层函数名），新解析器报 `jq: tombstone_body`（正确的函数名）。归错名字在今天不改变判定结果（反正都要报红），但自检断言「报出正确的函数名」之后，这类漂移就成了可见失败。新解析器按**定义处的缩进**配对闭合花括号，五个探针（活树/HEAD/植入/同函数补 local/main 还原）结果与旧解析器完全一致；全部 7 个被扫描资产里，6 个含函数定义（唯一的 0 是服务端那把 60 字节 wrapper `skill/assets/unix/agentq`），SEEN_FNS 与 grep 计数逐一一致、FINAL_DEPTH=0（没有任何函数没闭合）。
    - **扫描根扩到全部 7 个 shell 资产**：与 quiet-grep 锁从 31 扩到 38 同一纪律——只锁「发现它的那个文件」的锁有一个单文件洞。但**如实记录今天的事实**：POSIX 客户端、`sshp`、两个安装器**从未使用过 `local`**（grep 到的 12+3 处 "local" 全在注释与字符串里），所以这条规则对它们结构性空转——`declared[]` 为空，任何赋值都报不出来。今天真正能触发的只有服务端的两份 canonical 拷贝。扩面的价值在于：任何日后新增的、用了 `local` 的 shell 资产自动被覆盖，不用记得再改锁。
    - **客户端的全局变量约定（查清了，不动）**：客户端 105 个函数、255 个赋值名、**0 个 `local`**，39 个名字在一个函数里赋值、在另一个函数里读——全是**刻意的全局出参**：临时文件路径与 identity 由各函数登记、由 `cleanup_client_runtime` 统一清理；`ssh_binary`/`json_parser`/`stat_flavor` 是一次性解析的全局配置；`remote_platform`/`windows_probe_*` 是探测结果的传递。`run_platform_probe` 中途把 `platform_probe_log_file` 置空是注释写明的「identity-gated 清理」约定（identity 记不下来时**保留文件**、清掉路径，免得清理器拿空路径做 identity 校验的删除）。`for` 循环变量全在各自函数内声明 `local`（18 个站点逐一核对）。这个约定的风险（两个写者互相覆盖）与两个写者的场景（`agentq_remote_failure_reason_value` 在 `run_ssh_logged` 与 `run_wait_ssh_with_timeout`）都在不同的执行阶段，行为测试（`smoke/05` 的 env 面、`smoke/28` 的信号）覆盖了这些路径。**没有为「不用 `local`」立规则**：那会把 255 个名字全报出来，锁退化成噪音。
    - **同一条纪律用在「文件清单」上**：三个静态锁（quiet-grep、redirect、local-hazard）原本各自把「哪些是 shell 资产」那串 `find ... -name ...` 拼写一遍——三份拷贝。改成在脚本开头算一次 `shell_assets`，三个锁共用。红证：把清单换成匹配不到任何东西的 `find` 后，闸门报 `no shell assets were enumerated for the static shell rules; refusing to report a pass` 并 rc=1（此前三条锁在空清单上都是**静默全绿**）。闸门**放在清单的定义处**、不放在任何单个消费者上——我第一版就把它写在了 local-hazard 那一段，随后发现 redirect 锁**根本没有**自己的空清单检查，而 pipe 锁的计数还包含 smoke 脚本、结构上不可能发现资产清单为空；三份消费者各设一道门，正好又是「改一处漏两处」。三条锁各自植入违规后仍逐一点名（quiet-grep 报 `sshp:1327`、redirect 报 `sshp:1327`），还原后 `repo_pipes=0 redir_noop=0`。
    - **规则本身漏掉了第八处：`if NAME=` 形态。** 加完嵌套解析器与扫描面之后，我**再问了一遍「这个扫描器看不见什么」**，答案是一个 bash 赋值形态：`if NAME=$( ... ); then`。第一遍循环的前导字符集合是 `^ ; & | then do else`，**没有** `if`/`elif`/`while`/`until`——这四种之后也跟赋值。实测它藏了一个真实站点：`task_instance_created_at_is_recorded` 里的 `if probe=$( {...} | jq ... )`，而 `install_jq_line_ending_shim` 声明了 `local probe`。**这个函数今天不在那条调用链上**（算过可达集：114 个函数里不含它），所以它是「全局写」而不是「今天的跨帧写」，与另外 10 个同类。仍补上 `local probe`——理由与那 10 个一样：全局写在函数日后被声明同名 `local` 时就会变成跨帧写。修法与它们一样，是**改资产**；但规则也要能看见它，所以加了一遍**独立的关键字扫描**，且关键字必须**独立成词**（前一字符不是词字符），否则 `otherwise_x=`、`verify_x=` 会被当作 `else`/`if` 而报出一个不存在的变量——这条边界用夹具实测过。第一版我图省事把这四种塞进了**同一个** `match()` 的字符集，那样会把 `if x=$(...)` 里的 `x` 也当成赋值没问题，但也会把 `if [ -n "$x" ]` 之后的……实测结果是它同时报出了 `probe`（对的）与几个不存在的名字（错的），所以拆成两遍、各用各的判据。
    - **第三个盲区：注释里的赋值被当成赋值。** 关键字那遍扫的是整行，于是行尾注释里出现 `# if zzz=2` 会被读成一次真实赋值。夹具实测：一个只写了 `a=1 # if zzz=2` 的函数被报成持有 `zzz` 的裸写。修法是在关键字扫描里先定位 `#`，越过后不再匹配。**方向是刻意选的**：这个判据**不解析引号**，字符串里的 `#` 也会被当作注释起点——那只可能让规则**漏掉**一个真实站点，永远不会凭空造出一个（凭空造出会红掉一棵正确的树，而漏掉只意味着少报一次）。与这条规则一贯的取向一致：宁可漏报，不可误报。
    - **第四个盲区：`NAME+=`（追加赋值）。** 两遍扫描的匹配都以 `NAME=` 结尾，于是 `record_ids+=("$id")` 这种**追加赋值**完全看不见。它比 `NAME=` 更危险：`NAME=` 是**覆盖**调用者的同名局部，`NAME+=` 是**往调用者的数组里追加**——调用者读到的是一个更长、更陌生的值，而不是一个明显错的值。实测资产里有 7 处这种形态（`record_ids`、`tombstone_ids`、`log_args`、`combined`），今天都在各自函数里声明了 `local`，所以没有真实站点；但规则看不见这一类，下一个写它的人就没有保护。改为 `NAME(\+=|=)`，并给自检加**第三个植入点**（`log_encoded+=`）。**第一版我把交替写成了 `\+=?=`**，那要求一个 `+`，于是普通的 `NAME=` 反而不匹配了——自检当场报「silent on a planted violation」，这是自检第一次抓到我自己改坏规则。改成 `([+]=|=)` 而不是 `(\+=|=)`：POSIX ERE 没有定义 `\+`，而方括号里的 `+` 在所有 awk 上都是字面量——本行上方那段注释刚说过「这条规则要在每个 awk 上读同一个结果」，用它自己的判断标准，`\+` 就该换掉。
    - **反向验证：规则看不见的赋值形态还有哪些。** 把所有 `NAME=`/`NAME+=` 站点逐个问「前一个字符是不是规则认可的分隔符」，**只剩 1 个**：`LC_ALL=C ps ...` 这类**命令前缀环境赋值**——它不是 shell 变量写入（只作用于那一条命令），规则刻意不管它。除此之外没有遗漏形态。`declare`/`typeset` 在资产里一处都没有（grep 实测），所以不需要为它们写判据。
    - **自检加强（三处植入，一处一遍/一形态）**：自检现在植入**三个不同名字**的违规——`maintenance_lock_pid_path` 给普通赋值那遍、`lock_holder_age` 给 `if NAME=` 那遍、`log_encoded+=` 给追加赋值那支——并分别断言报出**正确的函数名**。红证：删掉关键字那遍 → 自检报「missed the `if NAME=` plant: that pass is not running」；删掉普通赋值那遍 → 自检报「missed the plain NAME= plant」。**植入必须分两条 `sed` 做**：BSD sed 的 `a` 命令在第一个非续行处结束，一次 append 里写两行会**静默截断**（实测：`sed '...a\
  line1
  line2'` 只插进 line1）。
    - **自检加强**：自检现在同时断言「报出的函数名是 `acquire_request_lock`」——不只要求非空，还要求**归对函数**（上面那个变异证明旧解析器会归错）。
  - **第十四类（2026-10-24，用户问「全部优化好了吗」后的自查）：服务端有 7 个从未被调用的函数，其中 3 个是在用校验器的逐行孪生。**
    - **怎么找到的**：不看代码，先做一次调用图扫描——对每个 `name() {` 定义，数「定义行之外」的出现次数，并单独查 `$name` / `${name}` 这两种动态调用形态，再对全仓 grep 与 `git log --all -S` 交叉。7 个全部为零，且没有任何动态引用。
    - **危害不是「代码冗余」，是孪生分叉**：`validate_pueue_task_id_precision_in_text` / `_task_shape_in_text` / `_log_shape_in_text` 与在用的 `_in_file` 版本**除读取方式外逐行相同**。2026-10-23 那轮修「文件读取途中消失」时只修了 `_in_file`——死孪生**当场就分叉了**，只是它不跑所以看不出来。这类结构下一次修 `_in_file` 时同样不会传播过去，一旦有人「把死代码接上」就带进旧 bug。`git log --all -S'validate_pueue_task_shape_in_text "'` 为空：**从本仓有 git 起就没有任何调用**。
    - **另外四个**：`require_agentq_task` 是两行包装（调 `compact_task` 再调 `report_compact_task_failure`），三个 `*_with_operation_lock` 是 0.1.11 读免锁改造的遗留。**判断前先查了注释**：`doctor_with_operation_lock` 的函数头自己写着「No caller today, but the omission was a live trap for the first one」——那是**刻意的 API 面**，不是遗忘。结论是「删或点名保留」的二选一，不是无脑删；本轮选了删，并在规则里留了白名单机制供将来保留。
    - **锁：`smoke/01` 第五条静态规则 `uncalled=0`**。判据是单遍 token 计数（`split` 于 `[^A-Za-z0-9_]+`）、跳过定义行，所以「自己声明自己」不算引用；函数名只含 `[A-Za-z0-9_]`，token 边界与原来的 `(^|[^A-Za-z0-9_])NAME([^A-Za-z0-9_]|$)` 是同一集合。第一版是「每个(函数,行)对跑一次动态正则」——176×6400——改成单遍。**实测澄清一处我写错的归因**：我一度在注释里把整条检查 92s 归给这条规则，实测「拆掉它 62s / 留着 53s」，50–90s 的波动属于 pwsh AST 那段，**不是**这条规则；注释已改。
    - **规则自己第一次是死规则**：把比较改成 `refs == 999` 后整条检查**全绿**——正是这条规则要抓的死法。补了自检（植入 `zz_planted_uncalled_helper`，必须按名报出）；改坏规则后自检报 `the detector itself is broken`。另加一道「看得见函数吗」闸门：扫描到的函数定义数 < 50 即报错，防止解析整体失效时静默通过。
    - **顺带更正一条现时态文档断言（`docs/performance.md`）**：实测补充二写着「调用链是 `status_with_operation_lock` → 锁把扫描串行化了……N 个并发 `status` 在锁内串行做 N 次全量扫描」。0.1.11 起派发走 `status_with_read_lock`（`ensure_not_in_maintenance` → `recover_stale_operation_lock_for_read` → `migrate_removed_request_records` → `status "$@"`，**不取操作锁**），所以：调用链名字已不存在（本轮作为死代码删除）、并发 `status` 不再排队而是**同时**各跑一次全量扫描、「锁把扫描排成队」对 `status`/`doctor` 不再成立（写路径仍然成立）。**原条目保留**（它记录的是 2026-09-24 那次排查的转折点），另加更正块；**并发读的新代价没有重测**，如实标为未验证——不能把「现在不排队了」写成「现在更快了」。`docs/plan/a-class.md:943` 的同款叙述有明确日期与「在此更正」的语境，按「历史条目不改写」保留。
    - **边界**：`uncalled=0` 是静态文本扫描，通过变量（`$cmd`）或跨文件调用的函数会误报；当前 7 个资产里两者都不存在（`$name` 引用扫描为空、每个资产自足）。它证明的是「没有零调用的函数」，不是「留下的函数都被正确调用」。
  - **本轮没有解决、如实记下的**：`load_request_records` 的消失窗口**仍然无法端到端命中**（几微秒，无钩子），所以 V4/V5 是**变异证明**而不是「真实竞态的复现」——它们证明的是「这条分支存在且被正确实现」，不是「这个竞态会发生」。真正的竞态由并发归档器产生，本仓的合成运行时造不出来。
  - **第十五类（2026-10-24，同一轮自查）：PowerShell 变量名不分大小写，9 个文件里的 `$profile` 撞上自动变量 `$PROFILE`。**
    - **怎么找到的**：换一个本仓从未用过的维度跑独立检测器——PSScriptAnalyzer 全量（此前只借它的 5.1 兼容 profile 复核过规则三）。`PSAvoidAssignmentToAutomaticVariable` 报 **15 条，分布在 6 个 `.ps1`，全部指向 `$profile`**：launcher（4）、start-daemon（4）、install-agentq（3）、install-client（2）、agentq 客户端（2）。
    - **为什么这不是风格问题**：PowerShell 标识符不分大小写，`$profile` **就是** `$PROFILE`——运行时自动变量，值为当前用户的 profile 脚本路径（一个看似合理的字符串）。同类的先例是 0.1.16 第十轮的 **`$lastExitCode` P0**：`$lastExitCode` 就是 `$LASTEXITCODE`，脚本作用域赋值把整数换成 PSVariable，Windows 任务全部报 exit 2、真实退出码丢失。两案同一类：「变量名与运行时变量同形（不分大小写），读写落错对象且无报错」。
    - **实测边界先量再改**（pwsh 7.5.4，macOS）：**函数作用域**内赋值只遮蔽局部、退出函数即恢复，`$PROFILE` 不被污染——launcher 的 `Get-CurrentWindowsUserEnvironment` 等都是函数内赋值，所以这是**潜伏缺陷**而非正在生效的故障；**脚本作用域**赋值确实改写 `$PROFILE`。2026-10-21 的 Windows 测试机端到端跑过这些行没有报错，**但那台机上的 PS 5.1 赋值语义没有单独实测**（本机无 Windows）——所以本轮只声称「这行代码在 5.1 上跑通过」，不声称「5.1 上脚本作用域赋值同样安全」。
    - **修法一（`.ps1`）**：6 个 `.ps1` 的 `$profile` 全部改名 `$userProfile`（88 处、79 行；近名 `$profileItem`/`$profileKey` 不受 `\b` 边界保护误伤——改名脚本里加了断言）。改后 PSSA 该规则 **0** 条、7 文件 AST 解析 0 错。
    - **修法二（**修法一没覆盖到的地方**）**：`$profile` 还出现在 **3 个 shell 资产内嵌的 PowerShell 载荷**里——服务端两份 canonical 拷贝各 3 处（`-Command '...'`）、`client/unix/sshp` 的 `windows_common_script` 11 处，共 43 处。**同一个检测器看不见它们**（PSSA 只看 `.ps1` 文件），**我自己的规则也看不见它们**（规则按 `.ps1` 扩展名枚举文件）。这是本轮最值得记的一条：**扫过 `.ps1` 之后，「资产都查过了」这句话是假的**。这 43 处同样改名，改后内嵌载荷单独抽出来跑 PSSA：只余 2 条 `PSAvoidUsingEmptyCatchBlock`（探测进程路径的 `try{...}catch{}`，刻意吞掉「进程路径取不到」，与 `.ps1` 侧已核过的那 10 处同款），无其它告警。
    - **锁一：`smoke/01` `ps1_static` 第四条规则**——名字表覆盖三种写入形态（赋值左侧、`foreach` 循环变量、`param()` 参数；三臂各自植入验证过，不是死代码）。名单**刻意不含**偏好变量（`$ProgressPreference` 按设计可赋值，资产用了 4 次）与 `$null`（`$null = …` 丢弃惯用法）——一条会报合法代码的规则会被关掉。作用域限定写法（`$script:profile`）记为盲区。**交叉验证**：对修复前形态，规则四与 PSSA 的报告在 `.ps1` 上**逐行一致（15/15，同文件同行号）**；标定夹具扩到 legal=0 / defects=7（新增 `$profile`、`$LastExitCode` 两个必报写入与 `$userProfile`/`$profileItem` 两个必须放行的近名）。红证：把改名整体撤回（6 文件 88 处）→ 报 15 条 rc=1；还原 → 0 条。
    - **锁二：把扫描面从「`.ps1` 文件」扩到「shell 资产里内嵌的 PowerShell」**——载荷提取按 **shell 引号语义**（单引号串到**第一个** `'` 为止），不是「找下一个引号」：服务端那个 `-Command '` 块按天真算法会**越过结尾 187 行**、把后面的 shell 代码当 PowerShell 解析。提取到的载荷用**同一套规则**检查，行号按载荷起始 shell 行回填。双引号载荷单独处理：shell 会先展开它，静态上无法断言，所以**报告而不是跳过**（服务端那条 `-Command "Get-ScheduledTask -TaskName 'AgentQ Pueued' ..."` 正是这种，今天无 `$`、以后永远查不到）。载荷内出现**撇号**会让提取截断——不静默：截断后的载荷解析失败被当作**违规**报出（`-ParseErrorsAreViolations`），红证为往载荷里插一个 `'` → 报 `embedded PowerShell does not parse` 且 rc=1。计数闸门：单引号载荷必须恰好 9 个、双引号恰好 2 个，否则退 2——提取器失效能被看见而不是静默全绿。
    - **锁三（自检时踩到并当场修掉）：PowerShell 变量名不分大小写这条规律，连这条规则自己也会踩。** 规则的行号换算原本写成脚本块 `$L`，而规则一里有 `$l = $a.Left`——`$l` **就是** `$L`，规则一先把脚本块变量换成 AST 节点，再由规则四去读它，于是报出「`$protocolProbe` is not recognized」这类**与缺陷无关的错误**（第一批实测就是 8 条这种噪音、真实违规 0 条）。改名 `$LineOf` 后正常。这与 0.1.16 那个 P0 **完全同形**：不是「应该注意」，是**同一条规律在同一天以另一种形式再现**。另实测 ForEach-Object 的脚本块在**当前作用域**执行（计数能累加），而 `& { }` 在子作用域（计数会静默丢失）——后者会制造一个「违规数恒为 0」的假绿，故计数器刻意用前者并把这条实测写进注释。
    - **边界**：`$lastExitCode` 被 PSSA 视为**可写**自动变量（实测：PSSA 不报它），但它正是本仓 0.1.16 的 P0，所以名字表是 PSSA 判定集的**超集**（实测逐个探针比对：PSSA 标 38 个，本表 41 个，多出 `lastexitcode`、`switch`、`foreach`）。偏好变量与 `$null` 刻意排除。作用域限定写入与表外名字仍是盲区。

