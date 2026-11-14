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
2. **一半代码凭什么被相信** —— 现役口径为 **417 行 / 34,514 = 1.21%**
   （2026-11-12 复核，见第六节；`docs/verification-status.md` 的覆盖表是它的逐项账本）。
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

- `client/unix/sshp`（**1,534** 行；**1,235** 是 2026-10-14 的复核值，**1,346** 是 2026-10-28 第四十六类的值，第四十七类改到 1,487、第四十九类改到 1,534）：本地契约 **134 例**（`smoke/19`，2026-10-02 新增；2026-10-07 加 `--check` 重试预算，2026-10-12 加两条 trap 位置锁，2026-10-28 第四十五类加 18 例「远端脚本执行矩阵」、第四十六类加 21 例「Windows 目标脚本矩阵」、第四十七类加 56 例——会话命令 30 + 长度上界单位矩阵 26——第四十九类加 4 例「`-x` 是权限不是承诺」——均见下）。
  覆盖参数校验、环境变量校验、`--help`、探测分派（含 `--check` **不得安装**）、
  重连策略、实际 argv、TMPDIR 零残留，以及会话名的注入守卫。
  **任何真实远端仍是零覆盖**——桩证明的是 sshp **发出什么**；交互会话本体、
  Windows 路径、远端安装路径都未覆盖（见 `smoke/19` 头注释的边界清单）。
  **第四十五类起，两个客户端内嵌的远端探针/安装脚本本身有了执行覆盖**：四个 body
  从两份资产里抽出后**逐字节**互比，并在只含一个撒谎 `uname` 的假 PATH 上按 8 行
  探针矩阵 + 5 行安装矩阵各自断言绝对期望。此前 `smoke/14` 只量长度、`smoke/20`
  只验证编码、本检查的 `plan_stub` 喂的是预写 marker——四个脚本从未被执行过，
  而两份实现答案不同（`FreeBSD + tmux` 一侧 READY 一侧 127）。

`client/windows/sshp.ps1`（1,440 行；1,179 是 2026-10-14 的复核值，第四十五至四十八类各改过）**不再属于「从未被执行过」那一类**：`smoke/20`
（2026-10-02）在 pwsh 里真跑它 `--check`、捕获它实际发给 ssh 的 argv 并断言往返。
但要说准：那是**一条路径**的断言（脚本怎么交给 ssh），不是它的本地契约——
它的参数校验、会话建立、Windows 路径仍未覆盖。

仍然**没有任何检查执行过**的资产（"执行过" = 行为执行或源码断言；只有 `01` 的
语法/结构解析不算；从资产中**抽出单个函数**执行的算覆盖该函数、不算执行过整个
资产）。按行数：`agentq-start-daemon.ps1`（268），
2 个 `.cmd` 薄启动器（8），
2 个 `.plist` + 2 个 `pueue.yml` + 1 个 `.service`（110），以及 `unix/agentq`（5，
只是转发 shim）。合计 **417 行 / 34,514 行 = 1.21%**（**2026-11-12 按当前字节重算**：分母 27,821→34,514（+6,693 行、+24.1%），分子 391→417——增加的全部是 `agentq-start-daemon.ps1` 268→294 与 declarative 配置的少量增长；口径与 2026-10-14 那次**完全相同**（"执行过" = 行为执行或源码断言，只有 `01` 的语法/结构解析不算，抽函数执行算覆盖该函数、不算执行过整个资产）。上一版分母 27,821 来自 0.1.10 落地后：`agentq.ps1` 2,516→2,522（stdin 读循环重写 +6）、`agentq-launcher.ps1` 442→466（env 块 try/catch +24）、POSIX 客户端 3,815（单行 wrapper 等长替换）；分母 0.1.8 后为 27,782。更早：`skill/assets/` 全部 23 个资产 `wc -l` 之和 = 27,415（2026-10-12 **第二轮**全维度审查修复使客户端 `agentq` 3,712→3,725、`sshp` 1,215→1,223（trap 形态与 reason 清零共 +21 行，四处版本常量 0.1.5→0.1.6）；同日**第一轮**修复使 `agentq-server` 5,399→5,464（净增 65 行修复注释与折叠）、客户端与两个 `.ps1` 亦增；同日早些时候的 dash/POSIX 修复与死变量清理曾使客户端 3,688→3,697）；此前为 27,394（2026-10-12 第一轮）、此前 27,216（2026-10-12 早些时候）、此前 2026-10-11 为 27,207、2026-10-10 为 27,199（`agentq-server` 随**路径守卫折叠**等改动在 5,395↔5,399 间小幅变动，折叠本身**净增 4 行注释**（4 守卫折到 2 守卫各留一段说明），故 27,199 → 27,207）；再往前 A31 使 `agentq-server` 由 5,388 增至 5,395，wrapper/客户端冲突修复（`install-client.sh` +16、`install-agentq.sh` +22）与原生 Windows jq 的 CRLF 修复（`agentq-server` +56）亦推高过它。**分子仍是 391**——这几处改动都不在这张表里，故未变）。
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
`agentq`/`sshp`），此前只有 `01` 的 `bash -n`。剩下的 417 行里，**没有一个资产超过 294 行**，
且其中 294 行的那个（`agentq-start-daemon.ps1`）已实测确认在 macOS 上不可**整体**执行（`smoke/22` 覆盖的守卫等除外，见上）；余下的是
2 个 `.cmd`（8 行，`01` 已有结构断言）与声明式配置（`.plist`/`.yml`/`.service`，110 行）。
分母已于 **2026-11-12 重算为 34,514**（`skill/assets/` 全部 23 个资产 `wc -l` 之和，实测；此前为 27,821，2026-10-14 记的值）。**分子 417 的构成**（逐项按当前字节）：`agentq-start-daemon.ps1` 294（整个资产仍不可执行，`smoke/22` 只覆盖它的两个路径守卫、`Set-AgentQUserEnvironment` 与三处拒绝站点）、2 个 `.cmd` 8（`01` 有结构断言）、2 个 `.plist` + 2 个 `pueue.yml` + 1 个 `.service` 共 110（声明式配置：`01` 做 XML/YAML/结构解析、`10` 做渲染占位符守卫）、`unix/agentq` 5（转发 shim）。
别再引用旧的 25.9%、13.8%、4.8%、1.6%、1.5%、1.4%、391、27,821、25,536 或 26,264。

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
  - **`SSHP_SSH` 的两侧守卫不同**（POSIX 查 exec 位、ps1 查非 reparse）：两侧的**威胁模型**本就不同（Windows 无 exec 位），不是同一属性的两个实现，记为平台差异而非缺陷。**2026-10-30 补充：这句话只覆盖「形状守卫」，不覆盖「起得来吗」**——`agentq.ps1` 自 2026-10-21 起会真的启动一次来回答后者，`sshp.ps1` 当时**没有**跟上，于是同一输入 POSIX 退 2、Windows 退 1 并把本地错误报成远端故障（并在 macOS 上打开了那个文件）。那是**缺陷**，已按第四十八类修复；「形状守卫按平台不同」这一半的结论不变。
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
  - **P1：`smoke/28` 的三个信号用例是同一个 TERM 用例跑三遍。** 桩里硬编码 `kill -TERM`，循环变量 `$signal_name` 从未传进去。而且 INT 用例结构上不可能成立——非交互 shell 启动的后台作业**以 SIGINT 忽略开始**，被忽略的处置无法被 trap 接管。修法：桩读 `SMOKE_SIGNAL`；INT 经一个「恢复 SIG_DFL 再 exec」的 perl 启动器（exec 保持 pid，桩仍能信号到正确的进程）；无 perl 时报 NOT-covered 而不是静默通过。**（2026-11-01 第五十七类更正：那两条都错了——perl 版让 INT 覆盖取决于一个与检查无关的解释器，而 NOT-covered 与 `not-covered-known.txt` 的闸门相撞，在没有 perl 的主机上把整条套件判红。现在用作业控制 + 就地校准，见第五十七类。）**红证：把两处 trap 改成「只清理不退出」→ 三个信号全部报红（含 INT），静态锁也独立报出。
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
  - **第十六类（2026-10-24 紧接一轮，用户再问「还有其他问题吗」）：五个 `#!/bin/sh` 资产的语法锁校验的是错误文法。**
    - **怎么找到的**：不再换检测器，改问「这条链路上每个工具**校验的是哪种语言**」。`smoke/01` 对全部 shell 资产跑 `bash -n` 与 `zsh -n`，但其中 5 个声明 `#!/bin/sh`（`client/unix/agentq`、`client/unix/sshp`、两个安装器、`unix/agentq` 包装器）——Debian/Ubuntu 上 `/bin/sh` 是 dash。bash 的文法**接受** dash 拒绝的构造，所以这两条解析器对它们不是「宽松一点」，而是**答非所问**。
    - **红证（实种进真实资产，不是想象夹具）**：在 `client/unix/agentq` 尾部加一个未调用函数 `zz_planted_bashism_probe() { arr=(x y); }`，然后跑每一层——`bash -n` exit 0、`zsh -n` exit 0、`shellcheck -s sh -i SC2319,SC2034,SC2221,SC2222` exit 0、**整个 `smoke/05`（cases=45，含用 dash 真跑客户端）全绿**，只有 `dash -n` 报 `Syntax error: "(" unexpected`。
    - **行为锁为什么不能顶替**：dash **惰性解析**——函数定义在执行流走到它时才被解析。`--version` 路径在读到文件尾部之前就退出，所以实测**种了 bashism 的客户端在 dash 下 `--version` 仍然 exit 0**。换句话说，「dash 能跑通我们测的那些路径」与「dash 能解析整个文件」是两件事，前者远弱于后者。这也解释了为什么 0.1.4 那次是「**先于任何诊断就崩**」：那次 bashism 在**顶层**执行路径上。
    - **修法**：`smoke/05` 新增 POSIX 解析臂——按 shebang 逐个 `dash -n`（声明 bash 的两个 canonical 孪生跳过，它们的 bash 语法会被 dash 正确拒绝）。计数闸门：扫到的 `#!/bin/sh` 资产少于 5 个即拒报通过。双向自检：自建的最小合法 POSIX 夹具必须解析通过、同一夹具追加 bashism 后必须被拒。摘要新增 `posix=checked(5)`；`dash` 缺失时 `posix=skipped(dash-absent)`，被 run-tests.sh 归入 PART（`skipped` 词表，与 `shellcheck=absent` 同理）。CI 的 linux job 把该 token 一并钉进断言。
    - **落点为什么在 `05` 而不是 `01`**：01 在 macOS 的 `--quick` 里也跑，而 macOS **没有 dash**（`/bin/sh` 是 bash 3.2）——放 01 会让 macos job 恒为 PART。05 只在 linux 全量 job 跑，那里 dash 必然存在。
    - **自检的第一版有个设计缺陷，被红证当场发现**：我拿 `client/unix/agentq`**本身**当「必须仍然能解析」的对照，于是种 bashism 时两个方向同时触发，除了真因还多报一条 `the detector is over-matching`——**自检不能依赖它所守护的对象**。改成两个独立的最小夹具后，红证只剩 1 条（真因）。
    - **边界**：`dash -n` 只抓 **parse 级** bashism。能在 dash 里解析、只是**语义**不同的构造（如某些 `set -e` 交互、`local` 的返回值差异）不在其内——那类仍归 Linux CI 的行为覆盖与人工判断。今天 5 个资产的 `dash -n` 全为 0，这是**新增的一层**，不是修掉了某个现存缺陷。
  - **第十七类（2026-10-24 同一轮）：`.ps1` 里出现 PowerShell 7 专有语法，5.1 连解析都过不去。**
    - **怎么找到的**：顺着第十六类的问题继续问「同一批资产，还有哪个运行时从没解析过它们」。`agentq.cmd` / `sshp.cmd` 调的是裸 `powershell.exe`——在真 Windows 上就是 **5.1**；而套件里的解析与行为检查全部跑在 **pwsh 7**（`smoke/12`、`13`、`20`、`22`、`23`、`25`、`01` 的 AST pass）。规则三已经在管「Core-only 的 .NET **API**」，但**语言语法**这一层没人管。
    - **今天是零命中，但这不是「没问题」，是「没人看过」**：先做了一次轻量扫描，`.ps1` 里 grep 到 `??`/`&&`/三元/`?.` 共十几处命中，看上去像灾难；**随后用 tokenizer 复核，全部是字符串或注释里的普通文本，真实 token 数为 0**。这一步很重要——grep 在这类问题上会给出**假红**，而假红会让人去改正确的代码。记下来是提醒下一个人：先过 tokenizer，再决定要不要动手。
    - **修法：`smoke/01` `ps1_static` 第五条规则「禁止 PS 7 专有语法」**。判据是 **token kind**，不是文本正则——这样字符串与注释天然免疫。实测（pwsh 7.5.4）各构造的 kind：`??` → `QuestionQuestion`、`??=` → `QuestionQuestionEquals`、`&&`/`||` → `AndAnd`/`OrOr`、三元 `?` → `QuestionMark`。**两个容易写错的点都实测过**：① `?.` **没有**专属 kind，`$x?.y` 会词法成一个**变量 token**、其文本以 `?` 结尾（所以规则里另有一臂判 `Kind -eq 'Variable' -and Text.EndsWith('?')`；没有任何合法标识符以 `?` 结尾）；② `:` **不能**进表——它与 `switch` 分支标签的分隔符、未加引号的哈希键是同一个 kind，收进来会对合法代码叫狼。`Where-Object` 的别名 `?` 是 `Kind=Generic`，因此别名安全（实测）。
    - **红证（双向）**：缺陷夹具里每种构造各一处 → 报 5 条（`??`、`&&`、三元 `?`、`?.`、`??=`），标定 defects 7→13；再把 `??` 分别种进一个真实 `.ps1` 与 `sshp` 的内嵌载荷 → 两处都被点名（`agentq-launcher.ps1:519`、`sshp(shell line 561):109`）并退 1。改回后 0 条。
    - **边界**：只覆盖**当前**这套表里的构造。其他 PS 7 专有写法（例如 `Get-Error`、`-Parallel`、`clean` 块）今天资产里都没有，未收；将来真出现时先在本条记一行再收表——**不要把「表没报」当成「5.1 能跑」**。另外，这条规则证明的是「没有这些 token」，**不证明**资产在 5.1 上真的跑通——那仍然只有 2026-10-21 测试机那次端到端与 Windows CI job 的证据。
  - **第十八类（2026-10-24 同一轮，第三层同心圆）：`.ps1` 里以 here-string 内嵌的 PowerShell 载荷——5 个真实载荷从未被任何检查解析过。**
    - **怎么找到的**：规则四把扫描面从 `.ps1` 扩到 shell 内嵌载荷之后，继续问「`.ps1` 自己有没有内嵌 PowerShell」。有：7 个 `.ps1` 里共 **14 个 here-string**，其中 **6 个**解析后是合法 PowerShell——`agentq.ps1` 的 launcher wrapper（`-EncodedCommand` 发给远端）与协议探针（`-Command -` 喂 stdin）、`sshp.ps1` 的 Zellij resolver 与两个 invocation 体、`agentq.ps1` 的 usage 文本之外的调用载荷。它们是**发到远端、由 powershell.exe 执行**的代码，而按文件扫的任何规则都把它们看成一个 String token，内部永远看不见。**这正是 0.1.16 那次 P0 `$lastExitCode` 真正所在的那一层**（`$launcherWrapper` here-string 里）——当时靠行为锁抓住，静态规则直到今天才照到。
    - **另外 8 个不是 PowerShell**，两类：4 个是 **shell 体**（`sshp` 的两段 POSIX 探针/安装脚本、launcher 写出的 `runtimeScriptContent`、`install-agentq.ps1` 的 status 探针）——里面的 `||`/`&&` 是 shell 操作符，不能拿 PS 规则去判（那会复刻本仓反复踩的「检测器假红」）；3 个根本解析不过（usage 文本、`Add-Type` 的 C# 体、一段无 shell 标记的小片段），靠「先分类解析、解析不过就跳过」挡住；1 个是 usage 文本。
    - **分类判据**：先按内容标识别 shell 体（`set -`、`cygpath `、`#!`、`command -v ` 行首标记），再用解析器试——**两类跳过都有据**：shell 体跳过是刻意的（语言不对），解析失败跳过是因为那不是 PowerShell（C# / 散文）。计数闸门钉「恰好 6 个 PowerShell 载荷」，新增载荷或分类失效都会红。
    - **红证（在真实资产上双向）**：往 `agentq.ps1` 的协议探针 here-string 里种 `$profile = ...` 与 `$missing ?? "d"` → 规则四与规则五各点名一行（行号回填到 here-string 起始行之后），`exit=1`；标定加 here-string 双向夹具（合法载荷 0 条、`$profile` 载荷恰 1 条），标定行扩为 `legal=0 defects=13 payloads=1 double=1 here=1`；载荷计数 `here=6` 印在 ps1_static 脚本自己的输出、**不在检查摘要行**（计数不为 6 时脚本退 2、检查整体变红，所以摘要的 `ps1_static=ok` 已蕴含「6 个都扫过」）。
    - **边界**：分类靠内容标记，一段**不带这些标记的 shell 片段**会被误当 PowerShell 解析——大概率解析失败被跳过（现状就是如此），但理论上存在「恰好是合法 PS 的 shell 片段」这个缝隙，计数闸门只保证数量、不保证分类语义。可展开的（`$($script:Program)` 这类**插值** here-string）按展开前文本解析，静态上无法断言展开后的内容——本仓 6 个载荷里没有插值进入载荷体的形态，记为盲区。
  - **第二十一类（2026-10-25）：`shell_assets` 清单按文件名枚举，两个 `.bash` 资产落在解析臂与静态锁之间。**
    - **怎么找到的**：逐一核对 01 摘要行的每个计数时，`repo_scripts=40`（29 个 smoke + run-tests + sandbox + shell 资产）与「shell 资产 = 7」的既有记忆对不上——`find skill/assets` 的 shebang 枚举给出 **9**。两个 `.bash` 启动器（`client/windows/agentq.bash`、`sshp.bash`）是真实 shell 资产（install-client.ps1 在有 Git Bash 时把它们装成无扩展名 shim），但扩展名不在旧名单（`*.sh`/`agentq`/`agentq-server`/`sshp`/`durable-move`/`start-daemon`）里。
    - **漂移为什么活了这么久**：01 内部有**两份枚举**——解析臂按 shebang 找文件（9 个，`shell=9`），静态规则按名单找（7 个，`local_hazard_files=7`）。两个数字**并排印在同一行摘要里**，无人比对。smoke/24 倒是单独执行了两个 `.bash`（18 例），所以行为层不是零覆盖——缺的是静态规则那半。
    - **修法**：`shell_assets` 改为**按 shebang 枚举**（与解析臂同一判据），解析臂改吃同一变量——单一来源。再加两道闸门：`shell=` ≠ `local_hazard_files=` 即失败（同一行摘要里 9≠7 曾经全绿，这正是「计数印出来没人看」的形状）；**无归属资产闸门**——skill/assets 里任何不属于已解析类别（`.ps1`/`.cmd`/`.plist`/`.yml`/`.service`/shebang-shell）的文件即失败，堵住「新种类资产静默加入、任何规则都不解析它」这个类（`.DS_Store`/`Thumbs.db`/`desktop.ini` 豁免——Finder 会在任何被显示的目录创建它，而 .gitignore 已挡住它；对它报红是假警报）。闸门刻意**不用**「23 个文件」常数：常数钉死今天的清单，而「这个文件的种类有没有规则解析」才是摘要行真正在说的问题。
    - **红证（四个方向）**：往 `sshp.bash` 植入五类构造（quiet-grep 管道、`< f 2>/dev/null`、mktemp 带后缀模板、动态作用域 hazard、未调用函数）→ **五条锁逐条点名**并退 1（改前同植入零命中）；让解析臂跳过 `.bash` → 漂移闸门点名「7 vs 9」并退 1；种入 `zz-probe.json` → 无归属闸门点名并退 1；把分类器改成永远接受 → 自检报错。还原后全绿。
    - **顺带的实测**：shellcheck `-S warning` 全量（未加 `-i` 白名单）在 9 个资产上只有 3 条——SC3045（POSIX sh 的 `ulimit -c`，本仓已有注释说明 best-effort 且 dash/bash 实测都接受）与 SC2140/SC1078（服务端 jq 双引号 filter 里的注释文本，`bash -n`/`zsh -n`/`dash -n` 全部接受）。两者都判为既有边界、不进锁，如实记录。
  - **第八十四类（2026-11-14：Skill 自身纳入版本管理，SKILL.md 拆分）**（资产零改动，`skill/assets/` 23 个文件字节未变；新增 `skill/references/` 5 篇；`skill/SKILL.md` 重写为操作摘要；`smoke/01` 版本块与 release-gate 派生 +1 记录；`release.yml` +1 读取；README/CONTRIBUTING/CLAUDE/HANDOFF 计数与措辞。）
    - **怎么找到的**：用户两句——「skill 也要更新适配，随本项目一起发布」与「SKILL.md 里文本非常多，很杂乱」。先量：228 行却 81,862 字节（平均每行 360 字节），`## 新主机接入` 65 行里 44 条是近乎同构的 `Get-Item -Force` 路径不变量，`## 调用端与终端` 把 Windows 机制、环境变量判据、凭据与探针缓存混在一节。**这是「实现清单」与「操作手册」被压进同一个文件**，不是内容错误。
    - **拆法（逐字搬运，零改写）**：`references/contract.md`（协议细节）、`references/clients.md`（调用端与终端）、`references/install.md`（新主机接入的安装部分）、`references/windows-installer-invariants.md`（44 条里 32 条命中 `Get-Item -Force|强制项读取|non-reparse` 的不变量）、`references/doctor.md`（发现与前置条件）。SKILL.md 保留：frontmatter、简介、执行工作流、命令面、**退出码表**（新写，内容取自原文各条）、硬性规则（8 条，取原文句子）、运行语义、参考索引。
    - **不丢内容的机械证明**：把原文件按 `## ` 切成 6 段，逐行比对「每个非空行是否出现在任一新文件中」→ 197 行里 4 行缺失，全部是变成文件标题的章节名（`## 调用端与终端` 等）。其余逐字在。
    - **Skill 的版本记录是真空**：`SKILL.md` frontmatter 只有 `name`/`description`，`agents/openai.yaml` 只有 3 个 interface 字段——「随项目发布」的 Skill **无法自报版本**。加 `version: 0.1.30` 并接入既有的版本记录机制：`smoke/01` 的版本块（现比较 7 处；服务端孪生仍由字节 parity 保证）、`release.yml`（读全部 8 处）、以及 `smoke/01` 的 release-gate 规则（要求 release.yml 在同一行同时出现路径与常量名）。
    - **红证（三向，全部实测）**：M1 改 Skill 版本为 0.1.29 → `version FAILED: the seven records disagree`；M3 给 Skill 版本加第四段 → `version FAILED: the Skill records "…", which is not X.Y.Z`；M2b 删掉 release.yml 里 skill 块的**两行** → `release-gate FAILED (release.yml never reads skill/SKILL.md…)`。三向还原后 `cmp` 与备份一致。
    - **M2 的第一版是错的，记下来**：只删 `compare 'Skill' …` 一行、留下 `v=$(awk … skill/SKILL.md)`，规则仍判「读过」而全绿——`release_gate_reads` 断言的是「路径与常量名出现在同一非注释行」，**不判断值是否真被比较**。这与既有 7 处记录的保证同一强度（它们同样在只删 compare 时通过），不是本次引入的洞，但**红证必须按规则自身的强度来写**，否则测的是我以为什么。
    - **边界**：① `references/` 里的内容与 SKILL.md 的摘要存在**刻意的重复**（同一事实的短摘要 + 长原文），优先级写进 SKILL.md 的索引段（细节以参考文件为准）；② 拆出去的 32 条不变量由 `smoke/01/10/13/23/25` 守着，但**这次没有新增针对「references 与 SKILL.md 不同步」的检查**——摘要与原文若漂移，只能靠人工；③ `skill/` 文件数 25 → 30，`smoke/01` 的 `skill_modes` 下界 `-lt 25` 仍成立（是下界，不是等值）。
  - **第八十三类（2026-11-14：CHANGELOG 三层结构与 tag 纪律规范化）**（资产零改动；新增检查 `smoke/31-changelog-and-tags.sh`；`ci.yml`、`CONTRIBUTING.md`、`README.md`、`CLAUDE.md`、`smoke/01` 注释、`smoke/not-covered-known.txt`、`docs/verification-status.md`。）
    - **怎么找到的**：用户要求「版本号管理规范化、changelog 规范化」。先量现状而不是先写规矩：31 个 tag 与 31 条索引一一对应，但**没有任何检查读它们**——索引指向不存在的 tag、tag 丢索引、索引乱序、新条目不写验证行，都可以全绿；31 个 tag 里 **7 个是轻量 tag**（v0.1.23/24/25/26/28/29/30）；`CONTRIBUTING.md` 说版本记录在「**six** places」，而 `release.yml` 实际逐条比 **7** 份（含 canonical 孪生），`smoke/01` 的版本块比 6 份——三处说法互不一致。
    - **第四条规则为什么只查最新条目**：降序段 227 条里 **137 条**没有 `|` 验证行（实测分布：2026-09-29 至 2026-11-09 都有），短格式约定 2026-10-15 才立，且 CLAUDE.md 明令历史条目不重写。把规则扩到全段等于要求重写历史；只查最新条目，保护的是**下一条要写的条目**，历史尾部照实计数、不判红。
    - **红证（六向，全部实测）**：幽灵 tag（索引写 `v0.1.99`）→ `version index names v0.1.99, but no such tag exists`；删一条索引 → `tag v0.1.27 has no version-index line`；造重复索引 → `v0.1.25 has 2 version-index lines`；交换两条 → `not strictly descending: v0.1.24 is followed by v0.1.25`；删最新条目的 `|` 行 → `the newest log entry (...) has no '|  <verification>' line`；顶部插倒填日期条目 → `the first log entry is dated 2026-01-01 but the newest date is 2026-11-13`。每向还原后 `cmp CHANGELOG.md /tmp/cl.bak` 为 0。
    - **两向边界实测**：无 tag 的检出（`git init` 空仓）→ `NOT-covered(no-tags-in-checkout)`、退 0，规则 A/B 不假绿；空索引 + 有 tag → `the version index is empty`、退 1。
    - **一个真实缺口，修在 CI 而不是检查里**：`actions/checkout` 默认 `fetch-depth: 1`，**tags=0**（实测：`git clone --depth 1 --no-tags` 得 0，全量克隆得 31），所以新检查在 CI 上会**永远**降级成 NOT-covered，规则只在开发机生效。linux job 改 `fetch-depth: 0`（仓库 27 MB，注释里写明实测数字）。检查本身不改：在真正的浅克隆上，它没有数据可比，如实说「没比」是对的。
    - **版本记录的三处说法统一**：以实现为准——**7 处记录**（两个安装器、服务端、服务端孪生、两份客户端、README）；`smoke/01` 的版本块比 **6** 处，孪生由其上方的字节 parity 断言覆盖（两文件必须逐字节相同，孪生不可能与 `server` 不同值），`release.yml` 在 tag push 时读全部 **7** 处（那条路径不跑 `smoke/01`）。`CONTRIBUTING.md` 与 `smoke/01` 注释同步改准；此前那条「孪生 2026-11-15 才被读」是我先写后查、**被 grep 推翻**的草稿，已删。
    - **tag 注释不检查，只约定**：`release.yml` 比的是 tag 名字，轻量 tag 照样过门禁；把「必须 annotated」写成机器检查要读 tag 对象类型，而历史 7 个轻量 tag 已经存在，检查要么排除它们（豁免表，正是本仓反对的形状）要么追溯重建 tag（改写历史）。所以规范写成文档约定「新 tag 一律 annotated」，PLAN 记下历史的 7 个，**不声称已机器执行**。
    - **已知边界**：① 索引行的**内容**（日期/描述与 tag 的对应）不检查，只查存在与顺序；② 「一次 push 最多 3 个 tag」无法由仓库内检查验证（是 GitHub 侧行为）；③ 新检查的名字已进 `expected_checks` 与 `not-covered-known.txt`，CI 会把 `31` 当作必须跑过的检查。
  - **第八十二类（2026-11-12 实测、2026-11-13 修复：Windows 目标的命令在 Pueue 执行时被静默截断）**（资产变更：两份客户端；`SKILL.md`；`smoke/05` +2 例，`smoke/14` +1 站点。服务端**未改**——原因见「为什么修在客户端」。）
    - **怎么找到的**：第八十一类之后对专用 Windows 测试机（`DefaultShell` 是 **Git Bash**，此前记作 cmd）做 `--stdin-script` 的端到端补验。base64 8000 → `Success`；8040 / 8100 / 12000 / 16000 / 20000 → **提交成功（exit 0）、任务执行失败**：`/usr/bin/bash: -c: line 1: unexpected EOF while looking for matching` + 一个单引号。而 `SKILL.md` 承诺 Windows 目标可用到 20000。
    - **定性（三步实测，逐步排除）**：① `pueue status --json` 里任务 303（b64 8100）存的命令是 **8256 字符、尾部完整**，对照任务 304（普通 `submit`，9.8K 字符引号参数）存的是 **9842 字符、尾部完整**——**Pueue 存储不截断**。② 绕开 AgentQ 直接喂 Pueue（长命令先上传成文件、用短 runner 读进 argv，排除 ssh 跳的干扰）：存储 **8160 字符正确执行**、**8200 被切掉**，而**任务照样 exit 0**（`printf %s <A×8160> | wc -c` 打印出一串 A 而不是计数）。③ 经 AgentQ 路径同一悬崖：base64 **8010 成功（存储命令 8166）、8040 被切（存储命令 8196）**。三者一致指向 **pueued 执行 spawn 时的命令串上限**：8196 被切、8166 没被切，与 **cmd.exe 的 8191** 一致（那一层包装的确切形态没有从 Pueue 源码读到，所以只说落在这个区间里）。
    - **推翻的一条既有文档断言**：`SKILL.md` 边界 ② 记「只影响 DefaultShell 为 cmd 的目标；Git Bash 目标不受此限」。不成立——pueued 自己经 cmd 执行，与 sshd 的 DefaultShell 无关。测试机正是 Git Bash，照样受限。
    - **另一个被纠正的结论**：此前一轮得出「普通 `submit -- <12000 字符参数>` 不受影响」。那是错的——那个用例的命令尾部只是 `echo … | wc -c` 之类，被切掉后仍 exit 0、输出看起来正常。改用 `printf '%s' '<9800 字符>' | wc -c` 对照后，普通 submit **同样失败**（exit 2 + 同一句 `unexpected EOF`）。**教训与 pipefail 那条同形：判据必须能让「截断」与「正常」输出可区分**。
    - **修法（客户端）**：两份客户端的 Windows `--stdin-script` 上限 20000 → **7800**（解码包装固定占 156 字符：`sh -c ''` 8 + Pueue 对守卫引号的转义 6 + 解码管线 142；8191 − 156 ≈ 8035，留余量）；两份客户端各加一道本地守卫：目标解析为 windows 时，把 `$@` 按 Pueue 4.0.4 的转义规则估成一条存储命令（每参数 +2 引号，每个内嵌单引号 +3），超过 **8100** 即在本地退 `2`，**先于任何载荷下发**。上限估计取**偏高**一侧（`${#arg}` 在 dash/C 下计字节、PS 侧用 `UTF8.GetByteCount`），因为低估的后果正是本条要消灭的静默截断。
    - **自审时又抓到一处孪生分歧（同日修）**：守卫的长度用 `${#arg}` 计算，而它在 **dash 下是字节、在 bash + UTF-8 locale 下是字符**——同一条带中文的命令在 Debian 上会被拒、在 macOS 上放行，Windows 孪生（`UTF8.GetByteCount`）又是第三个答案。这正是本仓记过的「拷贝上限必须连同单位一起拷」。改为 `wc -c` 计 UTF-8 字节（BSD `wc -c` 会补空格，故过一道 `tr`），三平台同界；非 ASCII 命令因此按字节**偏高**估计（真实上限以 UTF-16 单元计会更宽），偏向「宁可提前拒绝、绝不让它被静默切掉」。`smoke/05` 新增 CJK 用例（2699 个汉字＝8097 字节，字符数只有 2699）把单位钉死——字符制会放行、字节制报 8109。
    - **为什么修在客户端而不是服务端**：服务端拦更彻底（任何客户端都受保护），但①测试机上部署的是 0.1.29，新服务端要装到真机才能生效，那需要**另行授权**；②在 macOS 上把服务端推进到「Windows 机制 + 操作锁初始化」的深度来行为测试代价远超价值（试写过探针：`ps -W`、`Get-Process`、profile 解析、runtime 布局……层层前置）。客户端的守卫在**本地**即生效，用户升级客户端就得到保护。

      **服务端守卫：已评估，结论是「不做」（2026-11-13，用户同意）。** 判据取自本项目的实际使用方式，不是省事：
      ① **保护的场景与用法对不上**——`SKILL.md` 要求的做法是多行脚本走 `--stdin-script`，那条路的上限客户端本来就管（7800，真机已验证 7800 成功 / 7804 本地拒绝）。服务端守卫多覆盖的只剩「绕开客户端、或用 0.1.30 之前的客户端把近 8K 的命令塞进 argv」，而本仓历史里这种提交只出现在测量夹具中。
      ② **不存在「新服务端 + 旧客户端」的常态组合**——部署单元是 23 个文件的同一版本，`CLAUDE.md` 明令不得只升一侧，装服务端的机器同时放客户端，安装器还会拦住 wrapper/客户端冲突。服务端守卫没有额外的人群可保护。
      ③ **危害有界且立刻看得见**——队列强制 `parallel_tasks == 1`，一条被截断的坏命令最多占住唯一槽位；截掉尾巴的命令基本跑不出正常结果，用户看到的是任务失败 + `logs` 里的半截命令，不会把**错误结果**当成成功交出去。
      ④ **成本远高于收益**——服务端要在 Windows 机制上做行为验证，macOS 上写探针层层撞在 `ps -W`、`Get-Process`、profile 解析、操作锁初始化上；能落地的只有一条静态规则加「删规则就红」的证明，等于**没有行为证据的锁**。而且它要部署到真机才生效，本身还要一次授权与升级。
      **这不是遗留项，不要再翻出来当待办**；若将来引入了跨版本互操作（当前设计刻意没有协议版本协商，见 `CLAUDE.md` B2），这一条的前提才需要重新评估。
    - **锁与红证**：`smoke/05`（行为，Windows 目标桩）：9000 字符命令必须退 2、错误文本点名 Windows Pueue 上限、且 **launcher 调用次数不增加**——取消守卫后该例报「exited 0」+「调用 2→3」；把守卫条件整体改成 `false` 后同样报红，所以行为锁覆盖的是**可达性**。`smoke/14`（静态）：双客户端常量一致且 < 8035、两侧守卫阈值 ≤ 8100，三个变异各自报红（常量偏离、阈值放大、阈值改成不触发）；`if` 条件被改成 `false` 时静态锁**不红**——静态锁只管常量与阈值，可达性由 05 管，这是刻意的分工。
    - **真机复验（2026-11-13，用本仓 0.1.30 客户端对专用 Windows 测试机）**：`--stdin-script` base64 **7800 → `Success`**（输出 `G-5850`，尾部完好）；**7804 → 本地退 2**（5 秒，`the script is too large for --stdin-script (base64 length 7804 exceeds 7800 on this target)`，未发出载荷）；普通 `submit -- printf '%s' <9000 字符>` → **本地退 2**（6 秒，`the command is too long for a Windows target's Pueue (about 9016 escaped characters …)`）。另在真机上量到上限处的存储命令实际长度：base64 7800 的任务在 `pueue status --json` 里就是 **7956 字符、尾部完整**，距 8191 还有 235——与「解码包装 156 字符」的推算逐字相符，不再只是估算。这三个数覆盖了「上限内能用」「超限本地拒」两半；**未覆盖**的是「拒绝前确实零载荷下发」的真机证据（本地桩已证 launcher 调用不增加）与 unix 目标（该机不可用）。
    - **边界**：① 实测夹出的区间是「存储 8166 通过 / 8196 被切」，8191 是 cmd.exe 的命令行上限、与这个区间一致，但**包装的确切形态没有从 Pueue 源码读到**，所以 `8191` 是**推断**而不是直接量到的边界；客户端因此不按实测点取整，而是按最坏情况算 `8191 − 156 = 8035` 再留余量。② 上限是**主机/平台属性而非契约**：不同 Pueue 版本、不同 `shell_command` 下可能不同，因此客户端留了 228 字符余量、守卫阈值留了 91 字符余量，且都是**偏高**估计。③ 本轮**没有**部署新服务端到测试机，服务端侧的端到端覆盖仍为「无」。（**2026-11-13 已补**：专用 Windows 测试机整体升到 0.1.30，见本节末「0.1.30 真机部署」。）④ unix 目标不受影响（`MAX_ARG_STRLEN` 131072），未改。
    - **0.1.30 真机部署（2026-11-13，用户授权）**：专用 Windows 测试机 0.1.29 → 0.1.30，**服务端与客户端同时替换**，走官方安装器（服务端 `install-agentq.ps1 -StageDirectory`、客户端 `install-client.ps1`，均从完整暂存目录运行，两侧 `RC=0`）。结果：`agentq_version='0.1.30'`、客户端 `$script:ClientVersion = "0.1.30"`；部署字节与仓库 sha256 逐文件相同（服务端 `agentq`/`agentq-start-daemon.ps1`/`agentq-durable-move.ps1`、客户端 `agentq.ps1`/`agentq.cmd`/`sshp.ps1`/`sshp.cmd` 与无扩展名启动器 `agentq`/`sshp` 全 MATCH）；`agentq-launcher.ps1` 逐行比较只差 1 行——模板占位符 `__AGENTQ_GIT_BASH_LAUNCHER__` 被渲染成实际 Git Bash 路径，是安装器设计行为；`pueue.yml` 同理只差渲染。数据保留：队列 291 条全 `Done`、0 非终态；daemon 以新 PID 运行；无维护锁残留、无事务残留。协议端到端（本仓 0.1.30 POSIX 客户端 → 该机）：`submit` → 307、`wait` → `Success`、`logs` → `agentq-0130-e2e`（**耗时超过 120 秒**，与 2026-11-12 记录的「该机每次协议读 30–78 秒」同源，本次 submit/wait/lookup/remove 均秒级，故按沿用现象记录、**未做因果定位**）、`lookup` → `reused:true`、`remove` → `removed:true`、`wait` → exit 5 `state:"removed"`（连查 3 次一致，tombstone 非消费制）。**未验证**：unix 目标上的 0.1.30 端到端（本轮对 unix 主机只做了只读侦察，未部署、未改动该机任何文件）。（**2026-11-13 已补**：同一轮的后续，用户授权后专用 Linux 主机也已整体升到 0.1.30 并完成 unix 目标端到端，见下一条。）
    - **0.1.30 真机部署：专用 Linux 主机 0.1.3 → 0.1.30（2026-11-13，用户授权「升级到最新版本」）**：同一部署单元（`unix/` 7 个资产，sha256 与仓库逐个相同），走官方 `install-agentq.sh`（`INSTALLER_EXIT=0`、`AgentQ 0.1.30 installed`）。预检（只读）：队列 261 条全 `Done`、无 `~/.agentq.maintenance.lock`、`Linger=yes`（安装器不会因此改系统项）、`~/.agentq`/`~/.config/systemd/user`/`~/.local/bin` 全属主本人、GitHub 可达。结果：`agentq_version='0.1.30'`、`agentq-server` 与仓库 sha256 相同（`7fd15e2b…`）、wrapper 仍是 60 字节 exec 形态、`agentq-pueued` active+enabled 且以新 PID 运行、数据保留（260 request record + 2 cancellation marker，队列 261 条全 `Done`）。协议端到端（本仓 0.1.30 POSIX 客户端 → 该机）：`submit`→842、`wait`→`Success`、`logs`→`agentq-0130-unix-e2e`、`lookup`→`reused:true`、`remove`→`removed:true`、`wait`→exit 5 `state:"removed"`（复查 2 次一致）。**本机读速与 Windows 测试机对照明显**：这台机上 `submit`/`wait`/`logs`/`lookup`/`remove` 全部秒级返回，未见 Windows 那台 120 秒级的 `logs` 延迟——支持「那是 Windows 测试机本机属性、非协议层」的既有判断（仍未做因果定位）。**仍未验证**：生产主机（一台没碰）、跨主机并发与负载、真实运维中断下的行为。该机上另有三个 2026-07/09 的陈旧暂存目录（`~/.agentq-stage`、`~/.agentq-stage-p1-1-v43`、`~/.agentq-install-stage`，合计约 512K），非本次安装产物，**未删除**、留待用户决定。
    - **第八十一类（2026-11-11，0.1.29 落地后的续修：核对并清理 Orca 并行 worktree `agentq-codex-review` 时发现）**（资产变更：`unix/agentq-server` 与 canonical 孪生、`client/windows/agentq.ps1`、`smoke/03`、`smoke/12`、`smoke/27`。）
    - **① `--stdin-script` 的上界取了「两者较大」，于是拒绝仍要等 EOF（实测）**：0.1.29 把 `CopyTo` 换成块读循环，上界取 `max(unix, windows) * 3 + 3`（300003 字节）。凡负载落在**目标自己的预算**与这个上限之间、而写端不关管道，循环就永远等不满。实测 2026-11-11（macOS + pwsh 7.5，unix 目标，FIFO 写 100000 字节后挂起）：POSIX 孪生 ~1 秒退 2，PS 客户端 12 秒仍在读。**当日那条用例为什么绿的**：它喂 400000 字节——恰好越过那个上限，于是读端总能到达上限。夹具按实现的形状挑尺寸，契约就没被问到。修法：把目标预算的计算**前移**到读之前，按 `floor(limit*3/4)+1` 字节逐字节读（与 POSIX 孪生的 `head -c` 同一界）。
    - **② 块读本身在 PS 5.1 的 OpenSSH 管道上会挂（0.1.10 实测，同一文件里的第二个读取点）**：0.1.10 在 launcher 载荷通道量到 `[Console]::In.Read(char[])` 过 ~4.5K 字符后间歇挂起、逐字节读 12/12 通过（最大 53K）。`--stdin-script` 是同一文件的**第二个** stdin 读取点，0.1.29 却写成了块读；该形态在 Windows 上被声明 NOT-covered，从未被真实管道验证。修法：逐字节 `ReadByte()`。锁是**静态的**（`smoke/12`）：本套件跑 pwsh + POSIX 主机，两种读法都正常，行为用例看不见这个差异——规则在 `IsInputRedirected` 与 `ToBase64String` 之间取区域，剥注释后要求 `ReadByte()`、禁止 `.Read(`/`CopyTo`/`Console]::In.Read`、并要求上界行引用 `$stdinScriptLimit` 且不含 `[Math]::Max`。**自校准踩了一脚**：区域里的注释本身就写着被禁止的那个调用名，规则第一版把**已修好**的资产报成块读；夹具改为「取真实区域 + 三个变异体」，其中号数变异体的 sed 因多写了 `\)` 改了零处——两个自校准失败都被规则自己点名，没有静默通过。
    - **③ 本地命令行预算与孪生差 1 个字符（实测）**：`[int](97753.5)` 在 PowerShell 里是**银行家舍入**（97754），POSIX 的 shell 整除是截断（97753）。1 个字符也是分歧。修法：`[int][Math]::Floor(...)`，两边同界。
    - **④ submit 把「读取出错」当成「记录不存在」（P0 级，实测复现）**：`if record=$(read_request_record ...)` 无法区分 rc=1（不存在）与 rc=2（存在但读不出）。失败落到 else 分支，而 else **会写**：一次瞬时的 jq 失败就会用一个 prepared 记录**覆盖**已受理记录（丢掉 task_id）并照常 `pueue add`。实测（只在 per-id 读取器上注入一次 jq 失败）：修前退 0、记录被替换、任务被入队；修后同样的注入退 2、记录逐字节不变、`pueue add` 未被调用、只有一行 reason。修法：rc=1 才是「不存在」，其余原样返回（读取器已打印自己的 reason，调用方不得再打一行）。tombstone 一侧同规则（读臂放子 shell，别让 `fail` 先结束整个服务端）。**这是并行 worktree 里唯一 main 还没有的实质修复**：其余文件要么是 main 的子集，要么已被 0.1.29 以更强形态吸收。
    - **⑤ 「删除陈旧 marker」的分支必然 no-op（实测复现）**：`remove_cancellation_marker_for_task(N, created_at)` 只在 marker 的 created_at **等于**参数时删除。cancel 里那个分支的**进入条件**就是两者不等，于是它调用的永远是删不掉的那一支——看着像清理，实际什么都不做。后果：旧实例的 marker 赖在复用的 id 上，等当前实例离开 Pueue（rc=4）后再 `cancel` 这个 id，重放门槛只问「marker 的 created_at 有没有被记录过」——旧实例当然记录过——于是对一个谁都没取消过的任务答 `reused:true`。实测：在已完成任务的 id 上种一个外来 created_at 的 marker 再 cancel，修前 marker 仍在、修后消失（`smoke/03` 的 `stale-marker=removed`，变异体去掉调用即红）。修法：新增 `remove_stale_cancellation_marker_for_task(task_id, current_created_at)`，以**marker 自己的** created_at 作删除围栏（并发取消刚写下的当前实例 marker 会被这道围栏保住），submit 与 cancel 两处都用它（`smoke/27` 的 `s8-stale`/`s8-current` 两个方向）。
    - **⑥ 检查自身的缺陷：一次失败的 `smoke/03` 会毒化下一次运行（实测，被踩中两次）**：EXIT trap 只能 `remove` 仍在 Pueue 里的任务；queued 取消的受害者已经从 Pueue 消失了，它的 record 于是留下。下一次运行提交到被回收的同一批数字 id，在第一个 `wait` 上以 `task N has an ambiguous AgentQ identity` 失败——一个和残留、和契约都无关的报错。修法：预检里加一条「本检查自己的 record 还在」的显式拒绝，点名文件和可粘贴的清理命令（成功运行不会留 record：它们被归档成 tombstone）。
    - **边界**：① ②的静态锁只证明读取形状，不证明 PS 5.1 的挂起已消失——那需要真 Windows 主机 + sshd 管道，本地没有。**（2026-11-12 已补验：专用 Windows 测试机、真实 sshd 管道、PS 5.1.19041.3996。把资产里 launcher 载荷读取区原样抽出跑：200 KB 载荷下逐字节 6/6 完成、块读 3/9 挂起（`timeout` 20–30s 杀掉，rc=124、零输出）；100 KB 块读 1/3 挂、逐字节 5/5 完成；53 KB 块读 6/6 完成。所以挂起类真实存在且可复现，逐字节形态 200 KB 上 6/6、100 KB 上 5/5，合计 11/11 无挂。**但 `--stdin-script` 自己的上界（unix 目标 ≤18018 字节）低于可复现区间**——在该上界内块读控制组也跑完了，所以这条修复对 `--stdin-script` 是「形态正确、危害不可达」，真正被它保护的是读上限 1M 字符的 launcher 载荷通道。测试装置（原生 argv 记录器、抽取的读取区、各尺寸载荷）全部在测试机临时目录，跑完已删除。）** ③ 的 1 字符分歧只在本机实测过一次。④ 的复现是注入一次 jq 失败，真实故障下的触发频率未测。⑤ 的重放后果由 fixture 演示，不是真实回收时序。⑥ 只做了拒绝，没有自动清理（清理别人的目录不是检查该做的事）。
  - **第八十类（2026-11-10，第四轮复审：6 个隔离 worktree 的审查 Agent + Orca 里的 Codex；两条 P0 由我逐条复现后才采纳）**（资产变更：`unix/agentq-server` 与 canonical 孪生、两份客户端、`unix/install-agentq.sh`、`client/windows/install-client.ps1`、`sandbox.sh`、`.github/workflows/*`、`.gitignore`；`SKILL.md`、`HANDOFF.md` 同一轮补齐。）
    - **① 大小写不敏感文件系统上，只差大小写的 request id 会覆盖已受理记录（P0，实测复现）**：request id 是 record 的**文件名**，而 id 区分大小写。macOS 默认卷与 NTFS 上 `[ -e .../AAAA.json ]` 在只有 `aaaa.json` 时也为真：读者把**另一条**记录交给 jq，`request_id` 绑定当场失败；submit 的「记录是否存在」于是可能走到「不存在」分支，用 prepared 记录**覆盖**幸存文件。实测（默认 macOS 卷 + 桩 pueue）：先提交 32 个小写 `a`（exit 4，record 停在 `adding`），再提交 32 个大写 `A`——只剩**一个**文件、`request_id` 变成大写；此后 `status`/`lookup`（两种拼写）全部退 2 `invalid AgentQ request record` + `reason=protocol_error`，主机被**毒化**到人工删文件为止。修法：新增 `request_record_has_case_alias`（`-e` 为真、但目录里没有**逐字**同名项 ⇒ 别名），在读（`read_request_record`、`read_request_record_state_and_body`）与写（`write_request_record`）三处拒绝；写路径是承重的，因为读路径的 `fail` 跑在 `$( )` 里只终止子 shell。红证：修前大写提交 exit 2 且 record 被改写、`status` exit 2；修后大写提交 exit 2 + `request id differs only in case from an existing AgentQ record` + `refusing to overwrite …`，原记录完好，`status --summary` exit 0、`lookup <小写>` 正常。
    - **② Pueue 读失败时 `cancel` 用旧 tombstone 回放成功，而新任务仍在跑（P0，实测复现）**：tombstone 只证明**旧实例**被移除；Pueue 会回收数字 id，此刻该 id 上可能正跑着一个**新任务**。原逻辑在「Pueue 不可读」时仍接受 tombstone 证据 → 对一个活任务答 `cancel_requested`/`reused:true`/退出 0，且**没有**发出 kill/remove。实测（桩 pueue，第一次 status 成功、第二次失败）：marker 指向 2026-11-09 的实例、tombstone 同实例、任务 1001 是 2026-11-10 的新实例且 Running → `cancel 1001` 退 0 并报 `reused:true`，任务状态仍是 `Running`。修法：只有**读得出来**（`rc=4`，Pueue 明确回答「不可见」）才接受重放；读不出来时与 `logs`/`remove` 一致走 `report_compact_task_failure`（退 2）。红证：修前 exit 0 + `reused:true`；修后 exit 2 + `cannot inspect Pueue while reading AgentQ task: 1001`。
    - **③ 配置键名大小写使两份客户端选不同主机（P1，实测）**：`agentq.ps1` 用 `-match`（大小写**不敏感**），POSIX 孪生用 `LC_ALL=C sed`（敏感）。同一份含 `agentq_host=second-host` 的配置：Windows 连 `second-host`、POSIX 报 `no SSH host configured` 退 2。修法：`-cmatch` + `\A…\z`。红证：修前 pwsh `-match` 对该行返回 True；修后 False，且正常大写行仍 True。
    - **④ .NET 的 `$` 允许尾随 LF，非法 argv/env 通过本地校验（P1，实测）**：`'^[1-9][0-9]*$'` 对 `"1\n"` 为真，`'^[A-Za-z0-9_.-]+$'` 对 `"session\n"` 为真。同一输入 POSIX 本地退 2、PowerShell 进入 ssh。修法：四处数值/字符集正则全部改为 `-c(match|notmatch) '\A…\z'`（`agentq.ps1` 的 `Test-PositiveInteger`、`Test-TaskId`、`--timeout`、`AGENTQ_WAIT_TIMEOUT`；`sshp.ps1` 的 `SSHP_RECONNECT_DELAY`、session name）。红证：修前四条全 True，修后全 False，正常输入仍 True。
    - **⑤ `sshp.ps1` 缺顶层 trap（P1，实测）**：意外 throw（临时文件身份断言、远端环境解析）以 `exit 1` + 原始 PowerShell 异常转储结束，而 POSIX 孪生与同族 `agentq.ps1` 都是 `exit 2` + 受控单行。修法：加与 `agentq.ps1` 相同的 trap（不拦截 `exit`，故 `Stop-Sshp` 的 2 与探针码不变）。
    - **⑥ `--stdin-script` 在 Windows 上无界读（P2，实测）**：`CopyTo(MemoryStream)` 等到 EOF 才检查上限；持续流会拖住拒绝并吃内存。修法：显式上限的 `Read` 循环（上限取两目标较大者 ×3）。红证：修前 100000 字节且不发 EOF，3 秒后仍在跑；修后立即拒绝。
    - **⑦ macOS 首次跨用户安装会停掉别人的系统服务（P1，REVIEWED-ONLY：控制流经 launchctl 桩核实，真实跨账户未跑）**：系统标签固定为 `com.agentq.pueued`，`bootstrap_existing_macos_service` 只判「active」，忙碌队列检查又因调用者没有 `~/.agentq` 直接成功，随后 `bootout system/com.agentq.pueued` 杀掉**另一个账户**正在跑的任务。修法：读 plist 的 `UserName`，与 `id -un` 不同（或读不到且本账户没有 `~/.agentq`）时**拒绝**并点名，让运维显式停掉。
    - **⑧ 操作锁目录内的元数据临时文件使写命令永久楔死（P2，实测）**：`write_lock_metadata` 把临时文件建在**锁目录内部**，在 `mktemp` 与改名之间被杀会留下 `.agentq-lock-metadata.*` 且无 `pid`；两条回收分支（持有者已死 / 目录为空）都不匹配 → 所有写命令 30×1s 后 `lock_contention`，消息还因 `lock_pid` 为空而**不打印持锁者**；读命令照常工作。修法：回收判据从「真空」放宽为「除该前缀的正规文件外无其它条目」，删除后再 `rmdir`（`lock_directory_is_stale_unowned` + `remove_stale_lock` 内再确认）；这也是**升级自愈**路径。
    - **⑨ 墓碑清扫器删除活进程在飞的临时文件（P2，机制实测）**：`prune_request_temporary_files_in_directory` 与 `prune_cancellation_temporary_files` 在形状校验后无条件 `rm -f`，而墓碑目录会被**免锁读**写入（`wait` 在放锁后归档）。并发写命令的清扫会删掉读命令的临时文件 → 读命令 `2`/`protocol_error`，与「读命令在写操作中也能立即返回」相反。修法：与运行时清扫器一致，先 `process_is_confirmed_dead`。
    - **⑩ 文档与门禁漂移**：`SKILL.md:195` 的 `deployment_state`「目前有两处」→ 三类（含隔离区目录）；`HANDOFF.md:115` 的 reason 列表补 `deployment_state`；三处 usage banner 的 `--tail <lines>` → `<line-count|all>`（实际接受 `all`）；`ci.yml:43` 的「31 scripts」→ 32；`.gitignore` 补 `/smoke.log`；`actions/checkout` 由浮动 tag 钉成 v5 对应的固定 commit SHA，macOS job 的 `pyyaml` 钉 `==6.0.2`；`sandbox.sh` 的下载补 `--proto '=https' --proto-redir '=https' --tlsv1.2`；`install-client.ps1` 的 `-DestinationDirectory` 归一化为绝对路径（相对路径会进持久用户 PATH）。
    - **⑪ 落锁（同日收尾）**：上面每一项各有一个锁，且都做了单次变异红证——`smoke/12` 的配置**键**大小写三行（`-match` 变异体让两行 `windows-exit=255`）、开口管道 stdin（`CopyTo` 变异体 12 秒仍在读）、`smoke/19` 的 `sshp.ps1` 顶层 `trap`（移除/移位/改码三形态各自红）、`smoke/25` 的 `-DestinationDirectory` 归一化（移除 / 移到首个消费者之后两形态）、`smoke/26` 的 l8 与 `smoke/27` 的 s7（大小写别名；大小写敏感宿主上是 `not_found`/两条记录的正控，CI 的 ext4 走这一支）、`smoke/11` 的系统服务身份（helper、五项身份字段、已加载无 plist 的失败关闭、三个调用点计数、stop 路径先于分发；五个变异体各自只点名自己）。**⑦ 的实现当日换强**：原先只判 plist 的 `UserName`，同日把另一个 worktree 的更强形态并入——完整比较 Label / UserName / `EnvironmentVariables.HOME` / `WorkingDirectory` / `ProgramArguments`，并在 bootstrap、`stop_managed_daemon`（含回滚，用子 shell 保住退出码）、`replace_service_file` 三处调用；仍只有控制流核实，真实双账户 launchd 未跑。**⑫ 并行 worktree 的存在必须记下**：Orca 的 `agentq-codex-review` worktree 对同一轮复审另有一套实现（F1–F6），其服务端是本文服务端的子集、F5 已并入本文，其余（`install-agentq.ps1` 的改动、`README`/`CHANGELOG`/`verification-status` 的写法）未合并；两个 worktree 的提交必须由用户决定取舍，不得静默合并。
    - **边界**：① P0-① 的复现用的是**本机默认卷**（大小写不敏感）与桩 pueue，NTFS 与真实 Pueue 未跑；修复的判据不依赖 Pueue。② P0-② 的修法改变了一条既有语义（Pueue 不可读时的 tombstone 重放由 0 变 2），`smoke/15` 的对应用例与 `SKILL.md` 同轮改。③ macOS 跨用户安装只做了控制流核实，未在真实双账户 + 真实 launchd 上执行。④ PowerShell 的 5.1 行为仍只有 CI 证据。⑤ `smoke/28` 的 SIGHUP 偶发仍未定位。

  - **第七十九类（2026-11-10，第七十八类落地后的第三轮复审：6 个审查 Agent + Codex，我逐条复现才采纳；一处契约由用户在 `AskUserQuestion` 里定，见下）**（资产变更：`unix/agentq-server` 与 canonical 孪生、`unix/install-agentq.sh`、`windows-git-bash/install-agentq.ps1`、两份客户端、`smoke/01`、`02`、`05`、`09`、`11`、`12`、`13`、`27`；`SKILL.md`、`CLAUDE.md` 同一轮补齐。）
    - **① `wait` 的答复顺序（P2，`smoke/27` 实测红）**：`pueue wait` 退非零、而同一任务实例已经是 `Done` 且 `result` 合法时，旧代码先打印 `{task: …}` 再 `return 1`。客户端的 `validate_wait_response(1)` 要求 `Done.result != "Success"`，所以「任务成功、wait 因预算/中断退非零」这一组合会被客户端判成**协议违约**（退 2），一次成功变成一次诊断错误。修法：状态机按**任务状态**作答——Done 且 `result` 合法 → Success 答 `0`、其他答 `1`；没有 Done 或 `result` 非法 → `{task_id, state:"unavailable"}` + `6`。红证：把旧的「非零先返回 1」插回 Done 判定之前 → `p2: expected exit 0, got 1`、`p4/p7: expected exit 6, got 1`。
    - **② `verify_group` 的失败类别（P2，`smoke/27` 实测红）**：Pueue 组缺失或 `parallel_tasks != 1` 原先报 `protocol_error`——那会把「这台机器部署状态不对」指向「改你的参数」。**契约选择由用户在 `AskUserQuestion` 里定为新增 `reason=deployment_state`**（不改既有三类，新增第四类；`reason` 是机读契约，改类别属破坏性变更，所以只新增、不复用）。同一类别还用于「维护锁在但持有者不可确认」与「隔离目录是预先放好的符号链接」。
    - **③ 维护锁的空目录恢复（P2，`smoke/27` m0–m8 实测红）**：POSIX 安装器 `mkdir <home>.agentq.maintenance.lock` 后、写 pid 前被杀，会留下**空目录**；服务端 `maintenance_lock_is_stale` 读不到 pid 就 `return 1`，于是这个空锁**永远算活着**——此后每条命令都退 2 `lock_contention`，重装也救不回来（安装器同样判活）。修法：`maintenance_lock_owner` 重写为三态判定（`none`/`live`/`dead`/`empty`/`unowned`），空目录只在**真空 + 无符号链接 + 路径链安全 + 年龄 ≥ `maintenance_lock_empty_grace_seconds`（30s，可由同名环境变量覆盖以与服务端对齐）**时用 `rmdir`（**从不** `rm -rf`）回收；删除前再读同一 inode、再确认仍空。pid 存在但元数据损坏/超长/不可读 → `unowned` → `deployment_state` 并**保留**锁。安装器侧同样加这套判定（`smoke/11`）。
    - **④ 安装器 operation lock 的强删（P2，`smoke/13` 实测红）**：Windows 的 `Wait-ForAgentQOperationLock` 一次 `Test-ProcessIsConfirmedDead` 后就 `Remove-Item -Recurse -Force`——两处危险：判定与删除之间可能有新持有者接管；递归删除会连带删掉**不认识**的子项。修法：与 POSIX 对齐，新增 `Remove-StaleOperationLock`——重读同一身份、再判死、只删已验证的 pid 文件、`Directory::Delete(path,$false)` 删空目录；未知子项一律保留并报「无法确认，人工核查」。
    - **⑤ `reason=` 只应来自失败的那次调用（P2，Windows 实测红）**：Windows 客户端在**每个** `Write-Diagnostics` 调用点无条件转发 `reason=`，一次**成功**的调用只要 stderr 里带这个令牌，就会打印 `remote failure reason: …`——凭空报出一次并未发生的失败。POSIX 的 submit 路径同样。**取法由用户在 `AskUserQuestion` 里定为「只认与失败同一次调用的行」**。修法：`Write-Diagnostics` 增加 `-ExitCode` 参数（`$null` = 未知，保持原行为），全部 11 个调用点传入；POSIX 侧记录 `agentq_remote_failure_reason_status`，三处转发点同时要求状态非零。红证（两侧各自、单次变异）：Windows 旧逻辑 → `mutant-old.ps1: remote failure reason: not_a_failure`；新逻辑沉默；`smoke/12` 的红色断言直接点名 `the windows client forwarded a reason line from a SUCCEEDING call`。
    - **⑥ POSIX 客户端在 zsh 下直接不可用（P2，实测）**：`detect_stat_flavor` 用 `$0` 探测，而 **zsh 在函数体内把 `$0` 设成函数名**，于是 `stat -f` 探测失败，`zsh agentq --version` 在任何事之前退 2 `cannot determine how to read file identity`（dash/bash/ksh 与 shebang 调用都正常，所以 `smoke/01` 的 `zsh -n`——只解析不执行——看不见）。修法：脚本顶层捕获 `agentq_script_path=$0`，函数内改读它（不用 `local`：ksh93 没有 `local`）。
    - **⑦ `smoke/09` 的三个扫描盲区（P2，自检缺失 + 模式反写，实测红）**：带引号的 `'-c'`/`"-c"` 从不被匹配；「有 bash 调用就必须有 base64 通道」的编码器模式把 `GetBytes($script)` 报成违规、放过嵌套形式；通道规则只认 `| bash` 而 `agentq.ps1` 合法地走 `| sh`。三处都修了并加**五拼写自检夹具**（少一个拼写即拒绝作答）。
    - **⑧ `smoke/02` 的 return-2 审计在 0.1.28 后失去对象（检查自身的缺陷，实测）**：③ 把恢复路径改成经 `fail()` 作答后，服务端里「bare 调用函数内 消息 + `return 2`」的形态归零——规则本身没错，但它的 0 站点闸门把「盲了」和「形态没了」混为一谈。修法：新增 `__BAREFUNCS__N` 正控制（按定义表 ∩ bare 调用表计数，当前 68），闸门改为「bare 调用的**函数**为 0 才报盲」；红证：把 bare 检测关掉 → 自检夹具立刻报 `expected 2 judged sites / 1 gap, got 0 / 0`。
    - **⑨ `smoke/01` 的 local-hazard 自检夹具（检查自身的缺陷，实测三次连续假绿）**：一次 `sed a` 的植物文本以 `/` 开头时被 BSD sed 当作 `//` 地址（空正则 = 最后一行），于是被追加到文件末尾；另一次种进函数头**上方**，而规则只从 `local` 声明**之后**的行看起。两次夹具都**包含**文本，`grep` 也找得到，规则正确地沉默——自检却失败。修法：改用锚定到函数头/函数尾的 awk 植物，并改种**其他函数**声明的 local（`lock_mtime`/`lock_holder_age`/`log_encoded`）——规则只报「写进调用方 local」，种进本函数自己声明的名字是规则的**豁免**，测不到任何分支。红证：关掉第一遍赋值匹配 → 报 plain 与 `NAME+=` 两臂。
    - **⑩ `clear_runtime` 在 fixture 之后运行（`smoke/27` t1，测试自身缺陷）**：它删光 tombstone，于是在 seed 之后调用把本用例播下的文件删掉，断言读到 0 条。修法：移到 fixture 之前。
    - **锁**：`smoke/27` 新增 p2/p4/p7、g2/g3、m0–m8（89 例）；`smoke/11` +8（38 例）；`smoke/13` +1（8 例）；`smoke/05` +1（108 例）；`smoke/12` +2（204 例）；`smoke/09` 五拼写自检；`smoke/02` `__BAREFUNCS__` 正控制。
    - **边界**：① Windows 维护锁是**文件**，本次的空目录回收规则对它不适用（只走 `dead` 元数据分支），`smoke/27` 也只走 POSIX 目录形态——Windows 侧由 `smoke/13` 的 AST 抽取用例覆盖 `Remove-StaleOperationLock`，但**真机未跑**（PS 5.1 的 `Directory::Delete` 行为只有 CI 的 PS 5.1 job 会给证据）。② m4（live pid）依赖 `ps -o lstart`，不可用时 smoke/27 有明确 guard 并计失败。③ `smoke/28` 在全量跑里出现过一次 SIGHUP 未停住的偶发失败（独立复跑 3/3 + 负载下 3/3 通过），未定位到根因，记为已知偶发。
    - **文档漂移同一轮修正**：`verification-status` 的 `repo_scripts=38`→`41`、`workflow_pipes=2/7`→`2/10`、「原生 Windows 上的真实远端队列仍然未被验证」一句（2026-10-21 已在测试机补验）；`HANDOFF` 的「`smoke/` 下的 29 项」→`30`；`performance.md` 的 smoke/18「29 例」→`37`。

  - **第七十八类（2026-11-09，第七十七类落地后的复审收尾：Codex 复审 + 两份隔离 worktree 的审查 Agent，我逐条复现才采纳；服务端 Agent 的 3 条结论被实测推翻、未采信）**（资产变更：`unix/agentq-server` 与 canonical 孪生、两份客户端；`SKILL.md`、`CLAUDE.md` 同一轮补齐。）
    - **① `compact_log` 的身份校验在缺日志分支之后（P2，代码确认；窗口需并发，未实测）**：`pueue log` 退 0 且 `output` 是「日志文件打不开」诊断时，服务端用**之前**取的 `$task` 快照回 `{task, output:""}` / 退 0，而绑定同一任务实例的 `created_at` 比对在那之后。数字 id 在两次读取之间被新任务复用时，这条分支会把**旧任务**的元数据当新任务的答案。修法：把身份块整体前移到缺日志分支之前（同一 `$compact_log_raw_file`，两处守卫保持）。
    - **② 隔离区会被自己的保留期清理吃掉（P2，实测）**：`prune_request_tombstones` 的 `find` 没有 `-maxdepth 1`，会进 `.tombstones/.legacy-orphans/`；`mv` 保留 mtime，于是隔离满保留期的记录会被静默删除——与「字节留给运维」的承诺相反。修法：`-maxdepth 1`，注释写明 2026-11-09 的实测（回填 mtime 的隔离文件被同一条 find 选中）。
    - **③ `.agentqtmp.` 的前缀豁免必须匹配真实临时名（P2，实测）**：0.1.26 第一版对 `.agentqtmp.*` 一律跳过。旧规则允许的 id `.agentqtmp.aaaaaaaaaaaaaaaa` 于是漏给临时文件解析器，被判「非法临时 id」→ 每条命令退 2——正是 0.1.26 要消灭的那个故障的另一个入口。修法：只有 `.agentqtmp.<当前合法 id>.<数字 pid>.<非空随机串>.json` 才豁免（逐段校验），其余落回 id 判定被隔离。分割一律用 `##`/`%%` 加**带引号的字面前缀 `case`**：`${x#.agentqtmp.}` 是 glob、点号匹配任意字符，实测把 id 首字符也吃掉了。
    - **④ 隔离搬迁在并发读下不安全（P2，推断：静态时序）**：三条免锁读路径都会调 `migrate_removed_request_records`，两个 `status` 同时枚举到同一旧文件时，后到的 `mv` 因源已消失而失败（原先直接 `fail` → 退 2），且 `mv -f` 在同名目标存在时会**覆盖**先到的隔离副本。修法：目标已存在则顺延 `.1`、`.2`…；`mv` 失败后**再确认源是否已消失**，消失即视为被并发者成功搬走（否则才 fail）。两条都不放松 fail-closed。
    - **⑤ Windows 的 request-id 正则（P2，pwsh 7.5.4 实测）**：`-match '^…$'` —— `-match` 按语言规则**不分大小写**，`[A-Za-z]` 因此接受 U+212A（KELVIN SIGN）/U+0130（LATIN CAPITAL I WITH DOT ABOVE）；`$` 还匹配**尾随换行之前**，于是「15 个 a + LF」也通过。两者都让 Windows 放行 POSIX 与服务端拒绝的 id、把错误推到 ssh 之后（255）。修法：`-cmatch '\A…\z'`。
    - **⑥ POSIX 的 `--workdir` 空白判定随 locale 变（P2，实测）**：`[[:space:]]` 在 UTF-8 locale 下把 NBSP/U+3000 算空白、在 `LC_ALL=C` 下不算，而 U+0085 在两种 locale 下都**不算**——.NET 的 `\s` 三者全算，孪生对同一 argv 给出相反答案（C locale 下 POSIX 放行到 ssh、Windows 本地退 2）。修法：两侧统一成 **ASCII 字节集**（POSIX 用 `LC_ALL=C tr -d ' \t\n\r\f\v'`，Windows 用显式 `[ \t\n\r\f\v]`）：ASCII 空白是「没给」，其余一律是**值**，由服务端的绝对路径规则拒绝。
    - **⑦ 杂项（实测/静态）**：隔离目录原先 `mkdir -p` 吃调用者 umask，实测在 0700 的父目录旁建出 **0755**，而记录里含用户标签与工作目录 → 改为 `( umask 077; mkdir -p … )`（实测 700）；`repair_guard_stderr` 的 `mktemp` 同样补 `umask 077`；`workdir_is_blank` 的 `remaining` 未 `local`，是个全局泄漏。
    - **⑧ 文档**：`SKILL.md` 的 `wait` 段补齐 `1` 的第二种来源（`pueue wait exited …`，服务端两种措辞）、`lock_contention` 覆盖安装器维护锁、request id 的首字符规则；`CLAUDE.md` 退出码表加维护锁一行。
    - **未采信的三条（服务端 Agent 的 ①②③，我逐条复现后推翻）**：它用 `touch`/伪造 body 的 `DyNqB1legacy-aaaa` 记录断言「合法旧 id 漏网并卡死所有命令」——该 id 按新旧规则都合法，失败来自我自己的伪记录体（`request_records_filter` 要求 `payload`/`task_label`/`state` 齐全）；用 `mktemp` 的构造断言「`make_temporary_file` 生成非隐藏名」——该函数是内部拼模板 `"$dir/${prefix}.${owner}.XXXXXX"`，非裸 `mktemp`；把 `.legacy-orphans` 的 `find` 递归写成缺陷——本轮已按 `-maxdepth 1` 修好。**教训**：Agent 的 probe 若自建 fixture，必须先用同一判据证明「好输入通过」，否则它测的是自己的 fixture。同一轮它报的另外两条（`run_pueue` 屏蔽 stderr、`logs` 退 1 无输出）是刻意的既有设计/已被 0.1.26 的 `Pueue could not read the log` 诊断覆盖，未改。
    - **锁**：`smoke/18` 新增「legacy quarantine」组（三份旧名 record 必须进 `.legacy-orphans/`、真临时名**不得**被隔离，另加一条二次运行不搬不覆盖；共 2 例，其中**隔离目录必须 0700** 的断言在主例内——两棵树都在显式 `umask 022` 下跑，`stat -c '%a' || stat -f '%Lp'`，读不到模式计失败而非跳过）+ 6 条空白 `--workdir` 必退 2（`41 09 0a0d0c0b c2a0 e38080 c285`）；`smoke/12` 新增 3 条 request-id 差分（尾随 LF、U+212A 开头、U+0130 开头——两侧都退 2 且都报 `start with a letter or number`；值用 `$'\n'` 与八进制 `printf` 构造，macOS 的 bash 3.2 没有 `\u`）。**第七十七类的「隔离未做成自动断言」边界就此关闭**（不再需要一份旧规则的服务端：旧名文件直接播下去即可）。
    - **红证（逐条、单次变异、跑完即 `cmp` 还原）**：① 去掉 `umask 077` 包装 → `smoke/18` 报 `base-quarantine-mode:755 variant-quarantine-mode:755`，rc=1；② 把精确豁免换回 `case "$name" in .agentqtmp.*) continue ;; esac` → `base-missing/base-left:.agentqtmp.aaaaaaaaaaaaaaaa.json`（双侧），rc=1；③ Windows 副本换回 `-match '^…$'` → `smoke/12` 恰 3 条 `[request-id trailing-lf|kelvin-sign|dotless-capital-i]: windows-exit=255`，rc=1；④ POSIX 副本把 `workdir_is_blank` 换回 `case … [[:space:]]` → `smoke/12` 非 ASCII 空白差分变红，rc=1。
  - **第七十七类（2026-11-09，用户「本项目还有其他问题吗，使用Agents进行全维度全场景审查，也让codex审查一下」——5 个隔离 worktree 的审查 Agent + Codex 全量复审，我逐条复现后才采纳；三对 Agent/Codex 的结论被实测推翻、未采信）**（资产变更：`unix/agentq-server` 与 canonical 孪生、两份客户端；`CHANGELOG.md`、`CLAUDE.md`、`SKILL.md` 未改语义。）
    - **① `is_request_id` 的首字符规则只在消息里（P0）**：服务端（`agentq-server` 的 `is_request_id`）与 POSIX 客户端是同一份代码：`''|*[!集合]*|[!集合])` —— 第三支没有 `*`，是**单字符串**匹配，于是 `.aaaaaaaaaaaaaaa` / `_aaaaaaaaaaaaaaa` / `-aaaaaaaaaaaaaaa` 全部通过；三处报错都写着 `start with a letter or number`。Windows 孪生用 `^[A-Za-z0-9][A-Za-z0-9._-]{15,127}$`，一直是对的。**点开头的 id 不是美容问题**：`request_record_path` 写 `$request_directory/.<id>.json`，而服务端每个枚举都走 `shopt -s nullglob; "$dir"/*.json`（不开 `dotglob`），实测同目录下 `.abc.json` 不在 glob 结果里——该请求能提交、能建任务、`lookup` 走直读路径也能查到，但**永远不会被归档或修复**，是一条不可发现的死记录。修法：两支都写成 `[!集合]*`（照抄 Windows 的语义），`is_request_id` 加注释说明为什么第二个括号必须带 `*`。
    - **② 修复本身的升级陷阱（本轮新发现，比 ① 更险）**：规则收紧后，旧部署已经写下的 record（隐藏的 `.id.json`，以及可见的 `_id.json`/`-id.json`）会让**新**服务端的每一条命令退 2——`prune_request_temporary_files_in_directory` 把所有 `.*.json` 当临时文件、名字解析不出 `<id>.<pid>` 就 `fail`；`load_request_records` 与 wait 的扫描对文件名 id 跑 `is_request_id`，旧 id 不再合法同样 `fail`。**沙箱实测复现**：红证用旧服务端建出一条隐藏 record，换回修复版后 `lookup` 直接 `invalid AgentQ request temporary process id`、`status` 报 `invalid AgentQ request record filename`。修法：`quarantine_legacy_request_records`（挂进 `ensure_request_record_layout` **与** `migrate_removed_request_records`——后者是三条免锁读路径的共用前置点，`lookup` 恰好在锁路径之外先读），把「旧规则合法、新规则非法」的 record 连同字节移进同目录下的 `.legacy-orphans/`；没有任何扫描会进入该子目录（每个枚举都只 glob 一层且要求 `.json` 后缀），数据留给人，活路径不必学会跳过不再可寻址的 id。`.agentqtmp.*` 显式豁免（那是本服务端自己的临时记录，归 pruner 管）。`is_legacy_request_id` 只用于**识别存量**，绝不用来放行新输入。
    - **③ 纯空白 argv 的两端分歧（P1）**：`--request-id ' '` 在 POSIX 上退 `2`（`[ -z ]` 判空后再走字符集守卫）、在 Windows 上**静默生成 GUID 并提交**（`IsNullOrWhiteSpace` 当未提供）；`--workdir ' '` 在 POSIX 上白跑一次 SSH（服务端的 `working directory must be absolute` 不转发给调用方）、在 Windows 上本地退 `2`。修法对齐**结果**而不是谓词：Windows 的 `requestId` 判定改 `IsNullOrEmpty`（纯空白落进 `Test-RequestId` 退 2，与 POSIX 同一句消息）；`workdir` 两侧都显式拒绝纯空白（POSIX 用 `case` 的 `*[![:space:]]*` 免 fork，Windows 用 `IsNullOrEmpty` + `^\s*$`，`'/a b'` 这种含空格的合法值两侧都仍放行到 SSH）。
    - **④ `AGENTQ_PASSWORD` + `AGENTQ_PASSWORD_PROMPT` 同时设置（P1）**：ASKPASS 分支拒了它的两个组合，密码分支没有——实测 POSIX 静默取密码、照发起 SSH，提示来源成了死代码，而 `SKILL.md` 说「与另一来源同时设置时客户端拒绝运行」。Windows 侧两种情况本来都拒。补一句同源守卫，消息沿用 `'… are both set; set only one'`。
    - **⑤ 保留前缀检查的位置导致孪生报错优先级分歧**：POSIX 把 `agentq:` 检查放在参数循环**之后**（在 `--workdir is required` 与「缺命令」之后），Windows 放在 `--label` 解析分支**内**。实测 `submit --label agentq:x` 配缺 `--workdir`/缺命令时，两侧都退 2 但点名的是不同错误。修法：POSIX 把检查移进 `--label` 分支（与空标签检查并列），删掉循环后的那份。
    - **⑥ `run_pueue` 不屏蔽 pueue 自身的 stderr**：客户端读服务端 stderr 找 `reason=<class>`、取**最后**一条匹配，pueue 自己打的 `x: reason=…` 形态文本可以顶替真实类别；成功路径上它也是无法解释的噪点。`run_pueue` 两个平台分支都加 `2>/dev/null`。连带把 `compact_log` 的「`pueue log` 非零退出」路径补一行 `Pueue could not read the log for task N`——原先静默退 1 且无 `reason=`，调用方只能拿到退出码。
    - **⑦ 文档与计数**：`CLAUDE.md` 的退出码表称 `0–6` 全由服务端产生，但 `wait --timeout` 的预算耗尽在两份客户端上都本地产 `6`；`CHANGELOG` v0.1.24 索引行写「共四处拒绝」（守卫实际是 4 文件 × 2 = 8 个物理站点、6 个逻辑站点）。两处都按事实改写（历史条目只改这一处失真计数，因为它是**当前**版本的摘要行，不是过程叙事）。
    - **锁**：`smoke/03` 对 `submit`/`lookup` 各跑三种非法开头（退 2 + `start with a letter or number` + `reason=protocol_error`）；`smoke/05` +10（同上三条 POSIX 侧 ×2 入口、`--workdir` 空白两格、两条前缀优先级、一条 `PASSWORD+PROMPT`）；`smoke/12` 孪生表 +7 行（含单字符 `.` 与首字母正控）+ 两条直接 pair（空白 `--request-id`/`--workdir`），floor 保持 25、行数 30→37。**05 与 07 的计数**由摘要行自报：`cases=107 env=39`、`cases=196 twin=checked(37/37)`。
    - **红证（逐条、单次变异、只动一份副本）**：① POSIX 副本把 `is_request_id` 还原成缺 `*` 的两支 → `smoke/05` 4 条点名 `stderr does not contain start with a letter or number`，rc=1；② Windows 副本只把 `requestId` 还原成 `IsNullOrWhiteSpace` → `smoke/12` 恰 1 failure `whitespace request-id: windows-exit=255`；③ 只把 `workdir` 守卫还原成 `IsNullOrEmpty` → 恰 1 failure `whitespace workdir`；④ 把旧服务端喂 `smoke/03` → `submit accepted a request id starting with . (exit 0)`，rc=1，修复版 rc=0。**第一次红证整体无效并已弃用**：快照拷进 `/tmp` 时丢了执行位，`smoke/05`/`smoke/12` 的「红」全部是 `Permission denied`（调用错误），其中 `smoke/12` 还有 `$script:Program` 未设置的抛错——被判为无效红证，不是资产缺陷。
    - **边界**：① `.legacy-orphans/` 的隔离在沙箱手工验证（两种形态：隐藏 `.aaa…` 与可见 `_aaa…`，均进入子目录、`lookup`/`status` 恢复绿），**未**做成 `smoke/03` 的自动断言——构造它需要一份旧规则的服务端，而那正是本仓不该再发布的东西；记为「由手工实测覆盖，CI 不覆盖」。（**2026-11-09 第七十八类已关闭**：当时以为必须有一份旧规则的服务端，其实只要把旧名文件直接播进记录目录即可，`smoke/18` 的 legacy quarantine 组就这么做。）② `is_legacy_request_id` 与 `is_request_id` 的字符集必须同步演进，两者都是逐字写出的集合，没有静态规则把住一致性——若将来加字符，两处要一起改。③ 真远端与 Windows 目标未复测；PS 5.1 的 `-match`/`IsNullOrEmpty` 语义本轮未在 5.1 上跑（pwsh 7.5.4 通过，`ps51=NOT-covered`）。④ `run_pueue` 的 `2>/dev/null` 让 pueue 的失败细节不再出现在服务端 stderr 上——调用方拿到的仍是契约消息与 `reason=`，但运维手动排障时要直接跑 pueue。
  - **第七十六类（2026-11-08，收尾复查 0.1.24 时抓到的两条：`--tail all` 仍按文本判定、空标签生产/消费不对称）**（资产变更：`unix/agentq-server` 与 canonical 孪生、两份客户端；`SKILL.md`。）
    - **① `--tail all` 的措辞也能被诚实输出触发**：0.1.24 只给默认 tail 加了「与原始文件同窗口对照」，`--full` 分支仍是纯文本匹配。实测（0.1.24 资产）：任务真实输出同时含 `(Pueue error) Failed to read local log output file:` 与 `stream did not contain valid UTF-8`（比如它本身就在扫 Pueue 日志）时，`logs --tail all` 把**合法 UTF-8** 包成 base64——而 `SKILL.md` 说 `output_encoding: "base64"` 意味着「任务输出并非 UTF-8」，断言为假（解码后与磁盘逐字节相同）。修法：两种措辞统一走**数据对照**——`--full` 用 `cat` 与渲染窗口比、默认 tail 用 `tail -n N` 比，相同即任务自述、不同才重编码；原始文件不可读时留在重编码臂（其守卫会响亮报错，方向是「宁可给真实字节，不给 Pueue 文本」）。0.1.24 里为「tail 数值越界」加的 `log_window_raw_status` 守卫随之删除：读失败落回重编码臂同样响亮，规则更少一条。
    - **② 空标签：生产方接受、消费方拒绝（先于本次存在）**：`submit --label ''` 服务端实测建出 label 为 `""` 的任务，两份客户端的解析器也只检查「有没有值」；而 `remove --label ''` 三方都拒绝（`smoke/02` 还钉住了这条）。后果：这种任务**永远无法按标签批量清理**，只能单任务 `remove <id>`，`status --task` 显示 `""`。修法选了提交侧拒绝：`[ -n "$label" ] || fail '--label must not be empty'`（两份客户端本地 + 服务端，三处同一句）。
    - **锁**：`smoke/03` +2（`--tail all` 下诚实打印完整措辞必须返回纯文本——与既有 binary-log 的 base64 用例成对，一个证「真非法仍编码」、一个证「诚实输出不编码」；空标签提交退 `2` + 消息 + reason），token 增 `full-wording=text/0 empty-label=2/2`；`smoke/05` +1（本地拒绝空标签）；`smoke/12` 加一条**直接 pair 调用**——`read -ra` 的差分表不做引号移除，`--label ''` 在表里会变成两字符标签 `''`，空值只能用显式空参数调用（既有先例：host 值里的纯空白族同样走专用 runner）。
    - **红证**：① 在 0.1.24 资产上实测返回 base64（本轮评估时量的）；把对照改回「见措辞即重编码」→ 新正控红。② 去掉提交侧空标签守卫 → 实测退回退 `0` 并建出任务（评估时量的）；客户端两条用例在去掉本地守卫后同样红。**Windows 那条红证第一次无效（记为操作错误，不是资产缺陷）**：在 `smoke/12` 运行期间改写该文件，bash 边读边执行，半个脚本之后报出 `syntax error near unexpected token 'fi'`——那次「红」来自被改动的执行体；运行期间不动文件重跑，1 failure 落在空标签用例上，才是有效红证。
    - **边界**：① `--full` 的 `output` 是文件原文（**含**结尾换行，实测），对照在 `$( )` 里两侧同法剥尾，故尾部换行数量不影响判定；对照假设 `--lines N` 与 `tail -n N` 同语义，不一致时方向安全。② `--label ''` 从此被拒是行为变更（无人依赖的形态），发布说明点明。
  - **第七十五类（2026-11-07，同一轮「还有没有别的问题」再深挖，四条：默认 tail 的逐行替换串、`agentq:` 保留前缀、`status --task` 的身份歧义分歧，以及上一类**自己写错**的一句文档）**（资产变更：`unix/agentq-server` 与 canonical 孪生、两份客户端；`SKILL.md`、`CLAUDE.md`。）**
    - **① 默认 tail 的逐行替换串（独立审计发现，我用同一沙箱复现）**：日志含非 UTF-8 时，`pueue log --json <id> --lines N`（默认路径）**只把那一行**替换成 `Pueue: Failed to read line.` 并**退 0**（实测 4.0.4：混合非法与全非法的日志都如此）；`--tail all`（`--full`）走的是另一种措辞（`(Pueue error) Failed to read local log output file: … stream did not contain valid UTF-8`），那个分支 0.1.23 之前就处理了。危害坐实：一个任务写非法字节、另一个任务**直接 printf 这行文本**，两次 `logs` 的 `output` **逐字节相同**——调用方无法区分「命令输出」与「Pueue 自述」。这正是第七十四类①声称消除的那一类，措辞不同、路径不同，所以两个既有分支都没接住。
    - **修法：不匹配文本下结论，而是与原始文件对照**。识别到该串后，重读**原始文件的同一窗口**（默认 tail 用 `tail -n N`），与 Pueue 的窗口比对：不同 → 说明 Pueue 替换过，按 `--tail all` 的同一 base64 信封返回**真实字节**；相同 → 任务自己打印了该行，原样返回文本（避免「凡见该串皆重编码」把诚实输出误报成非 UTF-8）。`--full` 模式永不逐行替换（实测），故该模式下见该串即任务自述。
    - **② `agentq:` 是保留前缀（修法选了收窄语义，不是再加一句文档）**：`--label` 不限字符集，可以写成 `agentq:<另一个任务的 request-id>`；此时 `remove --label <那串> --confirm` 删掉的是**用户标签恰好等于它**的任务，而摘要里那一行对应的任务**仍在**、命令退 0（实测）。修法：`submit --label` 与 `remove --label` 都拒绝以 `agentq:` 开头（两份客户端**本地**拒绝 + 服务端拒绝，四处同一句消息、都带 `reason=protocol_error`）。这是**破坏性边界**：想用 `agentq:` 做前缀的用户标签从此被拒（发布说明需点明）；但 `agentq:` 本就是 AgentQ 自己的命名空间，收窄比继续让人踩坑好。
    - **③ `status --task` 与 `wait`/`logs` 对身份歧义给出相反答案**：同一歧义状态（一条 `task_created_at` 不匹配的第二活动记录）下，`wait` 退 `6`/`unavailable`、`logs` 退 `6`/`unavailable`，而 `status --task` **退 `0` 返回 `Done`/`Success`**（实测）。文档把 `status --task` 写成 `wait` 超时后的推荐回退，调用方据此会拿到 `wait` 拒绝担保的「成功」。修法：服务端给 `status --task` 加**同一** `task_identity_is_unambiguous` 守卫（与 `logs`/`wait` 逐字同源），歧义时退 `6`/`unavailable`；客户端两侧对 `6` 本就原样透传（实测：POSIX 只在 `--task` 解析期做本地校验，非零响应直接 cat body 返回；Windows 在非零路径不校验形状），无需改。
    - **④ 第七十四类自己写错的一句（文档）**：上一类写「两串同形」，实测是**每行各自的**裸标签（各不相同）；真正的错误删除形态见 ② 。已改正。
    - **锁**：`smoke/03` +7 例（默认 tail 非法行→base64 且字节相符、诚实打印该行的正控→纯文本、保留前缀 submit/remove 各退 `2` + 消息 + reason、「仅含 `agentq:` 字样」的正控必须通过、`status --task` 歧义→`unavailable`/`6` 且不带 `task`），摘要 token 增 `line-marker=base64/0+text/0 reserved-label=2/2 status-ambiguous=unavailable/6`；`smoke/05` +2（客户端本地拒绝）、`smoke/12` 孪生表 +3（含「仅含该词必须到 ssh」的正控，floor 27→30）。**变异红证（在仓库内跑，逐条恢复后 `cmp` 相同）**：① 让行标记永不匹配 → 「未按 base64 返回」；② 去掉两处保留前缀守卫 → 「submit 接受了保留前缀，退 0」；③ 去掉 `status --task` 守卫 → 「退 0，期望 6」；④ 让「见串即重编码」→ 正控「诚实打印该行的任务丢了纯文本输出」。四条各自被自己的断言点名，无一是崩溃或调用错误。
    - **边界**：① 逐行替换串是按 Pueue 4.0.4 实测的措辞；换版本变措辞则回落到「原样透传」（与修复前同），不会崩但少覆盖。② 对照的是**同一窗口**——若 Pueue 的 `--lines N` 与 `tail -n N` 语义在某个版本上不一致，对照会误判为「不同」而重编码（方向安全：多给真实字节，不给假文本）。`--tail` 没有数值上界时 `tail -n` 可能失败，那会让空串被读成「不同」并重编码诚实日志——对照只在重读**成功**时进行，否则保留 Pueue 的回答（即修复前行为）；此情形本机未构造。③ `agentq:` 收窄是行为变更，未做版本协商（本仓无协商字段），旧客户端仍可提交该前缀（服务端会拒绝）。④ 真远端/Windows 目标未复测。
  - **第七十四类（2026-11-07，继续问「还有没有别的问题」时量出来的两类，都属「契约说这是一回事，实际是另一回事」）：`logs` 把 Pueue 的**内部诊断**当成任务输出、退 0 交出去；`status --summary`/`doctor` 的 `label` 是 Pueue 的**裸标签**，与 `remove --label` 认的用户标签不是一回事。**（资产变更：`unix/agentq-server` 与它的 canonical 孪生；`SKILL.md`。）**
    - **① `logs` 把 Pueue 诊断当任务输出（实测，沙箱运行时）**：`pueue log --json` 在日志文件打不开时**退 0**，`output` 字段是 `(Pueue error) Failed to get log file handle: …`。服务端只对「非 UTF-8」那一形态做了处理，这句措辞没认，于是：**Queued 任务**调 `logs` 得到 `output` = 这行诊断、退 `0`；**Done 但日志已被删**的任务同样拿到这行、退 `0`——`SKILL.md` 说 `output` 是任务日志，调用方会把它当命令输出读。同时这串里带着**服务端本机的日志路径**。
    - **修法（按状态给不同答案，而不是一律报错）**：`compact_log` 识别该前缀后先看磁盘上的日志文件——可读则照常走原路径（前缀相同也出现在「文件在但打不开」的情形，不能一概当缺失）；不可读时以 `status` 判别：带 `Done` 的任务**已无答案可给**，输出 `{task_id, state: "unavailable"}` 并退 `6`（复用既有语义，不新增退出码）；仍在排队则正常返回 `{task: …}`、`output` 为空串、退 `0`——「此刻还没有日志」本就是 Queued 应有的状态。
    - **② 两套标签（实测，沙箱运行时）**：`submit --label L` 把 L 存进 request record，`status`/`status --task`/`logs`/`wait` 经 `decorate()` 显示 L；`status --summary` 与 `doctor` 默认摘要**刻意不连接 request records**（这是它便宜的来源），只能显示 `pueue add --label` 写下的裸标签 `agentq:<request-id>`；`remove --label` 匹配的是 L。后果：拿摘要里的标签去批量删——对裸标签**静默匹配不到、退 0 返回 `[]`**；两个任务共用同一 L 时摘要把它们显示成两串同形的 `agentq:…`，照抄其中一个去删会删到**另一串**。这是可用性问题，不是数据损坏，但「吞掉、退 0」让它容易被当成成功。
    - **③ 标签的修法选了文档 + 锁，不加运行时提示**：让摘要去连 request records 就把它的成本优势抹掉；在服务端 stderr 打提示，客户端按设计只转发 `reason=` 标识符，到不了调用方。所以 `SKILL.md` 的 `status` 与 `remove --label` 两处各点名这条语义，`smoke/03` 在**同一个任务**上同时钉两面：`status --summary` 的 `label == "agentq:" + <request-id>`，`status --task` 的 `label == <用户标签>`——任一面漂移都会红，而不是等到某次批量删除「删到别的」才发现。
    - **锁（行为，`smoke/03`）**：两条新用例 + 同上的标签双面用例，摘要 token 新增 `missing-log=empty/6` 与 `label-surfaces=raw/decorated`。红证：① 两条 logs 用例在修前资产上分别得到「Pueue 诊断串 + 退 0」与「退 0」，改后分别为空输出/`0` 与 `unavailable`/`6`；② 标签用例在正常树上绿，把 `--summary` 断言改成比对用户标签即红（即第七十四类①那个陷阱本身被钉住）。**排布教训**：删日志的用例先于排队用例执行时会 `exit`，把后者遮住——证明排队用例时用的是临时打补丁的副本，单独跑通后才放回。
    - **本轮抓到、但属于「检查自身/被锁救回」的三处（都已修），全部是改完先跑套件才发现、不是推演出来的**：① `smoke/03` 新写的 `printf … | grep -qF` 触发仓库既有 `repo_pipes` 规则——这是真的（pipefail 下会把命中读成未命中），改为 here-string；② 服务端新写的 `jq … < "$file" 2>/dev/null` 触发 `redir_noop` 规则（`<` 的打开错误在重定向生效前就已打印，`2>/dev/null` 是空操作）——**我的第一版修法是错的**：把文件改成 jq 的**位置参数**，`--quick` 看不出问题，全量套件的 `smoke/29`（「每条记录恰一个 jq 程序」）当场报 `69:2` 并在报错文本里点名了这个形态（"jq is now given a positional input FILE … paths are redirections"）；③ 有价值的盲区观察：**`smoke/08` 没抓到这条**——它是行为锁，桩只服务一个「已完成且日志在」的任务，新分支（排队/日志缺失）它的驱动器根本走不到；真正兜底的是 `smoke/29` 的计数形状。最终修法按 `redir_noop` 规则自己的文本：`{ jq … < "$file"; } 2>/dev/null`（组内重定向、组上压诊断），既保留「路径走重定向」的仓库约定，又让 `2>/dev/null` 真正生效。
    - **边界**：① 判别依赖 `pueue log --json` 里 `task.status` 是对象且带 `Done` 键——这是 Pueue 4.0.4 的实测形状，其他版本未测；形状变了会落到「排队」分支（空输出），不会崩溃但会少报不可用。② 「前缀相同但文件可读」时按原路径继续读，若 Pueue 此时真给不出内容，输出会是 Pueue 的诊断串而不是日志——这种情况本轮没有构造出来（需要文件可读却又打不开），记为未覆盖。③ 标签语义只改了文档与锁；调用方若仍照抄摘要标签去删，仍是静默 `[]`——这是本次**刻意接受**的残留，因为改行为会破坏「摘要不连 record」的性能契约。
  - **第七十三类（2026-11-07，上一类收尾当天继续「还有没有别的问题」时把同类隐患在**其他构造**上逐个量出来的）：大小写折叠走 `tr '[:upper:]' '[:lower:]'`，而 `tr` 的字符类映射**随 locale 变**——glibc 主机 + `tr_TR.UTF-8` 下 `I` 不被折叠，`agentq SUBMIT` 变成 `unknown command: submIt`；同一轮用字节级探针重画了「区间按谁排序」的整张工具×libc 表，发现上一类留下的两处声明比证据宽。**（资产变更：`client/unix/agentq`、`client/unix/sshp`、`unix/agentq-server` 与它的 canonical 孪生、`unix/install-agentq.sh`。）**
    - **① `tr` 折叠缺陷（实测确认，Ubuntu 24.04 + glibc + `locale-gen tr_TR.UTF-8`，真实资产、`AGENTQ_SSH=/bin/false`、不碰网络）**：`agentq SUBMIT …` 在 `tr_TR.UTF-8` 下退 2 `unknown command: submIt`，`en_US.UTF-8` 下通过本地校验；`AGENTQ_REMOTE_PLATFORM=UNIX` 同样被拒；`submit --WORKDIR … --REQUEST-ID …` 报 `unknown submit option: --WORKDIR`。影响面是全部含 `I` 的记号（命令词 `SUBMIT`、选项 `--WORKDIR`/`--REQUEST-ID`/`--STDIN-SCRIPT`/`--TAIL`/`--TIMEOUT`、环境值 `UNIX`/`WINDOWS`），全部 fail-closed（受控拒绝），但孪生分歧成立：Windows 客户端的 `switch`/`-eq` 实测在 tr-TR culture 下仍按 invariant 比较（`"I" -eq "i"` 为 True）——同一输入 Windows 接受、POSIX 拒绝。**macOS 的 BSD `tr` 在同一 locale 下正确折叠 `I`（实测），所以本机不可复现**——这正是它需要**静态锁**的原因。修法：两份 POSIX 客户端 15 处折叠全部加 `LC_ALL=C`（同文件 `tr -d '\r'` 早已是这个写法；实测 `LC_ALL=C tr` 在两套 libc 上只折叠 ASCII）。**教训与上一类同族**：坏格只在 glibc + 土耳其语系 locale 上存在，行为用例写出来在本机永远绿。
    - **② 区间归属的完整表（字节级探针重测，逐格 `LC_ALL=en_US.UTF-8` vs `C`）**：shell `case` 区间 → macOS **敏感**、glibc **字面**；`grep`/`sed` 区间 → macOS **字面**、glibc **敏感**（`printf 'café\n' | grep -cE '^[A-Za-z]+$'` 在 glibc+en_US.UTF-8 答 1、C 答 0；macOS 两种 locale 都答 0）；**数字区间**（`[0-9]`/`[!0-9]`）在两套 libc、两种工具上**都字面**。所以「这个工具安全」和「这台主机安全」都不能推广——唯一可移植的拼写是显式集合。
    - **③ 数字区间从「豁免」改为「违规」**：第七十二类的静态规则把 `[0-9]` 排除在外，理由写着「实测是字面的」。这句只在**测过的那几格**成立；现在 `chr_ranges` 的判据是「方括号里出现任意字母数字区间」，不再区分字母与数字（13 处 `[!0-9]` 风格守卫全部改写为显式数字集合，行为不变——同轮曾在嵌套引号 fixture 下误测出「glibc 接受阿拉伯数字」，用字节级脚本重测后推翻，记为 fixture 教训：**嵌套引号会改字节，探针要落盘再跑**）。
    - **④ 同一轮在 glibc 上发现的真实站点**：`install-agentq.sh` 的未渲染占位符检测 `grep -qE '__[A-Z][A-Z0-9_]*__'`（读 systemd/launchd 资产，找 `__AGENTQ_...__`）——glibc + 带排序的 locale 下 `[A-Z]` 会匹配重音大写字母，一段非 ASCII 的服务文件会被误判为「含未渲染占位符」。已改为显式集合。
    - **锁（静态三道，全部带双向校准与红证）**：`smoke/01` ① `chr_ranges` 判据放宽为「任意字母数字区间」（终端 `case` 备选 + 行内任意 `[!...]` 负集两种形态；正区间只认终结形态，非终结正区间记为边界）；② 新增 `tool_ranges`——行内出现 `grep`/`sed`/`awk` 且带方括号区间即违规（jq 按构造出局：Oniguruma 是码点区间；`LC_ALL=C` 行豁免）；③ 新增 `tr_fold`——`tr '[:upper:]'`/`'[:lower:]'` 不带 `LC_ALL=C` 即违规。红证（仓库内跑）：三处真实站点各改回旧拼写 → 三条规则各自点名（`sshp:126`/`sshp:321`、`install-agentq.sh:1849`、`agentq:4436`）退 1；还原后 `cmp` 相同、全绿。行为侧：`smoke/05` 的 `AGENTQ_REMOTE_PLATFORM` 大小写表加 `UNIX` 行（含 `I` 的拼写）、`smoke/12` 的孪生差分表加 `SUBMIT --workdir /tmp -- true` 行（**表内不放注释**——首字段非空的行会被当成用例，实测踩到）。
    - **边界（如实记录）**：① `tr` 坏格只在 glibc + 土耳其语系 locale 上存在，本机（BSD）与现有 CI 矩阵都不含该格，行为层不可变红——保证来自静态规则，不来自行为用例。② `awk` 的区间归属**未测**（资产里没有 `awk` 带区间的非 C 站点）。③ musl、`az_AZ` 等其他把 `I` 特异的 locale 未测。④ `tool_ranges` 的 `\b(grep|sed|awk)\b` 判据对**变量里存的正则**（如 `response_filter`）不可见，jq 之外未见此类站点。⑤ 非终结的正区间（`*[a-z]*|foo*)`）静态规则看不见——现存资产没有这种写法。
  - **第七十二类（2026-11-06，用户问「本项目还有其他问题吗」后逐个量出来的）：POSIX 客户端用方括号**区间** `[A-Za-z]` 写字符集守卫，而区间是按**排序规则（collation）**匹配的——在带排序规则的 locale 下，重音拉丁字母落在 `A-Z` **里面**，于是「只允许 ASCII」的守卫放行了非 ASCII 标识符，与 Windows 孪生和服务端自己的契约相反。**（资产变更：`client/unix/agentq`、`client/unix/sshp`、`unix/agentq-server` 与它的 canonical 孪生。）**
    - **实测（同一 argv，只换 shell 与 locale）**：`bash` + `en_US.UTF-8`（macOS 的默认值，`/bin/sh` 也是 bash 3.2）下 `aé` **落在** `[A-Za-z]` 内；`bash` + `C`/`C.UTF-8`、`dash`、`zsh` 一律**在外**。所以这不是平台差异，是 shell × locale 差异，而本机默认就落在坏的那一格。
    - **真实资产上的后果（修复前 0.1.20 资产）**：`sshp --check <host> café` 穿过了字符集守卫、直接驱动远端探针（退 `255`）；`agentq lookup aaaaaaaaaaaaaaaaé`（17 字符，长度合法、只有字符集该拒）同样穿过去走到 SSH；**服务端**也接受它，回退 `3` `not_found`——一个它自己的契约（16–128 ASCII）称为非法的 id，被当成「查无此 ID」的正常答案报告出去。**Windows 两份客户端对同一 argv 都退 `2`**：这正是本仓最忌讳的「孪生对同一输入给相反答案」，而且方向是 POSIX fail-open。
    - **为什么活了这么久**：所有字符集用例喂的都是 ASCII 标点（引号、分号、斜杠、空格、`-` 开头）——它们在**任何** locale 下都不在区间内，所以行为锁全绿。静态侧也没有任何规则检查「`case` 模式里出现方括号区间」。缺口是 `smoke/19` 的会话名矩阵只覆盖「非法 ASCII」，没有一个**非 ASCII 字母**。
    - **修法（5 处，全部把集合逐个写出）**：`client/unix/sshp` 的会话名字符集、`client/unix/agentq` 的 `is_request_id`、服务端 `is_request_id`、服务端两处临时文件 nonce 校验（`candidate_random` / `temporary_random`）、服务端 `normalize_workdir` 的 Windows 盘符模式（`[A-Za-z]:[\/]*`——区间在排序规则下还能匹配**多字节**字符，盘符位置因此可能吞掉一个非 ASCII 字符）。显式列表逐字节匹配，在所有 shell/locale 下同义，且不需要为守卫派生一个子 shell（`( LC_ALL=C; case … )` 也实测可行，但 `is_request_id` 在热路径上，避免每次多一个 fork）。Windows 侧无需改动：.NET 正则的 `[A-Za-z]` 是字面的 ASCII 区间，本来就与 locale 无关。
    - **锁（静态 + 行为，四道；静态规则本身也返工过一次——见下）**：`smoke/01` 新增 `chr_ranges` 静态规则——扫全部 shell 资产的 `case` 备选形态（方括号表达式紧跟 `*)` 或 `)`），判据是「方括号里出现**字母**区间」而不是字面的 `A-Z`/`a-z`：第一版只认那两种拼写，随后就被自己的漏网形态抓住——`client/unix/agentq` 的 `[0-9a-f][0-9a-f]*)`（平台缓存摘要前缀校验）同样是字母区间，实测 `éé` 在 bash+`en_US.UTF-8` 下通过它并**命名了一个缓存文件**；`[0-9]` 这类**数字**区间反而在各处实测是字面的（bash/dash × C/en_US.UTF-8 都拒绝阿拉伯-印度数字与全角数字），所以规则不拦数字区间。**（2026-11-07 订正：第七十三类的字节级重测确认这只在测过的那几格成立，判据已改为不区分字母数字；此句保留为当时的判断。）**`LC_ALL=C` 行豁免、注释行跳过（这条注释本身带着违规拼写，规则若自匹配就会报正确的树为坏，`smoke/16` 的自掩蔽教训），并带双向校准 fixture（一个违规备选必须**恰好**计一次；同文件里的注释、`LC_ALL=C sed`、jq 正则行一个都不许计）。它刻意只认 `case` 形态：`grep -E`、`sed`、jq 的方括号在**本机**实测不随 locale 变，把规则放宽到它们只会制造误报。`smoke/19` 加 11 例：`café` 在 `/bin/sh`、bash、dash、zsh × `C`、`en_US.UTF-8` 的每一格都必须被拒（逐格一条用例、直接起对应 shell，不走 `run_case` 固定的 `/bin/sh`）、一条枚举自校准（少于 2 格即失败，空表不算绿）、一条 CJK、以及一条 **ASCII 正控**（合法名必须穿过守卫抵达桩探针——没有它，一个「凡名皆拒」的实现能通过全部红行）。每一格同时用**旧惯用法**（`case "$1" in [A-Za-z])` 配单字符 `é`）探测「这一格是否真有该风险」：若本机一格都没有（glibc 实测如此），把结果作为摘要 token 报出（`charset-cells=` / `charset-vulnerable=`，本机 `8`/`2`），并在 0 格时另打印一行 note 说明该矩阵在本机无法变红、跨平台锁是 `smoke/01` 的静态规则——**不判失败**，因为那不是资产问题，而是平台没有这个风险形态。`smoke/05` / `smoke/12` 各加一条非 ASCII request id（POSIX 与 Windows 两侧同一句消息）。`smoke/02` 加一条服务端用例。
    - **红证（全部在仓库内跑）**：① 静态规则把服务端那行改回区间形态 → `smoke/01` 点名 `skill/assets/unix/agentq-server:613` 退 1；② `smoke/02` 对区间形态的服务端副本报 `lookup-nonascii-id: expected exit 2, got 3` 退 1；③ `smoke/05` 对区间形态的客户端副本（**文件名保持 `agentq`**，否则 `--version` 用例会因副本名不匹配而假红）报该用例失败退 1；④ `smoke/12` / `smoke/19` 的用例同样对区间形态红。还原后四处逐字节相同、全部绿。
    - **边界（如实记录）**：⓪ **风险形态是 BSD libc 特有的**——同一段区间匹配，macOS（BSD libc，bash 3.2）把 `é` 算进 `[A-Za-z]`，而 Ubuntu 24.04（glibc，bash 5.2，`locale-gen en_US.UTF-8` 之后）实测**不**算；C.UTF-8 两边都不算。所以这条缺陷在本机（macOS）可达且已实测复现，在 glibc 上未观察到，行为锁在 glibc 主机上无法变红（`smoke/19` 会打印那行 note）——跨平台锁是静态规则，不是这个矩阵。其他 libc（musl 等）未测。① 静态规则只认单行 `case` 备选；跨行书写的模式看不见——现存资产没有这种写法，但新写一个它不会报。② 规则对 `grep`/`sed`/jq 的方括号**不覆盖**：本机（macOS，BSD grep/sed）实测它们不随 `LC_COLLATE` 变；glibc 主机上 grep 的区间是否随 locale 变**未测**，记在这里而不是声称安全。③ 服务端 nonce、盘符与客户端的缓存摘要前缀三处只做了静态修正，没有行为 fixture——它们由内部状态驱动，构造成本高于收益；静态规则保证拼写，行为后果未测。⑤ **静态规则的范围本身就是一次返工**：第一版正则在上面这些修正全部落地后仍漏 `[0-9a-f]`，因为判据写成了字面拼写而不是「字母区间」这个类；这是本仓反复记过的「锁的扇面对齐的是那一轮点名的行，不是那一类」。④ 修的是**POSIX 侧**；Windows 侧本来就按 ASCII 判定，因此这次修的是孪生**分歧**，不是两端共同的错。
  - **第七十一类（2026-11-05，用户问「还有没有别的问题」时，把两处已记录但未修的项逐个量了一遍）：会话名没有长度上界；服务端把 `jq` 的原始诊断直接打到自己的 stderr。**（资产变更：`client/unix/sshp`、`client/windows/sshp.ps1`、`unix/agentq-server` 与它的 canonical 孪生。）
    - **① 会话名无上界（第四十七类当时记为「共享边界、未修」）。** 两份 `sshp` 对会话名只有**字符集**守卫（`[A-Za-z0-9_.-]`）与「不得以 `-` 开头」，而紧挨着它的**状态值**——解析到的 Zellij 路径——有 1024 上界。两者进的是**同一条** `powershell.exe ... -EncodedCommand` 命令行。实测：4000 字符的会话名让构造出的命令行达到 10986 字符，超过 powershell.exe 的 8125 截断点，尾部（含闭合引号）被静默丢弃——会话以没人要求过的参数启动。修法：两侧各加一个 1024 的常量与守卫，早于任何 SSH 动作，`session name must be at most 1024 characters`（两侧同一句）。**单位在这里是白送的、不是复述的**：字符集守卫已经把名字限制在 ASCII，字节数 = 码点数 = UTF-16 码元数，所以 POSIX 的 `${#session}` 与 `.Length` 是同一个数；路径那条正因为三者不等，才必须走 UTF-16 转换。
    - **② `jq` 的原始 stderr 泄漏（2026-11-05 记录为「观察到、未归因」。）** `pueue group --json` **退 0 但 stdout 不是 JSON** 时，`ensure_group`/`verify_group` 的 `jq -e ... < file >/dev/null` 只压了 stdout，于是运维在服务端 stderr 上看到一行光秃秃的 `jq: parse error: Invalid numeric literal at line 1, column 6`——没有 `agentq-server:` 前缀、没有 `reason=`、不指向任何可查的东西。这与本仓已修过的「子进程原始 stderr 直通」同型。修法：凡**读外部程序输出**的 `jq` 且 stdout 已被丢弃的站点一律加 `2>/dev/null`——`ensure_group` 两处、`verify_group` 一处、`validate_pueue_task_shape_in_file`、`validate_pueue_log_shape_in_file`、`wait` 的原始 status 文件两处、payload 比对一处、`task_is_done`/`task_is_queued`/`task_succeeded` 三处谓词，以及 Windows 用户环境解析里那 14 个 `jq -er`。受控消息本来就在这些站点的失败分支上（`AgentQ group response is invalid JSON`、`Pueue returned an invalid task identity in status` 等），所以压掉 jq 自己的话不损失任何信息。
    - **锁（行为，两处）**：`smoke/12` 新增会话名边界三例——1025 字符**两侧都退 2、两侧都打出同一句**（`stream_rows` 计数同步改），以及两条**正控**：1024 必须放过边界、随后被**下一个**守卫拒绝（`SSHP_SSH` 指向不可执行文件，本地确定性、不碰网络），断言"边界消息**不**出现"——没有这条，一个「凡长名一律拒绝」的实现在负例上完全一样。`smoke/19` 把路径上界那对常量的比对**扩成两对**，并新增一条存在性断言（`sshp.ps1` 里找不到 `SessionName.Length -gt $script:SessionNameLimit` 即失败），防止两侧常量同时消失后 `""==""` 通过。`smoke/02` 新增 `jq-stderr-leak` 两例：桩让 `group --json` 答 `pueue 4.0.4`、`status --json` 答合法 JSON（所以 `ensure_daemon` 立刻返回、不会走到起服务），断言退 2、受控消息点名 group、且 stderr **没有** `^jq: ` 行。
    - **红证（四个方向，全部在仓库内跑）**：① 两份 `sshp` 的守卫各删一处 → `smoke/12` 报 `session-name-bound [1025]: posix-exit=255 windows-exit=255 posix-missing-the-bound-message windows-missing-the-bound-message` 退 1；② 把常量改成 1023 制造 off-by-one → 两条**正控**各自点名并打出实际消息 `session name must be at most 1023 characters`（同时 [1025] 那条也红，因为断言里钉着 1024 这个数），共 3 条退出 1；③ POSIX 常量改 512 → `smoke/19` 报「the session-name bound is 512 here but 1024 in sshp.ps1」退 1；④ `verify_group` 的 `2>/dev/null` 撤掉 → `smoke/02` 报 `jq-stderr-leak: a raw jq diagnostic reached the server stderr: jq: parse error: Invalid numeric literal at line 1, column 6` 退 1。四处还原后 `cmp` 逐字节相同、全部绿。
    - **边界（不修，如实记录）**：服务端一共 **196 处** `jq` 调用，其中读**本进程自己写出**的记录/墓碑的站点（`read_request_record_state_and_body`、`request_tombstone_*` 等）**没有**加抑制——它们的失败分支与上面那批不同（多处是 `set -e` 下的裸赋值，压掉 stderr 会让一次失败变成「退非零且零输出」，比现在更糟）。因此**没有**写「所有 jq 必须重定向 stderr」的全局静态规则：它要在 196 个站点上正确、还要看穿跨行过滤器（`verify_group` 的 `>/dev/null` 就写在 filter 的收尾行上，行窗口规则看不见，`smoke/10` 规则 J 早已记过「near is not inside」），而它一旦误报就会把一整个文件锁成不能动的。本类只锁**行为**：被这个桩真正走到的组路径会红，其余站点是记录在案的未覆盖面。
  - **第七十类（2026-11-05，把「纯空白值」的差分从数值变量扩到**字符串/路径**变量时量出来的）：除 `AGENTQ_HOST` 外，Windows 客户端把纯空白值当**未设置**、POSIX 当**已设置**——同一环境在两平台得到相反答案，最尖的一格让两个客户端连上**不同的机器**。**（资产变更：`client/windows/agentq.ps1`、`client/windows/sshp.ps1`。）**
    - **怎么找到的**：第六十五类修掉了七个**数值**变量的这一类（`IsNullOrWhiteSpace` → `IsNullOrEmpty`），但那次的修法**按手里的变量逐个改**，字符串变量原封未动。于是把两侧客户端处理的全部 `AGENTQ_*` 变量列出来，对每个都喂纯空白（空格、制表符）与空串，逐格对照退出码、首行消息、以及最终交给 ssh 的**主机**。
    - **实测（修复前，0.1.19 资产，两侧同一 argv/env）**：`AGENTQ_REMOTE_PLATFORM=' '` → POSIX 2（`must be auto, unix, or windows`）/ Windows 255（当未设置 → 自动探测）；`AGENTQ_SSH=' '` → POSIX 2（`not executable`）/ Windows 255（当未设置 → 走 PATH 的 ssh）；`AGENTQ_ASKPASS=' '` → POSIX 2（`must be a single executable path`）/ Windows 255（当未设置 → 密钥认证）；`AGENTQ_PASSWORD_PROMPT=' '` → POSIX 2（`must be 1`）/ Windows 255；`AGENTQ_CONFIG=' '` → POSIX 2（`no SSH host configured`）/ Windows 255 —— **Windows 去读了默认位置的配置并连上它命名的主机**（`cfg-host`），POSIX 根本没读，同一环境指向两台不同机器。另有两条「both set」：有效的 `AGENTQ_ASKPASS` 加上空白的 `AGENTQ_PASSWORD`（或 `_PASSWORD_PROMPT`）时，POSIX 退 2 报「两个都设了」，Windows 把空白当未设置、**照样用 askpass 跑**。凡是空值（`VAR=`）的格，两侧一致——所以分歧只在「纯空白」这一列。
    - **根因**：判「是否已设置」的谓词不同，和第六十五类**完全同型**，只是当时修的是数值变量。POSIX 用 `[ -n ]` / `${VAR:-default}`，只为**空**替换；Windows 用 `IsNullOrWhiteSpace`，把纯空白也当未设置 → 走默认值。第六十五类的修法是对的，但**锁与修法的扇面对齐的是「那一轮点名的变量」，不是「这一类变量」**——同一个类在字符串变量上原样活着。
    - **为什么 Windows 这侧是 fail-open**：`AGENTQ_CONFIG=' '` 时它不是拒绝、而是**静默用默认配置连了一台机器**；`AGENTQ_ASKPASS=' '` 时它静默退回密钥认证，让运维以为密码在用。把变量展开成空白的脚本会在 Windows 上做出它在 POSIX 上被拒绝的事。
    - **修法**：`client/windows/agentq.ps1` 中所有**命名一个值**（路径、程序、枚举开关）的 `AGENTQ_*` 读取点，判据由 `IsNullOrWhiteSpace` 改为 `IsNullOrEmpty`——空值仍表示默认（与 sh 的 `FOO=` 一致），纯空白进入既有的校验器、按各自消息拒绝。涉及 `AGENTQ_CONFIG`、`AGENTQ_REMOTE_PLATFORM`、`AGENTQ_SSH`、`AGENTQ_ASKPASS`、`AGENTQ_PASSWORD`（两处 both-set 守卫 + 一处平台拒绝）、`AGENTQ_PASSWORD_PROMPT`（两处）、`AGENTQ_PLATFORM_CACHE_DIR`、`AGENTQ_PLATFORM_PROBE_CACHE`。**`AGENTQ_HOST` 是唯一例外，保持 `IsNullOrWhiteSpace`**：两侧文档都规定纯空白主机名视同未设置、回退到配置里的主机（`smoke/12` 的 host-value 行钉着它）。`AGENTQ_PASSWORD=' '` 这一格修后在 Windows 上变成「该平台明确拒绝 `AGENTQ_PASSWORD`」——这正是它对该变量的既有立场（任何非空密码都拒绝），旧行为反而是它漏掉的一种 fail-open。
    - **锁（`smoke/12` 新增 `wsstr(9/9)`，全部是**差分**）**：同一 argv/env 喂两份客户端，逐行断言**两侧**的退出码、**两侧**消息、以及**是否真的发起过 SSH**（用会记 argv 的桩——不记 argv 的桩会让「没连」这一句永远为真，是本仓记过的假绿形状）。五条纯空白行 + 两条「both set」行 + 两条空值正控（`VAR=` 两侧都必须放行并连到配置里的 `cfg-host`，否则「凡设置即拒绝」也能全绿）。**外加一条静态规则**：`smoke/12` 的 `mode_static_failures` 段遍历客户端源码，`IsNullOrWhiteSpace($env:AGENTQ_*)` 除 `AGENTQ_HOST` 外一律算违规——这样**下一个**新变量若又用错谓词会被直接抓住，而不必等到有人想起来扫。规则自带四行夹具标定：一个该报的（`_SSH`）、一个豁免的（`_HOST`）、一个用对谓词的（`_CONFIG` 用 `IsNullOrEmpty`）、一个非 `AGENTQ_` 前缀的，必须**恰好报出** `AGENTQ_SSH` 一个。静态规则的扫描与标定都在本机实测（夹具报 `[AGENTQ_SSH]`、修后客户端 `offenders=[]`）。
    - **同一类在同一轮的**另一半**：`sshp` 孪生体**。`SSHP_SSH` 与 `SSHP_RECONNECT_DELAY` 在 POSIX 侧同样用 `${VAR:-默认}` / `[ -n ]`（纯空白=已设置），Windows `sshp.ps1` 用 `IsNullOrWhiteSpace`（纯空白=未设置）。实测 2026-11-05：`SSHP_SSH=' '` → POSIX 2 `SSHP_SSH is not executable` / Windows 255（当未设置 → 走 PATH 的 ssh 去做真实探针）；`SSHP_RECONNECT_DELAY=' '` → POSIX 2 `must be a non-negative integer` / Windows 255（默认 2 秒）。空值两格一致。修法与锁都跟着做：`sshp.ps1` 两处改 `IsNullOrEmpty`；`smoke/12` 加两条 `sshp_ws_case`（两侧 2 且两侧消息必须点名该变量）；静态规则再扫 `sshp.ps1` 的 `IsNullOrWhiteSpace($env:SSHP_*)`——这一面**没有豁免**（没有任何 `SSHP_*` 变量有「纯空白=未设置」的文档契约）。**这正是本类的教训本身**：如果只修 `agentq` 这一对，下一轮就会在 `sshp` 上原样复现，和第六十五类只修七个数值变量是同一个错误。
    - **红证**：把修好的客户端换成修复前副本喂 `smoke/12` → 五条纯空白行与两条 both-set 行**逐条点名** `windows-exit=255 windows-message`（`AGENTQ_CONFIG` 那行连交给 ssh 的主机都不同）；静态规则在同一份副本上报出它不应放过的那些 `IsNullOrWhiteSpace($env:AGENTQ_*)`。换回修复后的资产，同一套检查全绿。
    - **边界**：`AGENTQ_JQ` 只有 POSIX 客户端读（Windows 客户端不依赖 jq），不在孪生面上；Windows 侧本就没有这个变量。`AGENTQ_HOST` 的「纯空白即未设置」是**刻意**的跨平台契约（第六类起就有），本类不改变它——只把「其余变量不得沿用这一豁免」钉住。空白集随 locale 变化这一点（NBSP、U+3000）与主机名那条一致，未新增断言。

  - **第六十九类（2026-11-05，挨个量配置文件的**形态**——目录、符号链接、不可读、FIFO——时量出来的）：配置**存在但读不了**时，POSIX 报的是「没有配置 SSH 主机」，把权限问题说成了配置缺失。**（资产变更：`client/unix/agentq`。）**
    - **怎么找到的**：把 `AGENTQ_CONFIG` 指向五种形态（目录、指向目录的符号链接、mode 000 的普通文件、父目录无搜索位的文件、FIFO），两侧逐一对照退出码与首行消息。退出码五种全部一致（都是 2），但**消息**在「存在但不可读」这一格上指向完全不同的东西。
    - **实测**：`chmod 000` 的配置文件——POSIX 退 2 `no SSH host configured; pass --host or set AGENTQ_HOST`；Windows 退 2 `invalid AgentQ config: AgentQ config file could not be read`。同一份文件、同一个退出码，一个指向主机、一个指向文件。
    - **根因**：POSIX 的读取块整个由 `[ -r "$config_path" ]` 守着。读不了 → 整段跳过 → `configured_host` 留空 → 落到文件末尾那条「没有配置主机」的通用消息。**守卫本身没错，错的是它失败后沉默**：`-r` 为假这件事没有被任何消息说出来。
    - **为什么这是缺陷而不是「两种平台各有措辞」**：这条消息是运维唯一能看到的线索。它说的是「没有配置主机」，于是人会去查 `AGENTQ_HOST`、去查主机清单，而真正要查的是那个文件属主是谁、父目录有没有搜索位。本仓对这类「诊断指向错误方向」已有一贯立场（BatchMode 那轮同型）。
    - **修法**：在既有的「存在且非普通文件」守卫之后加一条：文件存在但不可读 → 具名拒绝，消息点名权限与父目录的搜索位。
    - **锁（`smoke/12` 新增 `config-unreadable`）**：两侧都必须退 2；POSIX 消息必须含 `cannot be read` 且**不得**出现 `no SSH host configured`；Windows 消息必须含 `could not be read`。**断言消息而不只是退出码**是这一例的全部价值——退出码在修复前后都是 2，只有消息能区分。
    - **root 宿主的降级**：root 无视 mode 000，这一例在那样的宿主上不可达，因此先探测（`[ -r ]` 为真即跳过）并报 `NOT-covered(needs-unprivileged-user)`，不空跑一场绿。
    - **红证**：删掉新守卫 → `config-unreadable: posix-does-not-name-the-cause posix-still-points-at-the-host`、退 1；`cp` 还原后 `cmp` 逐字节相同。
    - **两条实测边界（不修，如实记录）**：
      ① **父目录没有搜索位**：`[ -e "$config_path" ]` 本身就为假，两侧都把配置当「不存在」、报同一句话。这**是一致的**，而且事实上无法与「确实没有这个文件」区分——要区分必须在每个父目录上逐级探测，代价远大于收益。
      ② **FIFO**：POSIX 用 `[ ! -f ]` 明确拒绝（`must be a regular file`），PowerShell 侧 `[System.IO.File]::Open` 会**阻塞等待写入者**——实测挂死。但 `UnixMode` 与 `FileAttributes` **都看不出 FIFO**（实测两者与普通文件完全相同），且 Windows 文件系统命名空间里构造不出 FIFO，所以这一格只在「在 Unix 上跑 ps1」时可达，属平台边界而非产品缺陷。
  - **第六十八类（2026-11-05，把「同一份配置喂两个客户端」继续扩到「同一份配置喂两个 locale」时量出来的）：主机解析随环境 locale 变；Windows 还收下一份 POSIX 拒绝的含 NUL 配置。**（资产变更：`client/unix/agentq`、`client/windows/agentq.ps1`。）
    - **① locale 决定连哪台机器（POSIX 侧）**。解析 `AGENTQ_HOST` 的那条 sed 是全文件**唯一**没钉 `LC_ALL=C` 的（同文件的 466/477/499/1750/1772 都钉了）。在 UTF-8 locale 下，BSD sed 遇到非法字节序列立即中止并打 `sed: RE error: illegal byte sequence` 到 stderr；**坏行之前已经打印的匹配仍然进 `tail -n 1`**。实测同一个文件（`AGENTQ_HOST=first-host` 后跟一个含 `\xff` 的值、同一 argv/env/桩 ssh）：`LC_ALL=C` → `bad\xffhost`，`LC_ALL=en_US.UTF-8` → `first-host`。**调用方的 locale 决定了连哪台机器**，且 stderr 混进一条 sed 自己的错误。修法：那条 sed 钉 `LC_ALL=C`，与同文件其他站点一致；两种 locale 下结果一致、stderr 干净。
    - **② 含 NUL 的配置：POSIX 拒绝、Windows 收下（孪生分歧）**。POSIX 有明确的 NUL 规则（`AGENTQ_CONFIG contains NUL bytes; text syntax is required`，理由是 NUL 能从按行读取的解析器面前藏内容）；.NET 则把 U+0000 当合法字符解码，于是 Windows 收下这份文件并用里面的主机（实测：posix=2 / windows=255，主机名正确）。修法：Windows 在 **UTF-8 分支**上先扫 NUL、具名拒绝；UTF-16 分支必须跳过——那里 NUL 是编码构造的一部分，扫了会把所有 UTF-16 文件都拒掉。
    - **③ 一个「抛在 try 里」的坑（我自己先踩了）**：NUL 拒绝的第一版写在 `try { … } catch { throw "AgentQ config file returned invalid encoding" }` 内部，于是那条具名消息被 `catch` 改写成笼统的「返回了非法编码」——正是本轮要消除的「主语指错」。改为在 `try` 内只算出 `$nulFound` 布尔值，`try/catch` 之后再抛，消息才出得来（实测：修前 stderr 是 `returned invalid encoding`，修后是 `contains NUL bytes; text syntax is required`）。
    - **锁（`smoke/12`）**：`bom` 段 6 → 7 例（新增 `nul`：两侧都必须退 2，且**两侧**消息都必须点名 NUL —— Windows 那条曾经指错，所以这里断言的是消息内容而不只是退出码）；另新增一条 `config-locale` 用例：同一文件在 `LC_ALL=C` 与 `en_US.UTF-8` 下必须解析出**同一个**主机，且 stderr 不得漏出 sed 的错误。
    - **locale 用例的自我校准**：只有「未钉 locale 的 sed 在该 locale 下真的报错」时才跑主用例。GNU sed 是逐字节的、从不报错，所以在 Linux 上这条如实报 `NOT-covered(no-locale-sensitive-sed)` 而不是空跑一场绿；这与本仓「locale 名字不存在会静默回落到 C」的既有教训同源。
    - **红证（两向，均在仓库内跑）**：① 撤掉那条 sed 的 `LC_ALL=C` → `config-locale [en_US.UTF-8]: locale-changes-the-host=[bad\xffhost]vs[first-host] locale-leaks-a-sed-error`、退 1；② 把 Windows 的 NUL 扫描改成 `$nulFound = $false` → `config-encoding [nul]: windows-exit=255 windows-missing-NUL-message`、退 1。两处 `cp` 还原后 `cmp` 逐字节相同。
    - **另记一次自查（同一个陷阱第二次踩）**：locale 校准的第一版写成 `printf … | LC_ALL=… sed … 2>&1 | grep -q 'RE error'`。本仓运行在 `set -o pipefail` 下，`grep -q` 命中后立即退出，写侧 sed 收到 SIGPIPE，整条管道报 141 —— 于是「该宿主确实有 locale 敏感 sed」被读成「没有」，用例自报 `NOT-covered` 而不是执行。改为先 `$( … || true)` 捕获、再用 `case` 匹配。这条与仓库既有的 quiet-grep 记录同型，说明那类规则仍需每次新代码落笔时现查一遍。
    - **边界**：① **非法 UTF-8 是平台能力边界**：Windows 用 .NET 的严格解码器直接拒收（`AgentQ config file returned invalid encoding`），POSIX 的 sed/awk 逐字节处理、不作 UTF-8 校验，因此同一份含非法字节的配置在两侧行为不同。已在 SKILL.md 写明；要真正对齐须给 `/bin/sh` 加 UTF-8 校验器（无内建手段、iconv 不是可承诺的工具），本类不做，也不假装一致。② locale 用例只在「宿主确有 locale 敏感 sed」时执行，Linux CI 上是 `NOT-covered`（具名，不是静默）。③ 本轮未在原生 Windows 上复测；改的是 PowerShell 层的字节扫描与 POSIX 层的 locale 钉法，但「在真 Windows 上跑过」这句话本轮不成立。
  - **第六十七类（2026-11-05，把「配置文件」的字节形态继续往下扫时量出来的）：CRLF 行尾的 `AGENTQ_CONFIG` 在 POSIX 上被当成「没有配置 SSH 主机」。**（资产变更：`client/unix/agentq`；Windows 侧未改。）
    - **怎么找到的**：第六十六类修完 UTF-8 BOM 之后，同一类问题的下一个形态是行尾——Windows 上编辑过的文件每行以 CR LF 结尾。实测（同一份文件、同一 argv、同一桩 ssh）：POSIX 退 2 `no SSH host configured; pass --host or set AGENTQ_HOST`，Windows 按 `\r?\n` 拆分、正常取到主机并退到 ssh。**这是同一个缺陷家族的第三个形态**（行首 BOM → 行尾 CR → 空值行），三者都表现为「一条指错方向的诊断」。
    - **根因**：POSIX 的 `sed -n 's/^AGENTQ_HOST=\([^[:space:]]*\)$/\1/p'` 要求值之后立刻是行尾，而 CR 属于 `[:space:]`，`[^[:space:]]*` 走不到 `$`，整行不匹配；Windows 的 `-split "`r?`n"` 在切行时就把 CR 吃掉了。
    - **修法**：解析前只剥掉**行尾**的 CR（等价于孪生的 `\r?\n`）。行**中间**的 CR 仍使该值不合格——反向控制 `mid-cr`（`AGENTQ_HOST=mid\rcr`）在两侧都必须退 2。用 awk 而不是 sed：`\r` 在 POSIX awk 的正则里不可移植，所以用 `-v cr="$(printf '\r')"` 把字节当值传进去、用 `substr` 比较，避免任何转义。
    - **第一版的红证先抓住了我自己**：把归一化写进中间变量 `config_text=$( … awk … )`，多出的一次命令替换剥掉了末尾换行，`sed` 于是**根本看不见最后一行**——`AGENTQ_HOST=`（文档里说明的「清空主机」写法）失效、前一行仍然生效，`smoke/12` 里既有的 `empty-last` 孪生行当场报 `posix-exit=255`。这不是新缺陷，是修复引入的回归，而**锁在它进入仓库之前就抓住了它**。改为与 `sed` 同一条管道、并用 `printf '%s\n'` 保证末行有行尾，`empty-last` / `empty-only` / `no-eol`（末行无换行）三个形态才都两侧一致。
    - **锁（`smoke/12` 的 `bom` 段 3 → 6 例，`bom(6/6)`）**：`crlf`（两侧 255 且送到 ssh 的主机名相同）、`bom-crlf`（BOM + CRLF 同时出现，两侧 255、主机相同）、`mid-cr`（行中 CR，两侧都必须 2）。主机名断言是承重的：只比退出码时，一个「把 CR 全删掉」的实现会让三条全绿，却与孪生在接受面上分叉。
    - **红证**：把归一化整段删掉 → `config-encoding [crlf]` 与 `[bom-crlf]` 逐条报 `posix-exit=2 posix-host=[]`、退 1；`cp` 还原后 `cmp` 逐字节相同。
    - **边界**：① 只归一化「行尾 CR」（CR 紧跟 LF 或位于文件末尾）；文件中间的孤立 CR 不被当作行尾，这与 Windows 的 `\r?\n` 一致，`mid-cr` 用例钉住。② 末行没有换行的文件（`no-eol`）两侧都接受，已实测；`printf '%s\n'` 补的那一个换行只用于让 sed 看见末行，不改变可见内容。③ 本轮没有在原生 Windows 上复测；改的是 POSIX 解析器，但「在真 Windows 上跑过」这句话本轮不成立。
  - **第六十六类（2026-11-04，接着第六十五类把「同一份输入喂两个客户端」扩到配置文件**的字节形态**时量出来的）：UTF-8 带 BOM 的 `AGENTQ_CONFIG` 在 POSIX 上退 2 并报「没有配置 SSH 主机」，而同一份文件在 Windows 上正常解析出主机。**（资产变更：`client/unix/agentq`；Windows 侧未改。）**
    - **怎么找到的**：两侧的 config 读取器对编码的处理完全不同——Windows 的 `Read-AgentQConfigFile` 显式分支处理 UTF-8 BOM、UTF-16LE/BE BOM；POSIX 把 config 快照当字节流，用 `sed -n 's/^AGENTQ_HOST=...'` 在**行首**匹配。BOM 的三个字节（`EF BB BF`）在行首时，`^AGENTQ_HOST=` 匹配不到。
    - **实测（同一份文件、同一 argv、同一桩 ssh）**：纯文本两侧都解析出主机；`EF BB BF` + `AGENTQ_HOST=…` 时 **POSIX 退 2**（`no SSH host configured; pass --host or set AGENTQ_HOST`）、Windows 退到 ssh 且主机正确；UTF-16LE+BOM 时 POSIX 退 2（`contains NUL bytes; text syntax is required`）、Windows 正常。
    - **为什么 UTF-8 BOM 这一格是缺陷而不是「平台差异」**：带 BOM 的 UTF-8 **仍然是合法的 UTF-8 文本**，BOM 是文件头的合法标记，Windows 记事本与「UTF-8 with BOM」选项默认就写它。POSIX 侧不但读不出主机，还给出了一条**指错方向**的诊断——它说的是「没有配置主机、请传 `--host`」，运维会去查主机而不是查文件编码。这与本仓已修过的「BatchMode 提示指向错误方向」同型。
    - **修法**：POSIX 在切出 `config_text` 之后、解析之前剥掉行首的 `EF BB BF`（三字节，无依赖、无策略变更）。NUL 拒绝**保持不动**——UTF-16 仍被拒，因为它确实含 NUL 字节，`text syntax is required` 是刻意的。
    - **同时把 UTF-16 的拒绝说清楚**：新增一条前置判断——文件前两字节是 `FF FE`/`FE FF` 时，报 `looks like UTF-16 (it starts with a UTF-16 byte-order mark); save it as UTF-8`。
    - **为什么 UTF-16 仍然不对称（并如实记录）**：`/bin/sh` 没有 UTF-16 解码器，`iconv` 不是可依赖的工具，所以 POSIX **不能**接受 UTF-16；Windows 能接受是因为 .NET 自带解码。这与 `AGENTQ_PASSWORD_PROMPT` 在 Windows 上被拒同型：**平台能力边界**，不是「同一输入两个答案」可以消除的那一类。锁里两侧各自断言自己那一半，并把原因写在用例注释与 SKILL.md 里，而不是假装一致。
    - **锁（`smoke/12` 孪生段新增 `bom(3/3)`）**：① UTF-8 BOM 配置——两侧都必须 255 且**送到 ssh 的主机名相同**（只比退出码会让「两边都连错主机」通过）；② UTF-16LE BOM 配置——POSIX 必须 2 且消息点名 UTF-16，Windows 必须 255；③ 纯文本正控——两侧 255、主机相同（没有它，一个「凡 BOM 即拒绝」或「凡 BOM 即接受」的实现也能骗过前两条）。
    - **红证**：把 BOM 剥离那行删掉 → ① 红（`posix-exit=2`）；把 UTF-16 的具名消息那一段删掉 → ② 红（消息不含 `UTF-16`）；还原后 `cmp` 逐字节相同。
    - **边界**：① 只覆盖 UTF-8 BOM 与 UTF-16 BOM 两种头部形态；无 BOM 的 UTF-16 与 UTF-16 的其余字节序形态不另测（前者不含 BOM 就无从判断、会被 NUL 规则拒）。② Windows 侧仍然接受 UTF-16，这是刻意保留的平台能力，不是遗漏。③ BOM 剥离只作用于**行首**，文件中间出现的 `EF BB BF` 不被当标记处理（与 Windows 的 `contentOffset` 语义一致）。
  - **第六十五类（2026-11-04，把「数值型环境变量的边界值」整组喂给两个客户端时量出来的）：七个变量的**纯空白**值，两侧给相反答案，且 Windows 一侧是 fail-open。**（资产变更：`client/windows/agentq.ps1`；POSIX 侧未改，它本来就是被对齐的那一侧。）**
    - **怎么找到的**：上一轮修完 config 路径后，把 0.1.21 修过的「数值环境变量上界」那组输入重新扫一遍，这次带上**纯空白**（`' '`、`'\t'`、`'  '`）与空串。九个取值 × 六个变量，外加 `AGENTQ_WAIT_TIMEOUT`（它只有 `wait` 路径才校验，所以第一次用 `status` 扫时它是「假一致」——**扫描命令选错会让检测器报绿**，这类我这次连踩两次）。
    - **实测分歧**：`AGENTQ_SUBMIT_RETRY_ATTEMPTS=' '` 等六项在 `status` 上、`AGENTQ_WAIT_TIMEOUT=' '` 在 `wait 1` 上——POSIX 一律 exit 2（`... must be a positive integer of at most 2147483647`），Windows 一律 255（当作未设置、用默认值继续）。
    - **根因**：判「是否设置」的谓词不同。POSIX 是 `${VAR:-默认}`——只把**空串**当未设置，纯空白是非空值，交给 `is_bounded_positive_integer`，空格不是数字 → 拒绝。Windows 用 `[string]::IsNullOrWhiteSpace`——纯空白被当作未设置 → 默认值。空串两侧一致（都当默认），所以只有空白这一格分歧。
    - **为什么这不是「无所谓的风格差异」**：一个把变量展开成空白的脚本（`AGENTQ_SUBMIT_RETRY_ATTEMPTS=$FROM_FILE` 而文件里是空格）在 Windows 上会**静默**跑默认重试次数，在 POSIX 上直接报错。本仓对这类「静默降级」的立场是一贯的 fail-closed（凭据源、AGENTQ_HOST 的纯空白、`AGENTQ_WAIT_TIMEOUT=abc` 都是拒绝），而且孪生规则要求同一输入同一答案。
    - **修法**：七处读取点由 `IsNullOrWhiteSpace` 改为 `IsNullOrEmpty`。空值仍表示默认（与 sh 的 `FOO=` 一致），纯空白进入既有的 `Convert-ToPositiveInt32` / `Test-PositiveInteger`，由那里按既有消息退 2——**判据没变，只改「什么算设置」**。
    - **锁（`smoke/12`，新增 `ws(9/9)`）**：六个变量在 `status` 上、`AGENTQ_WAIT_TIMEOUT` 在 `wait 1` 上、外加一行制表符值，全部期望两侧 exit 2；再加一条**正控**：`AGENTQ_SUBMIT_RETRY_ATTEMPTS=`（空串）两侧必须 255。正控是承重的——没有它，一个「凡设置即拒绝」的实现也能让前八行全绿。
    - **红证**：七处整体改回 `IsNullOrWhiteSpace` → 8 条逐条点名 `windows-exit=255`、退 1；`cp` 还原后 `cmp` 逐字节相同。空值那一行在变异下仍是绿的，正是它作为正控的意义。
    - **边界**：① 只覆盖「空白」这一格；`'0'`、`'05'`、上界等既有取值由 `smoke/12` 原有的数值循环与孪生表覆盖。② `AGENTQ_WAIT_TIMEOUT` 的**消息**两侧仍不同（POSIX 说「of at most 2147483647」，Windows 说「positive 32-bit integer」），本类只对齐**退出码**；消息一致性没有锁，如实记为边界。③ 这次没有在原生 Windows 上复测——修复点在 PowerShell 层的字符串判定，与平台无关，但「在真 Windows 上跑过」这句话本轮不成立。
  - **第六十四类（2026-11-04，按「同一 argv/env 喂两个客户端」做差分扫描时量出来的）：`AGENTQ_CONFIG` 的路径里出现符号链接时，两份客户端给**相反答案**；Windows 还把「config 被拒」说成「临时文件」。**（资产变更：`client/unix/agentq`、`client/windows/agentq.ps1`；两处 canonical 服务端资产未动。）**
    - **怎么找到的**：先用本仓自己的方法——同一环境、同一桩 ssh，把 63 行 argv 喂给两个客户端比退出码（`wait`/`submit`/`lookup`/`cancel`/`remove`/`status --task` 的边界形态）。第一轮 11 处「分歧」全是我自己的检测器造成的：我给 `AGENTQ_CONFIG` 建了一个**空文件**，POSIX 判它「不安全」直接退 2、Windows 继续走到 ssh。把路径改成**不存在**后 63 行零分歧。**检测器骗人的同一类**又出现了一次，所以我没有停在那里，而是把「已存在的 config 文件」单独拉出来量。
    - **量出来的分歧**：`AGENTQ_CONFIG=<某目录>/config`，只要路径链里有**任何**符号链接，POSIX 退 2 `AGENTQ_CONFIG path is unsafe or unavailable`，Windows 照常连 ssh。最要紧的形态不是随手造的：**macOS 的 `/tmp` 和 `/var` 本身就是指向 `/private/...` 的系统符号链接**，所以 `AGENTQ_CONFIG=/tmp/x/config` 在 POSIX 上一律退 2——而 `/tmp` 正是脚本、测试、临时排查最常放配置的地方。
    - **根因（两侧各一半）**：POSIX 的 `config_source_path_chain_identity_for_path` 逐组件走路径，**任何**组件是符号链接就 `return 1`（它记录整条链的 dev:inode 以做 TOCTOU 复核，符号链接会让链不稳定）；Windows 的 `Test-NonReparseTemporaryFilePath` 在链路检查之前，**先把 `/var`、`/tmp` 改写成 `/private/var`、`/private/tmp`**（仅当别名确为 reparse point 且 `/private` 对应项是目录）。同一条规则，一侧有别名豁免、一侧没有。
    - **第二个缺陷（诊断）**：Windows 的 `Read-AgentQConfigFile` 调的是 `Assert-NonReparseTemporaryFilePath`——**临时文件**的校验器。于是拒绝一个 config 路径时打的是 `invalid AgentQ config: Invalid AgentQ temporary file path; expected a regular non-reparse file: <config 路径>`：判据没错，**主语错了**，运维会去查 TMP/TEMP。这与 BatchMode 那条「提示指向错误方向」同型。
    - **修法一（POSIX，采用孪生已有的别名规则）**：在链校验的开头，对 `/var`、`/tmp` 做与 Windows **逐条件相同**的改写——别名确为符号链接 **且** `/private<别名>` 是目录时才改写。其余任何符号链接（包括配置文件本身）仍拒绝。`/tmp` 指向别处时两侧都不改写、都拒绝，已实测。
    - **修法二（Windows，同一判据、诚实主语）**：新增 `Assert-NonReparseConfigFilePath`，只在 `Read-AgentQConfigFile` 上使用，消息为 `Invalid AgentQ config path; expected a regular non-reparse file: <路径>`。判据（`Test-NonReparseTemporaryFilePath`）一个字没改——临时文件路径仍在用它。
    - **锁（`smoke/12` 孪生段，新增 `cfgpath(4/4)`）**：regular（两侧 255，走到桩 ssh）、symlinked-file（两侧 2）、symlinked-dir（两侧 2）、`/tmp` 系统别名（两侧 255）。最后一条在宿主的 `/tmp` 不是符号链接时（Linux CI）报**具名** `NOT-covered(needs-symlinked-tmp)`，不静默跳过；Windows 宿主上整段按既有 `twin_platform_state` 报 `NOT-covered(needs-non-Windows)`。另有诊断断言：Windows 拒绝 config 时必须打出含 `config path` 的消息，且不得只说「临时文件」。
    - **红证（两向，均在仓库内跑）**：① 把 POSIX 的别名条件中性化（`[ -L ... ]` → `false`）→ `config-path [system-alias-tmp]: expected exit 255; posix-exit=2`、退 1；② 把 `Read-AgentQConfigFile` 换回临时文件断言 → `config-path [diagnostic]: refusing a config path must say so; the Windows message named something else`、退 1。两处都用 `cp` 还原并 `cmp` 确认逐字节相同。
    - **边界**：① 别名规则只覆盖 `/var`、`/tmp` 这两个**操作系统自带的**别名，与孪生保持一致；用户自己造的符号链接（dotfiles 把 `~/.config` 链到仓库、HOME 本身是链接）在两份客户端上**仍然一致地拒绝**——这是两侧共同的安全立场，不是本类放松的对象，但它是真实的可用性限制（默认配置路径在那种布局下会退 2），要放宽必须两侧同时改并有各自的锁。② `/tmp` 那一例在 Linux 上不可达（`/tmp` 是真目录），所以是 `NOT-covered` 而不是绿。③ 本类只改两份客户端，服务端与两份 canonical 资产零变更（`cmp` 仍为 0）。
  - **第六十三类（2026-11-04，接着第六十二类问「门禁本身还能怎么坏」量出来的）：两个 workflow 的**接线**没有任何检查——门禁内容再正确，`on:` 改成不触发、job 标成 `continue-on-error: true`、或 CI 的 linux 全量步骤被换成 `true`，整套检查照绿。**（资产零变更：动的是 `smoke/01`。）
    - **怎么找到的**：第六十二类修好了 release 门禁「读几份记录」，紧接着要问的不是「它还读漏了什么」而是「它凭什么会跑、凭什么能红」。四个变异逐个量，修前全部 GREEN：
      ① `release.yml` 的 `on: push: tags: ['v*']` 改成 `branches: [main]`——门禁内容完好、永不触发，tag 打上去不做任何版本核对；
      ② `release.yml` 的 job 加 `continue-on-error: true`——它跑、它失败、GitHub 把这次 workflow 记为成功；
      ③ `ci.yml` 的 `push: branches: [main]` 改成 `tags: ['never']`——main 上再没有 CI，也就没人跑会发现问题的套件；
      ④ `ci.yml` 的 linux 全量套件步骤正文换成 `true`——job 照跑、下面的断言步骤要到运行时才失败，而所有静态规则看这棵树都自洽。
    - **为什么既有规则全都看不见**：`smoke/01` 关于 workflow 的三块规则（第六十二类的 release-gate 锁、workflow 管道锁、`ci.yml` 的检查名钉死）**都只读内容**——读 step 正文里的路径与常量、读管道的形状、读钉住的检查名清单。没有一条读 `on:`，没有一条读 job 级开关，也没有一条问「这份 workflow 里到底有没有真的跑套件的那一步」。
    - **修法**：`smoke/01` 新增 `workflow_wiring` 块，用 PyYAML 解析 **`.github/workflows/*.yml` 全树**（派生，不写死文件名），对每份断言：解析成含 `jobs` 的映射；`on:` 非空；没有 job 标 `continue-on-error: true`；至少一步跑非空 shell 命令。再加两条按名字的不变量：`release.yml` 必须在 **tag push** 上触发、且 `tags:` 里有模式能匹配一个版本 tag（用 `fnmatch` 对合成样本 `v0.1.19` 匹配，而不是比较字面量 `v*`——GitHub 求值的是 glob）；`ci.yml` 必须在 push 到 `main` 时触发、且 **linux job** 里有一行真正调用 `run-tests.sh`。
    - **写规则时才暴露的五个细节（全部实测）**：
      · **PyYAML 把裸 `on:` 解析成布尔 `True`**（YAML 1.1），GitHub 解析成字符串 `"on"`——只读 `data["on"]` 会在**每一份**真实 workflow 上拿到空，规则会以「没有 on: 事件」的形状对正确文件报红。改为 `data.get("on", data.get(True))`。
      · **`branches` 缺省不等于覆盖 main**：GitHub 的语义是「`branches` 与 `tags` 都缺省才是所有分支」；只写 `tags:` 的 push 触发器**永远不**在分支推送上运行。第一版按「缺省即覆盖」写，自校准夹具 `ci-tags-only` 当场把它打红。
      · **注释里的 `run-tests.sh` 不算调用**：变异 ④ 的第一版仍然绿——linux job 的「Assert the full suite really ran」步骤里有一条注释写着 `run-tests.sh already compares …`，而第一版只看 `"run-tests.sh" in run`。改为逐行跳过注释后再判断，重跑 ④ 才变红。**这与第六十二类那个「路径+常量名都在注释里」的缺口是同一类**：注释里的字不是行为。
      · **守卫与正文的 python 调用方式必须一致**：正文用 `python3 -I`，守卫原先写 `python3 -c 'import yaml'`（会看 user site）。yaml 只存在于 user site 时，守卫放行、正文 `ModuleNotFoundError`，**环境故障被报成「workflow wiring FAILED」**——正是本仓 pwsh-unusable 那一档纠正过的形态。守卫改为 `python3 -I -c`。
      · **失败明细的排版**：python 的问题打在 stderr，第一版只捕获 stdout，于是 `FAILED` 头下面是一个空缩进块、真正的明细在头**上面**。改为 `2>&1` 捕获，明细落在头下面。
    - **自校准（9 个夹具，每次运行都跑）**：一个好 release、一个好 ci，以及七个各打一条断言：无 `on:`、release 只有 `branches`、tag glob 匹配不上样本、job 带 `continue-on-error`、没有非空 `run`、ci 只有 tags、ci 不调套件。**永远放行的变异实测**：把 `wiring_problems` 改成立刻 `return []` → 7 条夹具逐条报 `calibration FAILED`、exit 1；还原后 `cmp` 逐字节相同。
    - **红证（四个变异，全部在仓库内跑、逐条点名，均 exit 1）**：① release 触发器改 branches → `release.yml: release gate's push trigger has no \`tags:\` list`；② release job 加 `continue-on-error: true` → 点名该 job；③ ci 触发器改 tags-only → `ci.yml: ci's push trigger does not cover \`main\``；④ ci linux 全量步骤正文改 `true` → `ci.yml's linux job never invokes run-tests.sh`。干净树 → `workflow_wiring=checked(2)`、exit 0；四次变异后都按字节还原（`cp` 自 `/tmp` 副本）。
    - **边界**：① 这是**接线**级的锁，不是行为级——它只在「按 GitHub 文档语义解析出的 YAML」上断言，不证明 GitHub 真的会按这些事件触发；真实触发只在 push / tag push 时由 Actions 自己证明。② tag 样本写死为 `v0.1.19`：将来 tag 命名规范换了，这条会以「没有 tags 模式匹配」报红——那正是需要人看一眼的时刻，不应放宽。③ 它保证 ci 的 linux job **调用了** `run-tests.sh`，不保证该调用的退出码被传播（后者由 `ci.yml` 自己那步 `set -e` 与既有断言覆盖，不在本锁范围）。④ 本机与 CI 都需要 PyYAML：CI 已有「Ensure pyyaml」步骤；本机缺 pyyaml 时摘要报 `workflow_wiring=skipped(no pyyaml)`，`run-tests.sh` 归入 partial，不会被当成全绿。
  - **第六十二类（2026-11-04，用户问「本项目还有其他问题吗」时按「门禁读了几份记录」量出来的）：`release.yml` 的 tag 门禁声称核对「部署单元记录的版本」，实际**只读一份记录**（POSIX 安装器）；两份客户端、Windows 安装器、两份 canonical 服务端与 README 它一概不读。**（资产零变更：动的是 `.github/workflows/release.yml` 与 `smoke/01`。）
    - **怎么找到的**：不是读代码猜的，是问「这个门禁声称覆盖一个**单元**，那它读了几份记录」，然后造 fixture 量。fixture 里安装器/服务端/README 都是 `0.1.19`、两份**客户端**停在 `0.1.18`，打 `v0.1.19`：旧 release.yml **GREEN**，而同一棵树上 smoke/01 比较的那六份记录里有两份不同。后果：tag 可以命名一个部署单元并不携带的版本。
    - **为什么 smoke/01 救不了它**：`smoke/01` 确实比较六份记录（2026-10-21 起含两份客户端），但它在 **push 到 main** 跑；`release.yml` 在 **tag push** 跑，两者是不同事件。tag 可以直接打在一个从未跑过套件的提交上（本仓自己的发版流程就是 commit → push main → force-move tag，tag 与 main 的 CI 并行，release 通常在 CI 完成前就结束）。**门禁必须自己站得住**，不能依赖「另一条流水线大概已经查过了」。
    - **修法**：`release.yml` 改为逐份比较——七条记录（两个安装器、服务端、canonical 孪生、README、两份客户端）各一行读取 + `compare`，任一缺失（读不到该常量）或与 tag 不符即红；成功行报告**实际比较过的份数**（`matches all 7 recorded versions`），所以这个数字不是写死的。提取式与 `smoke/01` 的版本块逐条对应（同样的 grep 形状、同样的去引号规则），README 取前缀后的第一个字段。
    - **锁（结构 + 自校准，装在 `smoke/01` 里）**：记录集**从树上派生**（`grep -rlE` 扫 `agentq_version=` / `agentq_client_version=` / `$agentqVersion = ` / `$script:ClientVersion = ` 四种形状），不是手写清单；每条记录要求 release.yml 里**同一行**既出现它的路径、又出现它自己的常量名——同一行这个约束是承重的（第一版只查「两个串在任何地方都出现」，一个把读取换成 `# <path> <constant> is read elsewhere` 的注释就能骗过它，实测如此）。再加两条闸门：① 派生集必须**覆盖**版本块按名字比较的那五个资产路径（变异实测：派生式掉一种形状时 Windows 安装器从 census 里消失、其余全绿；第一版的 `-eq 0` 闸门抓不到，因为 README 在循环外、总数从不为 0）；② README 显式补一次（它在 `skill/assets/` 之外）。
      - **自校准（跑在每次检查里）**：一个完整夹具两条都要被判「读了」，一个「路径+常量名都在注释里」的夹具必须被判「没读」，一个路径根本不存在的必须被判「没读」。把匹配器改成永远成功 → 校准报红。
    - **红证（五个变异，全部在仓库内跑、逐条点名，均 exit 1）**：① 删掉 canonical 孪生那一行读取 → 点名 `skill/assets/windows-git-bash/agentq`；② 把客户端读取换成「路径+常量名都在注释里」→ 点名 `skill/assets/client/unix/agentq`（**这个变异第一次跑是绿的**，就是上一条说的缺口）；③ 往 `skill/assets/` 放一个第八份记录（`agentq_version=`）→ 点名它，证明 census 派生而不是清单；④ 匹配器改成 `return 0` → 自校准红；⑤ 派生式丢掉 `$agentqVersion` 形状 → 点名 `skill/assets/windows-git-bash/install-agentq.ps1`（覆盖闸门）。
    - **行为侧也验了**：把 `release.yml` 的 step 正文原样提取成脚本，对**真实仓库**跑 `GITHUB_REF_NAME=v0.1.19` → 七条全对、`matches all 7 recorded versions`、exit 0；`v0.1.18`（陈旧 tag）→ 七条全不符、`7 of 7 recorded version(s) disagree`、exit 1；fixture 的「客户端偷偷不升」→ 只点名那一份、exit 1。
    - **顺带被本仓自己的锁抓住一次**：覆盖闸门第一版写成 `printf … | grep -qxF`，`smoke/01` 的 `repo_pipes` 规则（quiet grep 结尾的管道在 pipefail 下把**命中**读成缺失）当场报红并点名行号——改成 here-string 后绿。锁抓锁，这条记下来是因为它证明了那类规则确实在跑。
    - **边界**：① 该锁是**行级**的——同一行必须有路径与常量名。如果将来改用「先解析 YAML 再执行」的结构，它会误报，届时要按结构重写而不是放宽。② 它保证「每份记录都被读」，**不**保证读出来的值被正确比较——比较逻辑本身只由行为侧实测（三个方向）覆盖，没有静态锁。③ 这条路径**只在 tag push 时真正运行**，本地无法复现 Actions 环境；我用 YAML 解析 + 提取 step 正文跑真实仓库来近似，那不等于 GitHub Actions 实跑。

  - **第六十一类（2026-11-04，审第六十类「修复自己的覆盖面」时发现）：第六十类给记忆那一半加的「不静默跳过」，**没有继承仓库那一半的排除表**，于是它把两种根本不是泄漏的东西报成了「含 NUL 的二进制」，把一个全绿的检查变成假 PART。**（资产零变更：检查是 dev 工具，不在 `skill/assets/` 里。）
    - **怎么找到的**：第六十类把仓库那一半的判据搬进记忆那一半之后，问的是「这两半现在**完全**一样了吗」。它们不一样：仓库那一半的遍历先做 `is_derived_bytecode || is_os_junk` 排除、再用 `[ -s ]` 挡掉空文件，而 `scan_memory_dir` 只做了「不是文本就上报」。
    - **红证（两向，全部实测）**：① 记忆目录里放一个 Finder 的 `.DS_Store`（+ 一个正常笔记）→ `skipped a memory file that looks binary by NUL bytes .../.DS_Store`，`memory=scanned(1-NOT-TEXT)`、整条检查退 0 但被 run-tests 判 PART——**正是第五十九类从仓库那一半移走的那个假 partial，回到了记忆那一半**（同一棵树里仓库根的 `.DS_Store` 已被正确跳过，对照打印 `memory=scanned`）。② 记忆目录里放一个**空文件** → 同样被报成「含 NUL 的二进制」，而空文件一个字节都没有、根本没有 NUL 可藏——`[ -s ]` 这道守卫仓库那一半有、记忆那一半没有。
    - **这是「孪生实现」的经典漂移**：两个遍历做同一件事，写在两处，第二个是后加的，只抄了「上报」这个结论、没抄它的**边界**。本仓对此已有定论（两份客户端是同一契约的两个实现、`skill/assets/` 两份 canonical 必须逐字节相同）——**结论相同不够，边界也要相同**。
    - **修法（抽成一个分类器，两半共用）**：新增 `classify_file <path>`，输出恰好一个 `scan` / `not-text` / `skip`：`skip` = 字节码、OS 垃圾、空文件、以及既非文本又不含 NUL 的文件；`not-text` = **非空**且**确实含 NUL** 的文件（这个才值得上报）；`scan` = 其余。仓库遍历与 `scan_memory_dir` 都改调它——**一个实现，两处调用**，自检也直接驱动它。`scan_memory_dir` 的状态同时改成由**实际验证过的计数**导出：`scanned_text == 0 且 not_text == 0`（空、不可读、或只有被排除的残留）→ `empty(NOT-verified)`，不再因为「目录里有一个 .DS_Store」就宣称 `scanned`。
    - **锁（双向，直接驱动分类器 + 驱动真函数）**：`classify_file` 5 例（文本→`scan`；非空含 NUL→`not-text`；空文件→`skip`；`.DS_Store`→`skip`；`.pyc`→`skip`），外加 `scan_memory_dir` 新增 5 例（只有空文件→`empty(NOT-verified)`；只有 Finder 垃圾→`empty(NOT-verified)`；垃圾+真笔记→`scanned`；空文件+真笔记→`scanned`；`.pyc`+真笔记→`scanned`）。
    - **红证（两个有效变异，全部逐条点名）**：① 分类器丢掉字节码/垃圾排除（`if false` 替掉第一臂）→ 4 条红，含 `classify_file(.../.DS_Store) = not-text, expected skip` 与 `classify_file(.../stale.pyc) = scan, expected skip`；② 分类器把「非文本」一律当 `not-text`（去掉空文件那张 `skip`，即回到记忆那一半的旧行为）→ 4 条红，含 `classify_file(.../empty.md) = not-text, expected skip` 与空文件记忆目录那一例。**注意一个无效变异**：把 `[ -s "$file" ] &&` 换成 `true &&` 偏偏**不红**——空文件上 `grep -q NUL` 本就无命中、退 1，`-s` 与 NUL 检查在这个判据里**冗余**；这条如实记下，免得后人以为 `-s` 承重。
    - **边界**：① 分类器对**目录**（不是文件）没有意义，调用方只传 `find -type f` 的结果。② 一个含 NUL 但确实不是文本的大二进制文件仍会被上报——这是刻意的（本检查的判据就是「可能藏文本」），代价是一条 PART，而不是静默。③ 本类只动 `smoke/16` 一个文件，`skill/assets/` 与 `ci.yml` 零变更（第六十类的 CI 门禁正则不变，因为 `absent`/`empty`/`NOT-TEXT` 三个 token 都没改）。

  - **第六十类（2026-11-03，接着第五十九类问「同一半里还有别的静默跳过吗」时发现）：`smoke/16` 的记忆目录那一半有两种「什么都没查却报 scanned」的形态，而仓库那一半早在 2026-10-13 就改成「上报」了。**（资产零变更：检查是 dev 工具，不在 `skill/assets/` 里。）
    - **怎么找到的**：第五十九类把仓库根的 `.DS_Store` 从「上报」改成「按构造排除」之后，我回头读那段代码，问的是「仓库那一半拒绝静默跳过 NUL 文件，那**记忆目录那一半**呢」——它的循环写的是 `grep -Iq . "$file" 2>/dev/null || continue`：静默跳过。地址最初正是从记忆目录泄漏的（本检查头部写着 2026-09-27 那次），所以这一半**不能比仓库那一半松**。
    - **机制（两层，都是既有写法，不是新写的 bug）**：① **非文本文件**——NUL 字节让 `grep -Iq .` 失败，`|| continue` 把文件**静默**跳过，`memory=scanned` 照样宣布记忆这一半查干净了。实测：一个含「一行文本 + 一个 NUL 字节 + 一个点分四段地址」的记忆文件，`violations=0` 通过（而同样内容**去掉 NUL** 就被抓住、退 1）——UTF-16 笔记正是这个形状。② **目录存在但什么都没产出**——空目录上 `find` 不报错、退 0，于是 `scanned` 宣布了一次**没有对象**的验证（实测：空目录与真实的 37 文件目录打印同一句话）；**不可读**目录读起来一样——`find` 把 `Permission denied` 写到 stderr、退 0，`$( )` 只留下了它（空）的 stdout，于是也当作 `scanned` 通过。
    - **为什么从来没人看见**：成功路径上那个摘要 token 是**字面量** `memory=scanned`（写在最后的 `printf` 里），`run-tests.sh` 按这个形状归类、`ci.yml` 也按这个形状门禁——所以除了 `absent` 之外，任何降级状态**在证据里没有出口**。这与第五十七类「一条检查的**工具依赖**」是同一种病：判决比取证更响。
    - **修法（把这一半抽成一个函数，状态由计数器导出）**：新增 `scan_memory_dir <dir>`（紧挨 `scan_file` 定义），它**设置全局 `memory_state`**（而不是把状态打到 stdout——实测：用 `$( )` 捕获状态会让记忆文件对 `files=` 总数的贡献**掉在外面**，计数从 117 掉到 80）；三态：`scanned` / `scanned(<n>-NOT-TEXT)` / `empty(NOT-verified)`。非文本文件**出声**（与仓库那一半同一句话），空/不可读**出声**（状态 `empty(NOT-verified)` 点名目录路径）。`find` 的 stderr 在函数内被丢弃——这是安全的，因为**同一个事实由状态本身报出来**：枚举为空就变 `empty(NOT-verified)` 并点名路径，而「stderr 被丢弃、状态却不变」正是本类要抓的形状。抽取成函数是为了让自检驱动**真正运行的那段代码**，而不是它的副本。
    - **锁（行为，双向，驱动真函数）**：新自检在临时目录上建**真实目录**、调 `scan_memory_dir`、按「状态 + 违规数」两个量断言，共 5 例——空目录→`empty(NOT-verified)`/0；含地址的文本文件→`scanned`/**1**（这一例是正向控制：光看状态会漏掉「`scan_file` 根本没被调用」）；含 NUL 的文件→`scanned(1-NOT-TEXT)`/0；文本与 NUL 混放→`scanned(1-NOT-TEXT)`/0；不可读目录→`empty(NOT-verified)`/0。状态与计数从**同一次**捕获里读（`read -r state delta <<<"$( ... )"`），否则 `scanned`/`failures` 两个全局会被夹具污染。**以 root 跑时**不可读那一例不可达（root 无视 `chmod 000`），报 `skipped(needs-unprivileged-user)`（是 `skipped(...)` 而**不是** NOT-covered：后者会进 known-set 门禁，一个未登记的检查名会让**整条套件**在 root 主机上变红——为一条自检子用例让全套红是错误的量级；CI runner 非 root、永远走不到这一支）。实测于 `ubuntu:24.04` root：报该 `skipped(...)`、退 0。
    - **红证（三个变异，全部在内仓库内跑、逐条点名）**：① 把非文本文件改回**静默跳过** → 2 条红（`state [scanned] ... expected [scanned(1-NOT-TEXT)]`，nul 与 mixed 两例）；② 空目录改回报 `scanned` → 2 条红（empty 与 locked 两例）；③ 去掉 `scan_file "$file"` 调用 → 1 条红（`state [scanned] violations=0, expected scanned violations=1`——正向控制承重，证明它抓的是「地址被看见」而不只是状态字符串）。
    - **CI 同步（必须，否则 CI 与本地不一致）**：`ci.yml` 的门禁原本按 `memory directory not present` 放行——我改了措辞，那条正则不再匹配。**只放行 `absent`**（`reports absent\(NOT-verified\)`）：在 hosted runner 上目录从不存在，这是 CI 的属性而非内容的属性；`empty`/`NOT-TEXT` 一旦出现就是真实的覆盖缺口，**必须红**（两个 token 都不匹配新正则）。实测：`HOME=/tmp/aq-cihome` 模拟 runner，`smoke/16` 打印 `reports absent(NOT-verified)`，`grep -E '^SKIP +16-no-host-identifiers +.*reports absent\(NOT-verified\)'` 命中。
    - **边界**：① 自检的不可读那一例在 root 下**未被执行**（记为 `skipped(...)`，不是「已验证」）。② `find` 对**根目录内**不可读的子目录仍可能只给部分清单并退 0（本仓记忆目录是扁平的，未覆盖嵌套不可读）；本类只保证「目录整体不可读」与「空目录」两个形态被抓住。③ 本类只动 `smoke/16` 与 `ci.yml` 的一个正则，`skill/assets/` 零变更。
  - **第五十九类（2026-11-03）：`smoke/16` 把一个 Finder 写的 `.DS_Store` 当成「含 NUL 的二进制」上报，`run-tests.sh` 据此把整条套件判成 partial、打印 `NOT A FULL PASS`——而每个断言都已经通过。**（资产零变更：检查是 dev 工具，不在 `skill/assets/` 里。）
    - **怎么找到的**：用户问「还有其他问题吗」。这一轮的前几次修复跑完冻结树上的全量套件时，摘要行是 `30 ran, 0 skipped, 1 partial, 0 failed`——**不是 `0 partial`**，紧接着一行 `NOT A FULL PASS`。逐条读那一行 `PART 16-no-host-identifiers …` 才看到它出自 `smoke/16`，被点名的文件是仓库根下的 `.DS_Store`（实测 6148 字节）。**这正是本仓反复强调的一类：摘要说「不全绿」，而真正的原因是证据采集方式把一件正常的事报成了异常。**
    - **机制（两层，都是既有设计，不是 bug）**：① `smoke/16` 会走遍仓库里每个文本文件用 7 条规则找主机标识；一个文件若含 NUL 字节，它**不是静默跳过而是上报**（`skipped a file that looks binary by NUL bytes (it could hide a text leak)`）——这是刻意的（一个文本泄漏可能藏在一个 NUL 后面，例如 UTF-16 或损坏的文件），正确。② `run-tests.sh` 把**任何含 `skipped` 字样的行**（大小写不敏感）归进 PART 桶（`run-tests.sh` 的 PART 判定），于是「一条被如实上报的二进制文件」= 整条套件 partial。两层各自都对，叠起来就产生了「全绿却说不是全绿」。
    - **为什么只有 macOS 上看得见**：Finder 会在任何它显示过的目录里写 `.DS_Store`，所以 macOS 上仅仅浏览过一次仓库根就长出一个（本机实测：`.DS_Store`，6148 字节，`.gitignore` 已声明、未被跟踪、不在 git 索引里）。CI 看不见——`macos` job 只跑 `--quick`（只跑 `01`，不跑到 `16`），`linux` job 的 checkout 里没有这个文件。**所以这是「本机红灯、CI 绿灯」的形状**：一个只在开发者机器上出现、把全量套件的判决从绿变 partial 的假信号。
    - **同类先例**：2026-10-25 的 `__pycache__` 排除（`is_derived_bytecode()`）是同一形状——**不可提交的构建/系统残留让套件报假的不全绿**。而 `smoke/01` 早就把这三个 basename 当 `junk`（`asset_kind()` 函数）：`smoke/16` 缺的正是同一张表。
    - **修法**：`smoke/16` 新增 `is_os_junk()`——按 **basename** 判（`.DS_Store`/`Thumbs.db`/`desktop.ini`），与 `smoke/01` 的 `junk` 表逐字相同；文件遍历改成 `if is_derived_bytecode "$file" || is_os_junk "$file"; then continue; fi`。**刻意窄**：只这三个名字。宽成 `*.tmp`、`*~` 会把真实文件也吞掉，而含 NUL 的**普通名字**文本文件必须仍然被上报而不是跳过——自检（下）双向钉住这一点。
    - **锁（自检，双向）**：`smoke/16` 新增 `expect_junk()`——9 条：**5 条必须被判为 junk**（`.DS_Store` 相对路径、绝对路径、子目录、`notes/Thumbs.db`、`notes/desktop.ini`），**4 条必须仍被扫描**（`.DS_Store.bak` 不是垃圾、`smoke/.DS_Store.txt` 只是**名字里嵌了**垃圾名、`logs/notes.tmp` 是 class 之外的临时文件、`CHANGELOG.md` 是普通仓库文件）。任一方向不符即计一次自检失败并退 1——与 `expect_bytecode()` 同形。
    - **红证（两向，实测在内仓库内跑，逐条点名）**：① 把 `.DS_Store` 从 case 里去掉（模拟「排除没接上」）→ **3 条** `the OS-junk exclusion misses …` 并退 1；② 把 case 宽成裸 `*`（模拟「排得过宽」）→ **4 条** `the OS-junk exclusion covers … but must not` 并退 1。**A/B 在真资产上**：`git show HEAD:` 的旧版 `smoke/16` 打印 `… looks binary by NUL bytes … <checkout>/.DS_Store` 且 `files=117`，修后同样的树打印 `files=116` 且**没有**那一行。
    - **收尾实测**：修完在冻结树上重跑全量套件 → `30 ran, 0 skipped, 0 partial, 0 failed`，`PASS` 行不再伴随 `NOT A FULL PASS`。
    - **边界**：① 排除只认这三个 basename；含 NUL 的普通文件仍被**上报**（这一条正是 `smoke/16` 存在的理由之一，不能被这次修复松动）。② 用别后缀强加入库的 `.pyc`（`git add -f`）仍走 `is_derived_bytecode` 那条既有的、已记录的边界。③ 本类只动 `smoke/16` 一个文件，`skill/assets/` 零变更。

  - **第五十八类（2026-11-02 至 11-03）：「按 pid 文件定位自己的守护进程」在 dev 侧 `sandbox.sh` 上错三次——pid 文件可被删、数字可被复用、进程可活得比树长；再加上同一段代码上两个「谁的东西 / 谁先谁后」的缺口（`up` 接管外来树、`up` 先销毁再校验能否重建），一个**读进程表的方式**上的缺口（只有一种 `ps` 拼写，BusyBox 宿主上「看不到」被当成「没在跑」），第五处修复本身只落在一个调用点、把同族失败留在第二处（文档却声称整个 `up` 都不吞），以及给 `cmd_down` 写的结构锁前缀类过窄、换几种写法即可逃逸（同一形态在 `smoke/10` 规则 G 的 `mv` 站点枚举里是存量缺陷）。这一类共七处。**（资产零变更：`sandbox.sh` 是本仓 dev 工具，不在 `skill/assets/` 里。）
    - **怎么找到的**：用户问「本项目还有其他问题吗」，顺着第五十七类「一条检查的**工具依赖**」往下扫本仓自己的驱动脚本时，`pgrep -fl pueued` 列出**三个**在跑的 `pueued`，而 `sandbox.sh status` 报「not running」、`/tmp/aqsb` 早就不存在了。其中一个的启动时间是 **2026-10-26**——六天前的沙箱，一直活着。
    - **根因（一个，三种形态）**：`daemon_pid()` 只从 `$agentq_home/runtime/pueued.pid` 读数字。① **pid 文件可以被删**——`down` 只杀文件里那个 pid，文件不在就打印「removed <root>」退 0 而守护进程照跑；② **数字不是身份**——`kill -0 <n>` / `kill -9 <n>` 分不清自己的 pueued 与**后来复用了这个数字**的无关进程，旧形态会杀陌生人；③ **进程可以活得比树长**——`up` 只在 `[ -e "$sandbox_root" ]` 为真时才调 `down`，树一没就跳过，于是在同一份 config 上**再起第二个** pueued（实测：两个活的，其中一个因为 socket 随树一起消失而永远连不上）。
    - **reproduce（先把红证做出来再修）**：`AGENTQ_SANDBOX_ROOT=/tmp/aq-sbtest ./sandbox.sh up` → `rm -f /tmp/aq-sbtest/home/.agentq/runtime/pueued.pid` → `./sandbox.sh down` 打印 `removed /tmp/aq-sbtest`、退 0，而 `ps` 里 `52581 ./pueued --config /tmp/aq-sbtest/...` **仍在**。种子是 2026-10-26 那个（pid 11565）加上 27435；三个都用真名杀掉了。
    - **修法（定位靠 config 路径，不靠 pid 文件）**：新增 `sandbox_daemon_pids()`——`ps -ww -axo pid=,command=` 读**进程表**，`awk` 只取「命令行里含**本沙箱的** config 路径」且「argv[0] 恰好是 pueued」的行。`down` 改成把匹配到的**全部**杀掉（两个沙箱共用一个 config 时不再需要人工找第二个），并顺手删掉 pid 文件（避免下一次 `up` 读到一个陈旧数字）。`up` 的 `cmd_down` **移出** `[ -e "$sandbox_root" ]`——树不在也要先收尸，再起新的。
    - **`$2 ~ /pueued$/` 是承重的**：没有它，一个**命令行里恰好提到**那个路径的 shell 或编辑器也会被匹配到（实测：`sleep 300 # <cfg>` 的 argv[0] 不是 pueued，不被返回）。**config 路径的匹配也是承重的**：另一个沙箱（或另一位开发者的运行时）用的是**别的** config 路径，实测不被返回。
    - **`-ww` 是这轮里唯一的「差一点又漏掉」**：procps `ps` 即使用管道输出也会按 `$COLUMNS` 截断 command 列，而沙箱的 config 路径正好在行尾之后。实测（procps-ng 4.0.4）：`COLUMNS=20 ps -axo pid=,command=` 打出 **20 字符**、谓词**零命中**，`ps -ww` 打出完整 **108 字符**、命中。BSD ps（macOS）不这样截断，但两边都接受 `-ww`，一种写法覆盖两平台。**如果只在本机（macOS）量，这个洞永远看不见。**
    - **锁（行为，新检查 `smoke/30-sandbox-daemon-reaper`，当日 8 例 = 环境校准 1 + 七向；现为 16 例，见第五个缺口与第六个缺口）**：用 `bash -c "exec -a './pueued --config <cfg>' sleep 300"` **伪造 argv**（macOS bash 3.2 与 ubuntu:24.04 都实测可用），断言七个方向——① pid 文件不在时**孤儿必须被收**；② pid 文件里写着一个**无辜进程**的 pid 时它**必须活着**（数字不是身份）；③ config 路径**属于别的沙箱**的 pueued **必须活着**（不越界），同时本 config 的那个必须死；④ 无树 + 陈旧守护进程时 `up` 必须**先收尸再起**；⑤ 外来未标记树必须被 `up` **拒绝接管**；⑥ 被拒绝的树必须**逐字节不变**；⑦ 注定失败的 `up` 不得**销毁**沙箱。伪造进程由**已退出的子 shell** 拉起（因此被 reparent 到 1），本 shell 不会在摘要行之后打 `Terminated` 通知——`run-tests.sh` 是按**最后一行**报告检查的。
    - **校准先行**：某个宿主的 `exec -a` 或 `ps -ww` 若表现不同，**正向**用例会大声失败，而**负向**用例会无声通过——所以第 1 例先证明伪 argv 真能到达 `ps`，不成立就报**环境故障**并跳过其余各例（不是 NOT-covered：`smoke/30` 不在 `not-covered-known.txt` 里，与第五十七类同一理由）。
    - **红证（六个方向，全部实测，逐条点名而不是只看退出码）**：① 把定位器换回 pid 文件形态 → **5 条全报**（含「down KILLED pid N, which is not a pueued」与「up left a tree-less daemon alive」）；② 把 `cmd_down` 放回 `[ -e $sandbox_root ]` 里 → 恰 **1 条**（`up` 那条），其余七例仍绿；③ 去掉 `-ww`（在 ubuntu:24.04 上、`COLUMNS=20`）→ **4 条**报，**全部是正向断言**（该收的没收到：孤儿、无辜进程例的 own-config 断言、兄弟沙箱例的 own-config 断言、无树收尸），三条负向断言（不该杀的没杀）仍绿——同一棵干净树在 `COLUMNS=20` 下 `cases=8 exit 0`，所以红只由缺 `-ww` 造成。④ 去掉 `up` 的外来树守卫 → 1 条；⑤ 把 `cmd_down` 的所有权判据挪回删 pid 文件之后 → 1 条；⑥ 把 `installer_hashes` 放回收尸之后 → 1 条。四处都还原后，本机与 `ubuntu:24.04` 容器都是 `cases=8 … exit 0`（2026-11-02 重测，六个变异方向全部在当前 8 例文件上重跑过）。
    - **同一段代码的第二个缺口（usr 报「全部优化好」后量到）：`up` 会把标记种进一棵它没创建的树。** `down` 自己的守卫是对的——没有 `.agentq-sandbox` 就拒删并退 1（实测 tree kept）。但 `up` 在 `[ -e "$sandbox_root" ]` 时只打印一句提示就去调 `cmd_down`，而 `cmd_down` 对未标记的树是「拒删但**继续**」，于是 `up` 接着往下走：`mkdir -p` 发现目录已在、不报错，下一行 `: >"$marker"` 就把标记写进了别人的树。**拒绝被当成已处理**。实测（`AGENTQ_SANDBOX_ROOT=/tmp/aqaud1`，先放 `precious/keep.txt`）：`up` 打印「removing a stale sandbox」、种下标记、起 pueued、**退 0**；`down` 打印「removed /tmp/aqaud1」，`keep.txt` 结果是 **DELETED**。修法：在收尸**之前**加守卫——树存在但没有标记就 `die`（退 1，什么都不碰）。锁加进 `smoke/30` 的第 6 例：外来未标记树 → `up` 必须退非零、标记**不得**出现、随后的 `down` 之后原有文件仍在。红证：去掉守卫 → 该例报 1 条，`up destroyed a tree it did not create (precious/keep.txt is gone after up alone)`——**这条消息原来写的是「down DELETED」，是错误归因**：下载桩让 `up` 在种下标记之后才失败，于是是 `up` 自己的 `cleanup_partial` 删的树，不是随后的 `down`；断言已改为先看 `up` 之后树还在不在，再决定要不要归因给 `down`（不跑 `down` 了）。还原后 `cases=8`。
    - **第三个缺口（同一轮，量「拒绝」这个词的实际边界时发现）：`down` 说「拒删」，却已经删了那棵树里的一个文件。** 所有权检查排在 `rm -f "$agentq_home/runtime/pueued.pid"` **之后**，于是 `down` 对一棵外来树先删掉它的 pid 文件、再打印「refusing to delete it」并退 1。两个后果叠加：① 拒删是假的——它确实改动过那棵树；② 删掉的正是 **pid 文件**，而 pid 文件丢失正是 2026-10-26 那个孤儿（也就是本轮第一处修复）的成因——这个「拒绝」在**制造**它自己的失败形态。实测（`/tmp/aqaud3`，runtime 下有 `pueued.pid` 与 `notes.txt`）：`down` 退 1、打印拒绝，而 `pueued.pid` **已经不在**。修法：把所有权判据**提到函数第一句**，拒绝路径在杀进程与删文件之前返回；树不存在**不算**拒绝路径（守护进程可以活得比树长，那个孤儿是我们的，且没有别的东西需要保护）。锁为 `smoke/30` 第 7 例：外来树里放 pid 文件与 notes，`down` 之后两者都必须**原样存在**。红证：把判据挪回删 pid 文件之后 → 1 条，逐字点名 `down deleted the pid file of a tree it refused to delete`。
    - **第四个缺口（同一轮收尾时量「销毁」这个词的顺序发现）：`up` 先把沙箱拆了，才去校验自己还能不能重建它。** `cmd_up` 里代表「这个仓库能不能装」的那一步是 `installer_hashes()`——它读 `skill/assets/unix/install-agentq.sh`，文件缺了或哈希块不全就 `die`。这是一次**廉价的本地检查**，但它排在**收尸与 `rm -rf` 之后**。于是仓库处于临时坏状态（安装器被移开、改到一半）而沙箱正健康运行时：`up` 打印「removing a stale sandbox」、删掉整棵树、杀掉守护进程，**然后**才死在「installer not found」上——用户既没有能用的沙箱、也没有把它建回来的手段，一个完好的沙箱就这样为一次注定失败的启动陪了葬。实测（`AGENTQ_SANDBOX_ROOT=/tmp/aqcopy-sb`，安装器临时移开，收尸重排前）：`up` 退 1、报 `installer not found`，而 `[ -d /tmp/aqcopy-sb ]` 已是**假**、那个 pueued 也**不在了**。修法：把 `installer_hashes` 提到所有破坏性步骤**之前**（守卫、收尸、`rm -rf` 都在它后面）。收尸重排后同一场景：`up` 退 1、只打印 `installer not found`，树**仍在**、守护进程**仍活着**。**这是「破坏性步骤必须排在能中止它的廉价检查之后」的一般形态**——与第二个缺口（拒绝要排在动手之前）同源，但对象从「别人的树」换成了「自己的树」。锁为 `smoke/30` 第 8 例：一棵带标记、看似陈旧（socket 已删）的自建树 + 一棵把 `$root` 重定向到无安装器副本的脚本拷贝（所以用例是**自足**的，不碰本仓），跑 `up`，断言树**必须还在**。**这一例带正控制**：先断言该次 `up` **确实**失败在安装器上（退非零且 stderr 含 `installer not found`），否则一个因**别的原因**提前死掉的副本会什么都不碰，让断言因为错误的原因变绿——实测把 `up` 顶部塞一句无关的 `die` 就报 `the doomed-up case did not fail on the missing installer (exit 1), so it proves nothing` 并计一次失败。红证：把 `installer_hashes` 放回收尸之后 → 1 条，逐字点名 `up destroyed a healthy sandbox and only then failed on a missing installer -- nothing was left to rebuild from`；还原后本机与 `ubuntu:24.04` 容器都 `cases=8 … exit 0`。
    - **第五个缺口（2026-11-03，读「读进程表」这件事本身时发现）：定位器只有一种 `ps` 拼写，在不认它的宿主上「看不到」被当成了「没在跑」。** 修完第四处后重读定位器，问的是「`ps` 本身不认这两个参数会怎样」——不是猜的：本仓 C2 矩阵里就写着 Alpine，而 Alpine 的 `ps` 是 BusyBox 的。实测（`alpine:3.20`，BusyBox v1.36.1）：`ps -ww -axo pid=,command=` 报 `ps: unrecognized option: w` 退 1、stdout 0 字节；`command` 列名根本不存在（只认 `user,group,comm,args,pid,...`）。三层后果全部实测：① **`down` 静默死**——`pids=$(sandbox_daemon_pids)` 那行里管道的 `ps` 退 1，pipefail 让整条管道取 1，`set -e` 把脚本打死：退 1、stdout 0 字节、stderr 0 字节，树在、守护进程活着；② **`status` 给错答案**——同一台机上守护进程明明活着，它打印 `pueued: not running` 退 0（**是错答案，不是错误**）；③ **`up` 把前两处修复的形态重新造出来**——`cmd_down || true` 吞掉静默失败，接着种标记、（下载失败后）`cleanup_partial` 删树：跑完树 GONE、守护进程 **YES**。本机用「只接受 BusyBox 拼写的 ps 桩」完整复现同一三件套（`down` rc=1 且 0 字节输出；`status` 打 not running；`up` 后树 GONE、daemon YES）。
      - **修法（候选链 + 「看不到」必须出声 + 调用方分流三态）**：定位器改成显式候选链——先 `-ww -axo pid=,command=`（macOS BSD 与 procps 都认，`-ww` 承重，见上），被**拒绝**时才退到 `-o pid=,args=`（BusyBox 认；实测 BusyBox `ps` 无会话过滤、默认列全部进程，所以在 BusyBox 上语义等价于 `-axo`）。**顺序是承重的，回退绝不能当「第二意见」跑**：BSD `ps -o pid=,args=` 会**成功**但只回当前会话（实测 6 KB 对 298 KB），无条件回退会把不在调用者会话里的守护进程全部藏掉。`ps -ww -o pid=,args=` 刻意**不**进候选：procps 认它且需要 `-ww`，但 BSD 也认它并静默回会话级清单——唯一一种在两个意义上都错的拼写。全部候选被拒时打印一行点名两种拼写的报错并退 1；`down` 里改为 `pids=$(...) || return 1`（拒绝有声音，且下面什么都不跑）；`up` 里 `|| true` 改为显式判 `cmd_down` 的退出码，非零即 `die`（拒绝在「未审视的状态」上重建；**这是 `cmd_up` 的第一处 `cmd_down`；第二处当时漏改，见下方第六个缺口**）；`status` 改三态——0=running、1=表读到了且无匹配、2=表读不了，打印 `pueued: unknown (this host's ps cannot be read; NOT a verified "not running")`。
      - **锁（`smoke/30` 第 9–14 例，两种 fixture 各证一事）**：A「BusyBox 形状的 ps」——只接受 `-o pid=,args=`、拒绝其余（实现上把**真 ps 的全量清单**转发出来，委派拼写按真宿主逐一试，见下面的教训），断言 `down` 必须照常收掉守护进程（回退拼写**可用**，不只是「不崩」）；B「拒绝一切拼写的 ps」——三个断言：`down` 退非零**且有输出**（原先实测 0 字节正是藏缺陷的形状）、树**必须还在**、守护进程**必须还活着**；`up` 退非零有输出、树在、不杀不认识的进程；`status` **不得**打印 `not running`。校准先行：两个 fixture 都先证明自己的前提（stub 真的拒绝该拒绝的、真的能看见伪造 argv），否则该组用例不跑并计失败。
      - **fixture 自己也骗过三次（同轮实测，全部已修）**：① 伪造目标是 BusyBox `sleep`——它是 applet，会重设自己的 argv[0]（`/proc/PID/cmdline` 实测 `sleep|30|`），换成 `bash -c 'sleep 300'` 在 macOS 上也不行（bash 的末命令优化会 exec 掉自己，argv[0] 回来变成 `sleep 300`），最终用 `bash -c 'while :; do sleep 1; done'`；② BusyBox `ps` 在 argv[0] 与 comm 不一致时把 `{comm}` 打在 args 首位（实测 `{bash} ./pueued --config ...`），谓词 `$2 ~ /pueued$/` 因此落空——伪造进程的 comm 必须真是 `pueued`，修法是把 bash **复制成名为 `pueued` 的文件**再 exec（实测 comm=pueued、谓词命中；真 pueued 本来就是 ELF、comm 天然是 pueued，所以这是 fixture 的错不是资产的错）；③ stub 第一次委派用固定拼写 `-ww -axo`，在它要模仿的宿主上自己就死（BusyBox 不认 `-ww`）；改成裸 `-o pid=,args=` 在 macOS 上又是会话级的 6 KB——stub 必须产出**全量**清单，所以委派也按候选链逐一试。检查自己的校准也同步改成与定位器**同一**候选链（`table_dump`），否则检查就成了「单拼写的观察者在看双拼写的资产」，还会把回退拼写专为它而造的那些宿主判成环境故障。
      - **红证（四向，全部在 14 例文件上实测）**：① 候选链删掉回退拼写 → 2 条红（`down could not find the daemon because its ps is BusyBox` 等）；② `up` 的 `|| true` 放回 → 1 条红（`up deleted the sandbox although it could not list processes`）；③ `status` 改回两态 → 1 条红（`status printed "pueued: not running" about a daemon it could not see`）；④ `down` 吞掉定位失败 → 3 条红（`down claimed success ...` + `down deleted the tree ...` + `up deleted the sandbox ...`）。四个变异全部 `exit 1`。
      - **三平台实测**：macOS、`ubuntu:24.04`（含 `COLUMNS=20`）、`alpine:3.20`（BusyBox，`COLUMNS=20`）全部 `cases=14 ... ps-blind=reported exit 0`（当日的 14 例；现为 16 例，见第六个缺口）。**边界**：沙箱根长到被截断仍不匹配（两平台实测 `-ww` 解决 COLUMNS 那层；内核 argv 上限仍在）；`ps -o pid=,args=` 在 BusyBox 上默认列全部进程是**实测**的，但「某宿主只接受回退拼写且回退是会话级」的形态只存在于 BSD（那里第一拼写总是可用），未发现反例；伪造 argv 的校准依赖 `exec -a` 与 `ps` 的可见性，宿主若连这都不支持会以环境故障报出并跳过（不是 NOT-covered）。
    - **第六个缺口（2026-11-03，审上一版修复「覆盖到哪」时发现）：第五处的修复只落在 `cmd_up` 两处 `cmd_down` 中的一处，而文档把话说成了整个 `up`。** `cmd_up` 里有两处 `cmd_down`：收尸那处（`sandbox.sh` 251 行附近，行号会漂）已改成 `cmd_down >/dev/null || down_rc=$?`、非零即 `die`；「pueued 起不来」的清理那处仍是 `cmd_down >/dev/null 2>&1 || true`——状态被 `|| true` 丢掉、原因被 `2>&1` 重定向进 `/dev/null`，紧接着就是 `exit 1`，其 EXIT trap 的 `cleanup_partial` 会删掉带标记的整棵树。若守护进程已启动却始终不应答、而进程表此刻读不了，就删掉配置并留下进程——正是整个文件要防的孤儿形态，只是这次配置没了、后续 `down`/`up` 也难再按 argv 找到它。
      - **它是潜在形态，不是实测缺陷——必须说清。** 同一次 `up` 里两次 `cmd_down` 读的是同一个 `ps`；ps 完全不可用的宿主在收尸那处就 `die`，够不到第二处。实测（2026-11-03，拒绝一切拼写的 ps 桩 + 一棵带标记的树）：`up` 退 1，打印「removing a stale sandbox」「cannot read the process table」「could not stop the previous sandbox (reason above); refusing to delete or rebuild over an unexamined state」，**树仍在**。要触发第二处必须 ps 在两次调用之间从可读变为不可读（瞬态）。所以它**没有行为级红证**，记为潜在隐患；而文档（CHANGELOG「`up` 不再吞 `cmd_down` 的失败」、本节第五处的修法句「`up` 里 `|| true` 改为显式判」）对第二处不成立——**把已修范围说大本身就是一处失真**，这一条是可验证的。
      - **修法**：第二处改成与收尸同形态——`cmd_down >/dev/null || reap_rc=$?`，stderr 放行；失败时打印「could not reap the daemon that failed to come up … keeping <root> so a later down or up can still find it」并**保留树**：`cleanup_partial` 由新增的 `up_keep_tree` 解除（trap 条件加上 `&& [ "$up_keep_tree" != true ]`）。保留树的理由与第二次修法同源——删掉 config 正是那个孤儿的成因，而守护进程的 argv 里就写着它的路径，留着才有回收的机会。`up_keep_tree` 写成全局而不是 `local`：`local` 其实也能被 EXIT trap 读到（bash 实测），但此处不依赖那个细节。顺带 `sandbox ready (%s)` 在定位失败时打 `unknown` 而不是空括号。
      - **锁是结构级的，因为该状态在一次 `up` 内不可调度**（同一理由下 `smoke/02` 钉 reason-gaps、`smoke/28` 钉 trap 形态）：`smoke/30` 第 15 例——`swallow_rule` 取所有含 `cmd_down` 的非注释行，要求不得出现 `|| true` 或 `2>&1`（分别丢状态与丢原因），自带两向自校准（接受 `cmd_down >/dev/null || rc=$?`、必须标出 `cmd_down >/dev/null 2>&1 || true`，任一方向错即红）；第 16 例——`up_keep_tree` 必须在 `sandbox.sh` 顶层以 `=false` 初始化、被 EXIT trap 读取、在失败分支里以 `=true` 设置，缺任一半即红（否则该标志是只写的，树照样被删）。
      - **红证（结构级，逐条点名）**：① 第二处放回 `cmd_down >/dev/null 2>&1 || true` → 1 条红并**逐行点名**该行；② EXIT trap 去掉 `&& [ "$up_keep_tree" != true ]` → 1 条红（`the kept-tree mechanism is not wired`）。两次变异都在**真文件**上跑（改完即还原并 `grep` 确认），因为锁读的是 `$root/sandbox.sh`。
      - **同轮订正的两处文档失真**：① 本节「锁（… 8 例 = 环境校准 1 + 七向）」缺日期限定，与同一节的「第 9–14 例」和检查自报的 `cases=14` 并存——已改为「当日 8 例 … 现为 16 例」；② 第五处的修法句只描述了收尸那一处，已补一句指到本节。
      - **第七个缺口（2026-11-03，审第六处那条锁「自己的作用域」时发现）：给 `cmd_down` 做的那条结构锁，前缀类写窄了，真实缺陷换几种写法就能从它眼皮下溜过去。** 第一版谓词是 `(^|[[:space:]]|\))` 之后接 `[[:space:]]*cmd_down([[:space:]]|$)`——只在行首、空白或右括号之后认 `cmd_down`。于是 `out=$(cmd_down 2>&1)`（`$(` 的左括号前面是 `$`）、反引号包起来的同形调用、`(cmd_down 2>&1)`、`;cmd_down 2>&1` 这四种形态**全部不被看见**（探针行实测：13 种缺陷写法里 6 种逃逸（`out=$(…)`、`out=$(… 2>&1)`、`(cmd_down …)`、`;cmd_down …`、反引号、`x=$(cmd_down 2>/dev/null)`））。这是本仓反复出现的那一类——**锁的作用域有个形态洞**——只不过这次洞在我上一轮自己写的锁上。
        - **同一形态在 `smoke/10` 规则 G 里也有，而且是存量缺陷。** `mv` 站点枚举用的是同款窄前缀 `(^|[[:space:]])(run_as_root[[:space:]]+)?mv([[:space:]]|$)`，因此「一个 `mv` 写在命令替换或子 shell 里、其所在函数内没有复核」的站点**这条规则永远看不见**——而规则 G 正是本仓覆盖 move-site 复核的唯一手段。它的存在理由正是「move 成功却什么也没搬」能被发布出去。
        - **修法与 A/B 实测**：两处前缀类都宽化为 `(^|[^[:alnum:]_])…([^[:alnum:]_]|$)`（命令名前后只要是「非标识符字符」就算一个 token 边界）。宽化只会**增加候选**、不会隐藏站点——每个新增候选都仍要过同一条 `||true`/`2>&1` 判据。A/B 用**真资产**做（改完即按字节还原并 `cmp` 确认）：把 `moved=$(mv -- …)` 注入 `install-agentq.sh` 后，窄规则报 `installer-invariants … violations=0` 退 0（**漏判**），宽规则逐行点名该行并退 1（**抓住**）。在未注入的真资产上，宽化只多出 3 行候选、全是注释（枚举后仍被注释过滤掉），`sites=28` 不变——不是纸面上的改动。
        - **锁的锁：自校准必须包含逃逸形态**，否则改窄回去没人发现。`smoke/30` 第 15 例的自校准现在有三组 fixture：一个被检查的调用（必须接受）、一个吞掉的调用（必须标出）、以及 `$(cmd_down 2>&1)` 与反引号两行（**必须都被看见**，计数须为 2）。红证：把谓词改回窄前缀 → 自校准报 `the cmd_down swallow rule failed its self-calibration (it must accept a checked site, flag a swallowing one, and see the substitution and backtick shapes)` 并退 1；还原即绿。这条自校准本身用 heredoc 写 fixture 而不是单引号 printf 参数——后者会触发 SC2016（info），实测 `shellcheck --norc -S style` 报出。
        - **扫描范围**：全仓 `grep` 出所有用 `(^|[[:space:]])` 这类窄前缀锚定**命令名**的规则，共 4 处——`smoke/30`（本次新增的锁，已修）、`smoke/10` 规则 G（存量，已修）、`smoke/02` 的 `[<>]` 重定向判据与 `smoke/12` 的 `(^| )-o BatchMode=…`。后两处**不是同款**：`smoke/02` 匹配的是重定向字符而非命令名，`smoke/12` 的 `$joined` 是 `-join " "` 的单空格拼接（`(^| )` 在此是正确的），故未改。
    - **新检查必须登记**：`smoke/30` 加入 `ci.yml` 的 `expected_checks` 钉住清单（`smoke/01` 的 `ci_pin` 臂会把「smoke 里有而 ci.yml 没列」判红——实测改前 `ci_pin` 就报 `smoke/30-sandbox-daemon-reaper.sh exists but ci.yml's expected_checks does not list it`）。摘要 `ci_pin=30`。
    - **边界**：① 这一族只修了 `sandbox.sh`（dev 工具）。**`smoke/07` 与 `smoke/17` 也用 pid 文件收自己的 `sshd`**（`sshd_pid=$(cat "$ssh_dir/sshd.pid")`），但它们各自的 `cleanup` 是 `kill "$sshd_pid"` 且沙箱树由检查自己在 EXIT 里删——没有「树没了但进程还在」的窗口，也**没有**跨进程复用数字的风险（检查一结束就 `rm -rf` 整个 work 目录，sshd 的 pid 文件随之消失，不会留给下一次运行）。所以那两处**未改**，如实记为「同类形态、不同生命周期」。② 谓词读的是 `ps` 的 command 列，**沙箱根长到让 `ps` 截断**就不会匹配（`-ww` 已排除 COLUMNS 那一层，但内核的 argv 长度上限仍在）；`sandbox.sh` 本来就为 SUN_LEN 保持短根（实测 `/tmp/aqsb` 46 字节）。③ `ps -axo` 的**未加 `-ww` 的**形态在 procps 上受 `COLUMNS` 影响这一点是**实测**的，BSD ps 不受影响也是实测的；两者对 `-ww` 的接受同样是实测的。④ 没有在真实远端或生产上验证任何东西——这一整类都在本机 `/tmp` 的伪造进程上。

  - **第五十七类（2026-11-01）：`smoke/28` 的 INT 用例依赖 `perl`，而没有 perl 的主机不是「少测一例」，是**整条套件判 FAIL**。**
    - **怎么找到的**：第五十六类的教训是「一条检查取证据的方式可能让正确的资产看起来是坏的」，顺着往下问「还有哪条检查的**覆盖**取决于一个与它无关的工具」。`smoke/28` 的 INT 用例需要一个「以默认 SIGINT 处置启动」的后台进程（非交互 shell 的 `&` 会让子进程**以 SIGINT 忽略开始**，被忽略的处置无法被 trap 接管），它的做法是 `perl -e '$SIG{INT}="DEFAULT"; exec @ARGV'`，并在 `command -v perl` 失败时打 `client-interrupt: SIGINT case NOT-covered (perl is required …)`。
    - **为什么那是「整条套件红」而不是「少一例」**：`28` **不在** `smoke/not-covered-known.txt` 里（那份名单只收了 05/12/13/22/23/25）。`run-tests.sh` 的本地闸门（2026-10-27 加的）会把任何**未登记**的 NOT-covered 判为失败。fixture 实测（把仓库的 `run-tests.sh`、`smoke/28`、`not-covered-known.txt`、POSIX 客户端摆成最小树，PATH 里遮掉 perl）：`NCOV 28-client-interrupt …` → `FAIL check(s) declared NOT-covered without being in smoke/not-covered-known.txt: 28-client-interrupt`，`PASS/FAIL` 行是 `1 ran … 1 failed`，**exit 1**。同一棵树上 perl 可见时 exit 0。也就是说：**在一台没有 perl 的机器上，这个仓的测试套件整体是红的**，而红的原因是检查自己的工具依赖。
    - **这个依赖有多脆**：`ubuntu:24.04` 有 perl（实测 `/usr/bin/perl`），`alpine` 没有；而本仓的容器矩阵里就有 Alpine（C2 表：Alpine 装机路径）。一个只为「把 SIG_DFL 放回去」而存在的解释器依赖，撑不起一条行为用例。
    - **修法（不装工具、不加白名单）**：改用**作业控制**。`set -m` 让 `&` 启动的命令进入自己的进程组并**以默认处置开始**——实测（`bash 3.2.57` macOS 与 `bash 5.2.21` ubuntu:24.04，用一个只读 `trap -p INT` 的探针）：无作业控制的后台子进程 `SIGINT=IGNORE`，有作业控制的是 `undef`（默认）。作用域收到最小：`[ "$signal_name" = INT ] && set -m` 紧接启动，`client_pid=$!` 之后立刻 `set +m`——这样 bash **根本不会**打印 `Done`/`Terminated` 通知（实测：作用域内启动、作用域外 wait，输出里没有任何 job 通知），而 `run-tests.sh` 是按**最后一行**报告检查的，一条迟到的通知会顶掉摘要行。
    - **红证（三层，全部实测）**：① **机制**：一个六行校准受害者（同 `trap 'exit 130' INT`、同一个信号桩）在作业控制下退 130、无作业控制下退 9（跑完）；② **行为**：把客户端主 trap 改成 `cleanup_client_runtime || true; :`（handler 运行但不退出）→ 28 报 **TERM/INT/HUP 三条**外加 `wait --timeout` 一条，共 5 个失败；把 `set -m` 那一行删掉 → INT 报 `did not stop the client (exit 255, expected 130)`，其余两条仍绿（说明这条用例确实只由作业控制支撑）；③ **环境归因**：把校准受害者的 trap 改成 `trap ':' INT`（模拟一个不传递 SIGINT 的 shell）→ 28 报 `this shell does not give a background job the default SIGINT disposition even under job control … an ENVIRONMENT fault` 并跳过 INT，TERM/HUP 照常通过。
    - **锁（就地校准，不靠外部工具）**：校准受害者是检查**自己**跑的第一步，失败即计一个 failure 并跳过 INT 用例——既不会静默变成 NOT-covered，也不会把环境问题记成资产缺陷。**没有任何 `NOT-covered` token 留下来**，所以 `not-covered-known.txt` 不需要改（也不该改：加名字等于把「这台机器没有 perl」永久写成平台缺口）。
    - **边界**：① 作业控制是否可用是**测出来**的，不是假设的——校准失败就是环境故障，报出来、跳过 INT；TERM/HUP 两条与它无关，仍会跑。② `set -m` 只在**非交互** shell 的启动窗口里用；`set +m` 之后 job 通知不再产生，这一点在 macOS bash 3.2 与 Linux bash 5.2 上都实测过，但**没有**在 dash/ksh/zsh 下验证（本检查的 shebang 是 `#!/usr/bin/env bash`，run-tests.sh 也用 bash 调用它）。③ 本次只改了 `smoke/28`；其他检查里没有别的 `perl` 依赖（`grep -rn perl smoke/ run-tests.sh sandbox.sh` 除注释外零命中）。

  - **第五十六类（2026-11-01）：smoke/25 的 `-?` 用例断言的是「宿主怎么渲染」，不是「资产的契约」——它只在中文宿主上绿过，真 PS 5.1 一上就说正确的资产是坏的。**
    - **怎么找到的**：第五十五类修好 CI 的 windows job 之后，`22/23/25` **第一次**在 PowerShell 5.1 下真正运行。25 立刻红：`ps-client-installer -?: the synopsis does not list the three parameters`，而同一行打印的 stdout 是 **0 字节**。0 字节却报「没列出参数」，说明它不是「查了没找到」，而是「根本没拿到东西」。
    - **量到的根因（形态，不是资产）**：在真 Windows runner（PS 5.1.26100.33648）上逐个形态实测——
      | 形态 | 退出码 | stdout | stderr |
      | --- | ---: | ---: | ---: |
      | `-File <asset> -?` | 0 | **0 字节** | 0 字节 |
      | `& '<asset>' -?` | 0 | 105 字节（三个参数都在） | 0 |
      | `Get-Help '<asset>'` | 0 | 105 字节（三个参数都在） | 0 |
      也就是 **PS 5.1 在 `-File` 启动路径上把帮助开关吞掉了**，退 0、什么都不打印。pwsh 7 上 `-File` 也能渲染（本机实测 101 字节），所以两种形态在 macOS/Linux 上**看不出差别**——旧用例每次都绿。
    - **它为什么只在中文宿主机上绿过**：旧用例走 `run_installer`，即 `-File`（`pwsh_binder=en` 时）。而它在 zh-CN 主机上一直是绿的，因为那里 `pwsh_binder != en`，走的是 `binder-en.ps1` wrapper，而 wrapper 内部**正好**用调用运算符 `& $target ...` 重新组装调用——**绿的是包装器，不是资产，也不是这条用例**。第一台英文 Windows 主机（CI runner）就把正确的资产报成了坏的。
    - **这是「把宿主的渲染当成资产的契约」这一类**：断言的内容（「synopsis 列出三个参数」）本身是对的，但**到达方式**在一个引擎上不产生任何证据，而用例没有意识到「没有输出」和「参数不对」是两种完全不同的失败。本仓此前修过同一族的前提错误（第五十四类的宿主门、第五十二类把「需要伪造输入」当成「不可测」），但那些都是**门控**层面；这一条是**取证据的方式**层面。
    - **修法（资产零变更）**：`smoke/25` 改用调用运算符 `-Command "& '<script>' -?"`（实测两引擎都渲染），断言改成资产契约——退 0、synopsis **指名脚本**、列出三个真实参数。路径在进入 `-Command` 字符串前必须 `cygpath -w`（MSYS 只改写裸参数，不改字符串里的路径），并按 PowerShell 单引号规则转义。
    - **锁（双向，两道）**：
      1. **`smoke/25` 内置自检（行为）**：写一个带 `[CmdletBinding()]` 但 `param()` 为空的夹具，用**同一断言**去判，必须被判坏；并且**先断言 synopsis 真的渲染出来**（夹具名字出现在输出里），否则退回的那条红臂可能来自「引擎吞了帮助」，而不是「参数不匹配」。这两个断言合起来才排除「空洞的断言」。（`[CmdletBinding()]` 是承重的：本机实测，没有它的脚本**完全不打印 synopsis**，而只有属性、没有 `param()` 又会解析失败。）
      2. **`smoke/01` 新增静态规则 `ps_help=`（构造级）**：同一逻辑行上 `-File` 与 `-?` 同时出现即违规（续行先拼接，注释行跳过），判据是 `-File[^|;&]*-\?([^[:alnum:]_]|$)`——**边界字符类不能只写 `[[:space:]]`**，见下。带双向标定：末位形态与 `)` 后接形态各一例必报、`-Check` / 调用运算符 / 注释必不报。
    - **红证**：① 把 25 的调用改回 `-File` → smoke/01 点名 `smoke/25-ps-client-installer-contract.sh: 286: … -File "$target" -?` 并退 1（改回后 `ps_help=0`；**判据修正后重做**，见上面第③条）；② 往断言里加一个资产没有的参数 `-BogusParam` → 25 报 `the synopsis does not list -BogusParam (stdout 103 bytes)` 并退 1，同时把真实 synopsis 打出来；③ 让夹具丢掉 `[CmdletBinding()]` → 25 报「夹具没打印 synopsis……」并退 1（证明红臂不是静默产生的）；④ 把 `synopsis_problem` 改成永不返回问题 → 25 报「断言接受了不含任何期望参数的 synopsis——这条臂是空洞的」并退 1。还原后本地 `cases=10 pwsh=7.5.4 …` 退 0。
    - **写这条规则时自己踩的坑（三处，都已记进注释）**：① `ps_help_re` 以 `-File` **开头**，`grep -E "$re"` 会把模式当成选项（`-F -i -l -e`），实测报的是字面量 `(standard input)` 而不是行号，必须写 `grep -E -e "$re"`。② 第一版把夹具**字面**写在 smoke/01 里，于是规则扫到自己的夹具、报了自己两次——夹具、自检消息与诊断文本现在都**构造**出来（`%s` 携带 `-?`），不再字面出现。③ **第一版判据漏掉了最可能的回退形态**：边界字符类写成 `([[:space:]]|$)`，于是 `-File "$target" -?)`（开关后紧跟右括号——`$( )` 里的写法，正是把这条用例改回 `-File` 时的真实形状）**不被识别**。这不是假想：我先前的「改回 -File 应当报红」用的正是这个形态，**当时是被 25 自己的行为红盖过去的，规则其实没响**；提交后我重跑那次红证才量到（实测：旧模式对 `-File "$target" -?) >…` 零命中，新模式命中）。改判据为 `-\?([^[:alnum:]_]|$)`（非标识符字符或行尾），标定加一条 `x=$( … -? )` 形态。**教训：红证必须证明「是规则报的」，而不是「整条命令退了 1」——同一次变异可以同时触发别的检查，绿灯/红灯都可能被冒领。**
    - **边界**：① 静态规则只看 `-File` 与 `-?` 出现在**同一逻辑行**。**原始缺陷本身就不在这个形状里**——它当时是 `run_asset` 里的 `-File "$asset_path" "$@"` 加调用点的 `-?`，跨行、跨函数，规则永远看不见；那一半只能靠 25 自己的行为自检（以及这条规则在**别处**重犯时的新写法）。`-?` 赋给变量再传进 `-File` 同理不在其内。② `smoke/25` 的自检证明的是**这条断言**能区分「synopsis 缺参数」与「引擎没渲染」，不证明任意断言都如此。其他 PS 用例断言的是**错误消息**的渲染（12/13/20/22/23），那类渲染**已被实测证明在 5.1 上成立**——同一个 windows job 全绿就是证据；静默消失的只有帮助开关这一条路径，所以今天只有 25 需要这种自检。将来若有别的「可能什么都不打印」的断言，得各自补。③ 真 PS 5.1 的证据来自 CI runner（`PS 5.1.26100.33648`），**不是**本机；本机只有 pwsh 7.5.4，两种形态都绿——这正是这个缺陷能躺这么久的原因，也说明「本机绿」对这类问题**没有**证明力。

  - **第五十五类（2026-11-01）：CI 的 windows job 自 0.1.16 起结构性损坏——`$( )` 里以裸 grep 开头/结尾的管道在 `set -e -o pipefail` 下一无命中就静默终止整个 step，三个检查因此从未运行。**
    - **怎么找到的**：第五十四类提交后第一次 push 触发了 CI（**上一次 CI 运行是 2026-10-14**——这之间的所有提交只在本地）。linux job 绿（正是本轮要证的那半），**windows job 红**。失败点是「PowerShell 5.1 client contracts」这一步，输出停在 `===== 20-ps-native-argv-roundtrip (exit 0) =====`：`22/23/25` 连 `=====` 头都没有，紧随其后的「Assert PS 5.1」步骤报 `smoke-22-launcher-contract.log: No such file or directory`。**12 和 13 明明打印了 NOT-covered，20 没有**——这个「哪个检查的日志里没有那个 token」的分布正是判据。
    - **根因**：ci.yml 的 windows 步骤声明 `shell: bash`，GitHub Actions 把它展开为 `bash --noprofile --norc -e -o pipefail`（实测日志里那行 `shell: C:\Program Files\Git\bin\bash.EXE --noprofile --norc -e -o pipefail {0}` 就是）。循环体里
      ```
      occurrences=$(grep -o 'NOT-covered' "$log" | wc -l | tr -d ' ')
      named=$(grep -o 'NOT-covered([^)]*)' "$log" | wc -l | tr -d ' ')
      ```
      在日志里**一个匹配都没有**时，`grep -o` 退 1，pipefail 让**整条管道**判非零，`$( )` 的赋值命令因此失败，`set -e` 杀掉整个 step。`smoke/20` 是六个检查里唯一**不声明任何 NOT-covered** 的（它的正常输出就没有 token），所以循环在它这里必死；`12`/`13` 逃过只是因为它们的摘要恰好带 token。linux job 的 `expected_count=$(printf '%s\n' $expected_checks | grep -c .)` 是同一族（默认 shell 无 pipefail，但 `grep -c` 是管道末段、在 `-e` 下同样会中止），一并修。
    - **为什么它躺了两周**：这条 `occurrences=` 是 2f5755a（0.1.16，2026-10-17）加的，而**最后一个被 push 的提交是 2026-10-14**——也就是说这个 CI 步骤**从未执行过**。新加的 CI 断言第一次运行就是它的第一次运行；本仓的「本地先行」在这类**只在 CI 里跑的代码**上不管用。
    - **修法**：三处改为 `( grep … || true )`——守卫**必须在子 shell 内**，因为 `wc -l`/`tr` 永远成功、写在管道尾部的 `|| true` 看不见那个失败的 grep。这是本仓既有的 `agentq-pipefail-grep-race` 同一族的**第二种形态**：那条讲「管道末尾的 quiet grep 在读端」，这条讲「管道首段/末段的普通 grep 在写端，被 pipefail 抓住」。
    - **锁（`smoke/01` 新增 `workflow_pipes`，与既有 `repo_pipes` 同族）**：读两个 `.github/workflows/*.yml`（用 pyyaml 取 `jobs[].steps[].run` 与 `shell`），对每个步骤的 `$( )` 替换做**引号感知**的切分（单引号内是字面；双引号内仍识别 `$(`——ci.yml 的 `known_ncov=" $(grep …)"` 就是这么写的；`||` 不当管道分隔符，否则 `grep -v q || true` 会被切成两段）。判据分两档：`shell: bash` 步骤里**任何**未守卫的 grep 算违规（pipefail 下哪一段都致命），默认 shell 步骤只查**管道末段**的 grep（前面有阶段能把它挡下）。标定 8 例覆盖两档 × 守卫/未守卫 × 末段/非末段，外加「带括号的引号内正则不被误切」（`grep -o 'NOT-covered([^)]*)'`——第一版检测器**没有引号感知**，把这个 `(` 当成嵌套、把替换切错，实测在正确资产上报出 2 条假红）。闸门：一个被检查的 `shell: bash` 替换都没有时退 2 拒绝通过（枚举器瞎掉时「无违规」与「没检查」不同义）。
    - **红证**：HEAD 版 ci.yml 喂给**已发布的** `smoke/01` → **3 条逐站点点名**并退 1（`ci.yml job=linux step=3 shell=default: grep -c .`、`ci.yml job=windows step=1 shell=bash(pipefail): grep -o 'NOT-covered' "$log"` 与 `… 'NOT-covered([^)]*)' "$log"`）；两个单点还原（只回退一个守卫）→ 各 1 条、退 1；当前树 → `workflow_pipes=2/7`、exit 0（本机 macOS 与真实 `ubuntu:24.04` 均绿）。三个变异都在整仓副本上跑，避免「少文件」的旁枝失败掩盖规则本身。
    - **边界**：① 检测器只**读** workflow 源文本，不执行任何步骤。② 它假定 `shell: bash` = `-e -o pipefail`（Actions 的既定行为，日志实测），并假定 `set -e` 语义——不建模 `set +e`/子 shell 的局部关闭。③ 默认 shell 那一档只查末段 grep：**非末段**的 grep 在 `bash -e`（无 pipefail）下确实被后段掩盖，但若将来某步改成 `shell: bash`，同一行会立刻被严格档抓住。④ 只扫 `.github/workflows/`——`smoke/` 与 `run-tests.sh` 的同一形状由既有 `repo_pipes` 覆盖。⑤ **windows job 的 22/23/25 三个检查到今天为止从未在 PS 5.1 下跑过**：修好这一步只是让它们**开始**运行，它们自己是否通过要等下一次 CI 结果，此处不预设。

  - **第五十四类（2026-10-31）：两个同族的 `$(id -un)` 泄漏点 + 我自己上一轮引入的「Darwin 用例在 Linux CI 上必红」回归——三个发现都来自「把 HEAD 的套件放到真实 Linux 上跑一遍」这一个动作。**
    - **怎么找到的**：第五十三类收尾时只有本机（macOS）证据，而 Ubuntu CI 的 linux job 跑的是**全量**套件。我在真实 `ubuntu:24.04` 容器里跑了一次 HEAD 的 `smoke/02`，结果 **7 条失败、rc=1**——第五十三类新加的 4 条 Darwin 用例全军覆没（「expected exactly one launchd_service= line, found 0」×4 + `darwin-start-guard: expected exit 2, got 2` 的三条后续断言）。原因不是资产坏，是**用例门控错**：我给它们套了 `[ "$(uname -s)" = Darwin ]` 的**主机平台**守卫，非 Darwin 主机直接跳过并打 `NOT-covered(needs-macOS)`——而 `platform` 就是文件顶部那**一个** `uname -s`，与 Linux 分支（第五十一类）和 Windows 分支（第五十二类）**同一手法遮蔽即可进入**。我自己刚在第五十二类订正过「把『需要伪造外部输入』当成『不可测』」，转头就在 Darwin 用例上犯了同一个错。
    - **为什么它当时没被抓住**：第五十三类的「全量套件 29/0/0/0」是**本机 macOS** 跑的（守卫为真、用例正常跑）。Linux CI 只在 push 之后才跑，而这个会话的提交没等到 CI 结果就被我继续往下做了。**「全量套件绿」必须注明在哪个主机上跑**——这是本轮的元教训。
    - **顺手量到的第二个缺陷（真实资产缺陷，非回归）**：容器里 `USER` 未设，`systemd_case uid-unresolved` 那例也红了。追进去是 `run_pueue` 的 unix 分支：
      ```
      USER="${USER:-$(id -un)}" \
      LOGNAME="${LOGNAME:-${USER:-$(id -un)}}" \
      ```
      两处 `${VAR:-$(id -un)}` 在 `USER`/`LOGNAME` **都被清空**时才求值（ssh 命令执行、cron、容器正是这三种场景），而 `$(id -un)` **没有任何 stderr 重定向**——`id` 一失败（uid 无 passwd 项的容器里 `id -un` 就会退 1，实测 `id: cannot find name for user ID 501`），它的诊断直通服务端自己的 stderr。实测（macOS 与 Linux 同形，`id` 桩对 `-un` 报错退 1、`env -u USER -u LOGNAME`）：**2 行泄漏**（两个展开各自求值一次，`env` 的赋值列表里 `USER=` 不改变 shell 自己的 `USER`），`USER` 设时 **0 行**。这是「按 `reason=` 读 stderr 的调用方拿到噪声」的同类第五处，也是第五十三类 `systemd_linger=` 内层 `$(id -un)` 的**亲兄弟**——同一个「内层命令替换的 stderr 不归外层管」形状，只是这里连外层都没有。
    - **修法**：① `run_pueue` 两处 `$(id -un 2>/dev/null)`——stdout 不变（`id` 的回答本来就在 stdout），Pueue 拿到的环境值与改前逐字节相同；② Darwin 用例**去掉主机门与 NOT-covered**，改为给 shim 各加一个 `uname → Darwin` 桩（与 Linux arm 的 `uname → Linux` 桩对称），`cannot-start` 那例再加一个「存在但每个 target 都不存在」的 `launchctl` 桩（`exit 1`），使**没有 launchctl 的 Linux** 也能走到同一目标解析（实测没有它时 Linux 上 `start_managed_daemon` 停在更早的 `launchctl is required to start AgentQ on macOS`，永远到不了空 uid 守卫）；③ `darwin-start-guard` 接受两种受控拒绝——空 uid（`cannot determine the launchd service target: no user id could be read`）与已安装系统 LaunchDaemon 时的 `system LaunchDaemon … is inactive`——因为本机是否装了 LaunchDaemon 决定走哪条，两种都退 2 且带 reason。
    - **NOT-covered 门因此不需要动**：去掉了那个 `NOT-covered(needs-macOS)` 声明，`smoke/not-covered-known.txt` 不加名字。**本类比主机门方案更好的地方**：Linux CI 的 linux job 现在真实覆盖了 Darwin 分支（遮蔽之下断言的是同样的行），而不是把它声明成「测不到」。
    - **锁（`smoke/02` 33→34）**：新增 `pueue-env-id`——`env -u USER -u LOGNAME PATH=<id 桩>:$PATH "$server" status`，断言 stderr **无 `id:`** 且退出码在 0–6。该站点由 `platform_kind`（unix）选分支、不依赖 doctor 的哪条 arm，所以这条用例**不需要平台门**，任何主机都跑。红证（只回退这两处 `2>/dev/null` 的副本）：macOS **1 条失败**（`pueue-env-id: the USER/LOGNAME fallback leaked its stderr: id: cannot find name for user ID 501`）、Linux **3 条失败**（容器里 `USER` 未设，泄漏同样打进 `systemd_case`/`darwin` 用例的 doctor stderr，各多 1 条「raw probe diagnostic」）。第五十三类全量还原的旧红证副本在改后的 `smoke/02` 下 → **11 条失败**（新用例也算它）。
    - **边界**：① `pueue-env-id` 用 `id` 桩制造 `id -un` 失败——真实 Linux 上「uid 无 passwd 项」正是这个形态（实测 `setpriv --reuid=54321` 下 `id -un` 打 `id: cannot find name for user ID 54321` 并退非零），但那次容器复现**没有走到 run_pueue**（更早的目录权限检查先退 2），所以「生产形态完整走到泄漏」的端到端只有桩证据、没有真实 uid 证据，如实记为边界。② `id -un` **成功**时无泄漏（它不打 stderr），所以这类的触发条件是「USER/LOGNAME 未设 **且** `id` 失败」的合取——比第五十～五十二类的单条件窄。③ Darwin 用例遮蔽 `uname`/`launchctl`/`id` 三个探子，被测的是版本块的**写者**如何呈现探针结局；真实 `launchctl print` 的输出形状由 macOS 本机路径覆盖（`cannot-start` 在真机上实测过）。
    - **元教训（写在这里给下一轮）**：「全量套件 → exit 0」**不是**一个可独立验证的陈述，必须带上**哪个主机**；本仓的 arm 可达性结论已经五次被「遮蔽探子」推翻，**第六次（Darwin）我在同一轮里先犯了再改回来**。写 `NOT-covered` 之前先问一句：那个平台的判定探子是不是也是 PATH 上按名查找的命令？
    - **同一次排查中看到、但本轮**没有修**的一条**：合成 fixture 下 `doctor` 的 stderr 里还会出现一行光秃秃的 `jq: parse error: Invalid numeric literal at line 1, column 6`（`ensure_agentq_group`/`verify_group` 的 `jq -e … < "$group_file" >/dev/null` 只压了 stdout、没压 stderr）。触发条件是「`pueue group --json` **退 0** 但 stdout 不是合法 JSON」——这也是「子进程原始 stderr 落到服务端 stderr」的同类。**本轮不修的理由**：smoke 的 pueue 桩对 `group --json` 答的是 `pueue 4.0.4`（非 JSON），所以这行在合成环境里必然出现、也确实被既有断言容忍；而**生产可达性没有证据**——真 pueue 的 `group --json` 要么答合法 JSON、要么退非零（已有 `cannot inspect the AgentQ group` 分支）。按本仓规矩，没有红证就不动，记为**看到但未归因、未测**的观察，不是已修项，也不是待办。将来若拿到「退 0 但输出非法 JSON」的真实来源，先补一条红证再改。**（2026-11-05 已修：第七十一类补上了行为红证与 `smoke/02` 的锁，凡读外部程序输出的 jq 站点都加了 `2>/dev/null`；此段保留为当时的判断。）**

  - **第五十三类（2026-10-31）：同一条 `key=value` 泄漏还有第四处，而且就在**本机**——`doctor` 的 Darwin 分支，进入它需要的不是遮蔽而是让探针 `id` 失败。**
    - **怎么找到的**：第五十二类把三条 arm（`pueue=`/`systemd_*=`/`scheduled_task=`）都修完之后，我核对「还有没有同族站点」，用 `grep "printf '[a-z_]*=' >&2$"` 扫**所有以未终止的 key 开头**的 `printf`。结果只有两处：`agentq=` 与 `launchd_service=`。前者紧跟 `printf '%s\n' "$agentq_version"`，是安全的；后者是**同一形状**——`printf 'launchd_service=' >&2`（无换行）之后调 `macos_launch_service_target`，而那个函数第一条语句是 `macos_uid=$(id -u)`，**没有 stderr 重定向、也没有失败容忍**。
    - **为什么以前没看见**：本机 `id -u` 恒成功、`$(id -u)` 的成功路径不打 stderr。这条 arm 的进入条件**不是平台**（本机就是 Darwin，无需遮蔽），而是**探针 `id` 失败**——「`id` 什么时候失败」在本机是零覆盖的（uid 无 passwd 项、`PATH` 上的 `id` 起不来）。第五十～五十二类每次都是「换一个平台才看得见」，这条是「换一个失败的探针才看得见」——同一个类的第五种入口。
    - **实测修复前（本机，真实的 Darwin 分支，未遮蔽任何平台）**：把 PATH 上的 `id` 换成 0755 纯文本文件后，
      ```
      launchd_service=/tmp/aqA/shim/id: line 1: not: command not found
      ```
      且 `doctor` **退 127**（在文档化的 0–6 契约之外），没有 `launchd_domain=` 行、**没有 reason 行**、没有人类可读诊断——一个只读诊断命令把 shell 的 exec 抱怨当成了自己的退出码。第二种形状（`id` 存在但退 1，如 uid 无 passwd 项）同样泄漏。这与第五十～五十二类是**同一个类**，只是进入路径不同：那三条靠遮蔽工具，这条靠真实的 launchd 状态分派。
    - **又一次把「进不去」当成了「不可测」**：第五十二类刚因为「`cygpath` 缺失所以 Windows arm 不可测」被推翻，这里我又差点犯同一个错——我最初写下的注释是「这条 arm 需要 macOS 自己的 launchctl 先说不存在服务，桩替代不了它，所以不可测」。**这句话对其中一条形状是错的**：`id` 本身完全可以是桩（它是要被测的探针），只是 `launchctl` 那条短路路径需要真机状态。两条形状因此拆开测：`id` 答非整数（桩可得）与 `id` 起不来（桩可得）——都不需要 `launchctl` 配合。
    - **修法**（与其三条 arm 同形，另加四处）：① Darwin arm 改为先调 `macos_launch_service_target`、再整行 `printf 'launchd_service=%s\n'`，与 `systemd_*=`, `pueue=` 一致；② `macos_launch_service_target` 里 `macos_uid=$(id -u 2>/dev/null) || macos_uid=''`——丢掉 stderr、容忍失败；③ **空 uid 时不再编造 `user/`**：旧代码会把 `macos_launch_service="user/$macos_uid/..."` 渲染成 `user/`（实测到的 `launchd_domain=user/` 就是它），现在空 uid 时把 `macos_launch_service` 置空、doctor 两行都写 `unavailable`；④ Linux 的 `systemd_linger=` 行内层 `$(id -un)` 补 `2>/dev/null`——实测 `loginctl show-user "$(id -un)"` 里 `id` 的 stderr **不归**外层捕获行的 `2>/dev/null` 管（内层命令替换的 stderr 直通服务器的 stderr；实测它渲染在两条 systemd 行**之间**），这是同一类的第四处，只是藏在内层。
    - **为什么空 uid 用 `unavailable` 而不是退回 `system/`**：`system/` 已经在函数开头检查过（`launchctl print system/... ||` 失败才走到这里），再报一次会与「已确认不存在」矛盾。`unavailable` 是契约里对「探不出来」的既定值。**没有**给函数加新的非零返回：它有两个调用点（`managed_daemon_is_active`、`start_managed_daemon`）是 `set -e` 下的**裸语句**，新返回值会把一个诊断缺口变成崩溃——空 `$macos_launch_service` 与它们的「不匹配」判据天然兼容。
    - **锁（`smoke/02` 29→33）**：四例。`uid-unresolved` 加进 `systemd_case` 矩阵（`id -un` 报错退 1、`systemctl`/`loginctl` 正常答），断言 `systemd_linger=no` 且 stderr 无 `id:`；Darwin 两例共用一个 `darwin_assert`——**断言的是形状不是主机值**（`launchd_service` ∈ {active,inactive,unavailable}，`launchd_domain` ∈ {system, gui/*, user/*, unavailable}），所以装了 LaunchDaemon 的主机（答 `system`）与只有用户域的主机同样通过，只有「空域 `user/`」和「原始诊断」被拒。`cannot-start` 那例额外钉死 `unavailable`——**这条正是空 uid 编造 `user/` 的守卫**。第四例 `darwin-start-guard` 换掉 pueue 桩使 `status --json` 失败、进入启动路径，断言退 2 + 受控消息 + reason 行 + **stderr ≤1024 字节**。
    - **顺手量到的第五个缺陷（同一处容忍的后果）**：把 `id` 的失败容忍掉之后，一个**此前不可达**的状态变得可达——空 uid。它不仅影响版本块，还影响 `start_managed_daemon`：那里 `macos_launch_service_target` 之后直接 `launchctl kickstart "$macos_launch_service"`，空目标就是 `launchctl kickstart ""`。**实测这不是无害的 no-op**：macOS 把该域**全部服务清单**倾泻到 stderr，**55238 字节**（实测 `launchctl kickstart "" 2>&1 | wc -c` = 55238，退 64），足以淹没这个命令自己的诊断。修法：空目标时退 2 报受控消息 `cannot determine the launchd service target: no user id could be read`。**这是「容忍一个失败」的典型代价**——它把一个「崩溃」换成了一个「新状态」，而新状态需要它自己的守卫。锁里用**字节上界**（stderr ≤1024）钉「空目标没喂给 launchctl」，这是「它没发生」的可测形式；单独去掉这个守卫的变异体实测 `stderr was 55340 bytes`、2 条失败。
    - **红证**：四处（doctor 的 Darwin arm、`macos_launch_service_target`、`start_managed_daemon` 的守卫、Linux 的 linger 内层）都还原成旧形态的副本喂 `AGENTQ_SMOKE_SERVER` → **10 条失败、rc=1**，逐条点名 `launchd_service=<path>/id: line 1: not: command not found`、`launchd_domain=` 缺失、`doctor exited 127`、`darwin-start-guard: expected exit 2, got 127`、内层 `id:` 泄漏、以及两条 `unavailable` 断言。修复后 `smoke/02 → cases=33` 全绿。
    - **边界**：四例都在**本机真实 Darwin 分支**上跑（不需要平台遮蔽），但 `launchctl` 是真的——**服务已装/未装两种机器状态没有被切换验证**（本机 system/gui 两域都不存在，见 `launchctl print` 双双退 113）。形状断言正是为这个不确定性选的：两种状态都在可接受集合内。`launchd_domain` 的 `gui/<uid>` 这类**具体值**与 `id` 的真实回答绑定，本机实测为 `gui/501`，但那不是契约的一部分，所以未进断言。`darwin-start-guard` 走的是 `run_pueue status --json` 失败的路径（桩），**没有真的启动任何服务**。**（2026-10-31 订正：这一节的四条用例最初被套上 `[ "$(uname -s)" = Darwin ]` 的**主机门**、非 Darwin 打 `NOT-covered(needs-macOS)`，于是 Ubuntu CI 的 linux job 全红（实测真实容器里 7 条失败、rc=1）。第五十四类去掉了主机门——`platform` 与 Linux/Windows 两条 arm 一样是 PATH 上按名查找的 `uname -s`，遮蔽即可在任意主机进入；详见第五十四类。）**
  - **第五十二类（2026-10-31）：第五十一类把 `scheduled_task=` 记成「Windows 分支进不去」是错的——`uname`/`cygpath`/`powershell.exe` 三样 `/bin/sh` 桩遮蔽就能把 `doctor` 的 Windows 分支在本机跑起来，而同一行在漏同一个类。**
    - **怎么找到的**：第五十一类收尾时写了「Windows 那半的不可测是真的，因为 `cygpath` 在 macOS 上缺失，Windows 分支第一句就退 127」。这句话本身没算错**实数**，但把一个**可构造**的问题记成了**不可构造**：`cygpath` 是 PATH 上按名查找的命令，把它遮蔽成桩就答得出 `-aw`/`-u`；`uname -s` 已经证明是这个分支的唯一探子；`powershell.exe` 同样可按名遮蔽。三个桩会伪造的是**分支入口的输入**（`uname` 的回答、`cygpath` 的路径转换、`powershell.exe` 的环境元数据），但本类要测的是版本块**如何呈现探针结局**——这正是桩能如实建模的：探针失败怎么写 stderr、能不能泄漏到 key 行。**与「为进入分支而伪造 `cygpath` 返回」的顾虑并不冲突**：伪造的是不可控外部环境的输入，被测对象（版本块的写者）在桩下真实执行。
    - **实测修复前（macOS，最小 home，`uname` 答 `MINGW64_NT-10.0`、`cygpath`/`powershell.exe` 为 `/bin/sh` 桩，`MSYSTEM=MINGW64`）**：探针把诊断写到 stderr、退 1 时，`doctor` 的 stderr 版本块是 `scheduled_task=Get-ScheduledTask : No MSFT_ScheduledTask objects found`（**同一行**上 key 与探针原文直接接续，没有换行）；探针零输出退 1 时是 `scheduled_task=<program>: scheduled startup task is unavailable; on-demand daemon startup remains available`（**人读的告警自己成了值**）。旧写法是**三个写者一个流**：`printf 'scheduled_task=' >&2`（无换行）写 key、探针伸到 `>&2` 写 stdout、失败时再往同一流追加一行告警。修复前的成功形状则与现在逐字节相同（JSON 跟 key 拼在一行——因为 key 无换行，成功的 JSON 也贴着 key），所以**只从成功形态看不出缺陷**，必须测失败形态。
    - **修法与 systemd 行同形但判据不同**：捕获 stdout → 只在**成功**时取值 → 打一次 `printf 'scheduled_task=%s\n' "${output:-unavailable}" >&2`，失败时 `unavailable` 与告警各占一行。**关键差异**：不能像 `systemctl` 那样「非零也保留 stdout 答案」——`systemctl --user is-active` 的 stdout 在非零时仍是合法答案（inactive 退 3），而 `powershell.exe -ErrorAction Stop` 的失败 cmdlet 是**错误记录走 stderr、stdout 为空、退 1**（实测 pwsh 7.5：94 字节 stderr、0 字节 stdout）。所以 Windows 这条以 **exit 0** 为唯一成功判据：探针退非零时 stdout 一律丢弃（避免把半个 JSON 当成值——那比 `unavailable` 更难诊断）。
    - **锁（`smoke/02` 25→29）**：三个桩（`uname`、`cygpath`、`powershell.exe`）+ 四条形状。`ok`（JSON、退 0）断言 `scheduled_task=` 整行恰为 JSON；`err-stderr`（诊断写 stderr、退 1）断言行恰为 `unavailable` 且 stderr **不得**出现 `MSFT_ScheduledTask`/`Get-ScheduledTask :`；`quiet-fail`（零输出、退 1）断言 `scheduled_task=unavailable`（旧形态下这里是告警本身成值）；`unlaunchable`（0755 纯文本）断言**另一件事**——`resolve_windows_user_environment` 在 `doctor` 版本块**之前**调用 `powershell.exe`，桩起不来时进程在 profile 解析处就退 2 并报 `unable to resolve the current Windows user profile`，**到不了版本块**，因此「恰好一行 `scheduled_task=`」对它是错误期望，正确期望是「一行都没有 + 解析诊断 + 退 2」。这一条明确了分支入口与版本块的先后关系，避免把「版本块没跑到」误判成「版本块修坏了」。
    - **`powershell.exe` 桩要回答两次调用**：`resolve_windows_user_environment`（`-Command '<大脚本>'`）与版本块（`-Command "Get-ScheduledTask …"`）。第一版桩只回答了后者，进程在前者处就失败、`doctor` 根本没跑（实测「found 0」）。最终桩按 `case "$*" in *Get-ScheduledTask*)` 分流：命中则按 shape 作答，否则输出完整 profile JSON。桩还要求在 `runtime/` 下有 `agentq-request-tombstones-v2` 标记与 `agentq-durable-move.ps1` 占位、`pueue.exe`/`pueued.exe` 桩——这些是 Windows 分支进入 `doctor` 之前会被触碰的路径。
    - **桩的引号陷阱（本轮唯一的假红来源）**：把成功答案写成 `scheduled_answer='printf ''{"TaskName":…}''\n'` **没有**嵌入引号——bash 里 `''` 是两个空串，拼起来只是删掉引号，于是桩拿到**未加引号**的 JSON，它的 shell 对 `{a,b}` 做花括号展开、把 JSON 拆成两个词，`doctor` 读到 `TaskName:AgentQ Pueuedn`（实测）。同理，resolve 分支的 format 写成未加引号的 `printf %s\n` 时，stub shell 的 quote removal 会吃掉反斜杠、printf 看到的是 `%sn`——JSON 尾部多一个 `n`、丢掉换行，服务端 `jq` 在 `doctor` 之前就报 `Invalid numeric literal`。**修法：成功答案用与 resolve 分支相同的生成器（`printf "  *Get-ScheduledTask*) printf '%%s\\\\n' %s ;;\n" "'$task_json'"`），format 在桩内部一律带引号。** 这是本仓的老类：`printf` 的 format 字符串被外层 shell 的 quote removal 改写。
    - **红证**：把版本块还原成旧三写器形态（`printf 'scheduled_task=' >&2` + 探针 `>&2` + 失败追加告警）的副本喂 `AGENTQ_SMOKE_SERVER` → **3 条失败、rc=1**（`err-stderr` 的「值不对」与「原始诊断」各一、`quiet-fail` 的「告警成值」一）；`ok` 与 `unlaunchable` 在旧形态下本来就通过（JSON 贴 key 行、unlaunchable 在解析处退出），红证只点名真的坏掉的两条。修复后 `smoke/02 → cases=29` 全绿。
    - **边界**：本类证明的是**版本块的写者**在三种探针结局下的行为，不是真实的 `Get-ScheduledTask`（本机没有 Windows 计划任务）。真实 Windows 主机上 `Get-ScheduledTask` 的输出形状（`ConvertTo-Json -Compress` 的字段、本地化）由专用测试机的真远端覆盖，不在本类的范围。同理，`cygpath` 桩只答 server 用到的 `-aw`/`-u` 两形；真实 Git Bash 的其它参数未验证。

    - **怎么找到的**：第五十类收尾前，我在想「边界里那句『Linux 无相应平台可测』站得住吗」。`platform` 就是文件顶部那句 `platform=$(uname -s …)`；`platform_kind` 由它推到 unix，`doctor` 里再按 `$platform` 的 `Linux*` 分支进 `systemctl`/`loginctl` 探针。**提示就在代码里**：探针是 `command … >&2 || true`——和第五十类刚修掉的 `pueue=` 形状**逐字同构**（`|| true` 只压退出码、不压文本）。于是不用真 Linux：`bin/uname` 答 `Linux` 遮蔽、`bin/systemctl`/`bin/loginctl` 同样遮蔽，macOS 上整条 Linux 分支就真实地跑起来了，不碰任何真服务。
    - **实测修复前（macOS，最小 home、不含任何凭据，uname 遮蔽成 Linux）**：`systemctl`/`loginctl` 缺失时，stderr 版本块是 `systemd_user_service=<path>/agentq-server: line 5855: systemctl: command not found`（**与 `pueue=` 完全同一类**——shell 的 exec 诊断漏进机器可读 key=value 行）；工具在但连不上 bus 时是 `systemd_user_service=Failed to connect to bus: No such file or directory`（systemd 自己的诊断同样漏进去）。healthy 形状（stdout `active`/`yes`、退 0）与 inactive-with-stdout 形状（stdout `inactive`/`no`、退 3）当时是干净的——**后者是这条路径与 `pueue=` 的关键差异**，一把它当「非零=无答案」修就会修坏。
    - **修法与第五十类相同，但兜底语义更细**：`systemd_user_service_output=$(systemctl --user is-active agentq-pueued.service 2>/dev/null) || true` + `printf 'systemd_user_service=%s\n' "${systemd_user_service_output:-unavailable}" >&2`（linger 同），`doctor` 里加 `local systemd_user_service_output systemd_linger_output`；注释写明**为什么 `-x` 的形状与 `pueue=` 相同**、**为什么这里非零≠无答案**（`is-active` 把 active/inactive/failed 写 stdout、退 3 是正常「inactive」的退出码；`unavailable` 只留给无 stdout——缺失 / exec 失败 / bus 错误）。
    - **锁（`smoke/02` 21→25）**：`uname` 遮蔽 + 四种 `systemctl`/`loginctl` 形状（healthy `active/yes`、inactive-with-stdout-exit-3 `inactive/no`、bus-error 原始诊断、0755 纯文本 unlaunchable），每条对 `systemd_user_service=` 与 `systemd_linger=` 各断言「**恰好一行** key=value」+「`grep -qxF` 整行恰为期望值」+「stderr 无原始诊断」+「退出码仍在 0–6」。四个形状把两个方向都钉死：有 stdout 答案必须保留（inactive 不能变 unavailable）、无 stdout 必须 unavailable（bus-error/unlaunchable 不能漏原始诊断）。用 `uname`（不是 `shim` 目录名里的别名）遮蔽，是因为**服务端只认 `uname -s` 这一个探子**、改它就能进分支。
    - **红证**：把版本块还原成 `printf 'systemd_user_service=' >&2; systemctl … >&2 || true` 的副本喂 `AGENTQ_SMOKE_SERVER` → **6 条失败、rc=1**（bus-error/unlaunchable 两形状 × 两条 key 的「值不对」与「原始诊断」各一），失败行逐字点名 `Failed to connect to bus` / `command not found`；修复后 `smoke/02 → cases=25` 全绿，且 healthy 与 inactive-with-stdout 两种**「非零但该保留 stdout 答案」**的形状在修复前后都不变（再次确认把非零当无答案会修坏 inactive）。
    - **边界订正**：第五十类把 `scheduled_task=`（Windows）与 `systemd_user_service=`/`systemd_linger=`（Linux）一起记成「同族未修、无平台可测」——**其中 Linux 那半是错的、已修**（本轮）。**Windows 那半当时记为「不可测」也是错的、下一轮（第五十二类）已修**：我当时看到的是「`cygpath` 在 macOS 上缺失，Windows 分支第一句就退 127」（这是真的**实数**），但由此推出「不可测」是错的——`cygpath`/`powershell.exe` 都是 PATH 上按名查找的命令、可遮蔽成桩，`uname -s` 遮蔽已证明是这个分支的唯一探子。把「进入分支要伪造外部输入」当成了「不能测」，其实桩能如实建模被测对象（版本块的写者）在探针失败时的行为。实测（三桩遮蔽）：旧写法把探针诊断与告警漏进 `scheduled_task=` 行，第五十二类已修并锁进 `smoke/02`。
  - **第五十类（2026-10-30）：第四十九类修完客户端，这一轮问「同一个形状在服务端还在吗」——在，而且服务端自己的注释**已经写出了前提**，只是兜底只做了一半。**
    - **怎么找到的**：第四十九类的静态规则用「触发消息 `<NAME> is not executable`」圈定范围，服务端不在其中（它的消息是 `required executable is missing` / `must be a regular file`，且 pueue/pueued 是**安装树里的固定路径**、不是环境变量配置）。**这类「不在规则覆盖里」的地方必须手工问一遍**。问法是读服务端的 `doctor()`：`agentq-server` 里 `doctor` 版本块上方的注释写着 *a binary that exists but cannot execute (corrupt, wrong ABI) must not leak its own status*，并**自己承认** `require_executable checks -x, not runnability` ——也就是说作者知道这个形状存在，只是认为 `|| printf 'unavailable'` 已经处理了。
    - **实测（macOS，最小 home 从零搭、不含任何凭据）**：`|| printf 'unavailable'` 处理的是**退出码**，没有处理**文本**。三种「0755 但 exec 失败」的形状（纯文本 / `#!/nonexistent/interpreter` / shebang 以 CR 结尾）实测 `doctor` 的 stderr 版本块：
      - 纯文本 → `pueue=/tmp/x/pueue: line 1: not: command not found`，然后**下一行**才是 `unavailable`；
      - 坏解释器 → `pueue=./agentq-server: /tmp/x/pueue: /nonexistent/interpreter: bad interpreter: No such file or directory` + 下一行 `unavailable`；
      - CRLF shebang → `pueue=./agentq-server: /tmp/x/pueue: /bin/sh^M: bad interpreter: No such file or directory` + 下一行 `unavailable`。
      两个后果：① `pueue=` 这行本应是**机器可读的 key=value**，实际装的是 shell 原文；② 契约保留给这种情况的值 `unavailable` 被挤到**下一行、丢了 key 前缀**，按 `^pueue=` 解析的调用方拿不到它。同一条缺陷对 `pueued=` 一模一样。
    - **修法：捕获后只打印一次，而不是在原命令末尾打补丁。** `pueue_version_output=$("$pueue_bin" --version 2>/dev/null) || true` + `printf 'pueue=%s\n' "${pueue_version_output:-unavailable}" >&2`（`pueued` 同），并在 `doctor` 里加 `local pueue_version_output pueued_version_output`。**为什么不是只加 `2>/dev/null`**：那个版本能修掉实测的三种形状，但修不掉「探针打印了却退非零」——`A >&2 || printf 'unavailable' >&2` 会把 `unavailable` 挤成**孤儿行**（实测：`pueue=pueue 4.0.4` 之后再来一行光秃秃的 `unavailable`；我先写的就是这个版本，量到孤儿行后才改的）。捕获到变量再 `printf` 一次，**任何**探针结局都恰好一行 `key=value`——这是把**类**修掉，不是把观测到的形状修掉。捕获的是 **stdout**（实测真 `pueue --version` → stdout `pueue 4.0.4`、stderr 空；`pueued --version` 同），所以 `2>/dev/null` 丢掉的恰好只是 shell 的 exec 抱怨。**成功路径逐字节不变**（`od` 对照过两种实现的 good-case 输出，完全相同）。
    - **为什么不是给 `require_executable` 加启动探针**（这是最容易想到的错修法）：它跑在**每一次服务端调用**上（`main` 顶部对 `pueue_bin`/`pueued_bin` 各调一次），而 `status` 是热点路径（`docs/performance.md`）——每次调用多两次 exec 探针不可接受。第四十九类客户端那套「失败点探针」在这里同样成立：`doctor` 的版本行本来就要跑一次二进制并打印结果，多一次 `$( )` 捕获零进程成本。
    - **锁（`smoke/02` +3 例，18→21）**：三种形状 × 两个二进制，每条断言 `pueue=`/`pueued=` 行**恰好等于** `unavailable`（`grep -qxF`，不是子串——子串会在 `pueue=…: line 1: …` 上命中 `unavailable` 的续行吗？不会，但 `-x` 钉的是「整行就是它」这个契约）、stderr 不得出现 `: line N:` / `bad interpreter` / `cannot execute` / `command not found`、退出码仍在 0–6（doctor 可能因无真 daemon 失败，但必须是 2，绝不能是 shell 的 126/127）。**每例跑完立刻恢复可用的 pueue 桩**，避免一个失败级联到后面所有需要 launcher 的用例。
    - **红证**：把版本行还原成 HEAD 形状（`printf 'pueue=' >&2` + `--version >&2 || printf 'unavailable'`）的副本喂 `AGENTQ_SMOKE_SERVER` → **9 条失败、rc=1**（三形状 × 三条断言），失败行逐字点名 `pueue=/tmp/.../pueue: line 1: not: command not found` 与 `bad interpreter`；修复后 `smoke/02 → cases=21` 全绿。**第一次红证是假红**：我把 `AGENTQ_SMOKE_SERVER` 指向了**已修复**的文件，于是「红证」退 0——红证必须指向真的存在缺陷的那份。
    - **边界**：`scheduled_task=`（Windows，`powershell.exe … >&2` 在 `if` 里）与 `systemd_user_service=`/`systemd_linger=`（Linux，`systemctl … >&2 || true`）是**同构的**。本轮只修了实测到的 `pueue=`/`pueued=`。**该轮把 Linux 也记成了「同族未修」，理由是「本机是 macOS、无相应平台可测」——这条理由对 Linux 是错的，下一轮（第五十一类）实测推翻了它**：`platform` 就是一个文件顶部的 `uname -s`，把 `uname` 遮蔽成答 `Linux` 就能让 Linux 分支在本机跑起来，`systemctl`/`loginctl` 用桩遮蔽即可，不碰任何真服务。对照：Windows 分支当时记为「确实进不去」——**这条后来也被推翻**，第五十二类用 `cygpath`/`powershell.exe` 桩（加上 `uname` 遮蔽）进了该分支并实测到同一个泄漏，`scheduled_task=` 已修；`launchd_service=` 那行不受影响（它 `>/dev/null 2>&1` 后自己 printf active/inactive，本就没有子进程答案直通）。

  - **第四十九类（2026-10-30）：第四十八类在 Windows 侧修完了「这个文件起得来吗」，这一轮问同一句在 POSIX 侧成不成立——答案是**不成立：两份 POSIX 客户端资产、三个变量（`AGENTQ_SSH`、`AGENTQ_JQ`、`SSHP_SSH`）都能被同一个形状骗过，而且它们给出的诊断都指错了方向**。**
    - **怎么找到的**：第四十八类给 `sshp.ps1` 补启动探针时，`smoke/12` 的孪生表把「`SSHP_SSH` 指向一个存在的 0644 文件」判成 Windows 独有（POSIX 侧 `is not executable` 本来就对）。这一轮把同一张表反过来问：**POSIX 的守卫是不是也把某个真实误配置放过去了**。`-x` 测的是**搜索位**——它是「允许执行」，不是「能够执行」。第四十一类已经用这个性质解释过**目录**（目录天然带搜索位），但目录不是这个类的全部，只是它的第一个形状。
    - **实测（macOS，`/bin/sh`=bash 3.2 / bash 5 / dash / zsh 各跑一遍，三种 0755 常规文件）**：纯文本文件 → 127/127/127/127；`#!/nonexistent/interpreter` 脚本 → 126/126/127/127；shebang 以 CR 结尾的脚本 → 126/126/127/127。**126 与 127 都要接**，而且**哪一种由 shell 决定、不由文件决定**——这是判据必须接受两个码而不是一个的原因。三种形状都通过 `[ -f ]` 和 `[ -x ]`。
    - **修复前的四种失败（全部实测，不是推断）**：① `sshp`：退 **126/127**（契约外），stderr 是 `remote dependency probe failed for both Unix and Windows shells`——**把本地配置错误报成远端故障**，shell 自己的那行被脱敏成 `class=ssh`。② `agentq` 未设 `AGENTQ_REMOTE_PLATFORM`：退 **127**，报 `unable to detect the remote platform; set AGENTQ_REMOTE_PLATFORM to unix or windows`——**那个变量救不了它**，平台从来不是问题。③ 已设该变量：退 **126/127**、**零 stderr**，`status`/`submit`/`cancel`/`remove` 全部如此。④ `AGENTQ_JQ` 指向 0755 垃圾文件：一个**合法**响应被判成 `invalid JSON response`（把本地配置错误指向服务端），并把 shell 自己的 `line 1: not: command not found` 漏到 stderr。Windows 孪生对同一输入一律退 **2** + `<变量> cannot be launched: <路径>`。
    - **修法：只在一次已经失败的调用上做一次真实启动探针。** `refuse_unlaunchable_ssh_binary` / `refuse_unlaunchable_json_parser` 先看状态码，只有 **126/127** 才继续；再要求变量是**显式设置**的（`PATH` 解析出来的 `ssh` 与孪生一样不探）；然后用 `-V` **跑一次**（ssh 不建连接、jq 打印版本），**只有**探针自己答 126/127 才 `fail "<变量> cannot be launched: <路径>"`（退 2）。任何其它状态码都意味着文件**确实跑起来了**，一律放行。
    - **为什么必须探针，而不是判状态码**：POSIX 没有「exec(2) 会成功吗」的原语。四种廉价判别法逐项实测**全部失效**：EXIT trap 哨兵在 dash 上会跑、在 sh/bash/zsh 上不会；`set -e` 加哨兵无法区分「启动失败」与「合法退 255 的 wrapper」；shell 自己的 exec 诊断无法与子进程的分离，因为重定向在 exec 尝试**之前**生效；纯状态码规则会把**远端**的 126/127 也判成本地。
    - **反向那一半是承重的**：一个**能跑**的 ssh，其远端命令退 127（远端缺 `agentq-server`）必须继续报成远端故障。`smoke/19` 的 `ssh-remote-127` 桩（`-V` 答 0、其余答 127）实测：修复后退 **127** + `remote dependency probe failed`，**不含** `cannot be launched`；只按键状态判的规则会在这里翻车。
    - **落点为什么是「失败点」而不是「解析点」**（这条是设计选型，代价实测过）：解析点探针（在 `resolve_ssh_binary` 里无条件跑一次）让 `smoke/19` 出现 **51** 条失败、`smoke/05` 破了两条锁——因为 `smoke/19` 的桩**按调用序号**回答计划，多一次调用就整体错位。失败点探针在成功路径上零成本、不改变任何 fixture 的调用计划，实测 `smoke/19` 130→134、`smoke/05` 77→93 **全部是新增用例**，没有一条既有用例的行为被改动。
    - **落点为什么还要收进 `run_ssh_logged`**（第一版漏了，实测发现）：四个诊断分支各自补上后，`submit`/`cancel`/`remove` 仍以 **126/127 零 stderr** 退出——它们不经过平台探针，也不经过操作诊断分支。`run_ssh_logged` 是这三类调用**唯一**的漏斗，把拒绝放在它的返回处才一次覆盖；`wait --timeout` 走 `run_wait_ssh_with_timeout`（独立漏斗），所以操作分支那一处也保留。
    - **锁（三层，都是构造级）**：① `smoke/19` +4 例（三种形状 + 反向 127 对照，130→134），断言退 2 + `SSHP_SSH cannot be launched` + **不得**出现 `remote dependency probe failed`；② `smoke/05` +16 例（77→93）：3 形状 × `AGENTQ_SSH`/`AGENTQ_JQ` 两个面 + 反向 127 对照 + **九个操作面**逐个枚举（`status`/`lookup`/`logs`/`wait`/`wait --timeout`/`cancel`/`remove`/`doctor`/`submit`），每个都断言退 2 点名变量——枚举是必需的，第一版只测 `status` 时 `submit`/`cancel`/`remove` 的零 stderr 完全没被发现；③ `smoke/01` 静态规则 `launch_probe`（新）：在**任何**带 `<NAME> is not executable` 守卫消息的 shell 资产里，凡通过 `-x "$VAR"` 且被当作命令调用的变量，必须出现在 `"$VAR" -V` 探针里。摘要行 `launch_probe=0 launch_probe_sites=3`。
    - **静态规则自己踩了三个坑，每个都是实测发现、不是审阅发现**：① 程序最初写成 `$(cat <<'AWK' ... )`，而 bash 的 `$( )` 扫描器**不把 heredoc body 当不透明文本**——它按 shell 词法分析，于是 body 必须看起来「配平」。两个判据都单独量过：未配对的 `)` 报 `syntax error near unexpected token ')'`，而 `"` 的总数是**奇数**时报 `unexpected EOF while looking for matching '"'`——是**奇偶**，不是逐行配平（`x = "1" "2" "3"` 六个引号照样过）。本程序有 45 个引号、`)` 比 `(` 多两个，所以在 `$( )` 里必然崩，而失败会以几百行外某个 `case ... ;;` 的语法错误现形（`bash -n` 在 3133 行报 `unexpected token ';;'`）。改成 `IFS= read -r -d '' ... <<'AWK' || true`（实测 bash 3.2.57 下 body 逐字节保真）。**另外四个程序今天恰好是配平的——那是运气，不是规则。**② 第一版把判定放在 `END` 里，于是 `envguard` 读的是**最后一个文件**的状态——九文件清单里最后一个 `windows-git-bash/agentq` 没有那条触发消息，规则在**真实清单上报 0 站点**，只在单文件测试时碰巧报 2。改成在文件边界冲刷（`FNR==1` 与 `END` 各调一次 `flush()`）。③ 调用识别第一版用一个字符类列「后面能跟什么」，漏掉**续行**形态 `"$ssh_binary" \`——而 `sshp` 与 HEAD 版 `agentq` 的 ssh 调用正是这个写法，规则因此在两个客户端里各漏一个真实站点。改成用 `index()` 判断 `"$var"` 后面那个字符是不是 `]`/`)`/`&`/`|`/`;`（不是就是一次调用），既捞回续行形态，也避开「字符类里要不要转义反斜杠」这个 POSIX awk 各实现有分歧的点（本机只有 BSD awk 可量，Linux CI 是 gawk/mawk）。
    - **修完之后全量套件红了 `smoke/12`，而那次红是本轮的修复造成的——这条要记住。** `smoke/12` 的孪生自检里有一条「把 POSIX 的普通文件守卫改成 `! -e`，要求两侧对目录**不一致**」。启动探针上线后，它成了同一个输入上的**第二道独立守卫**：目录过 `-x` → 客户端真的去跑它 → shell 答 126 → 探针改成 `cannot be launched` 退 2 → 两侧一致，自检的「必须不一致」不再成立。实测：只去掉普通文件守卫 `posix=2 windows=2`；**两道都去掉** `posix=126 windows=2`。这不是自检错了，也不是修复错了——是「一道守卫单独就能盖住这一行」的纵深防御，而变异必须复现**整个**修复前的客户端才有判别力。已把变异改成同时中和探针（`refuse_unlaunchable_ssh_binary() { return 0;`），并加一条 `elif` 断言「探针那一行确实被改到了」，否则变异没发生、自检会静默通过。**教训：加第二道守卫会让别处以第一道守卫为前提的变异失效，全量套件是唯一会告诉你这件事的地方。**
    - **红证（双向，都在真实树上）**：把 `smoke/01` 的新规则指向 HEAD 的 `agentq`/`sshp` → 点名 `$json_parser`、`$ssh_binary`、`$ssh_binary`，`__SITES__3`；用 HEAD worktree 跑整条 `smoke/01` → 退 **1**、三条 `shell FAILED (... launch probe ...)`；把当前资产的 `-V` 探针行删掉（变异回缺陷）→ 规则同样点名三条。自检夹具双向：`zz_unprobed`（有守卫、被调用、无探针）必须报，`zz_probed`（有探针）与 `zz_not_invoked`（有守卫、无调用）必须不报，站点计数必须恰为 2。站点闸门是**下限**（`< 3` 即失败），新增第四个 env 配置的可执行文件应当抬高它，丢守卫的树会在这里红而不是静默通过。
    - **边界**：① 只有**显式设置**的变量探；`PATH` 解析到的 `ssh` 不探（与孪生一致），所以「`PATH` 上的 ssh 是个坏文件」不在覆盖内。② 一个对 `-V` 答 126/127、却在真实调用上正常的 wrapper 会被拒绝——但只在**已经失败**的调用上，且点名变量与路径；真实 OpenSSH 与 jq 都退 0。③ `AGENTQ_ASKPASS` **刻意不探**：实测一个可执行但起不来的 askpass 不产生任何失败（ssh 根本没走到它），而探它等于**执行一个凭据助手**——这是边界，不是遗漏。④ 静态规则只认 `<NAME> is not executable` 这条守卫消息；删掉消息会让规则静默（站点下限就是为这个设的）。⑤ 全部在 macOS 上实测；Linux 上的 dash 矩阵由 `smoke/05` 在 Linux CI job 覆盖，未在本机验证。
  - **第四十八类（2026-10-30）：第四十七类把「上一层的孪生分歧」修完了；这一轮再往上问一层——**同一个类还在别处吗**，答案是：`sshp.ps1` 的 `SSHP_SSH` 从来不问「这个文件起得来吗」，而它的兄弟 `agentq.ps1` 早在 2026-10-21 就问了。**
    - **怎么找到的**：第四十七类修完会话命令后，收尾时用自建的窗口普查给整轮做回归。普查（先自测：开 Calculator 必报 `Calculator=0->1`）在**全量套件**上只报一次窗：`Evernote: 0->1`。追这一条时走错了两次方向（先怀疑 Evernote 自己弹窗——20 分钟空闲对照里 `Evernote=0` 全程不动，排除；再怀疑普查本身——把每个 app 单独测一遍，除了 ego lite 需要辅助访问权限、其余 18 个都答得出来），最后回到「哪个 app 会被**文件关联**拉起来」这条线：实测本机关联表里有 `.md → EME`（第三方 Markdown 应用）、`.txt → TextEdit`、`.ps1/.ps → Notepad`。**这条路没走通就换个问法**：与其猜哪个扩展名，不如问「**还有哪条代码路径会走到 `& '<文件路径>'`**」。
    - **答案是：`sshp.ps1` 的 `Resolve-SshPath` 有 `SSHP_SSH` 分支，却没有任何启动探针。** `grep -n 'ProcessStartInfo\|can be launched' sshp.ps1` 返回**空**，而 `agentq.ps1` 同一函数里有完整的一段（2026-10-21 加的，注释里写着「without this, the exception propagated out of Invoke-SshLogged with NO top-level trap: the client died with exit 1, a stack trace on stderr and no controlled line -- while the POSIX twin refused the same configuration at startup with exit 2」）。**`sshp.ps1` 正是同一个缺陷的第二个实例**，只是那天没被一起改。
    - **实测（macOS pwsh 7.5，`SSHP_SSH=<已存在的 0644 常规文件>`，`--check`）**：Windows 客户端退 **1**、打的是 `remote dependency probe failed for both Unix and Windows shells`——**把本地配置错误报成远端故障**，指错了机器；POSIX 孪生同一输入退 **2**、报 `SSHP_SSH is not executable: <路径>`。而且 `pgrep -x TextEdit` 实测从「不在跑」变成「在跑」——**macOS 的 `& '<存在的非可执行文件>'` 走 LaunchServices 把这个文件打开了**，与第四十七类同一条机制。改回 0644 文件跑的 `agentq.ps1` 对照：退 2、`AGENTQ_SSH cannot be launched`、**不开窗**（`Process.Start` + `UseShellExecute=$false` 走 fork/exec，不问窗口服务器）——所以这条探针本身就是修法，不需要另想办法避窗。
    - **修法：把 `agentq.ps1` 的那段启动探针**（`ProcessStartInfo`、`-V`、stdin 关管道、异步读、10s 上限、catch 里 kill）**逐字搬进 `sshp.ps1` 的 `SSHP_SSH` 分支**，消息改成 `SSHP_SSH cannot be launched: <路径>: <原因>`。**探针的返回值被刻意忽略**——它只回答「起得来吗」，不问 ssh 说什么。
    - **fixture 的选择是量出来的，不是挑的**（这一条是本节最该记住的，因为**第一版选错了**）：最初用**悬空符号链接**（第四十七类在 `smoke/19` 用的那个形态，理由是「没有 target 可打开，红证也不开窗」）。实测**反向**：悬空符号链接被 `sshp.ps1` **自己的** `Test-NonReparseWindowsFilePath` 守卫拒掉（退 2、`not a regular non-reparse file`），**根本走不到启动探针**——于是修复后失败、修复前通过，用例方向反了。逐形态重测（前缀资产 vs 修复后资产）：`0755`+垃圾内容 与 `0755`+坏解释器 **都能判别**（前缀退 1、带 `Exception:` 原始栈；修复后退 2 受控）；`000` 也能判别（前缀退 1，且**不开窗**——`_LSOpenURLsWithCompletionHandler() failed with error -5000`，LaunchServices 拒绝打开不可读文件）；`0644` 判别最清晰（前缀退 1 + `remote dependency probe failed` + **开窗**，修复后退 2 受控）。最终选 **0644**：它是**人真的会造成的**那个误配置，也是兄弟用例的形态。**代价如实披露**：对**修复前**的资产跑红证会开一个窗口（绿证不会——探针在 `&` 之前就拒了）。
    - **锁（`smoke/12` 新增 4 例，140 → 144）**：① fixture 是已存在的 0644 常规文件；② POSIX 侧退 2 + `SSHP_SSH is not executable`（**按 `twin_platform_state` 门控**，与孪生表一致——Git Bash 上 exec 位是挂载选项的产物，本项目不为自己没量过的属性写断言）；③ Windows 侧退 2；④ Windows 侧消息必须是 `SSHP_SSH cannot be launched`；⑤ **另加一条独立的「不得甩锅远端」断言**——因为一个「答 2 但还印着 `remote dependency probe failed`」的客户端修了码没修诊断，而那行文本正是操作员会追到错机器上的东西。
    - **红证**：把 `HEAD` 版 `sshp.ps1` 喂 `AGENTQ_SMOKE_SSHP_PS_CLIENT` → **3 条失败**退 1（`exited 1, expected 2`、`lacked the controlled message: sshp.ps1: remote dependency probe failed…`、`was reported as a REMOTE failure`）；第 4 条（POSIX 侧）在红证里**照常通过**——POSIX 客户端本来就答得对，这正是「孪生分歧」而不是「两边都错」的证据。**该 run 的输出里没有出现任何别的检查项**（本检查只在失败时点名，摘要行仅在全绿时打印），所以这三条来自新块，不是别处连带。
    - **边界**：`sshp.ps1` 与 `agentq.ps1` 现在**都有**探针，但仍是**两份各自内嵌的实现**（这一段是复制过去的，不是共享的）——将来一处改了另一处不会自动跟，检测靠 `smoke/12` 的两条用例（它们各自独立断言，不是互比）。探针在**真 Windows** 上的行为未实测（本机 pwsh 7.5 + macOS）；Windows 无 LaunchServices，所以「开窗」这一面在目标平台上不存在，那一面只对 macOS 上的测试主机成立。全量套件那次 `Evernote: 0->1` **未能归因**——它不在 `smoke/12`（该检查单独跑、用 0.4s 轮询全程无窗口变化，本轮又复测一次），20 分钟空闲对照里 Evernote 也不动；记在这里是**未解观察**，不是已归因的发现。**同一天晚些时候、用同一个自检过的检测器重跑全量套件（修复落地后的最终 run）：`NO WINDOW ROSE ABOVE BASELINE`，Evernote 基线 0、全程 0——那一次没有复现。** 两次对照给出的结论只能是「读到过一次、没能复现」，不是「已排除」：两次跑的是**不同的树**（第二次含本轮修复），而且窗口计数这类观测天生带噪声。

  - **第四十七类（2026-10-29）：POSIX `sshp` 的 Windows 会话把 `exec zellij attach --create '<名字>'` 写进 pty 交给远端 `DefaultShell` 解析——它假定那是 Git Bash，且假定 `zellij` 在 PATH 上，而探针刚刚为了绕开陈旧 PATH 才解析出绝对路径。**
    - **怎么找到的**：第四十五/四十六类比的都是两份客户端**内嵌的脚本体**。再下一层没比过的是**会话命令本身**——`smoke/19` 的头部当时明确写着「POSIX 客户端的 Windows 会话命令是 `exec zellij attach --create` 的裸名（checked, not assumed）」，把它当成已知事实记下来了，没有问它对不对。这一轮问了。
    - **两个独立的缺陷，方向不同、都落在本仓实测过的配置上**：① **`exec` 是 POSIX 内建**。`SKILL.md` 记着 `DefaultShell` 有三种（`cmd.exe` / `powershell.exe` / Git Bash，三列都有真机实测），而 `cmd.exe` 是 OpenSSH 未设置该键时的**默认**。实测（pwsh 7.5）：`exec zellij attach --create 'g'` 在 PowerShell 里落到 `Switch-Process` 并报错；`cmd.exe` 根本没有这条命令。Windows 客户端发的是 `powershell.exe … -EncodedCommand`，三种 shell 都能跑。② **裸名字是 PATH 查找**，而同一文件里探针的注释写着它用原生 PowerShell「avoids stale SSH-server PATH values after WinGet, Scoop, or Chocolatey installs」——**客户端自己的安装流程正好制造这个状态**：winget 装完 → 重新探针（PowerShell 走解析器的绝对路径）→ READY → 会话用裸名在 Git Bash 的陈旧 PATH 里找不到。实测：zellij 只在解析器给出的绝对路径上时，`exec zellij …` → `sh: line 0: exec: zellij: not found`；`exec '<绝对路径>' …` → 正常启动。而 `--check` 在同一台机上刚刚打印过 `persistent remote session: Zellij (Windows)`。
    - **修法：让 POSIX 侧发出与孪生逐字节相同的命令，而不是「把裸名换成绝对路径」**。路径必须经 base64 传输才不会被任何 `DefaultShell` 的解析器咬到（`-Command` 会把单引号放回命令行，那是 `cmd.exe` 要解析的），所以两侧都是 `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand <UTF-16LE base64>`，作为 **ssh 的远端命令**发送（不是写进 pty 的一行）。POSIX 侧为此要读探针报回的 `__SSHP_ZELLIJ__`（第四十六类刚让两个 body 都发这一行），并按孪生的三条守卫拒绝（引号/换行、控制字符、>1024）。`--check` 之后才构造，所以只读探针不新增 `iconv`/`base64` 依赖。**顺带删掉的是 FIFO**：`mkfifo`、feeder 进程、`windows_input_pid` 的会话用途全部消失（`run_windows_remote_command` 的交互分支是死代码，未动）。
    - **实测方法**：先用桩 ssh 驱动真实客户端，捕获第 3 次调用的 argv，把 payload 解码回 UTF-8 与手写期望串比较；再把 `Get-WindowsSessionCommand` 从 `sshp.ps1` 里**按花括号深度**抽出（行窗口做不到——函数里有 here-string 与注释，smoke/10 规则 J 早就记过「near is not inside」），加三行 shim 后由 pwsh 真跑，同一路径/会话名下的产物必须**逐字节相同**。两侧对同一恶意路径也必须给出同一条拒绝消息。
    - **锁（`smoke/19` 新增 30 例，74 → 104）**：① 桩新增 `@file` 作答形态（就绪应答是两行，而计划格式是一行一次调用；`@` 开头不可能与既有计划冲突，也**不用** `printf '%b'`——那会重解释 Windows 路径里的反斜杠）。② **绝对判据**：解码出的脚本必须等于按固定路径/会话名手写的期望串——只做两客户端互比，两边一起漂也会绿。③ happy path 三条（退出码 / 3 次 ssh 调用 / 第三条 argv 是编码命令）。④ 四个拒绝各三条（退出 2、消息是孪生的**原文**、探测之后**零调用**——发出去再拒等于没拒）。⑤ `--check` 在**没有** `__SSHP_ZELLIJ__` 的应答上仍须退 0 且不构造命令（它必须保持只读、不依赖 `iconv`）。⑥ 长度上界**从 `sshp.ps1` 读出来**与本地常量比对（复述的常数会漂，这是 smoke/14 站点 9 用变异教过的）。⑦ 差分两条 + 两条「比了个寂寞」的闸门（产物为空、twin 没跑起来）。⑧ 自检：裸名探测器先喂**手写**裸名载荷（必须命中）与合法绝对路径（必须不命中）——这一半不依赖被测资产，所以在**修复前**的副本上也会跑；再把资产副本改回裸名，要求探测器拒绝客户端**实际发出**的东西。
    - **红证（两个方向）**：HEAD 副本喂 `AGENTQ_SMOKE_CLIENT` → **20 条失败**退 1（happy path 四条、四个拒绝各三条、长度上界、差分、自检）；把载荷退回裸名但保留新结构 → **5 条失败**退 1，其中一条点名 `the payload invokes Zellij by BARE NAME instead of an absolute path`。修复后 `smoke/19 cases=104 … windows-session=compared` 退 0（**这是本节修法完成时的中间态**；同轮收尾自查又加 26 例，最终 130 例，见下面「单位矩阵」那条）。
    - **边界**：**会话的运行时从未在真机上验证过**——这一轮改的是**构造**，验的也是构造。三种 `DefaultShell` 是否各自接受这条命令行、`-tt` 下 Zellij 能否接住 tty，都需要真机会话；与 0.1.16 那条「两段式会话没有真机证据」是同一条边界，不是新的。差分只在 pwsh 可用时跑（沿用本检查既有的三态闸门：`skipped(pwsh-absent)` 进 PART，起不来则点名环境故障并计一次失败）。`smoke/19` 的桩仍然不是 ssh：它证明客户端**发出什么**，不证明真 sshd 拿它做什么。
    - **同轮收尾时自查出的第二个缺陷（未提交，未出仓）：上界的「单位」错了——`${#windows_zellij_path}` 不是孪生的那个数。**孪生是 `.NET String.Length -gt 1024`，即 **UTF-16 码元**；`${#var}` 是**字节数**（dash 恒为字节；bash/zsh 在 UTF-8 locale 下是**码点**，在 C locale 下是字节）。同一个路径因此有三个答案：实测一条 1220 字节 / 420 码元的 CJK 路径，bash+UTF-8 数出 **420**（接受）、bash+`LC_ALL=C` 与 dash 数出 **1220**（拒绝），而孪生**接受**——**同一台机器上 bash 和 dash 对同一条路径给出相反的判决**；600 个 emoji（620 码点 / 1220 码元）方向相反，码点计数会**接受孪生拒绝的**路径。也就是说这条上界在 Debian/Ubuntu（`/bin/sh` 是 dash）与 macOS（`#!/bin/sh` 是 bash 3.2）上根本不是同一条。修法：数 UTF-16LE 字节再折半（`iconv -f UTF-8 -t UTF-16LE | wc -c` ÷ 2）——与 `.Length` 同一个数，也正是命令行实际花掉的单位（载荷是 UTF-16LE 的 base64，每码元两字节）。**实测独立判据**：把 `Get-WindowsSessionCommand` 按花括号深度抽出、由 pwsh 真跑，两条 fixture 上两侧判决一致（420 码元两边都接受且产物**逐字节相同**，1362 字符；1220 码元两边都退 2 且**同一条消息**）。边界也钉住了：正好 1024 接受、1025 拒绝，与 `.Length -gt 1024` 逐点对齐。
    - **同轮自查出的第三个：`iconv … >/dev/null` 不能当合法性探针。**第一版用它验路径可转换，实测在 macOS 上 **`ENOTTY`（`Inappropriate ioctl for device`）**——转换输出够大就失败（340 个 CJK 字节数正常、360 个失败；字节数翻倍的纯 ASCII 反而正常），于是一条**完全合法**的长路径被报成非法。改成往返判据（UTF-8→UTF-16LE→UTF-8 必须等于原值），与载荷那条检查同一形状：截断的转换无法往返，而 `wc -c` 在失败的管道上会数到一个**前缀**——那是**低估**，只会放过超长路径，且事先已经有一行裸 `iconv:` 打到用户终端上。
    - **这三条给出的锁：`smoke/19` 加「单位矩阵」**（104 → 130 例）。两个 fixture 按构造区分三种单位（400 个 CJK = 420 码元 ≤ 1024 但 1220 字节；600 个 emoji = 620 码点但 1220 码元），期望判决由 `iconv` **独立**算出来，然后在 **shell × locale 矩阵**上各跑一遍真实客户端（`/bin/sh`、bash、dash、zsh × C 与一个 UTF-8 locale），每格两条断言（可接受的必须退 0 且载荷里原样带着该路径；必须拒绝的必须退 2）。**每格的实际单位是量出来的、不是按标签假定的**（实测：本机不存在的 locale 名会**静默退化到 C**，写死 `en_US.UTF-8` 的格子可能其实在数字节却在报告里自称码点），所以 UTF-8 locale 是**挑出来的**（`C.UTF-8`/`en_US.UTF-8`/`en_US.utf8` 里第一个真有 shell 按码点计的，且逐个 shell 试——Debian 上 `/bin/sh` 是 dash、任何 locale 下都数字节，只用它探测会在能用 bash 的机器上误判「本机没有 UTF-8 locale」），摘要行报 `units:bytes chars`，某一半没覆盖到就**出声说明**而不是沉默通过。另加两条构造级静态锁（只读**代码行**——资产注释里就写着 `${#...}` 为什么错，按全文匹配会把正确的资产报成坏的，正是 smoke/16 那条自掩蔽检测器教过的类）：不得再用 `${#windows_zellij_path}`，且必须仍走 `iconv -f UTF-8 -t UTF-16LE | wc -c`。
    - **红证**：把资产副本的上界换回 `${#windows_zellij_path}` → **13 条矩阵失败**（8 格 × 1~2 条，附退出码与哪一侧的判决）＋ 两条静态锁各 1 条，共 **15 条失败**退 1；`git show HEAD:` 的同一份资产 → **36 条失败**退 1。修复后 `smoke/19 cases=130 … windows-units=matrix(sh+C sh+utf8 bash+C bash+utf8 dash+C dash+utf8 zsh+C zsh+utf8 units:bytes chars)` 退 0（91s）。
    - **更早那两条「先证能红」的红证（HEAD 与裸名变异体）在下面「红证」里记着**，本轮重测的数字变了：HEAD 副本 → **36 条失败**退 1（多出的 16 条是这一节新增的矩阵与静态锁），裸名变异体 → **13 条失败**退 1（原先 5 条；多出的 8 条是矩阵的「载荷必须原样带着多字节路径」——裸名同样不带着它）。
    - **本节的边界（新增）**：① 上界只在**长度**上对齐，`smoke/14` 站点 9 的 3646 字符是按 **1024 的容量**算的；**会话名没有长度上界**（两侧都只有字符集守卫），实测 4000 字符的会话名会让命令行长到 10986 字符、远超 powershell.exe 的 8125 截断上限——**两侧同形**，所以不是孪生分歧，是一条共享的边界，本轮**未修**（记在这里，不是待办清单——`docs/PLAN.md` 才是）。**（2026-11-05 已修：第七十一类给它补了 1024 上界，两侧同一常量；此句保留为当时的判断，不再是现状。）**② 单位矩阵只在**本机**跑；某个远端 shell 单位不同这件事不在覆盖内。
    - **同轮自查出的第四个（用户先报的）：`smoke/19` 的 `cannot-start` fixture 每跑一次，macOS 就弹一个 GUI 窗口。**用户报告「跑测试会乱打开文件」，并附截图显示 Dock 里出现 **Parallels Desktop**。第一版按「文件关联」去查，实测把这个方向钉死了：本机 `open` 的关联是——**无扩展名 → TextEdit、`.exe` → Parallels Desktop、`.dat` → IINA**。扩展名只是**选哪个 app 去打开**，不是「会不会被打开」；第一版把 fixture 从无扩展名改成 `.exe`，用只数 TextEdit 窗口的检测器量出 `0→0` 就以为修好了，**而它只是把 TextEdit 换成了 Parallels**——用户的截图正是这一步的产物（检测器只问一个 app，就是「比了个寂寞」）。
    - **机制**：测试主机上 `& '<path>'` 对**存在的、非可执行**的文件不失败——它走 macOS LaunchServices，用关联的 app **打开**这个文件。这是**测试主机**的属性，不是被测代码的：真 Windows 目标在 CreateProcess 里失败，从不问 LaunchServices。这一行要的是「失败且 `$LASTEXITCODE` 未被设置」，而 LaunchServices 路径反而**装作成功**。
    - **实测（前台 app 追踪，不是进程计数）**：正常跑一次 `smoke/19`，前台 app 在 TextEdit 与 `prl_client_app` 之间来回 **13 次**，而检查依旧 `cases=130` 退 0——**绿着开窗**。逐形态测（真安装 body，fixed vs 轮46 前缀 body）：0644 常规文件（任意扩展）→ **开窗**；`0755` + 坏解释器 / 目录 / 不存在路径 → **终止性**错误，守卫根本没跑（前缀 body 也退 1，行失去判别力）；`000` → 仍调 LaunchServices（失败）；**悬空符号链接 → 完全不碰 LaunchServices**（`The file … does not exist`，非终止错误、`$LASTEXITCODE` 未设置，fixed=1 / 前缀=0，判别力保留）。
    - **修法：fixture 改成悬空符号链接**（指向一个不存在的 target）。理由不是「这个扩展名安全」，而是**没有 target 可打开**——任何机器的任何关联都够不到它。守卫改成双向：真判据 `[ -L "$1" ] && [ ! -e "$1" ]`，一条断言 fixture 必须满足它，**另一条拿一个常规文件喂同一个判据要求它拒绝**（判据恒真的话这一半先红——变异 C 实测正是 `launch-safety guard accepted a regular file`）。
    - **红证**：把 fixture 换回 0644 常规文件 → 守卫点名 `is not a dangling symlink` 退 1（变异 B；该 run 同时禁用了矩阵行，避免为了取证再开窗）；判据改成 `return 0` → 自检那条先红（变异 C）。绿证：一次完整 `smoke/19` 前后**全进程窗口普查逐字相同**（`TextEdit=5;prl_client_app=2;…` 不变），对照修复前同一检测器在运行中看到 13 次前台切换。
    - **边界**：悬空符号链接在 Git Bash/Windows 上不可移植（`ln -s` 会失败或需要开发者模式），但这个 fixture 只在 `pwsh` 可用时构造，而 `smoke/19` 在 windows CI job 里**不跑**（该 job 只跑 12/13/20/22/23/25）；Linux CI 的 `ln -s` 行为与 macOS 相同（实测 Linux pwsh 7 上同一 fixture 仍是「No such file or directory」、无窗口、stderr 不含 `Write-Error:`/`Exception:`）。「已有文件被 macOS 打开」这个类**只在这一处**修了；`smoke/12` 的 `unlaunchable`（0644、无扩展名、交给 PS 客户端）**实测不开窗，而且原因是代码级的、不是量出来的巧合**：Windows 客户端的启动守卫走 `[System.Diagnostics.ProcessStartInfo]` 且 `UseShellExecute = $false`，实测对同一个 0644 常规文件**抛 `Permission denied`**（本机 pwsh 7.5，`agentq.ps1:679-693`），而 LaunchServices 只在**调用运算符 `&`** 的路径上被问到——`smoke/19` 的 Windows 目标 body 正是 `& $installer.Path …`，`smoke/12` 不是。窗口计数也做了两遍：0.4s 轮询贯穿整次运行，**没有任何 app 的窗口数超过基线**（`IINA=1` 自始至终），运行前后全进程普查逐字相同。**但同一台机上粗糙的前后两次快照普查曾对 `smoke/12` 报过一次 `WINDOW-OPENED`——那是两次取样的间隙里无关桌面活动造成的假阳**，由更细的轮询判掉；记下来是因为「粗检测器报红」和「真的开窗」在这一轮都出现过，先例与本轮 `smoke/19` 的 `.exe` 误修同型（检测器问得越窄越容易撒谎）。`smoke/05` 的 `askpass-noexec`（0600）从未被执行——同样没有开窗行为。
  - **第四十六类（2026-10-28）：两份 `sshp` 客户端内嵌的「Windows 目标」脚本是三个不同的程序，且没有任何检查执行过它们——失败被报成成功、拒绝被报成崩溃、探针还少一行。**
    - **怎么找到的**：第四十五类统一了「Unix 目标」那一对 body。同一份资产里还有第二对：`windows_common_script`（POSIX）与 `Get-WindowsZellijResolverScript`（PS）是同一段解析器前奏，`windows_probe_script`/`windows_install_script`（POSIX）与 `Get-WindowsProbeCommand`/`Get-WindowsInstallCommand` 的 here-string（PS）各自把解析器拼在前面。先问「谁执行过这三个 body」——答案仍是**没有**；`smoke/14` 只量长度，`smoke/20` 只验编码，第四十五类的矩阵喂的是 Unix 目标那一对。抽取本身也需要新工具：POSIX 侧两个尾段不是 `<var>='` 而是 `$windows_common_script'` 连接式，Windows 侧两个尾段开在 `-ScriptText ($resolver + @'` 里，第四十五类的两个抽取器都够不到。
    - **实测方法**：把三个部件从两份资产里原样抽出（修复前字节数：解析器 **8105 / 8097**、探针尾 **580 / 637**、安装尾 **736 / 1073**），再把两个安装尾从**两条客户端真正使用的通道**喂进 `pwsh -NoProfile -NonInteractive -Command -`——前两行 `$ProgressPreference`/`$env:MSYS_NO_PATHCONV`、脚本、**尾部空行**——解析器用桩替换（它要 `WindowsIdentity`、`Get-Acl` 与 profile 注册表键，非 Windows 主机根本跑不了）。
    - **三类分歧，方向各不相同**：① **拒绝被报成崩溃**。无可用安装器：POSIX `127` + 一行 `sshp: no supported Windows installer found for Zellij.`；Windows **`1`** + 一整块 `Write-Error: Line | 16 | …`。`$ErrorActionPreference = "Stop"` 让 `Write-Error` **抛异常**，所以下面那句 `exit 127` 是**死代码**——这正是 `agentq-start-daemon.ps1:203` 在 2026-10-07 修过的类，而这里还留着 skill/assets 里**最后一处活的 Write-Error**。不支持的安装器种类同形（Windows 用 `throw`，退 1 + `Exception:` 块）。② **失败被报成成功**。安装器**存在但起不来**（AV／策略拦下 CreateProcess，实测 2026-10-17；本机用 0644 脚本与 `.ps1` 两种 fixture 复现同一状态：调用返回、记录一条非终止错误、`$LASTEXITCODE` 从未被设置）：Windows 走 `Get-Variable` 守卫退 **1**，POSIX 走 `exit $LASTEXITCODE`——变量未设时 `exit $null`，退 **0**。这是本轮唯一一处「静默地把失败报成成功」。③ **探针少一行**。就绪应答里 Windows 侧发 `__SSHP_READY__:Windows` + `` `n__SSHP_ZELLIJ__:<路径>``，POSIX 侧只发前者。**影响面是核过的，不是推的**：POSIX 客户端的 Windows 会话命令是 `exec zellij attach --create`（裸名，第 1050 行），从不读这一行，所以对**它**惰性；读它的是 Windows 客户端——`(?m)^__SSHP_ZELLIJ__:(.+)$` 解析进 `$script:ResolvedZellijPath`，会话命令是 `& '<路径>' attach --create`（第 1017/1223 行），所以一个停止发这一行的 body 只会打断**那一侧**，而两侧文本本该相同。解析器另有一处纯风格分歧（`New-Object "System.Collections.Generic.List[string]"` vs `[…]::new()`，pwsh 7.5 实测两者等价）。
    - **修法：取两侧各自正确的那一半，而不是「拿一个覆盖另一个」。** 两处拒绝分支取 POSIX 形态（`[Console]::Error.WriteLine` 不是异常，`exit 127` 能活到执行）；尾段取 Windows 形态（fail-closed 的 `Get-Variable` 守卫）；探针补上 `__SSHP_ZELLIJ__`（对 POSIX 侧惰性——它的 `probe_reports_marker` 是行锚定的，多一行不影响，且 `probe_output` 不会被打出来）；构造器统一到 `::new()`（仓内主流写法，且 Windows 客户端在真机 5.1 上早就这么用）。
    - **锁：`smoke/19` 新增一节，与第四十五类同形但多了三件事。** ① **三个抽取器守卫用内容哨兵**，不是长度：第四十五类用 `set -eu` 开头，这里三段文本没有共同的起始行，所以每段各查一个独有标记（`function Resolve-RemoteInstaller {` / `__SSHP_READY__:Windows` / `switch ($installer.Kind) {`）——空 body 与**抽错函数的非空 body** 都能挡住。② **三对逐字节 `cmp`**。③ **执行矩阵**：安装 8 行（zellij 已在、无安装器、不支持的 kind、安装器退 5、退 0、调用没设退出码、起不来、路径不存在）× 2 body，探针 3 行（ready / install-required / unavailable）× 2 body，**每行对两个 body 各自断言绝对期望**，并额外断言 stderr **不含** `Write-Error`/`Exception:`——只断言退出码会放过「把变异体退回 1 但消息仍是崩溃块」的形态。④ **两条自检**：把 `Write-Error` 放回去要求 `no-installer` 行不再是 127；把尾段换成裸 `exit $LASTEXITCODE` 要求 `call-sets-no-exit-code` 行不再是 1。两条都先验证变异**确实生效**（`cmp` 不等），否则报「mutation did not apply」。
    - **pwsh 三态**：抽取与三对 `cmp` **不需要** PowerShell，永远跑；矩阵需要，所以按 `smoke/01` 的规矩分三档——`AGENTQ_SMOKE_PWSH` 未设且 PATH 上没有 → `windows-matrix=skipped(pwsh-absent)`（进 PART，不谎称跑过）；在 PATH 上但起不来（启动缓存损坏，本仓实测过五次）→ 点名**环境故障**并计一次失败，绝不报成资产缺陷；可用 → 跑矩阵并报 `N/N`。
    - **红证（先证能红）**：HEAD 的两份副本分别喂 `AGENTQ_SMOKE_CLIENT` 与 `AGENTQ_SMOKE_SSHP_PS_CLIENT` → **9 条失败**退 1：三对 `DIFFERENT … scripts`（各带 `diff -u`）、`no-installer` 行点名 Windows 侧 `status 1, expected 127` 且 stderr 含 `Write-Error`、`unsupported-kind` 行点名 `Exception:`、`call-sets-no-exit-code` 与 `cannot-start` 行点名 POSIX 侧 `status 0, expected 1`、探针 `ready` 行点名 POSIX 缺 `__SSHP_ZELLIJ__:<路径>`。修复后 `smoke/19 cases=74 … windows-scripts=identical(3/3) windows-matrix=11/11` 退 0。
    - **`smoke/22` 的第二个锁：规则的根按树推导，而不是按文件名枚举。** 本轮同时发现 `bare_last_exitcode_lines` 与 `assert_last_exitcode_guard` 的根是**五个手写的 `.ps1`**，而 POSIX 客户端在 here-string 里内嵌了同一段 fail-closed 守卫——HEAD 上那份文件第 **824** 行正是一个裸 `exit $LASTEXITCODE`，即这条规则存在的**全部理由**，落在一个它从未读过的资产里（实测：扫描器报 `client/unix/sshp:824`）。改法不是「把第六个名字加进列表」（下一个资产还是同一个洞），而是：根由 `grep -rli` **在 `skill/assets` 上推导**——凡带 `$x = Get-Variable -Name LASTEXITCODE` 赋值的资产都必须在上面那条调用里出现，否则点名要求补上它真正的 token；再加一次**全域裸读扫描**（`find skill/assets -type f`，覆盖「有裸读、没有守卫」的 HEAD 形态，那不是守卫推导能看见的）。两条都在临时 fixture 上自检：推导函数必须恰好报出「未点名的那个」、跳过注释行；裸读扫描必须恰好报出 `bare.ps1:1`、不报两个带守卫的和那个注释掉的。红证：HEAD 的 POSIX 副本喂 `AGENTQ_SMOKE_POSIX_SSHP_CLIENT` → `line(s) 824` + 守卫不 fail-closed，2 条失败退 1。修复后 `smoke/22 cases=87 lastexitcode-guards=12` 退 0。
    - **边界**：① 解析器前奏**只比字节、不执行**——它要 `WindowsIdentity`/`Get-Acl`/HKLM，非 Windows 主机跑不了（与 `smoke/22` 的 `windows-api=NOT-covered(needs-Windows)` 同一类，未在本检查里再加标记，因为这里它是被 `cmp` 覆盖的，不是被跳过的）。② 矩阵里「起不来」用的是 0644 脚本与 `.ps1` 两种 fixture，它们复现的是**状态**（调用返回、`$LASTEXITCODE` 未设），不是 Windows AV 的机制本身。③ 三份文本现在逐字节相同，但仍各自内嵌（检测漂移，不是消除重复）——与第四十五类同一条边界。④ `write-probe` 的 stderr 断言是 PowerShell **渲染文本**（`Write-Error:`/`Exception:` 前缀），在 PS 5.1 上渲染格式不同；矩阵只在 pwsh 上跑，5.1 侧由 `smoke/22` 的静态规则兜住。
  - **第四十五类（2026-10-28）：两份 `sshp` 客户端内嵌的远端依赖探针和安装脚本从未被执行过——同一个目标，POSIX 客户端说「去装 tmux」、Windows 客户端直接连上去；另一类目标上两者又把「可安装」和「没救」对调。**
    - **怎么找到的**：第四十四类把「同一 argv 喂两份」推到了 `agentq` 的远端命令。`sshp` 这一对还有两层没被比过：退出码表（第四十三类已补）和**两个客户端各自内嵌的远端脚本体**。先问「谁执行过这两个 body」——`grep` 遍历 29 个检查：`smoke/14` 只量它们的**长度**（base64 后的命令行字符数），`smoke/20` 只验证 Windows 侧的**编码**（base64 往返后仍是单个 argv），`smoke/19` 的 `plan_stub` 喂给 POSIX 客户端的全是**预先写好的 marker**——`grep -n 'uname' smoke/*.sh` 只命中 `smoke/05` 自己的桩。**没有任何一处真正运行过这两个脚本。**
    - **实测方法**：把四个 body（探针 ×2、安装 ×2）从两份资产里原样抽出，在只含一个「撒谎的 `uname`」和指定工具的 PATH 上执行。**PATH 必须收窄到假目录**：第一版把假目录前置到真实 PATH，宿主自己的 `/usr/bin/screen` 替「什么都没装」的行回答了 `command -v`，于是每一行都报 READY——这本身就是一次「桩没照抄现实」的假绿；`/bin/sh` 要用绝对路径（PATH 收窄后裸 `sh` 也解析不到，第一版因此每行都退 127）。
    - **两类分歧（都是真缺陷，方向相反）**：① **平台门在就绪判断之前**。POSIX 探针先按 `case "$platform" in Darwin*|Linux*) ;; *) 拒绝` 过滤，之后才检查多路复用器；Windows 探针没有这道门。实测 `FreeBSD + tmux` → POSIX `127 __SSHP_INSTALL_UNAVAILABLE__`（用户被告知「去装 tmux」，而该机**已经装有 tmux**）、Windows `0 __SSHP_READY__`；`SunOS + tmux`、`unknown + tmux` 同形。**客户端级**：`sshp <freebsd-host>` POSIX 退 127、Windows 正常进会话。会话命令本身是 `exec tmux new-session -A -s '<name>'` 这样的可移植 shell，**不需要**任何平台知识，所以这道门是纯粹的假阴性。② **候选安装器按平台分桶**。Windows 探针的 `case` 只给 Darwin 列 brew/port、给 Linux 列 apt..apk；POSIX 探针是**扁平**列表。而两份客户端的**安装** body 都是扁平的 apt/dnf/yum/pacman/zypper/apk/brew/port。实测 `Linux + 只有 Homebrew` → POSIX `42 __SSHP_INSTALL_REQUIRED__`、Windows `127 __SSHP_INSTALL_UNAVAILABLE__`；**客户端级**：POSIX 退 1（询问是否安装后因无 tty 拒绝）、Windows 退 127 并让用户自己去装。也就是 Windows 探针**拒绝了一台它自己的安装器本来就能装好的机器**。
    - **修法**：把两个 body 各自统一成**同一份文本**。就绪判断移到最前（有 tmux/screen/zellij 就 READY，不看 `uname`），候选列表改成扁平、与安装 body 的列表**同序相同**；MINGW 分支保持最先（`__SSHP_WINDOWS_SHELL__` + 43），`package_label`/分桶 `case` 一并删除。删除是等价的，且这一点是逐分支核对过的：旧 body 里那个 `case` 的 `MINGW*` 臂（`package_label=zellij` + winget/scoop/choco）**不可达**——同一个函数体上方已经有一个 `case` 在 `MINGW*|MSYS*|CYGWIN*` 上 `exit 43`，Windows 目标根本走不到这里（winget/scoop/choco 三条也从未被执行过）；`Darwin*`/`Linux*` 之外的任何平台在旧 body 里本来就得到空 `installer`，安装 body 的差异（POSIX 有 `run_as_root` 的 sudo 缺失消息和收尾行、Windows 是压缩版且静默退 127）也一并对齐到 POSIX 的完整形态。
    - **为什么不是「加一道门到 Windows 侧」**：那道门唯一的产物是拒绝一台**已经有依赖**的机器，且给出的建议（装 tmux）在该机上是错的。判据不是「平台白名单谁更严」，而是「会话命令需要什么」——它只需要一个多路复用器。
    - **锁**：`smoke/19` 新增一节，四件事。① **抽取守卫**：四个 body 都必须以 `set -eu` 开头，抽到空文件即报错——两个空 body 相等，是本仓反复踩的假绿形状。② **逐字节相等**：探针一对、安装一对各一条 `cmp`，不等就打印 `diff -u`。③ **执行矩阵**：探针 8 行（Linux/Darwin/FreeBSD × 有无 tmux、Linux+brew、Darwin+port、MINGW）、安装 5 行（apt-get/brew/port 的真 argv 轨迹、`pkg` 无候选、空 PATH），每行对**两个 body 各自**断言绝对期望（只问「两边是否一致」会放过两边一起漂）；安装行比的是**会运行什么命令**（假安装器把 argv 写进 trace），不是退出码。行数下界 8/5。④ **自检**：把平台门重新插回探针副本，要求 `FreeBSD+tmux` 行必须报错（锚点找不到时点名「mutation did not apply」，而不是静默通过）。
    - **红证（先证能红，双向）**：预修复形态的 POSIX 副本喂 `AGENTQ_SMOKE_CLIENT` → 报 `clients embed DIFFERENT dependency probes`（附 diff）+ `probe matrix [FreeBSD tools=tmux]` 行两侧对调，退 1；预修复形态的 Windows 副本喂 `AGENTQ_SMOKE_SSHP_PS_CLIENT` → 同样两条，其中矩阵行是 `Linux tools=brew`，退 1。**另外两个方向各一**：只把候选列表改回分桶（保留平台门的删除）的 POSIX 副本 → `Linux tools=brew` 与 `Darwin tools=port` 两行同时点名，退 1（证明矩阵不只钉平台门）；把探针表删掉一行的检查副本 → 下界点名「shrank to 7 probe row(s)」，退 1（证明下界不是摆设——删行时「跑的行数」与「表声明的行数」一起变，等值闸门看不见，只有下界能抓）。修复后 `smoke/19 cases=53 … remote-scripts=identical(2/2) matrix=13/13` 退 0。
    - **边界**：两个 body 现在逐字节相同，但仍各自内嵌两份副本（`agents/openai.yaml` 之外没有共享机制）；本节的锁是**检测**漂移，不是消除重复。矩阵里的平台名是 fixture 文本，覆盖的是「探测脚本读到某个 `uname -s` 时怎么答」，不是真在 FreeBSD 上跑过 `sshp`——**没有任何一个非 Linux/macOS/Windows 的远端被实测过**。Windows 目标的 `sshp` 会话路径不经过这两个 body（走 `__SSHP_WINDOWS_SHELL__` 就转 PowerShell），所以本节不覆盖它。
  - **第四十四类（2026-10-28）：两份客户端给同一个 argv 构建的**远端命令**从未被比过——Windows 客户端的 unix 远端命令里没有 `AGENTQ_WAIT_BUDGET` 机制，每次 `wait --timeout` 预算耗尽都在目标机上留一个孤儿 `agentq-server wait`（带一个 `pueue wait --quiet` 子进程），而 POSIX 孪生留 0。**
    - **怎么找到的**：第四十三类之后把「同一 argv 喂两份」从退出码推到**远端命令本身**。先证明缺口存在：`grep` 遍历 29 个检查，没有任何一处把两份客户端发出的远端命令放在一起比过——`smoke/05` 钉 POSIX 侧（对着从 POSIX 侧抄下来的期望）、`smoke/20` 钉 Windows 侧的 base64 通道形状，各自内部自洽，互不相见。手工差分（桩 ssh 捕获最后一个 argv，Windows 侧先 base64 解码）：**9 行 argv 全部不同**——差异是 POSIX 的 wrapper 带 `if [ -n "$AGENTQ_WAIT_BUDGET" ] && command -v timeout …exec timeout…` 子句，Windows 的没有。
    - **为什么它是真缺陷而不是编码差异**：base64 传输层是刻意的（PLAN A21），两客户端的**解码后命令**应当同义。实测后果（真实 sshd + 真实 agentq-server + 真实 pueued，目标 PATH 含 coreutils `timeout`，即任何正常 Linux 主机）：同一 argv `wait <id> --timeout 3` 连跑三次，POSIX 客户端**0 个**孤儿（远端 `timeout 3s` 把等待进程杀在预算上），Windows 客户端 **1、2、3 个**孤儿累加；5 次轮询 5 个。每个孤儿是一个 `agentq-server wait` 进程加一条 pueued socket 连接，**活到任务终态为止**（实测任务 cancel 后归零）——轮询型 agent（SKILL.md 的推荐用法）在长任务上会线性堆积。
    - **两个既有断言被实测推翻**：① 两份客户端都返回 `6` + 同一条消息，所以本文件里**所有**只比退出码/消息的差分都看不见它；② POSIX 资产注释里写孤儿「kept holding the server operation lock」——实测**不成立**：服务端 `wait_for_task` 在 `run_pueue wait` 之前已 `release_operation_lock`（基线即有），孤儿持有的是进程与 pueued 连接，不是锁。SKILL.md 的「持锁孤儿」措辞一并改为实测后的说法。
    - **另一处先前的「假绿」自纠**：本会话早前的两个本地探针（`orphan.sh`、`sighup.sh`）一个用本地 `sh -c` 代替传输（`exec` 后被杀的就是自己）、一个直接给本地进程发 SIGHUP，**都没有经过 sshd**，于是得出「无孤儿后果」的中间结论；把真 sshd 拉起来重测才推翻。教训与本仓「桩必须照抄真实 ssh 行为」同源：**没过传输层的测量不能用来下传输层的结论**。
    - **修法**：Windows 客户端 `New-UnixRemoteInvocation` 改用与 POSIX `remote_base_command` **逐字节相同**的 wrapper（含 `command -v timeout` 条件——`timeout` 不在 PATH 时退化，如 macOS 默认），`New-RemoteInvocation` 新增 `-WaitBudgetSeconds`，wait 路径传入 `$waitTimeoutSeconds`，预算以**前置赋值语句**放进解码后的脚本（不是 `timeout <N>s <命令>` 前缀——函数定义只能出现在命令位置，2026-10-16 实测过语法错误）。Windows 目标不加（POSIX 的 `!= windows` 同款闸门）。修复后同靶重测：两客户端各 3 次轮询均 **0 孤儿**；9 行解码命令与 POSIX **逐字节一致**（submit 的随机 request-id 用显式 `--request-id` 钉住后也一致）。
    - **锁**：`smoke/12` 新增 **remotecmd 表** 10 行（status/doctor/lookup/logs/logs --tail/cancel/remove/wait/wait --timeout/submit 带显式 request-id）——同一 argv 喂两份客户端，捕获各自发出的远端命令，Windows 侧解码后**逐字节比较**；外加两条**单向**断言防「两边同样坏」：`wait --timeout 5` 两边都必须以 `AGENTQ_WAIT_BUDGET=5s; ` 开头且 wrapper 含确切 exec 形式，`wait 1`（无预算）两边都**不得**含 `AGENTQ_WAIT_BUDGET=`；行数下界 10；自检把 Windows 副本的预算臂禁用、要求 `wait --timeout` 行必须报分歧。表在非 Windows 主机运行（与 twin 表同门：POSIX 客户端在 Windows 上不可信），Windows 主机上报 `remotecmd=NOT-covered(needs-non-Windows)`。
    - **红证（先证能红）**：修复前的 `.ps1` 喂 `AGENTQ_SMOKE_PS_CLIENT` → 10 行差分逐行点名 `clients-build-different-commands`（附两侧命令原文）+ `wait budget` 行点名 `windows-missing-budget-assignment windows-wrapper-does-not-exec-under-timeout` + 自检报「anchor 不存在」，共 12 处失败退 1。修复后 `smoke/12 cases=140 twin=…+remotecmd(10/10)` 退 0。
    - **边界**：① 本表只钉「同一 argv → 同一命令」**在 unix 目标上**；Windows 目标的远端命令是 PowerShell launcher，两客户端本来就同形（另一条协议），未进此表。② 远端 `timeout` 缺失时（macOS 默认）两客户端都退化，**孤儿仍会发生**——这是已记录的平台边界，不是分歧。③ 解码用固定形状 `^printf %s <b64> \| base64 -d \| sh$` 匹配，若传输形状变了表会整表报「不匹配」而不是假绿。④ 孤儿的实际危害上限：活到任务终态；对**永不结束**的任务才是无界堆积。
  - **第四十三类（2026-10-28）：两份 Windows 客户端把 usage 写在 stdout 上、错误路径的 stderr 是空的——诊断送错了通道，而既有孪生差分表在结构上看不见。**
    - **怎么找到的**：第四十二类之后，把「同一 argv 喂两份、比答案」推到**第三对孪生**（`sshp` 的 POSIX 与 PowerShell 实现）。`grep` 先证明了一件更基础的事：**没有任何检查把同一 argv 喂给过两份 sshp**——`smoke/19` 只在注释里引用 `sshp.ps1`，`smoke/20` 只跑 PS 侧。于是手工做差分表，第一轮 17 行退出码全部一致，**但把 stdout / stderr 分开量时出现了两种错位**。
    - **主缺陷（两台客户端同病）**：`agentq.ps1` 无参数 → 退出码 2、stdout **2673 B**、stderr **0 B**；POSIX → stdout 0 B、stderr 2596 B。`sshp.ps1` 无参数 → 305 B / 0 B；POSIX → 0 B / 379 B。两个 `Show-Usage` 都写 `[Console]::Out`，而错误路径直接调它。后果：`out=$(client …)` 把 usage banner 当成数据收走，`2>&1 >/dev/null` 什么都看不到——而 SKILL.md 的整套脱敏策略正是建立在「stdout 数据 / stderr 诊断」这个划分上。`--help`（退出 0）写 stdout 是**对的**，这条不能一起改。
    - **为什么既有锁看不见**：`smoke/12` 的孪生表用 `{ flatten_err w.err; cat w.out; }` 合并两个流再 grep 片段——消息落在错的流上仍然匹配。这是「锁的断言比契约弱」的又一例：表断言了**内容**，没有断言**位置**。
    - **次缺陷（同一次扫描发现）**：POSIX `sshp` 的会话名守卫把 `''|-*|*[!A-Za-z0-9_.-]*` 三种情况合并成一条「must contain only letters…」，于是 `sshp h -s` 报的理由**与输入不符**（`-s` 恰好只含允许字符）；Windows 早已拆成两条。退出码两边一致，所以只比退出码的差分看不到它。
    - **修法**：① 两个 `Show-Usage` 加 `[switch]$ToStandardError`，用 `[Console]::Error` 写；错误路径传 `-ToStandardError`，`--help` 路径保持 stdout。② POSIX sshp 的会话守卫拆成「字符集（含空串，与孪生的 `+` 量词对应）→ 连字符」，与 Windows 的检查顺序和消息逐字一致。
    - **锁**：`smoke/12` 新增 **stream 表** 9 行——每一行给一个「消息必须落在哪个流」以及「另一个流必须为空」，两侧各断言一次，并按行断言共享的消息片段；agentq 两行（错误路径 → stderr、`--help` → stdout），sshp 七行（无参数 / 三个位置参数 / 只有 `--check` → stderr，`-h` → stdout，`h -s` / `h a:b` / `-x` 的消息）。**sshp 这一对因此第一次有了差分覆盖**。同时加 `AGENTQ_SMOKE_SSHP_CLIENT` 与 `AGENTQ_SMOKE_SSHP_PS_CLIENT` 两个变异钩子（与既有的 `AGENTQ_SMOKE_CLIENT` / `AGENTQ_SMOKE_PS_CLIENT` 同形），否则给这两处源码级修复做红证只能去换真实资产。
    - **红证（三份变异体，各自喂进对应的钩子）**：`agentq.ps1` 的错误路径去掉 `-ToStandardError` → `stream [agentq.ps1 <no args>] windows-stdout-not-empty(2709B) windows-missing-on-stderr`；`sshp.ps1` 同样 → 无参数 / `h s x` / `--check` **三行**同时点名；POSIX sshp 把合并的 case 放回 → `stream [sshp.ps1 h -s] posix-missing-on-stderr`。三次都退 1。
    - **边界**：只断言 usage 这一处的流位置；其它错误消息本来就写 stderr（`Stop-AgentQ` / `Stop-Sshp` 用 `[Console]::Error`），未逐条加锁——它们的流由同一个 helper 决定，而 helper 本身没有测试。`--version` 走 stdout 是正确的（数据），未纳入本表。stream 表在 Windows 主机上随孪生段一起 `NOT-covered(needs-non-Windows)`。
  - **第四十二类（2026-10-27）：同一个配置文件在两份客户端上解析出不同主机——空值 `AGENTQ_HOST=` 在 POSIX 算一次赋值、在 Windows 不算。**
    - **怎么找到的**：第四十一类之后把同一问法推到「路径/配置类环境变量」，差分扫 `AGENTQ_CONFIG`、`AGENTQ_PLATFORM_CACHE_DIR`、`TMPDIR` 的形状——那些都一致。于是换了个角度：**不是变量的形状，而是配置文件内容的语法**。两个解析器都是「逐行匹配、最后一行胜出」：POSIX 是 `sed -n 's/^AGENTQ_HOST=\([^[:space:]]*\)$/\1/p' | tail -n 1`，Windows 是 `foreach` + `-match '^AGENTQ_HOST=([^\s]+)$'`。**差别只有量词**：`*` 让空值算一次赋值，`+` 让它不算。
    - **红证**：同一份 `AGENTQ_HOST=first-host` + `AGENTQ_HOST=`，POSIX 解析为**空**并退 2 `no SSH host configured`，Windows 解析为 `first-host` 并退 255——argv 捕获确认到达 ssh 的主机分别是 `[]` 与 `[first-host]`。**同一个配置文件，一台机器拒绝、另一台连上去**。
    - **相邻形态全部实测以钉边界**：只有一行空值（两边 2）、两行都有值（两边 `beta`）、值带尾随空格（两边 2）、中间夹空行（两边 `beta`）、注释行（两边 `alpha`）。**分歧只在末尾空值这一种**——所以修法必须窄，不能顺手「统一」别的。
    - **方向**：选 POSIX 的 fail-closed。用户把主机那行清空就是要清空；Windows 的行为是悄悄回退到旧主机，正是本仓反复拒绝的那种「静默回落」。文档此前写的是「写入**单行** `AGENTQ_HOST=<ssh-host>`」，多行是未定义行为——但未定义不等于可以两边不一致，而一旦定义，就该定义成安全的那一侧。
    - **修法**：Windows 的 `Get-ConfiguredHost` 正则 `([^\s]+)` → `([^\s]*)`，并在注释里写清「空值也算赋值，因为两边都取最后一行，量词决定了末尾空值的含义」。
    - **锁**：① `smoke/12` 新增**配置语法表** 5 行——两个客户端读**同一份**配置文件，每行断言「两边各自等于期望退出码」，到达 ssh 的行还断言**真正到达的主机名**（只看退出码分不出 `alpha` 与 `beta`）；② 该表的自检把 `+` 放回 `.ps1` 副本、要求 `empty-last` 行必须报分歧（`sed` 找不到量词同样报红）；③ `smoke/05` 加 2 例同样的断言（末尾空值 → 退 2 且**零 ssh 调用**；两行有值 → `beta` 到达 ssh），因为 twin 表在 Windows 主机上是 NOT-covered，而这一半必须在所有平台都被钉住；下界 15→17。
    - **边界**：`[^\s]` 与 `[[:space:]]` 的空白集仍随 locale 不同（第四十类已记录），所以「值里含 NBSP」这类行在 `LC_ALL=C` 下两边仍可能不一致——未进套件。配置只解析 `AGENTQ_HOST` 一个键，其它键两份客户端都不读，所以不存在同类第二处。多行配置本身仍不是文档推荐形态（文档写「单行」），这里只是把它定义成两边一致。
  - **第四十一类（2026-10-27）：`[ -x ]` 测的是搜索位、目录天然带它——四个「这是可执行文件吗」守卫都接受目录，失败以契约外的 `126` 收场且零诊断。**
    - **怎么找到的**：第四十类修完「主机值的形状」后，问同一个问题到下一层：「还有哪个**值**被当成『可用』却没校验形状」。`grep` 出全部 `-x "$VAR"` 站点，逐个问「这个测试问的是不是它以为的那个问题」——`test -x` 问的是**执行/搜索位**，而**每个目录都有搜索位**。这一条不需要猜：`[ -x <目录> ]` 直接为真（实测）。
    - **红证（修复前，三条同源、后果各异）**：① `AGENTQ_SSH=<目录>`（`AGENTQ_REMOTE_PLATFORM=unix`）退 **126**，stdout 与 stderr **各 0 字节**——126 不在契约的 0-6 / 42-45 / 124 里，而且**没有任何诊断**，调用方拿到一个既不在契约里、也没有解释的码；走平台探针路径时退 126 并打出一句**指错方向**的话（`unable to detect the remote platform; set AGENTQ_REMOTE_PLATFORM…`）。② `AGENTQ_JQ=<目录>`：shell 自己的 `…: line 1768: …: is a directory` 漏到 stderr，紧接着一个**合法**响应被判 `invalid JSON response`——把本地配置错误报成服务端的错。③ `SSHP_SSH=<目录>` 退 126 且报 `remote dependency probe failed for both Unix and Windows shells`，同样指向远端。④ 服务端 `require_executable` 同病：`pueue` 是目录时 `doctor` 的 `pueue=` **机器可读**行里混进 shell 原文（`pueue=…line 5805: …: is a directory`）。Windows 孪生体三条全部退 2（`not a regular non-reparse file`）。
    - **为什么必须修**：126 是 shell 的「找到了但执行不了」，不是 AgentQ 的码；「零输出 + 契约外退出码」是最坏的一种失败——按契约分支的调用方既不能重试（不是 255）、也不能报告（没有消息）。而 `AGENTQ_JQ` 那面更糟：它把责任指到服务端。
    - **修法**：四个守卫都先要求 `-f`，再要求 `-x`，消息点名形状（`must be a regular file`）。**`-f` 跟随符号链接**，所以 `/usr/local/bin/ssh` 这类链接照旧可用——这是刻意的：Windows 拒绝 reparse point 是那套平台的加固，POSIX 上符号链接到可执行文件是常态。安装器两处 `-x`（`existing_path`、`existing_client`）也补上 `-f`，让「可执行」这个判断在本地自洽，而不是依赖三次调用之外的 helper。
    - **锁**：① `smoke/05` 加 5 例——目录、链接到目录、`AGENTQ_JQ=目录`，每条断言**退出码 2 + 消息片段 + 零 ssh 调用**（用计数桩），并断言 stderr 里**没有** raw shell 行（`is a directory` / `: line N:`）；另有一条专测 `AGENTQ_JQ=目录` 时**不得**报 `invalid JSON response`、且 ssh **根本没被调用**；接受侧 1 例（链接到可执行文件必须仍退 255 且确实调用了 ssh）。② `smoke/19` 加 1 例（`SSHP_SSH=目录` → 退 2 + 点名形状 + **不得**报 `remote dependency probe failed`）。③ `smoke/02` 加 1 例（`pueue` 换成目录 → 退 2 + `reason=protocol_error` + stderr 无 shell 原文）。④ `smoke/12` 加 1 例孪生差分（同一 `AGENTQ_SSH=目录`，两边都退 2；消息文本按平台不同，所以断言的是**退出码**这个契约面）与 1 条守卫自检（把 `! -f` 放宽成 `! -e`，要求该行必须报分歧）。⑤ `smoke/01` 新增**构造级**规则 `executable_shape`：同一函数内每个 `-x "$VAR"` 之前必须有 `-f "$VAR"`（字面量操作数豁免；`-f` 出现在**别的函数**里不算数——函数作用域用缩进栈跟踪，嵌套函数也认）。四向自检：植入「只有 `-x`」必须开火、`-f` 在前的必须沉默、字面量必须沉默、跨函数的 `-f` 必须开火。站点数另设下界（今天 9 个），枚举到 0 即失败。
    - **红证 · 静态规则对真实变异体**：分别删掉 `resolve_ssh_binary`（agentq）、`resolve_json_parser`、sshp 的守卫、服务端 `require_executable` 的 `-f` 分支，规则逐条点名（`resolve_ssh_binary: -x on $ssh_binary with no preceding -f …` 等四行），修复后的真树零命中。
    - **写作中自己踩的两个坑（都当场被真实树抓住）**：① `printf … | grep -q` —— 本仓自己的 quiet-grep 锁立刻报出四处；改成先重定向再 grep。② awk 的输出格式里漏了函数名（只打了 `FILENAME:FNR`），于是自检 grep 的 `zz_missing_regular: …` 永远不中，**规则本身是对的、自检却在报红**——把函数名补进输出才修好。第二个性状与第二十五类「判据自检通过不等于判据在真实输入上工作」正好相反：这次是**真实输入通过、自检不通过**，同样说明两边都要跑。
    - **边界**：规则只覆盖 `-x "$VAR"` 这一种写法（`test -x`、`[[ -x ]]` 当前树里没有；出现时规则看不见——与既有几条单行规则同一个边界）。`-f` 必须是**普通文件**，因此指向**设备文件**的 `AGENTQ_SSH` 也会被拒；这判为正确（拿设备当 ssh 不是可用状态），但没有实测过。非 UTF-8 locale 与符号链接的组合未单独测。
  - **第四十类（2026-10-27）：POSIX 客户端只校验主机「非空」，Windows 孪生体校验它的**形状**——同一 argv 一边退 255（可重试的传输类）一边退 2（参数错误）；带配置文件时，同一环境把两台客户端指向**不同机器**。**
    - **怎么找到的**：第三十九类建立了差分表，但它只覆盖「本地能裁决的 token」。收尾时换了个问法：「表里的行都是**值已知**的形态，哪些输入形态这张表**表达不出来**」。答案有两层：`read -ra` 造不出纯空白单词，所以 `--host ' '` 这一族永远进不了表；而 `--host` 的**值**本身从来没被形状校验过——`grep` 确认 POSIX 侧只有 `[ -n "$host" ]` 一处，Windows 侧有 `IsNullOrWhiteSpace` + `StartsWith("-")` 两处。
    - **红证（修复前，桩 ssh 一律 255、无配置文件）**：`--host -x` / `-` / `--` / `-evil` → POSIX **255**、Windows **2**；`--host ' '` / TAB / CR / NL / `' \n'` 与 `AGENTQ_HOST` 的 space/TAB/CR → POSIX **255**、Windows **2**。`--host` 后无命令时两边都是 2 但**消息不同**（POSIX 走 usage，Windows 走连字符消息——孪生体的主机守卫在「有没有命令」之前）。相邻形态全部实测以钉边界：`'a b'`、`' a'`、`'a '`、`'.'`、`'..'`、`'a:b'`、`' -'`、`' - '` 两边都 255（**内嵌空白不是分歧**，sshp 才拒绝任意位置空白）；`''` 两边都 2。
    - **更尖的一面（不是退出码）**：配置文件写 `AGENTQ_HOST=cfg-host`、环境里 `AGENTQ_HOST=' '` 时，POSIX 把 `" "` 交给 ssh、Windows 把 `cfg-host` 交给 ssh——**同一环境指向两台不同机器**。机制是 `IsNullOrWhiteSpace` 把纯空白当**未设**并回退到配置值，而 `${VAR:-...}` 只在**空**时替换。用捕获 argv 的桩实测，两侧分别拿到 `[ ]` 与 `[cfg-host]`。
    - **为什么 255 比 2 严重**：`255` 在契约里是「传输失败、可重试」，`2` 是「改你的参数」。把一个永久拼写错误报成可重试类，按契约重试的调用方会永远重试；同时 stderr 的措辞把人指向网络，而问题在参数——与 BatchMode 那次「报错指错方向」同一类。
    - **修法（POSIX 对齐 Windows，不是反过来）**：① 解析处改 `case "${AGENTQ_HOST:-}" in *[![:space:]]*) …;; *) default_host=$configured_host;; esac`，纯空白即回退到配置主机（与 `IsNullOrWhiteSpace` 同义）；② 全局选项之后补两条守卫，**同序同文**于孪生体：先 `*[![:space:]]*`（否则 `no SSH host configured; pass --host or set AGENTQ_HOST`），后 `-*`（否则 `SSH host must not begin with a hyphen`）。方向不能反：`255` 是「可重试」，把一个永久参数错误报成它，调用方会永远重试；而 sshp 的「任意位置不得有空白」**刻意不采用**——两份 agentq 客户端都接受内嵌空白（实测都是 255），收紧要另立契约。
    - **锁**：① `smoke/12` 差分表 +3 行（`--host -x`/`--`/`-evil`），下界 20→25（表 26 行），三向断言不变；② 新增**host 值扫描** 5 例（space/TAB/CR/space-NL/VT，经 `AGENTQ_HOST` 走环境路径，`read -ra` 造不出的形态）——两侧各自必须退 2 且都打出 `no SSH host configured`，执行数设 ≥5 下界；③ **配置回退孪生用例**：捕获两侧真正交给 ssh 的主机名，都必须是 `cfg-host`；④ **两条守卫自检**：分别把 `-*` 守卫改成永不匹配、把空白守卫改成 `:`，各跑对应行要求比较器**必须报分歧**——`sed` 找不到守卫行同样报红（说明变异没发生）；⑤ `smoke/05` 加 16 例：13 条拒绝（9 条 argv——含 `$'\n'`/`$' \n'`——加 4 条 env），每条断言**退出码 2 + 消息片段 + 零 ssh 调用**（平台探针先于参数校验，拒绝前不该花掉一次往返），加 1 条配置回退拒绝与 2 条**接受侧**边界（`'a b'`、`' a'` 必须仍退 255 且**确实调用了** ssh），防止以后有人把规则收紧到 sshp 的「任意位置空白」。
    - **红证 · 先证能红**：修复前 `smoke/05` 14 条逐条点名退 1（`--host -x` 报 `expected exit 2, got 255`，配置回退报 `ssh was sent to [ ]`）；`smoke/12` 3 行差分 + 5 例 host 值 + 配置回退 + 2 条守卫自检（`the POSIX hyphen-host guard was not found`）全部点名退 1。修复后 `smoke/05 cases=70 host=16`、`smoke/12 cases=113 twin=checked(26/26)+host(5/5)`。
    - **修好后又扫了一遍相邻形态**：16 种（含 `- `、` -`、`- \n`、`\v`、`\f`、`.`、`..`、`a:b`）全部 0 DIFF；配置来源的 `AGENTQ_HOST=-x` 与「env 空白 + 配置 `-x`」也两边一致。
    - **边界**：`[[:space:]]` 的空白集**依赖 locale**——UTF-8 locale 下它把 NBSP(U+00A0) 与 U+3000 当空白（与 .NET 一致，实测 `AGENTQ_HOST=<NBSP>` 修复前两边 255/2，修复后两边 2），`LC_ALL=C` 下不当空白（.NET 仍当），所以**非 UTF-8 locale 上 NBSP-only 主机仍是一处分歧**，如实记录、不进套件（进了会让套件随 locale 变色）。内嵌空白两台 agentq 客户端都接受、`sshp` 拒绝，这是**两套契约**，不是分歧。校验发生在解析 ssh 与 `initialize_remote_invocation` 之前，所以「零 ssh 调用」是结构性的，不是偶然。
  - **第三十九类（2026-10-27）：孪生客户端的大小写规则被修在「token」上，漏在「值」和「全局选项」上——同一 argv 在两份客户端退出码不同，而套件里没有任何检查真的把同一 argv 喂给过两个人。**
    - **怎么找到的**：第三十八类收尾后问「还有哪个类只在文档里、不在锁里」。CLAUDE.md 的孪生对偶规则写着「检测方法是差分，不是读代码」——2026-10-21 那次差分扫出了五处分歧，但**它是一次性的人工扫描**，`grep` 确认没有任何 smoke 检查运行两个客户端并比较答案。于是重做差分：同一 argv / 同一环境分别喂给 `client/unix/agentq` 与 `client/windows/agentq.ps1`（桩 ssh 一律 255），比退出码。
    - **红证 · 先证能红（实测 44 行表里 8 行 DIFF）**：① `--VERSION`/`--Version`/`--HELP`/`HELP`/`Help`/`-H` —— Windows 退 0（版本行 / usage），POSIX 退 2 `unknown command: --version`；② `logs 1 --tail ALL` / `--tail All` —— POSIX 本地退 2，Windows 接受并转发，由大小写敏感的服务端在**一轮 SSH 之后**拒绝（桩上表现为 255）。
    - **方向相反，不是一个 bug 而是两个**：① 是**选项 token**——客户端自己消费，从不发给服务端，PowerShell 的 `-eq` 按语言规则大小写不敏感，所以该由 POSIX 折叠来对齐（与 `STATUS`/`--WORKDIR`/`sshp --CHECK` 同一判例：折叠 token，不折叠值）；② 是**选项值**——`all` 被逐字转发，服务端用 `[ "$2" = all ]` 大小写敏感地比，所以该由 Windows 改成 `-ceq`，POSIX 本来是对的。把 ② 也「折叠对齐」会制造一个更糟的状态：本地接受、远端拒绝，用户为一处本地拼写错误付一次往返。
    - **修法**：① POSIX 全局选项循环里 `global_option=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')` 后再 `case`，`--host` 的**值**原样传入（hostname 折叠会连到别的主机）；② `Test-PositiveIntegerOrAll` 的 `all` 比较改 `-ceq`，注释写明「option token 保持 `-eq`，这个值不行」。
    - **锁**：① `smoke/12` 新增**差分表**（23 行）：同一 argv 喂两个客户端，三向断言——两边各自等于期望退出码、两边彼此相等、拒绝行两边都打出同一条消息片段。**期望码两边都断言**，只问「是否一致」的差分在两处同时坏掉时会绿。服务端不可达时接受型行为 255、拒绝型为 2 且**不触网**，所以整表不需要远端。② 行数用 `grep -c` 独立数一遍，循环少跑一行即红，并且**表的行数另设 ≥20 的下界**——一张悄悄变短的表现在和跑它的循环**总是相等**，等值闸门在结构上看不见它（与第三十六类同一个形状：把「少覆盖」读成「覆盖了」）；下界是双向自证过的（截到 5 行的副本 → 点名退 1，真表 23 行绿）。③ 自检：把 POSIX 客户端的折叠行 `sed` 还原成 `$1` 的副本跑同一行，要求比较器**必须**报分歧；`sed` 找不到那行（未来改了写法）同样报红——那说明变异没发生，不能说「比较器有效」。④ 同一段的安装（桩 ssh / 环境）对两侧各用各的形状：Windows 形态的 `.cmd` 给 `pwsh`，`#!/bin/sh` 给 `/bin/sh`，第一版只备一份，在 Git Bash 主机上会让 POSIX 侧以 `AGENTQ_SSH is not executable` 退 2，读起来像契约分歧。⑤ Windows 主机上这段声明 `twin=NOT-covered(needs-non-Windows)`：Git Bash 的 `sh` 既不是 POSIX 客户端发布的平台、也不是忠实的 `sh`，在上面跑只会把测试台的缺口报成契约分歧；用命名的 NOT-covered 而不是 `SKIPPED`（Windows job 拒绝 `SKIPPED`）或静默通过。
    - **红证（锁之后，全部实测）**：① 把关掉折叠的 POSIX 客户端副本喂给 `smoke/05` → 6 个变体逐条点名、退 1（对照：真实资产 `global=6` 全绿）；② 把 `-ceq` 还原成 `-eq` 的 `.ps1` 副本喂给 `smoke/12` → 差分表点名 `logs 1 --tail ALL` / `All`（`windows-exit=255 clients-disagree windows-missing-message`）与原有的两条 tail 用例，退 1；③ 差分段自检在正常运行时每次都跑（折叠行一旦被改回去就立刻红）。
    - **边界**：① 差分表是**静态**的 23 行，不是从两个客户端的 `case` 臂枚举出来的——新加一个选项 token 时没有人会自动为它加一行；行数闸门只保证「表里的一行都没被跳过」，不保证「表覆盖了全部 token」。这是刻意的取舍：从 arm 枚举出的 argv 需要知道每个 token 的语法位置，而猜位置的差分测试会制造假分歧（这一轮最初的人工扫描就因为 `env "VAR="` 与 `env VAR` 混用、忘了给 Windows 侧设 `AGENTQ_SSH` 报过两次假分歧）。② 表只覆盖**本地可判定**的行（拒绝，或触桩后 255），不覆盖任何真实远端行为；`255` 是桩的答案，不是服务端的。③ 全局选项的 `--host` 值用 `ssh-argv` 桩断言「原样传给 ssh」，但只覆盖一个混合大小写样本。④ Windows CI 的 Git Bash 上差分整段不执行，那里只有 `smoke/12` 原有的单侧用例——「两客户端一致」在这台主机上**没有证据**。

  - **第三十八类（2026-10-27）：`smoke/02` 两条结构性 reason 规则的枚举面比它们声称的窄——`printf` 之外的打印器完全隐形，函数名含数字不被识别；「没有 gap」与「没有检查」同义。**
    - **怎么找到的**：第三十六类给 `smoke/10` 的枚举规则加了「0 站点即失败」之后，换了个问法：「**缺席型**规则（报出违规、默认零违规）有没有等价物」。`smoke/02` 的两条结构性规则是唯一覆盖 Windows-only 路径的守卫（运行时用例到不了那里）——「每个 `>&2` 消息后跟 `exit 2` 的站点必须打 reason」与「bare 调用的函数里消息后跟 `return 2` 也必须打 reason」。它们的失败路径全在 `if [ -n "$sites" ]` 里，站点谓词还要求字面 `printf`。
    - **红证 · 先证能红（两条，全部实测）**：给服务器副本追加 `echo '...' >&2` + `exit 2` 的函数（无 reason 行）→ `reason-gaps=0`、退 0；同样给 bare 调用的函数追加 `echo` + `return 2` → 也退 0。两条规则对 `printf` 以外的打印器完全失明。
    - **第二个洞（同一轮实测发现）**：return-2 规则的函数名类是 `[a-z_]+`，不含数字。`mutant_return2_helper()` 这种名字既不被认作定义、也不被认作 bare 调用，站点被归到上一个被识别的函数（实测报 `[main]`）——bash 允许数字，一个 `foo2()` 里的 `return 2` 同样逃逸。真机上两种名类各 169 个定义，放宽是零变化。
    - **修法**：① 两条规则的站点谓词从「含 `printf`」放宽到任意 `>&2`（真机仍是同样 9 个 exit-2 站点、同样 3 个被判定 return-2 站点，零假阳性）；② 函数名类放宽到 `[a-z_][a-z0-9_]*`；③ 两条扫描各抽成函数，输出违规行并以 `__SITES__N` 收尾——N 是它**实际检查过的站点数**（含合规站点），为 0 即失败；④ 摘要追加 `reason-sites=9 return2-sites=3`；⑤ 两条扫描各带双向自检（`printf` 与 `echo` 两种拼写都必须被抓住、合规站点必须被计数、未被 bare 调用的函数不计入），自检走**已发布的函数**而不是复制一份 awk。
    - **红证（锁之后，全部实测）**：① echo 的 exit-2 变异体 → 点名第 6267 行并退 1（修复前退 0）；② echo 的 return-2 变异体 → 点名 `[mutant_return2_helper]` 并退 1（修复前退 0，且修复函数名类之前被归到 `[main]`）；③ 把 `printf` 要求还原到 exit-2 扫描 → 自检报「expected 3 sites / 2 gaps, got 1 / 1」，且真机站点数归 0 触发闸门，两条并退 1；④ 把两个扫描的站点谓词同时改瞎 → 四条（两条自检 + 两条闸门）同时点名并退 1。各变异单独施加、单独还原，还原后与备份 `cmp` 逐字节一致。
    - **边界**：① 谓词仍是「`>&2` 且**下一条语句**是 `exit 2`」——一个先打印、再做别的、最后 `exit 2` 的站点仍不在面内（规则注释里原有的窗口说明不变）；② return-2 规则只判 bare 调用且未被 `return $?` 折叠的函数，非 bare 函数的站点不计入 `__SITES__`（那是规则的边界，不是漏检）；③ 本轮没有改动 `skill/assets/` 的任何字节。

  - **第三十七类（2026-10-27）：本地套件对 `NOT-covered` 只印不判——新增一个平台缺口声明，本地 `PASS` 退 0、CI 退 1。**
    - **怎么找到的**：第三十六类收尾后问「本地与 CI 的判定还有哪些不对称」。`run-tests.sh` 把 `NOT-covered` 单列第五桶（NCOV）、打印清单，**判定只在 `ci.yml` 的 linux job 里**——那里的 `known_ncov` 是一份写死的检查名清单。`grep -rn known_ncov` 确认本地没有任何等价物。这正是上一轮（`ci_pin`）为「检查清单」修过的形状：本地全绿，第一个反对的是 CI。
    - **红证 · 先证能红（两侧都实测）**：用两个检查的夹具树跑**真实**的 `run-tests.sh`（复制到 `/tmp`，检查是打印摘要的几行脚本）：一个检查打印 `staging=NOT-covered(needs-Windows)` → 本地 `PASS checks: 2 ran, 0 skipped, 0 partial, 0 failed`、**exit 0**，清单行照打 `NOT-covered: 1 check(s) ...: 02-gap`；同一份 `smoke.log` 喂给 `ci.yml` 里那段 `known_ncov` 闸门（原样抄出）→ `NOT-covered reported by check(s) not in the known platform-expected set: 02-gap`、**exit 1**。
    - **修法**：已知集合抽成单份数据文件 `smoke/not-covered-known.txt`（每行一个检查名，`#` 注释），两个消费者同读：`run-tests.sh` 的本地闸门与 `ci.yml` 的 linux job（后者不再自带清单，改读文件；文件缺失或空名则显式退 1）。本地闸门放在**算 verdict 之前**，所以未知名字会让总结行直接是 `FAIL checks: ...`，不会出现「打印 PASS、退出码 1」的自相矛盾。闸门要求：① 文件存在（读不到的策略不得读成通过）；② 至少命名一个检查（空表会让每个缺口都成未知）；③ 报出的名字是已知集合的子集（已知名字缺席是覆盖变强，不判红——沿用 CI 的语义）。
    - **子集判定的自检**：抽成 `not_covered_unknown <已知集> <报出集>` 函数，每次运行先做双向自检——未知名字必须被返回、已知名字必须静默。一个恒返回空的子集判定就是这道闸门要防的假绿，所以它自己也要能被证伪。
    - **红证（锁之后，全部实测）**：① 未知名字 → 本地 `FAIL check(s) declared NOT-covered without being in smoke/not-covered-known.txt: 02-gap` 并退 1；② 同一检查改名为 `12-ps-client-contract`（在集合内）→ 退 0（对照组）；③ 删掉已知文件 → `is missing; the platform-gap policy cannot be read` 并退 1；④ 只留注释 → 「names no check」与「02-gap 未知」两条同时点名、退 1；⑤ 把判定函数改成 `printf ''` → 自检 `failed its self-test` 并退 1；⑥ `ci.yml` 的新片段：未知名字退 1、全已知放行。
    - **边界**：① 本地闸门只按**检查名**判定，与 CI 语义一致——一个已知检查**新增**第二个 `NOT-covered` token 不会被它区分（这一点 `ci.yml` 的注释早已如实写明，本轮未改变它）；② `smoke/not-covered-known.txt` 是数据文件，`run-tests.sh` 用 `-name '*.sh'` 发现检查，所以它不会被当成检查执行；③ 本轮同样没有改动 `skill/assets/` 的任何字节。

  - **第三十六类（2026-10-27）：摘要行里的覆盖计数不是证据——三个字面量（`files=5`、`rules=7`、`tombstones=0`），加上五条枚举型规则在枚举到 0 个站点时照打 `violations=0`。**
    - **怎么找到的**：第三十五类修完「按种类枚举臂」之后，把 29 个检查的**汇总行**逐个看了一遍，问的是同一个问题：「这个数字是谁算出来的」。`smoke/10` 的 `files=5` 在 printf 里是字面量——`grep -n` 确认整行只有 `rules=%s` 一个替换，`files=5` 没有任何实参；而规则实际读的是 **10 个不同文件**（9 个资产 + `smoke/10-launcher-parity.py`，由 `$root/...`、`$root/smoke/...`、`$AGENTQ_SMOKE_INSTALLER_DIR/...` 三种前缀解析）。`smoke/16` 的 `rules=7` 同样未计算。`smoke/15` 的 `tombstones=0` 也是字面量——它的断言是**增量**比较（`tombstone_count != tombstones_before`），所以只要沙箱起始就有墓碑，打印的 0 就是假的。`smoke/08` 早在注释里写过这个原则（「computed, not a literal」），但没有一条规则检查另外 28 个。
    - **第二个缺陷（更重）**：`smoke/10` 的 B/D/F/G/H 五条规则都是「枚举站点、逐个断言」，而它们的失败路径全在 `if [ -n "$sites" ]` 里面。`grep` 匹配不到时经 `$( )` 只剩一行空行，`while read` 体 `continue` 掉，规则**绿着退出**，`rules_checked` 照加一——摘要说 `rules=14 violations=0`，读起来像 14 条不变量都验过，实际有一条什么都没看。同文件里 RULE I 早有这道闸（`render_pairs_seen -lt 3`），RULE K2 也有（「could not extract any finally block」），这五条没有。
    - **红证 · 先证能红（两条，全部实测）**：① 删掉 `move_client_file` 的复核块、并把它那行 `mv` 改写成 `/bin/mv` → `smoke/10` **退 0**，摘要照打 `posix-mv-recheck=asserted violations=0`；**对照组**——同样的复核删除、只保留 `mv` 拼写 → 退 1 并点名「moves a file but nothing in its enclosing function re-checks the result」。也就是说一条真实的、未被复核的 move 只因拼写不同就能出厂。② `files=5` 而实测读 10 个文件；把这份脚本复制到临时树、加**第 11 个**文件引用再跑 → 仍然打印 `files=5`，token 对覆盖面完全免疫。
    - **修法（smoke/10）**：`files=` 改为**对脚本自身源码做路径普查**——从非注释行里抽取三种前缀的路径、经 `$root`/`$AGENTQ_SMOKE_INSTALLER_DIR` 解析、`sort -u` 计数（今天 10）。检测器用 `census_dollar` 拼正则，自己的模式行不会被算进去（检测器匹配自己是本仓踩过的坑）。普查有自检：夹具里三条不同路径 + 一条重复 + 一条注释 → 必须恰好数出 3。`sites=` 为五条规则实际检查的站点数（今天 28：B 3、D 2+1、F 2+2、G 1+15、H 2）。`rule_sites` 闸门：0 站点失败、非数字失败，自检三向（0 必须红、2 必须绿、非数字必须红）；`rule_sites_checked` 必须恰为 8（B 1 + D 2 + F 2 + G 2 + H 1），少一处调用即红——这道计数本身就是「闸门有没有被接线」的检查。粒度是**按规则且（在设计要求每个文件都有该构造时）按文件**：实测的变异只改了一个安装器，若按规则合计 16 个站点仍非零，闸门就看不见它。
    - **修法（其余三处）**：`smoke/16` 的 `rules=` 从 `RE_Rn` 定义推导，并要求每条规则同时出现在 `first_match` 的 case 分支与 `scan_file` 正文里（用 awk 抽 `scan_file` 函数体，与 RULE D/B 同一种「作用域是函数」的形状）；`smoke/15` 的 `tombstones=` 改为计算的增量；`smoke/09/10/16/29` 的 `violations=0` 一并改为计算值（`violations` 本来就是 `failures`/`len(violations)`）。
    - **构造级锁（smoke/01，`summary_census`）**：任何 `smoke/*.sh` 的 `checks passed:` 行里，覆盖类 token（`files rules sites cases scripts programs records blocks invocations tombstones tokens functions specs`）**不得**写成字面数字，必须是 printf 的 `%s`/`%d`。词表刻意不含契约类 token（`exit=0/1/2`、`wait=6/unavailable`、`queued_removed=5`）：那里的字面量**就是**检查断言的值，断言失败时检查在打摘要之前就退 1，数字不会与实际跑出来的东西脱节；覆盖计数不同——文件里没有任何断言能让它变对，它必须从「扫了什么」里算出来。自检双向：夹具第 1 行（`files=5`）与第 4 行（`rules=7`）必须命中，计算值、契约值、注释行、非摘要行必须静默；枚举到 0 个脚本拒绝报通过。夹具里的短语用变量拼，避免本文件自己成为一条「字面量摘要」。
    - **红证（锁之后，全部实测）**：① 变异体（`/bin/mv` + 删复核）→ 点名「rule G(install-client.sh) enumerated 0 site(s)」并退 1；对照组仍退 1（原消息）。② 带第 11 个引用的副本 → `files=11`（修复前同一副本打印 5）。③ 普查正则改成 `skill/asset` → 自检报「expected 3 ... got 2」并退 1。④ 把 `rule_sites` 的 0 分支改成 `return 0` → 自检报「failed its own self-test (blind-on-zero)」并退 1。⑤ 删掉 RULE H 的 `rule_sites` 调用 → 「ran 7 time(s), expected 8」并退 1。⑥ `smoke/16` 加一条 `RE_R8` 不接线 → 「scan_file never greps with $RE_R8」「first_match has no R8) arm」两条并退 1。⑦ 把三处字面量（`files=5`/`rules=7`/`tombstones=0`）临时改回 → `smoke/01` 的 `summary_census` 锁**逐行点名三个文件**并退 1；还原后逐字节一致。
    - **边界**：① `files=` 数的是**本脚本源码里引用的不同路径**，不是「真的被打开过的文件」——一条 `grep` 若因变量拼错而指向别处，普查看不见；它锁的是「摘要数字随引用变化」，不是「每个引用都被执行」。② `sites=` 的粒度按规则/按文件是逐条判断的：H 用按规则合计（客户端安装器合法地没有 `[AllowNull()][string]` 参数），B/D/F/G 用按文件——判据写在代码注释里，将来若某个安装器合法地不再包含某构造，闸门会红，届时应当**替换规则**而不是删闸门。③ `summary_census` 的词表是固定的：新造一个覆盖类 token 名（例如 `fixtures=3`）不在词表内就不会被拦，除非同时加进词表——这是词表式锁的固有边界。④ 本轮没有改动 `skill/assets/` 的任何一个字节：修的全是检查自身。

  - **第三十五类（2026-10-26 同一轮）：`smoke/01` 的五个按种类枚举臂，任何一条 glob 写错都会让整类资产静默变成「解析过 0 个」，而这一行摘要照常打印。**
    - **怎么找到的**：第三十四类收尾时问了一句「摘要行里还有哪些**计数**是印出来没人比的」。`syntax-and-parity checks passed:` 这一行有五个按种类来的计数——`plist=`、`yml=`、`service=`、`cmd=`、`ps1=`——每个都来自一条独立的 `find ... -name '*.X'`。同一行里还有十二个别的计数，其中 shell/repo_scripts/workflows/configpaths/python3_users/gitattr/gitignore/skill_modes 都各有一道「枚举到 0 就拒绝报通过」的闸门，这五个没有。
    - **红证（先证能红，五条全绿）**：把每条 glob 各改一个字母——`*.plist`→`*.plst`、`*.yml`→`*.yam2`、`*.service`→`*.srvc`、`*.cmd`→`*.cmdx`、`*.ps1`→`*.psx`——各自单独施加，`smoke/01` **五次都退 0**，摘要分别打印 `plist=0`、`yml=0`、`service=0`、`cmd=0`、`ps1=0`。也就是说那一整类资产（2 个 plist、2 个 yml、1 个 service、2 个 cmd、7 个 ps1）由「没有任何规则解析它」，而检查说自己通过。
    - **为什么现有的两道闸门都看不见**：`unclassified` 问的是**反面问题**（存在一个文件，它的种类没有规则解析）——它遍历 `find skill/assets -type f` 逐个分类，删掉/改坏一条枚举 glob 时文件还在、种类仍然被认得，所以它是 0。`shell=` 与 `local_hazard_files=` 的漂移闸门只覆盖 shell 这一种。而四个 `*_count` 变量（plist/yaml/service/cmd）是**只写变量**：自增、从不读。SC2034 抓不到——实测 `dead=0; dead=$((dead+1))` 在 `-i SC2034` 下是干净的（自引用自增算一次「使用」），所以 shellcheck 锁对这个形状天然失明。CI 那边只钉了 `ps1=7`（macOS 快速串），其余四个类别在任何平台上都没有下界。
    - **修法**：把 `asset_is_classified`（布尔）抽成 `asset_kind`（返回种类），分类表只此一份；再加一道**按种类普查**——独立遍历 `skill/assets` 下每个文件、按同一张表求种类并计数，然后逐个与各臂的计数比对。这道闸门证明的是「臂的 glob 仍然匹配它自己那一类」，**不是**「部署单元完整」：删掉一个资产是另一个问题（`skill_modes` 的 `-lt 25` 索引下界回答它），而从工作树删除、索引里还在的文件两者都看不见，只出现在 `git status` 里——记为边界。`.ps1` 的比对只在 `pwsh_state=usable` 时做、`.yml` 只在 pyyaml 存在时做：工具缺失时那两个臂本就没跑，摘要已经打 `skipped(...)`，再比就会造出假红。
    - **自检三向**：① 普查必须把夹具分对（一个 `.plist`、一个 `.cmd`、一个 `#!`-shim、一个 `.json` → 期望恰为 `cmd 1 plist 1 shell 1 unknown 1 `）；② 比较器对**错误**计数必须报警；③ 缺失的种类按 0 比（臂数 0 时两者一致）。第 ② 条是必须的：一个「永远同意」的比较器会让这道闸门永久变绿，而这正是它要防的形状。
    - **红证（锁之后，七条）**：五条 glob 各自点名「the .X arm counted 0 file(s) but the tree holds N」并退 1；把比较器短路成 `return 0`（永远同意）→ 自检报「a wrong count was accepted」并退 1；把 `asset_kind` 塌成只返回 `shell` → 三道闸门同时报红（分类器自检、普查自检、五个比对里的每一个）并退 1。全部单独施加、单独还原，还原后与基线 `cmp` 逐字节一致。
    - **摘要与 CI**：摘要追加 `kinds=checked`（同时加进 `summary_tokens` 那份「每个承诺的 token 必须出现」的清单——不加就会被它当场抓住）；`ci.yml` 的 macOS 断言从 `ps1=7 ps1_static=ok .*tool_full=6/6` 扩成 `... .*kinds=checked`，否则这道闸门在 CI 侧没有证据。
    - **边界**：① 普查只证明「每个臂的计数与树一致」，不证明每个资产都**被真正解析过**（那是各臂内部的事，例如 plist 的 xmllint 分支）；② 从工作树删除一个资产、索引里仍保留时，本闸门与 `skill_modes` 都不报——`git status` 是唯一的信号，未加锁；③ 普查的分数依赖 `asset_kind` 的分类表，表本身改了而臂没改时闸门会红（这是期望行为），但表**和**臂一起改错（同一条 glob 在两处都被改坏）时它看不见——`unclassified` 能接住其中一部分（文件变成 unknown），接不住「改成一个仍然合法的类别」。

  - **第三十四类（2026-10-26 同一轮）：shellcheck 这把锁可以被它所检查的文件（以及文件外部）关掉——两个 smoke 脚本各有一行以指令令牌开头的散文注释，从那一行到 EOF 从未被 lint。**
    - **怎么找到的**：第三十一至三十三类都在问「写在文档里的保护，哪一条真的有人读」；本轮换问法：「**我自己写下的检查，在什么情况下会静默不跑**」。`smoke/05` 的 shellcheck 臂用 `-i SC2319,SC2034,SC2221,SC2222`（只报这四个码），而 shellcheck 的指令语法是**注释**：一个 `#` 之后跟小写令牌 `shellcheck` 就进入指令解析，解析不了就报 SC1073 + SC1072 并**中止该文件其余部分的分析**。`smoke/01:1104` 的散文是 `# shellcheck/posix tokens and the NOT-covered allowlist...`、`smoke/20:348` 是 `# shellcheck reported it SC2034; it is gone...`——两行都在描述锁，却各自把所在文件从该行起整段关掉。
    - **实测的四层机制（全部在本机 shellcheck 0.11.0 上量过）**：① 被承认的指令形式是 `#` + 可选空白 + **小写**令牌——`# shellcheck`、`#shellcheck`、`#  shellcheck`、行首制表符、`    # shellcheck` 都成立；`# Shellcheck`/`# SHELLCHECK`/`## shellcheck`/`# see shellcheck ...` **不成立**（后者正是此前的写法之一）。② 畸形指令报 SC1073「Couldn't parse this shellcheck directive」+ SC1072「Fix any mentioned problems and try again」，并**停止分析该文件的其余部分**。③ 行尾指令（`echo x  # shellcheck disable=SC2034`）报 SC1073 + SC1126「Place shellcheck directives before commands, not after」+ SC1072。④ **`-i <codes>` 把解析错误一并抑制**——这正是这个缺口能活下来的原因：锁的过滤面恰好把「解析已中止」这个信号滤掉了。
    - **红证 · 先证能红**：在 `smoke/01` 那行之后（1104 行往后）种一个未使用变量——`-i` 白名单下**仍然退 0**（该文件此后没被 lint）；把 `-i` 扩权到含 SC1072/SC1073 后，同一处**立刻报红**，且报出的是那两行散文本身。这一步同时**顺带暴露两处一直被掩盖的真缺陷**：`smoke/01` 的 `gitattr_violations` 里有一个**死变量 `attr`**（读取函数参数名用的那个 `local` 变量，因函数改用 `$1` 比较而再未被读），以及 `python3_census` 的 `case` 里两个 **`elif python3` 死分支**（`*if\ python3*` 的子串匹配本就覆盖 `elif`，SC2221/SC2222 早已指出）。两者都已修：`gitattr_violations` 改为 `local attr_name=$1` 并在循环里比对，`case` 分支收敛为 `*if\ python3* | *if\ !\ python3* | *while\ python3*`。
    - **修法三层**：① **锁的码集合加 SC1072/SC1073**（「解析已中止」本身成为锁要守的东西），实测本仓 40 个 shell 文件扩权后**全绿**——只加信号，不加噪音。② `smoke/05` 新增**逐行指令探针**：枚举「可能是指令的注释行」（50 行），每行喂给 shellcheck 一个夹具，要求报出的码集合**恰为四个锁定码**（说明这行既没缩小锁、也没中止解析）；**且**一个刻意诱发解析错误的第二夹具必须仍报出 SC1072+SC1073（否则一行 `disable=SC1072,SC1073` 就能把中止信号本身关掉——实测种在 `client/unix/agentq:2` 上确实退 0）。**为什么必须是双夹具**：单个夹具无法同时回答两个问题，解析中止会**压制所有其它发现**（`dead var + 未闭合 if` 实测只报 SC1072/SC1073），所以「缩小了锁吗」和「中止了解析吗」要用两个方向分别问。③ **统一调用加 `--norc -S style`**：实测这把锁可以从**文件外部**整仓静音——祖先目录的 `.shellcheckrc`、`$XDG_CONFIG_HOME/shellcheckrc`、`SHELLCHECK_OPTS`（`-e`/`-i`/`--include`/`--exclude`/`--rcfile=`/`-S error`）各自都能让全部文件看起来干净；`--norc` 胜过所有 rc 文件通道、显式 `-S style` 胜过 `SHELLCHECK_OPTS='-S error'`、命令行 `-i` 胜过 `-e`/`--include`/`--exclude`。**`SHELLCHECK_OPTS=` 前缀是空操作**（实测：加与不加无差别），所以没有把它写成一道防线。还有一个**自检兜底**：在带收窄 rc 的临时目录里植入一个已知缺陷，若它被静音就报「can be silenced from OUTSIDE」。
    - **枚举面刻意比工具规则宽**：`shellcheck_directive_candidates` 用大小写不敏感、任意位置的 `grep -n '^[[:space:]]*#.*[Ss][Hh]...'`，而**不是**照抄 shellcheck 自己的判据——若照抄，一次工具判据的收紧就会让枚举面跟着缩水而无人察觉。枚举器自身有自检（一个候选行在第 2–5 行、诱饵在第 6–7 行的夹具，返回值必须恰为 `2 3 4 5`），且**走的是已发布函数**（不是复制的第二份实现）。
    - **红证（六条，全部实测）**：① `client/unix/sshp:2` 插 `# shellcheck disable=SC2319,SC2034` → 逐条点名「disables a locked code」并退 1；② 把两处原始散文行还原 → **两个文件各被主锁与探针点名（4 failure(s)）**并退 1；③ `client/unix/agentq:2` 插 `# shellcheck disable=SC1072,SC1073` → **第一夹具四个码全绿**、第二夹具点名，退 1（这条正是双夹具存在的理由）；④ 枚举器收窄为「只认工具自己的拼写」→ 自检报「返回 [2 4 ]，候选应为 2–5」并退 1；⑤ 去掉 `--norc -S style` → 外部配置自检报「can be silenced from OUTSIDE」并退 1；⑥ 枚举器改盲（函数体换成 `:`）→ 幻影修复后 `directives=0`，`checked(0)` 守卫与枚举器自检同时报红、退 1（修复前同一变异得 40、守卫静默，见下一段）。各变异单独施加、单独还原，还原后 `smoke/05-client-contract.sh` 与 `skill/assets/client/unix/agentq` 对备份 **diff 为空**。
    - **红证之后（改完再测一次）**：`smoke/05` 全绿并打印 `shellcheck=checked(9) scriptcheck=checked(31) directives=checked(50) posix=checked(5)`，退 0、stderr 为空；扩权后的六个码在**全仓 40 个 shell 文件**上跑一遍 `files=40 red=0`；`smoke/01` 退 0 且 `ci_pin=29 gitattr=checked gitignore=checked skill_modes=checked`。`ci.yml` 的摘要 grep 同步要求 `directives=checked\([1-9][0-9]*\)`——否则一个新部署可以让 `directives=checked(0)` 悄悄过去。
    - **本轮最后一轮自审抓到的、我自己新代码里的缺陷（已修，两个方向都实测）**：`checked(N)` 的 N 第一版报 78，而独立重数（Python 逐行正则，同文件集）只有 47（重排注释后的树上是 50 对 81）。差值 31 恰好等于**无候选文件数**：命令替换为空时 here-doc 仍留一行空行，`while IFS=: read` 于是对每个无候选文件各迭代一次**幻影空行**，每行还真的跑两次 shellcheck。后果两层：① 摘要 token 声称的「候选行数」是 47 真 + 31 假；② 更要紧的是那道 `checked(0)` 守卫——它的存在理由就是「枚举器瞎了」——**在幻影计数下永远不可能触发**。实测（复刻旧循环形状 + 把枚举器换成 `:`）：`directives=40`，守卫**不**触发；修法（`[ -n "$candidate_line" ] || continue`）之后同一盲枚举器得到 `directives=0`，守卫与枚举器自检同时报红、退 1。顺带实测掉一个我先写下又推翻的断言：`IFS=: read` **不会**在第二个冒号处截断——POSIX 规定多余字段连同其间的 IFS 字符一起给最后一个变量（实测 `# Why the shellcheck lock: measured on 0.11.0, second: colon` 整行到手），所以切分写法是风格改动，不是缺陷修复；注释已按实测改写。
    - **边界**：① 探针问的是「这一行**整体**作为指令有问题吗」，所以它证明的是**这些具体行**不缩小锁、不中止解析，**不证明**每个文件的整段文本都被 lint 过（等价说法：它不替代「把整个文件喂给工具」这件事——那件事由主锁做）。② `--norc -S style` 挡住已知的三条外部通道，但 shellcheck 未来新增的配置来源不在覆盖内。③ `directives=checked(N)` 的 N=50 是**今天**的候选行数，会随注释增减而变——它是一道「枚举器没瞎」的活口，不是常量断言（而它本身此前是坏的，见下一段）。④ 本轮揭示的是**静态锁**的可被关闭性；**行为层**（真正执行那份资产并比对退出码）不受这些指令影响，所以这不是「检查全废了」，而是「一层锁被静音、而没有人会发现」。

  - **第三十三类（2026-10-26 同一轮）：两处「只锁了一半」的保护——`.editorconfig` 的资产段有三个键、检查只读了一个；`skill/` 的索引文件模式从未被断言。**
    - **怎么找到的**：沿用第三十一/三十二类的同一个问题——「文档与配置里写下的保护，哪一条真的有人读」。`.editorconfig` 的 `[skill/assets/**]` 段有三行（`end_of_line = unset`、`trim_trailing_whitespace = false`、`insert_final_newline = unset`），而 `smoke/01` 的 `asset_protection` 只匹配 `*end_of_line*unset*` 这一行。CLAUDE.md 另有明文一句「**不要**把 `skill/assets/` 下的文件设成可执行后提交——`install-agentq.sh` 刻意保持 644」，而全仓没有任何检查读索引模式（`grep ls-files -s` 零命中）。
    - **红证（`.editorconfig`，四条，全部实测）**：删掉 `trim_trailing_whitespace = false` → 全绿；删掉 `insert_final_newline = unset` → 全绿；把 `trim_trailing_whitespace` 翻成 `true` → 全绿；把 `insert_final_newline` 翻成 `true` → 全绿。对照：把 `end_of_line = unset` 翻成 `lf` → **退 1**（那一行有锁）。同一段里一行有锁、两行没有，是本仓反复修的「半锁」形状——幸存的那行让检查保持绿色，读起来像整段都守住了。
    - **红证（索引模式，两个方向都实测）**：`git update-index --chmod=+x skill/assets/unix/install-agentq.sh`（CLAUDE.md 明文禁止的那个状态）→ `smoke/01` 与 `--quick` **都退 0**；`--chmod=-x skill/assets/unix/agentq-server` → 同样全绿，而新克隆会得到一个**跑不起来的服务端**（安装器的 `cp` 复制源文件模式，后面的 `chmod 700` 只作用于 `cp` 之后的暂存副本）。
    - **修法一（`.editorconfig`）**：把 `asset_protection` 从「一行匹配」改成「三个键逐个比对期望值」，键值由一个小 awk 抽取器读（读段内**最后一个**值、不跨段、缺键返回空）。段本身仍用既有的 `pattern_matches_under` 找，所以「段被改名但等价」的情形保持绿色。抽取器自带三向自检：读最后一个值（`first`/`second` → `second`）、不读邻段（`b/**` 的 `other`）、缺键返回空。**为什么不是文本 grep**：`trim_trailing_whitespace = false` 的反面是 `true`，`grep -q 'trim_trailing_whitespace'` 对两个值都命中——判据必须是**值**。
    - **修法二（索引模式）**：`smoke/01` 新增 `skill_modes` 臂，oracle 是 `git ls-files -s`（**索引**，不是工作树——`core.fileMode=false` 让工作树位对 `git status` 隐形，而索引仍带着它）。期望集合写成两张显式清单而不是「今天长什么样」：8 个可执行（两个 POSIX 客户端、`install-client.sh`、两个 `.bash` 启动器、`unix/agentq`、`agentq-server`、`windows-git-bash/agentq`），其余必须 644。判据用**精确行匹配**而非子串——`skill/assets/unix/agentq` 是 `skill/assets/unix/agentq-server` 的前缀，第一版用 `*"$path"*` 会把前缀当命中，自检四向（前缀对、服务端本体、`.service`、`x/` 前缀路径）当场钉住。另加枚举闸门（`ls-files` 失败或零行即拒绝报通过）与下界（≥25）。
    - **红证（锁之后，四条）**：`install-agentq.sh` → 755 → 点名并退 1；`agentq-server` → 644 → 点名并退 1；`.editorconfig` 删/翻那两个键 → 各点名并退 1；还原后 `skill_modes=checked`、`configpaths=3`、全绿。
    - **边界**：索引模式只证明**新克隆会拿到**什么模式，不证明本机工作树的位（安装器会在部署时自行 `chmod`，所以工作树位不影响部署结果）；`.editorconfig` 臂只证明这三个键的值，不证明某个具体编辑器真的遵守它（那需要一个真实编辑器实现——本轮用 py-editorconfig 0.17.1 做过一次人工核对，三个键在 `skill/assets/` 下都解析出来，段外的文件解析成 `lf`/`true`，但**检查本身不依赖它**，所以这条核对记在这里而不是进套件）。

  - **第三十二类（2026-10-26 同一轮，紧接着第三十一类）：`.gitignore` 是「凭据不进仓库」的执行机制，而没有任何检查读它——删掉整个文件，套件全绿。**
    - **怎么找到的**：第三十一类修完 `.gitattributes` 之后，我按同一句话往下问：「仓库里还有哪些写在文档里的保护机制，本身没有任何检查守着」。`.gitignore` 是 CLAUDE.md 明确点名的那个——「`.gitignore` 用机制挡住凭据落库……`CLAUDE.md` 的凭据规则此前只是一句话，现在是可执行的」。全仓只有两处**注释**提到它（`smoke/16` 解释 `.pyc` 排除时引用、`smoke/01` 的 farm-write 注释），没有任何一处读它的内容。
    - **红证（先测再改，两条都实测）**：① `rm .gitignore` → `smoke/01` 与 `smoke/16` **都退 0**；② 把 `agentq-askpass.*` 收窄成 `agentq-askpass.tmp` → 同样全绿。第二条尤其要紧：POSIX 客户端真实的 askpass 临时文件是 `agentq-askpass.<random>`（`client/unix/agentq:607` 经 `make_client_temporary_file` 建），所以这一改**恰好重开该模式存在的那个泄漏**——一个密码认证场景下必然产生的凭据文件重新变成可提交。
    - **同形的第二个缺口**：三个保护文件（`.gitignore`/`.gitattributes`/`.editorconfig`）从索引移除后也全绿——工作树副本还在，所有断言照过，而新克隆里根本没有它们。实测：`git rm --cached` 三者各一次，`smoke/01` 三次都退 0。这比「文件内容被改坏」更安静：改坏至少在本机可见，untrack 只在别人的克隆里可见。
    - **修法（`smoke/01` 新增 `gitignore` 臂）**：oracle 是 `git check-ignore`，它对**不存在的路径**也作答（实测：`--no-index` 下一条不存在的 `certs/nope.key` 报出 `*.key` 与 `certs/`），所以 41 条凭据夹具**不落任何文件**。两条守卫保证答案说的是**本仓库**而不是这台机器：`-c core.excludesFile=/dev/null` 摘掉开发者的全局忽略文件；匹配来源必须是 `.gitignore`（`-v` 打印来源，实测 `.git/info/exclude` 与全局文件各自署名；两者都设了同一个模式时 `.gitignore` 胜出，所以判据只看来源字段）。反向五条：`notes-about-askpass.md` 钉住文件自己注释里说的「刻意按名锚定」（裸 `*askpass*` 曾静默吞掉普通文件）、`sub/out`/`sub/err` 钉住 `/out`/`/err` 的**根锚定**（`sub/out` 实测不被忽略）、`README.md`/`skill/SKILL.md` 是普通对照。
    - **两个额外闸门**：① 三个保护文件必须**被跟踪**（`git ls-files --error-unmatch`）；② **无任何已跟踪文件被 `.gitignore` 命中**——用 `--no-index` 做全量扫描，因为 git 对已跟踪文件豁免忽略规则（实测：`skill/` 加进 `.gitignore` 后，不加 `--no-index` 的 `check-ignore skill/SKILL.md` 退 1，加了才退 0），不加这个旗标宽模式会隐形。红证：`skill/` 加进去 → 25 个跟踪文件逐个点名。
    - **自检四向**：一个 scratch 仓里 `.gitignore` 有 `*.secret`、`.git/info/exclude` 有 `*.excluded`，分类器必须分别答 `.gitignore`、`none`、`.git/info/exclude`；第四个探针把**非仓库目录**当根，必须答 `error` 而不是二选一——`git check-ignore` 在仓库外退 128，把它读成「没被忽略」会让一台 git 坏掉的机器看起来像「所有凭据都没保护」。自检放在 git 可用分支**之内**：没装 git 时整个臂报 `skipped(no-git)` 走 PART 桶，而不是把环境故障记成资产坏（pwsh-unusable 那类教训的 git 版）。
    - **红证汇总（四条，全部实测）**：删 `.gitignore` → 41 条逐条点名「no longer ignored」并退 1；收窄 askpass 模式 → 精确点名 `agentq-askpass.9fXq2` 并退 1；untrack `.gitignore` → 点名「not tracked」并退 1；`skill/` 宽模式 → 25 个跟踪文件逐条点名并退 1。还原后 `gitignore=checked`、全绿。
    - **边界**：只断言 `.gitignore` 里**已经写下**的模式仍在生效，不证明它列全了所有该列的凭据形态（新的凭据形态出现时没人会自动加一行——与第三十类的 token 清单同一个边界）；`.git/info/exclude` 与全局忽略文件被刻意排除在「保护」之外（它们不进仓库，别人的克隆没有），所以本臂证明的是「克隆后仍有效」，不是「本机现在安全」；`check-ignore` 的模式语义（`**`、`!` 取反、目录锚定）由 git 解释，本臂不重建那套语义，只读它的结论。

  - **第三十一类（2026-10-26 同一轮）：`.gitattributes` 里被断言的两个属性值，有一个是我凭想象选的——真正的合并保护是 `-merge`，它从未被设置。**
    - **怎么找到的**：上一轮给 `smoke/01` 加 `gitattr` 臂时，我断言了两件事：25 个部署文件的 `text` 必须解析成 `unset`，两份 canonical 服务端副本的 `diff` 必须解析成 `unset`。第二件事的理由写在失败消息里——「`-diff` 挡住三路文本合并，否则可能只改写一份」。写文档前我按本仓纪律先测这句话：**它是假的**。
    - **实测（git 2.55.0，全部在 `/tmp` 的 scratch 仓里）**：① 只设 `-text -diff` 时，两个分支各改同一文件的不同行 → `Merge made by the 'ort' strategy`、两处修改都在、**静默自动合并**；② 设 `-merge` 后同一场景 → `warning: Cannot merge binary files` + `CONFLICT (content)`，合并被拦下；③ **单侧修改在两种设置下都干净合并**，所以 `-merge` 不会制造假冲突。`-diff` 的作用只是让 `git diff` 把该文件显示成二进制（`Bin 20 -> 20 bytes`）。`.gitattributes` 头注释里那句「`-text` 也阻止 git 把文件当文本做 diff/merge」同样被推翻：`-text` 只影响换行转换与文本判定，合并策略看的是 `merge` 属性。
    - **真实的字节保护是有效的，但此前无人断言它的具体形态**：删掉 `* -text` 后，25 个已跟踪部署文件里有 **10 个**解析成 `text: unspecified`（`SKILL.md`、`agents/openai.yaml`、`client/unix/agentq`、`client/unix/sshp`、`unix/agentq`（60 字节 wrapper）、`unix/agentq-pueued.service`、两个 `.plist`、两份 `pueue.yml`）——按扩展名的四条规则只覆盖 `.sh/.bash/.ps1/.cmd`。实测两种转换：`core.autocrlf=true` 下把 60 字节 wrapper 检出成 `#!/bin/sh\r`（第一行就带 CR）；`core.autocrlf=input` 下工作区是 CRLF 的文件入库成 LF（`od` 逐字节对比，`0d 0a` → `0a`）。真实树里这 10 个文件当前 CRLF 计数全为 0，所以今天的仓库没有受损——这条锁保护的是**检出/入库那一刻**。
    - **修法（三处）**：① `.gitattributes` 两份 canonical 副本的规则改为 `-text -diff -merge`，并把两句被推翻的注释按实测重写（`-merge` 才是合并保护，`-diff` 只管显示）；② `smoke/01` 的 pair 臂从查 `diff` 改为查 `merge`，失败消息写明它守的是字节同一性约束；③ 该臂补**记录数闸门**——期望恰好 2 条记录，不足即报「refusing to report a pass」，因为 `check-attr` 在 git 查询失败时（例如路径跑出仓库）会零记录退出，而**对不存在的路径它仍返回一条 `unspecified` 记录**（实测），所以闸门不会把「文件被改名」误判成查询坏掉：改名由值判据点名。
    - **红证（三条，都实测）**：① 把两条 canonical 规则改回 `-text -diff`（去掉 `-merge`）→ 两个文件逐条点名「no longer marked `-merge`」并退 1；② 整条删掉那两行规则 → 报 2 条、退 1（值判据接住，不是闸门）；③ 自检夹具三向——把比较短路成「从不报告」→ 自检报 `got ""` 并退 1；短路成「总是报告」→ 报 `got "a b c "`（`a` 是 `unset`，不该被报）并退 1；还原后 `gitattr=checked`、全绿。
    - **边界**：`-merge` 保护的是 git 的三路合并，不保护任何**非 git** 的改写（部署脚本、编辑器、`sed -i`）；`check-attr` 只报告当前工作树的属性解析结果，不证明历史上提交进去的字节是对的——那需要 `git cat-file` 逐 blob 比对，本仓没做，因为 canonical 约束由 `cmp` 在**检出后**的工作树上直接验证，覆盖更强。另一条边界是 git 版本：实测只在 2.55.0 上做，`merge` 属性本身是 BCL 级的老特性，但 `-merge` 与 `-diff` 的**组合语义**未在旧版 git 上验证。

  - **第三十类（2026-10-26 同一轮）：摘要 token 的三种失效形态——只在失败分支赋值（死代码）、printf 参数被掉、值为空。**
    - **怎么找到的**：第二十九类给 `smoke/01` 加 `ci_pin` 臂时，我在失败分支写了 `ci_pin_summary='failed'`。**上一轮（第二十七类）我刚因为同一个原因撤掉过 `farm_write_summary='failed(scan)'`**——`smoke/01` 在打摘要**之前**就 `exit 1`，失败分支设的 token 永远印不出来。实测：把 `ci.yml` 的清单换成不存在的名字，`smoke/01` 退 1，输出里 `grep ci_pin=` **零命中**。同一类错误我写了两遍，说明它不是疏忽而是一个**可被结构检查抓住的形状**。
    - **另外两种形态**（都实测）：① **printf 参数被掉**——格式串里留着 `ci_pin=%s` 而实参列表少一个，后续所有值右移错位（实测报出 20 个 token「丢失」，因为整行从此读不对）；② **值恒为空**——`ci_pin_summary=''` 且成功分支不再赋值时，行里印出 `ci_pin=`（键在、值空），只查「键是否存在」的判据会放过它。
    - **修法**：摘要行末尾加一条**对打印结果**的锁，而不是对赋值做控制流分析（后者要写 bash 解析器，本仓在第二十一类上已经证明这类判据易错）：声明一份 token 清单（25 个），逐个要求 `" $summary "` 里出现 `" tok="`，**且值非空**（`*" $tok="` 或 `*" $tok= "*` 即视为缺失）。锁放在 `summary=` 之后、失败闸门之前——**第一版放在了闸门之后**，于是它抓到问题却仍然退 0（`failures` 递增但闸门已经过了）。这个顺序错误也是实测出来的：丢掉 `ci_pin=%s` 时锁报出 20 个 token 丢失，而退出码是 0。
    - **红证（三条，都实测）**：① 掉 printf 实参 → 报出成串 token 丢失并退 1；② 让 token 只在失败分支赋值/值恒空 → 点名 `ci_pin` 并退 1；③ 顺序错误版（锁在闸门之后）→ 报出问题但退 0，正是它暴露了顺序问题。还原后 `ci_pin=29`、全绿。
    - **边界**：锁只证明「清单里的 token 都带非空值印在行上」，不证明每个值的**含义**正确（一个永远印 `0` 的计数器是通过的）；清单本身要人维护——新增 token 时忘了加进清单，这条锁看不见（与第二十一类「两份枚举」同形，区别是这里的清单只有一份）。  - **第二十九类（2026-10-26）：新增一个检查文件时，本地套件比 CI 绿——`ci.yml` 的检查名清单只在 CI 侧生效。**
    - **怎么找到的**：核对 `.github/workflows/ci.yml` 里那条 `expected_checks='…'` 时问了一句「本地有对应的比对吗」。没有：CI 在 `run-tests.sh` 之后 grep `smoke.log` 的 `^(ok|SKIP|PART|NCOV|FAIL) +NN-` 集合与写死的 29 个名字比对，**本地的 `run-tests.sh` 与 `smoke/01` 都不知道这份清单存在**。
    - **实测（种入 `smoke/30-probe-new-check.sh`）**：`smoke/01` **退 0、全文零次提到它**，`run-tests.sh` 把它算进 `ran` 得 30 —— 开发者看到的是满绿，第一个反对的是 CI。这把「本地先发现」这件事反了过来：新增检查本该是最容易忘的一步（忘了加进 `ci.yml`），而恰恰只有最远的那道闸会响。
    - **同一形状的第二个方向**：清单里留着一个己经删掉的检查名（`30-ghost`）同样只在 CI 红；清单整个被删掉则 CI 的 `grep -qE '^PASS checks: …'` 之外什么都不剩。
    - **修法**：`smoke/01` 新增 `ci_pin` 臂，直接用 python 读 `ci.yml` 的 `expected_checks` 与 `smoke/*.sh` 做**集合比对**，两个方向都报（有文件没登记、有登记没文件），清单缺失或任一侧为空报「refusing to compare」而不是跳过。摘要加 `ci_pin=29`。
    - **红证三条（实测）**：种入 `smoke/30-probe-new-check.sh` → 点名「exists but ci.yml's expected_checks does not list it …」并退 1；把 `30-ghost` 加进清单 → 点名「lists 30-ghost but smoke/30-ghost.sh does not exist」并退 1；把整条 `expected_checks='…'` 删掉 → 「ci.yml has no expected_checks='...' pin」并退 1；还原后 `ci_pin=29`、全绿。
    - **边界**：只比对**集合**，不比对 ci.yml 里其余的钉（三个 token 枚举、NOT-covered 白名单、`0 partial` 判据）——那些是行为性的，只能在 CI 上真跑；本臂不证明 workflow 其余部分正确。缺 pyyaml 时该臂报 `skipped(no pyyaml)` 走 PART。
  - **第二十八类（2026-10-25，同一轮继续自查）：`smoke/26` 是唯一一个真的依赖 python3 却没有可用性探针的检查，头部注释还把依赖说错了。**
    - **怎么找到的**：第二十七类给 `smoke/01` 加探针时，顺手把「哪些检查用 python3、哪些探了」做了一次全量普查（`grep` 出 11 个文件命中，逐个看是不是真依赖）。`smoke/23` 的命中**只是注释**（它已改为 awk 抽取，注释里正好在解释这件事）；`smoke/26` 有 **21 处 `python3 - <<PY` 实调用**，一处探针也没有——而它头部第一句写着「No SKIP: this needs only bash, jq and cp」。那句是**错的**。
    - **实测后果**：PATH 上放一个 `exit 49` 的 python3 桩（普通文件，非符号链接——本仓 2026-10-25 那次截断真实解释器的教训），`./smoke/26` **退 49、零输出**。`run-tests.sh` 只能把它报成 `FAIL … exit=49`，与「契约被破坏」无从区分。这正是 `pwsh-unusable` 那一档要修的东西的 python 版：**环境故障被报成资产/契约问题**，而 zh-CN Windows 上 Store 别名是默认形态、本仓 CI 有 windows job。
    - **修法**：① `smoke/26` 加与 08/10/12/14/20/22/29 同形的探针（`python3 -c 'import sys'`，不可用时报 `read-paths NOT run: …` 并给出修法，退 1），并订正头部那句假话；② `smoke/01` 新增**构造级普查锁**——扫 `smoke/*.sh` + `run-tests.sh` + `sandbox.sh`，凡出现「未被注释掉的 `python3 -`」就必须同时出现探针写法，否则点名。摘要加 `python3_users=10`。
    - **为什么判据收窄成 `python3 -` 而不是「出现 python3 这个词」**：这些文件的注释里成天在讨论 python3（本仓的 23 就是纯注释命中）。一条对散文开火的规则一周内就会被关掉。收窄的代价是看不见异形调用，如实记为边界；**普查下界**（`< 5` 即失败）让「正则坏掉、一个都没枚举到」当场红，而不是印一个漂亮的 0。
    - **自检用自己造的夹具，不用仓库里的文件**：四个（裸用=1、带探针=0、不用=2、纯注释=2）。拿仓里的文件当夹具的写法在本仓栽过——红证植入时被测文件自己也在集合里，两个方向同时开火，打出第二份错误诊断。
    - **红证（三条，实测）**：把 `smoke/26` 的探针整段删掉 → 普查点名 `smoke/26-record-read-paths.sh` 并退 1；把普查的使用正则改成永不匹配 → 自检两条 + `python3-census FAILED (only 0 dependent scripts were enumerated…)` 并退 1；加上探针后真实运行 `cases=115`、`smoke/01` 全绿。
    - **第三层（同日继续自查）：「有探针写法」不等于「探针有用」。** 第一版普查只 grep 探针的**拼写**，于是两个假探针都通过：`python3 -c 'import sys' >/dev/null 2>&1 || true`（结果丢弃）与 `... || probe_broken=1` 而 `probe_broken` 从不被读。判据收紧成「探针行必须消费自己的结果」，认三种本仓在用的形态：`if/elif/while python3 …`（条件上下文）、`|| exit …`、`|| VAR=` 且 VAR 在同文件后文被读。红证用**真实文件变异**：把 `smoke/26` 的探针改成 `|| true` → 点名；把 `if [ "$python3_probe_status" -ne 0 ]` 改成 `if false`（变量设了不读）→ 同样点名。
    - **收紧判据时先被自己的规则打了一次（假阳性，如实记录）**：新判据立刻点名 `smoke/01` 自己。两处原因，都在判据不在资产——① 探针正则没锚住闭合引号，`python3 -c 'import sys, yaml'`（YAML 探针）被当成可用性探针；② **规则扫到了自检夹具自己的文本**——本文件的夹具是用 `printf '#!/bin/sh' "python3 -c 'import sys' …"` 写出来的，那些行看起来就是探针。修法：正则加闭合引号（`'import sys'` 整词），并跳过以 `printf`/`echo` 开头的行（那是被**写出**的夹具文本，不是会运行的探针）。**这条是「检查把自己当成被测物」的又一例**，与 R6 注释自命中、`$profile` 规则扫到自身注释同族。
    - **边界**：判据是行首非注释的 `python3 -`——经变量间接调用（`$PY`）、`python3 script.py` 带文件名、或写在 `$( )` 里换行的形态看不见；探针消费判据认的是三种形态，`|| { …; }` 分组、把状态存进数组、或经函数返回的写法看不见；`printf`/`echo` 前缀的豁免意味着「用 printf 构造真探针」的写法会被漏掉（当前仓库没有）；普查下界只证明「至少枚举到 5 个」，不证明枚举完整。
  - **第二十七类（2026-10-25，本轮收尾自查）：新分类器自己就带着「空枚举读成干净」的缺口，而调用方还用 `|| true` 把它的退出码吞了。**
    - **怎么找到的**：写完第二十六类的 `is_derived_bytecode` 之后，我拿 `smoke/01-farm-write.py` 直接对着 `/tmp` 里的空目录、一个不存在的路径、以及 `/` 各跑了一次——**三个都退 0、零输出**。`walk()` 在目录不存在时 `os.walk` 只是空迭代、`os.path.isfile` 只是假，于是「一个文件都没扫」与「扫了 40 个文件全干净」共用同一个判决。而 `smoke/01` 的调用是 `$(python3 … 2>/dev/null || true)`：退出码、stderr 一起丢，`farm_writes=0` 照印。这是本仓自己反复修的同一类（`smoke/16` 的 `tree_scanned -eq 0`、`smoke/01` 的 `shell_count -eq 0`、`workflow_count -eq 0` 全是它），只是新的分类器没有继承。
    - **为什么这比看起来严重**：`farm_writes=0` 是**新加**的锁，它的价值全部来自「它真的扫过那 40 个脚本」。一个空枚举会让它永久全绿，而摘要行读起来与真扫过一模一样——这正是 2026-10-13 那次「`files=` 计数照涨、含 NUL 的文件对七条规则隐形」的同形。
    - **修法（三处）**：① `walk()` 改为产出 `(path, group)`，`scan()` 按 `entry`/`smoke`/`assets` 三组计数，**任一组为空即退 2** 并说明是哪一组——分组而不是只数总数，因为「总数 40、但 assets 一个都没扫到」这种半坏必须也能报出来；② `smoke/01` 不再 `|| true`：`rc` 进 `case`，`0|1` 之外（2=空枚举、127=解释器不在、其它=崩溃）打 `farm-write scan FAILED (exit N)` 并把分类器 stderr 转出来，计一次失败；③ 加 **python3 可用性探针**（`python3 -I -c 'pass'`，不是 `command -v`——zh-CN Windows 上 Store 别名存在但退 49），不可用时摘要报 `farm_writes=skipped(no-python3)` 走 PART 桶，**而不是**把环境故障报成「分类器坏了」——这是 pwsh-unusable 那条教训的 python 版。
    - **自检把闸门也钉住**：`--self-test` 现在用**出货的 `scan()`** 跑两棵树（空的、只有两个入口点的），两者都必须退 2；另有 `tree_checks < 2` 的清单守门。红证四条：去掉空枚举闸门 → 自检报「empty tree: expected rc 2 …, got 0」并退 1（`smoke/01` 随之退 1）；把闸门改成永远触发 → 自检报「entry-points-only tree…」且真实树上 `smoke/01` 打 `farm-write scan FAILED (exit 2 …)` 并退 1；PATH 上放 `exit 49` 的 python3 桩 → 摘要 `farm_writes=skipped(no-python3)`、`smoke/01` 仍退 0（PART 而非 FAIL）；还原后 `farm_writes=0`、`smoke/01` 退 0。
    - **写作中自己踩的一处**：第一版给失败路径加了摘要 token `failed(scan)`，想让「扫失败」与「扫干净」不共用 `0`——但 `smoke/01` 在打摘要**之前**就 `exit 1` 了，那个 token 永远印不出来，是死代码，已撤。
    - **同日的第三层（退出码语义）**：分类器的契约写着 `0`=干净、`1`=有命中、`2`=空枚举/自检不一致，而调用方 `case 0|1` 把它当成功——**但 Python 的 `SyntaxError` 与任何未捕获异常也都退 1**。实测植入一个只在真树上触发的 `RuntimeError`（`--self-test` 不 walk `skill/assets`，所以自检照样绿）：分类器崩了、退出码 1、stdout 空，`smoke/01` 结论是 **`farm_writes=0` 全绿**。两层修：① 分类器把未捕获异常映射到**独立退出码 3**（`except BaseException` 打 traceback 后 `sys.exit(3)`，`SystemExit` 放行），② 调用方加规则 **「退 1 必须伴随非空 stdout」**——`SyntaxError` 在解释器里就死了、进不到 ① 的处理器，只有这条能接住。红证两个方向：植 `RuntimeError` → 分类器退 3、`smoke/01` 打 `farm-write scan FAILED (exit 3)` 并退 1；植语法错 → 分类器退 1、`smoke/01` 打 `farm-write scan FAILED (exit 1 with no output …)` 并退 1；把 `smoke/11` 一处改回 `cat >`（真命中）→ 仍走「repo script FAILED」路径、`farm_writes` 非 0，两种失败不混。
  - **第二十六类（2026-10-25 同一轮收尾）：一个 git 忽略的派生产物能把整轮套件降成「部分验证」——`run-tests.sh` 的 PART 判据是输出里出现 `skipped` 这个词，而 `smoke/16` 用它来如实报告二进制文件。**
    - **怎么找到的**：全量套件 U 的判决行是 `29 ran, 0 skipped, **1 partial**, 0 failed`，而 `smoke/01` 自己的摘要行全绿。差别在于：错误的那一半在 `run-tests.sh` 的桶判据里——`grep -qi 'skipped'`（第 87 行）不看语境，只要输出里出现这个词就把整个检查归入 PART。命中的是 `smoke/16` 的一行：`skipped a file that looks binary by NUL bytes (it could hide a text leak): smoke/__pycache__/01-farm-write.cpython-314.pyc`。
    - **那个 `.pyc` 是谁写的**：**我自己**。本类之前那几轮开发中我 `import` 过 `smoke/01-farm-write.py`（想复用 `analyse()` 做验证），CPython 就把字节码写进了 `smoke/__pycache__/`（mtime 19:24，套件跑到一半）。它与仓库内容的正确性毫无关系，且 `.gitignore` 早已声明 `__pycache__/` 与 `*.pyc` 永不入库（规则六十四条起）。
    - **为什么这是个**缺陷**而不是「清一下就好」**：清掉只会让下一次 `import` 把问题带回来，而症状是**判决行变化**——同一个提交、同一份资产，有人算出全绿、有人算出 1 partial，取决于他有没有 import 过那个辅助文件。这与本项目反复纠正的「环境状态混进检查判决」是同一类（对照：`smoke/01` 的 `tool_full=6/6`、pwsh 的 `skipped(pwsh-unusable)` 分档）。更糟的方向是：为了让它闭嘴，最省事的做法是把 `skipped` 那行删掉或改词——那正好毁掉 2026-10-13 第四轮审查加这条报告的理由（「一个含 NUL 的文本文件会对七条规则全部隐形，而 `files=` 计数照涨」）。
    - **修法**：`smoke/16` 新增出货判据 `is_derived_bytecode()`（`*/__pycache__/*` 或 `*.pyc`），在树遍历里**先跳过它再走 NUL 判断**。跳过的理由是具体的而不是「噪声太多」：每个 `.pyc` 都编译自一个**walk 会扫的** `.py`，而 `.gitignore` 声明这一类不可提交。**没有**用 `-not -name '*.pyc'` 直接改 `find`——那样判据散在 `find` 的一行里，无法被自检调用；这里要的是**一个可被双向钉住的函数**。
    - **双向自检（`expect_bytecode`，与既有的 `expect_path` 同形）**：derived 方向三条（`smoke/__pycache__/01-farm-write.cpython-314.pyc`、按绝对路径的嵌套缓存、`__pycache__` 之外的孤立 `.pyc`），scanned 方向五条（`.py` 源文件本身、按绝对路径的源文件、检查自己、`notes.pyc.txt` 这种只以 `.pyc.txt` 结尾的名字、`__pycachex__/a.bin` 这种只是长得像缓存目录的名字）。**为什么两个方向都要**：放宽成 `*.py` 或 `*` 时上面所有地址样本仍然全绿，只是含 NUL 的文本文件不再被报。
    - **红证（四条，实测）**：① 判据放宽成无条件 `return 0` → 自检点五条「covers … but must not」并退 1；② 判据收窄成无条件 `return 1` → 自检点三条「misses …」并退 1；③ 在 `smoke/` 下放一个含 NUL 的非缓存文件 → **仍被报告**（`skipped a file that looks binary`），证明排除没有顺手放过整类；④ 同一个含 NUL 文件放进 `smoke/__pycache__/` → 静默，证明排除真的生效。还原后 `./smoke/16` 退 0 且无 `skipped` 行。
    - **边界**：`git add -f` 强加入库的 `.pyc` 会对内容扫描隐形——它编译自 walk 会扫的源、且 `.gitignore` 声明该类不可提交，记为接受的边角；判据是路径字符串匹配，`__pycache__` 之外改名的字节码缓存（`python -m compileall -b` 的同目录 `.pyc`）由 `*.pyc` 那一臂覆盖，但用别后缀命名的缓存看不见（当前仓库没有该形态，也不产生）。
  - **第二十五类（2026-10-25 同一轮）：夹具沿符号链接写桩会截断它指向的真实二进制——本类同时记录一次对开发机的真实损坏。**
    - **发生了什么（如实记录）**：为验证「缺 pyyaml 时 `smoke/01` 报 skipped 不报崩溃」，我在临时目录建符号链接农场，把 `python3` **链接到真实解释器**、再 `cat >` 写桩。`>` 跟随符号链接，写入穿过链接把 Homebrew 的 `python3.14` 二进制截断成 300 字节桩。此后约 40 分钟该机每次 `python3` 退 0、零输出、零副作用——`raise SystemExit(7)` 都退 0——我一度把「桩正常工作」与「解释器健康」两个假象同时当成证据（期间做出的 skipped 结论全部无效，已用安全夹具重做）。
    - **恢复**：该文件后来被恢复为原始字节（sha256 与同 keg 未受损的 `Python.app/…/MacOS/Python` 逐字节一致；`mtime=08-14`、`ctime=13:40:31`，`cp -p` 形态）。**恢复动作不是我做的**，机制未查明——记为未闭合的环，不当作已解释的事实。
    - **仓库侧同类前例**：`smoke/11` 的 `stub_linux` 注释记录了 Linux 主机上 `cat >` 穿过链接写向 `/usr/bin/loginctl`（Permission denied）。两处同一个形状：**复制循环里的手写排除 case 与下方字面 `cat >` 是一对约定，配错即开火，且没有任何东西守着这对约定**。
    - **修法**：① `smoke/11` 新增 `write_stub()`——目标若是符号链接**先 unlink 再写**（桩永远落成普通文件、农场条目被替换而非跟随），若是普通文件则**拒绝覆盖**（那意味着已经有东西写过那里，静默替换会把那次写藏起来）；十个 `cat > …<<STUB; chmod 700` 站点全部改用它。② 新增独立分类器 `smoke/01-farm-write.py`（`smoke/01` 以 `python3 -I <file>` 调用，644 入库即可执行位不必）+ `farm_writes=0` 摘要 token；自检是**双向夹具**（farm+裸写必须开火；`write_stub`、单条具名链接、深路径必须沉默），且**跑的就是出货的分类器本身**——第一版把夹具内联在 shell 里、复刻了一份规则，我禁用真分类器的比较后它照样绿，夹具自检必须测被测物。③ 分类器自带「夹具清单守门」：删掉一条夹具或去掉一个方向 → 退 2（改名那条夹具的第一版守卫 `case not in names` 判据写错没抓住，换成计数+方向判据后红）。
    - **精确性优先于覆盖面**（都实测过）：农场判据是「**两个分量都是变量的**链接目标 `"$D/$X"`」——link-everything 惯用法的产物。第一版把任何符号链接目标都当农场，`smoke/05`/`smoke/18` 里每个普通的 `> "$work/out"` 全被点名；一条爱叫狼的锁一周内就会被关掉。`build_stub_path` 这类「循环在函数里、目的地来自 `$1`」的形态也认（调用点的 `"$VAR"` 实参记为农场）。
    - **别名曾经是盲区，现已补上（2026-10-25 实测）**：`smoke/11` 有三处写桩走的是 `for stub in "$stub_bare" "$stub_pkgmgr" "$stub_full"` 的**循环别名**（`write_stub "$stub/uname"`）。把 `$stub/uname` 那处改回 `cat >` 时锁**沉默**（实测 exit 0、零命中）——一把在仓库真正使用的写法上不开火的锁保护不了任何东西。现在 `analyse()` 做别名传播并迭代到不动点：`for X in ...` 的某个词**恰好**是 `$已有农场` 时把 `X` 记为农场；`X=$农场`（含 `local`/`export`/`readonly` 前缀）同理。**刻意窄**：`"$A"/*` 是 glob 不是农场（有一个字面分量、展开后指向真实文件），夹具里有 `glob-over-farm` 一条必须沉默。夹具从 5 条扩到 8 条（新增 `via-loop-alias`、`via-alias-assignment` 必须开火，`glob-over-farm` 必须沉默），守门阈值同步。
    - **修别名时自己写错一次**：第一版把循环变量以**裸名**（`stub`）存进 farm 集合，而集合里其它元素是 `$stub` 形态，于是传播看起来生效、实际一个都不匹配——`hits` 为空、自检却绿（因为它的夹具走的是函数那条路）。是「把真实文件改为 `cat >` 后锁仍沉默」这条**端到端红证**抓出来的，不是单元夹具抓到的：单元夹具自测的是 `analyse()` 的返回值，而这次错在两个集合的**键形态**不一致。教训与第二十一类同族——**判据自检通过不等于判据在真实输入上工作**。
    - **边界**：单行正则不是 bash 解析器——跨行续写的 `ln -s \` + `"$D/$name"` 看不见（当前树里没有该形态）；`printf > "$farm/x"` 这类非 `cat >` 的写同样被 REDIR 抓到（判据是重定向不是 `cat`）；别名只认「词恰好是 `$X`」与「赋值右侧恰好是 `$X`」，`${X}` 花括号形态、数组、`x=$A/sub` 这类带后缀的赋值看不见。
  - **第二十四类（2026-10-25 同一轮）：仓库自己的入口点（`run-tests.sh`/`sandbox.sh`）与 CI workflow 不在任何解析范围内。**
    - **怎么找到的**：第二十一类把「按文件名枚举」改成按 shebang 判定后，我顺手问「那两份驱动脚本自己呢」。答案是没有：`smoke/01` 的解析臂 scope 是 `skill/assets`，`run-tests.sh` 的 `bash -n` 只作用于**它即将运行的检查**。
    - **最严重的那条实测**：在 `run-tests.sh` 的 `verdict=` 行前植入 `if [ 1 = 1 ]; then :`（未闭合）→ `bash -n` 退 2，而 `./run-tests.sh --quick` **退 0，stdout 上一条 `PASS checks:` 都没有**。机制：bash 读到 EOF 时停在未终止的复合命令上，那个 `if` 从未执行，于是脚本末尾的 `exit 0` 照常返回；唯一痕迹是 stderr 一行 `syntax error`。CI 的判据是 grep stdout 的 `^PASS checks:`，所以 CI 会红——但**本机跑的开发者只看到 exit 0**，而且 0.1.19 之前的套件在被 `pkill -9` 后正是这个形态（我曾把 mktemp 的崩溃当成「环境故障」，同一种误导）。
    - **`sandbox.sh` 同形**：只坏 `up)` 分支时 `sandbox.sh status`/`down` 都退 2（这两个分支会走到解析错误），但把错误放进一个**不会被走到的分支**（例如 `status` 之后）则退 0。
    - **workflow 那条**：改坏 `ci.yml` 缩进 → `./smoke/01` 与 `./run-tests.sh --quick` 都退 0。`ci.yml` 钉住 29 个检查名、`shellcheck=checked/scriptcheck=checked/posix=checked` 三个枚举、NOT-covered 白名单；`release.yml` 是唯一把 tag 与 `version` 常量绑起来的闸。GitHub 对不可解析的 workflow 是**直接不运行**——本该抓错的那道 CI 恰好是停摆的那道。
    - **修法**：`smoke/01` 两臂。entry-point 臂 `bash -n` 两个驱动脚本 + 自带夹具自检（一个含未终止 `if` 的临时文件必须被拒）。workflow 臂 `safe_load` + 必须是带 `jobs` 的映射 + 必须有 trigger 键。摘要加 `entrypoints=2 workflows=2`；缺 pyyaml 时 workflow 臂报 `skipped(no pyyaml)`（走 PART 桶，不是静默绿）。
    - **为什么不用已有的 shellcheck 锁**：实测 shellcheck 0.11.0 上仓库用的 `-s bash -i SC2319,SC2034,SC2221,SC2222` **连解析错误一起抑制**——一个含 SC1046/SC1047（`Couldn't find 'fi'`）的文件在 `-i` 下退 0，只有不加 `-i` 才退 1。这条锁是为了「不让新规则红 CI」而收窄的，代价就是瞎于语法错误；`bash -n` 才是这些文件的忠实文法。
    - **写作中自己踩的两个坑（都当场被真实树抓住）**：① **awk 的 `exit` 仍会执行 `END` 块**——frontmatter 抽取器第一版写 `END { exit 3 }`，成功路径的 `exit 0` 被覆盖成 3，**正确文件被报成坏的**（与 smoke/23 抽取器用 `done` 标志防的是同一形状）。② **`set -u` 与探针顺序**——`workflow_count=0` 最初写在 `if python3 -c 'import yaml'` 内部，缺 pyyaml 时摘要行读它直接 `unbound variable` 崩溃；计数器/占位符必须初始化在探针之外。
    - **边界**：`bash -n` 只证明两个入口点可解析，不证明它们的逻辑正确；workflow 臂只证明 YAML 可解析且有 `jobs`/trigger，不证明 action 版本、权限或 step 内容正确（那些只有 GitHub 侧执行才知道）。
  - **第二十三类（2026-10-25 同一轮）：Skill 的两份 YAML（`SKILL.md` frontmatter、`agents/openai.yaml`）不在任何解析范围内。**
    - **怎么找到的**：核对「部署单元是 `skill/` 整目录（CLAUDE.md 写明 25 个文件）」与「检查只扫 `skill/assets/`」的差集。`smoke/01` 的 plist/yml/service 臂全部 `find skill/assets`；`skill/SKILL.md` 与 `skill/agents/openai.yaml` 的 YAML 从未被解析。红证先行：把 frontmatter 改坏（`name: agentq\nbroken: [unclosed`）且把 openai.yaml 改坏缩进，`--quick` 套件仍 PASS——frontmatter 的 `description` 是 Skill 的触发条件，一个未闭合引号或错位键就静默改变它何时被加载。
    - **修法**：`smoke/01` 的 pyyaml 分支加两臂。frontmatter：awk 抽 `---` 之间的体——**抽取器自己必须响亮失败**（首行非 `---` 退 2、未闭合退 3），空抽取绝不能读成「解析通过」；`safe_load` 必须是 dict 且 `name`/`description` 非空。openai.yaml：解析 + `interface` 三键（`display_name`/`short_description`/`default_prompt`）必须非空。文件缺失报错（不存在「没有元数据也行」的状态）。
    - **写作中踩的坑（awk 的 exit 语义）**：第一版抽取器 `END { exit 3 }` 无条件执行——awk 在 body 里 `exit 0` **仍然会跑 END 块**，成功退出被覆盖成 3，正确文件被报坏（自证：`./smoke/01` 退 1 且报 extractor FAILED）。与 smoke/23 抽取器用 done 标志防的是同一个形状。红证四个方向全过（坏 YAML、合法但缺键、无开定界符、无闭定界符），还原全绿。
    - **边界**：`description` 的**内容**无法静态判断（「什么措辞能触发」没有本地 oracle）；这里只锁「frontmatter 是可解析、键齐全的映射」。`.DS_Store` 类 OS 豁免同上一条。
  - **第二十二类（2026-10-25）：`smoke/23` 的 C# 提取器依赖 python3，是本仓唯一没有可用性探针的 python3 依赖。**
    - **怎么找到的**：第二十一类的同一轮，逐文件核对「哪些检查依赖 python3、哪些探了可用性」。12/20/22/29 四个检查都有探针（zh-CN Windows 10 上 Store 别名 exit 49 的实测教训，2026-10-20）；01 的 pyyaml 分支也有；**23 没有**——而 23 恰是 windows CI job 必跑的检查。坏解释器在旧实现里会走「提取出空 C# 体」分支，把环境故障报成检查失败——正是 pwsh-unusable 那类误导的 python 版。
    - **修法选了更小的**：不加深探针，**去掉依赖**——here-string 体用四行 awk 抽取（`Add-Type -TypeDefinition @"` 起、`"@` 行止、剥 CR），awk 本就在 23 里用（ANSI 剥离那处）；抽取失败有显式状态码（2=未见开始标记、3=未见结束标记），不再静默空体。实测 awk 体与旧 python 体**逐字节一致**（3306 B + 末尾换行）；红证：PATH 上放 `exit 49` 的 python3 桩 → HEAD 版 23 退 49、零输出，改后同环境 `cases=8 cs5=compiled` 全绿。
    - **边界**：awk 判据锚定 `"@` 行首，C# 体内若出现行首 `"@`（不是 here-string 结束标记的形态）会提前截断——计数与长度自检（非空 + 编译成功）兜底，且 C# 5 编译本身会把截断体报红。
  - **第二十类（2026-10-24 同一轮，来自一次真实故障）：BSD `mktemp` 只随机化**末尾**的 X 串，两处模板把后缀写在 X 之后。**
    - **怎么找到的**：不是审计出来的，是**撞上的**——一套全量套件在 01 报 `mktemp: mkstemp failed ... File exists`，我第一反应是「临时目录脏了」，查下去发现目录里躺着一个**字面名字**的文件 `agentq-parse-ps1.XXXXXX.ps1`：BSD mktemp 只在模板以 X 结尾时替换，`XXXXXX.ps1` 里的 X 不在末尾，于是它创建了这个名字本身。
    - **为什么平时看不见**：`smoke/01` 用 EXIT trap 删这两个文件，正常退出时干净。**只有 SIGKILL 不执行 trap**——本轮我为了重跑套件多次 `pkill -9`，留下的字面文件让**之后每一次** 01 在第一条断言之前就崩，且报的是 mktemp 的环境错，指向临时目录而不是脚本。
    - **为什么必须修**：这个形态使**一次被杀 = 后续全坏**，而且跨会话持续（文件在 TMPDIR 里，重启才清）。GNU mktemp 接受两种写法，所以 Linux CI 永远不会红——**又一个 Mac-only 形态**。
    - **修法**：模板改为以 X 结尾（`agentq-parse-ps1.XXXXXX`），后缀去掉——实测 `pwsh -File` 不要求 `.ps1` 扩展名。
    - **锁：`smoke/01` `mktemp_suffix=0`**——扫 `smoke/*.sh` + `run-tests.sh` + `sandbox.sh` + shell 资产，判据是「`mktemp` 的模板里 X 串之后还跟着非 X、非引号、非空白、非 `)` 的字符」。**跟随类写错过两次，两次都在真实树上当场叫狼**：① 不带 `X` 时 `[X]{3,}` 只吃 3 个 X、第 4 个 X 成了「后缀」→ 三条假红（含 `smoke/02` 的正确模板）；② 不带 `)` 时 `mktemp -d .../x.XXXXXX)` 全被报 → smoke/04–07 各一条。最终判据在真实树上只剩两处真缺陷，修掉后 `mktemp_suffix=0`。红证：把模板改回带后缀 → 规则点名该行并 exit 1。
    - **边界**：只覆盖 `mktemp` 的模板字面量；模板来自变量（`mktemp "$template"`）的站点看不见——当前仓库没有这种形态。规则对 GNU 系统同样会报（虽然 GNU 接受），这是**刻意的**：同一个脚本要同时跑在两个平台上，统一按最严格的那个写。
  - **第十九类（2026-10-24 同一轮，第四层同心圆）：`Add-Type` 里的 C# 由宿主编译器编译，而这段 C# 从未被任何检查编译过。**
    - **怎么找到的**：here-string 那条线走到 C# 时，先做了文本正则扫 C# 6+ 特征（`$"..."`、`?.`、`nameof`、表达式体成员等）——**先证明了正则本身能在植入的 `$"..."` 上报出**，再扫真体：零命中。但「零命中」只说明没有可见特征，不说明它编译得过。
    - **关键测量**：`smoke/23` 的四个用例全部是**参数校验拒绝**，而 PowerShell 的参数绑定发生在**脚本体之前**——实测一个缺必填参数的脚本连体内第一条语句都不执行。所以这段 `Add-Type` 在本地 pwsh 7 上、在 Windows CI 的 5.1 上**都没被编译过**。本地即使跑合法参数也只会走到 P/Invoke 的 DllNotFound，与编译无关。
    - **为什么这是缺陷类而不是风格**：Windows PowerShell 5.1 的 `Add-Type` 用 .NET Framework 的 **C# 5** 编译器；pwsh 7 用 Roslyn（C# 10+）。一个 `$"..."` 在开发机上编译通过、在每个真 Windows 主机上 `Add-Type` 抛「Feature not available in C# 5」——整条 durable-move 路径全灭，而 `smoke/23` 在 Mac 上全绿。
    - **修法（真 oracle，不是正则）**：`smoke/23` 新增用例——从资产里抽出 `Add-Type` 的 C# 体，在 pwsh 7 上以 `-CompilerOptions "/langversion:5"` 编译。实测这是**同语言版本**：拒绝 `$"..."`（`error CS8026: Feature 'interpolated strings' is not available in C# 5`）与 `?.`（`Feature 'null propagating operator'`），真体则编译通过。两个变异各被点名并 exit 1；还原后 `cases=8 cs5=compiled`。**同一轮抓到自己引入的一个 CI 风险并修掉**：`-CompilerOptions` 是 PowerShell 7 的参数，真 5.1 没有它——在 Windows CI 的 5.1 上直接传会**参数绑定失败**，把正确资产报成 broken。改为按 `$PSVersionTable.PSVersion.Major` 分支：≥6 才加 `-CompilerOptions`；5.1 上裸 `Add-Type` **本来就是** C# 5 编译器，忠实性反而更高。**同轮第二个自伤也被抓住**：路径最初经**环境变量**传给 pwsh，而 MSYS bash 只自动转换**命令行参数**里的 POSIX 路径、环境变量不转——Windows CI 上 `ReadAllText('/tmp/...')` 会报「找不到文件」，把正确资产报成 broken；加 `cygpath -w`（仅当存在）修正。两处都是「在 Mac 上永远绿、只在 Windows job 上红」的形态，靠推演 CI 环境提前发现，未等 CI 报错。
    - **踩到的两个坑，都是「夹具自己坏了」**：① `-Command '<脚本>' <path>` 取 `$args[0]` 在 macOS 上不可靠，且裸 `.cs` 路径会被 LaunchServices 接管（`No application knows how to open URL file:///...`）——第一版把两者都报成「TypeDefinition is null」。改为路径走**环境变量**。② 第一次红证用 `| tail -2` 取退出码，拿到的是 `tail` 的 0——**又一个管道吞码**；重测才得到真正的 `exit 1`。
    - **边界**：`/langversion:5` 匹配的是**语言版本**，不是 **.NET Framework 的 API 面**——C# 里用一个 Core-only API 仍会本地编译通过、5.1 上运行时炸；那类由 `smoke/01` 规则三（.NET API 双运行时）覆盖 PowerShell 侧，C# 侧没有等价静态检查，如实记为边界。
    - **`.ps1` 里的 4 段 shell 体同样没进静态解析臂，本轮判为边界而不加锁**：实测四段（`sshp.ps1` 的 783/876、launcher 的 `runtimeScriptContent`、`install-agentq.ps1` 的 1584）今天 `bash -n` 与 `dash -n` 全为 0，且 launcher 那段**每轮套件都被 `smoke/22` 抽出来在 bash 下真执行**——行为层已经解析它，静态臂的边际价值远低于 PowerShell 载荷那 6 个（后者没有任何本地检查执行过，远端是桩）。同一套判别式的矛盾也记在这里：`install-agentq.ps1:1584` 一段**同时**含 shell 与注释的体，分类靠的是行首标记；把「shell 体也 bash -n」做成臂，等于给判别式加第二条依赖，而它每多一条就多一个漂移点。将来真出现「shell 体带语法错却没人发现」的缺陷时，先修行为层的覆盖，再考虑静态臂。



