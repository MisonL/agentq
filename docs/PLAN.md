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
   其缩小——见第六节的现役口径，2026-10-10 为 391 行 / 27,085 = 1.4%）；另有更大
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

**条目记录在哪**：A 类（A1–A30）的完整记录在 [`plan/a-class.md`](plan/a-class.md)，
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
| C1 | P1-3 整体操作矩阵（**改为三台**、**真实网络中断**；2026-09-22 用户裁定） | **已执行（2026-09-22）**，结果与两个新缺陷见 `CHANGELOG.md`。三台里只有一台跑当前版本。**两项遗留均已消解（2026-09-24）**：① 主机 A 的客户端路径——重装后 `status`/`submit`/`wait`/`logs`/`remove` 五项 exit 0（见 B5-执行）；② 缺陷二已修并验证（见 A6，`smoke/03` 有用例、M3 证明其敏感）。**C1 无遗留** |
| C2 | 平台/安装矩阵（WSL、arm64、RHEL、Fedora、Alpine、真实升级回滚） | **已执行容器可覆盖的部分（2026-09-24，用户全权授权）**，见下；**真实升级回滚 2026-10-07 已补验**（见「C2 补格」）；**WSL2 2026-10-09 已在真机补验**（容器里仍不可伪造，真机可以） |
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
- ~~**WSL 无法在容器里伪造**~~ —— **2026-10-09 已在真实 WSL2 上补做并关闭**。原先的结论
  只说了「容器里伪造不了」，这句仍然成立：安装器读 `/proc/version`，而 runc **拒绝**在
  `/proc` 内 bind-mount（`check proc-safety of /proc/version mount`）。但由此推出的
  「WSL 路径没有证据」是错的——真机上跑得到。载体：一台 Windows 主机上的 **WSL2
  Ubuntu 24.04**（systemd 为 PID 1、`systemctl --user show-environment` 正常、sshd 在
  22、linger 已开）。全新安装 `INSTALLER_EXIT=0`、服务 `active`+`enabled`、
  `doctor` 报 `agentq=0.1.0`；协议面 `submit→wait`=`Success`、`logs` 回读到 token、
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
launcher 端到端，见 W5 条目末；Windows 侧**升级回滚**仍未单独构造）；**WSL 已于
2026-10-09 在真实 WSL2 上补验并关闭**（见上「两格明确不可达」一节——容器里仍不可
伪造，真机上可以）。

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

## 六、执行状态

已完成（本会话）：A1、A2、A3、A4（零授权项），A5、A6（零授权、只改 `assets/`），
A7（零授权、只改 `smoke/`），B2、B3、B4（用户已授权），**C1（三台，用户已裁定范围）**。

**A29 公开仓库标准化（2026-10-08，用户指示）**：用户选定「薄壳加装」路线、公开仓库、
MIT、四子项全做。①②④ 已完成（版本 0.1.0 与 Pueue 4.0.4 拆开并加 `smoke/01` 版本一致性
规则；`LICENSE`/`CONTRIBUTING`/`README`/`CHANGELOG` 头部/`.github` 模板与 `SECURITY.md`）；
③ 的 `ci.yml`/`release.yml` 已实跑：`ci` 三平台全绿（run 37894054291，2026-10-09；首跑三平台全红，
三次失败全是 fixture 的可移植性问题、无一是资产缺陷，逐条见 A29 ③），`release` 在 tag `v0.1.0` 上成功。
**A30（`doctor` 报 AgentQ 版本）已完成**（服务端常量 + doctor 的 `agentq=` 行 + `smoke/03`
逐字断言 + `smoke/01` 扩为四方 + 四份文档同步）。
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
只是转发 shim）。合计 **391 行 / 27,085 行 = 1.4%**（分母 2026-10-10 重算：`skill/assets/` 全部 23 个资产 `wc -l` 之和 = 27,085；上一次 2026-10-07 记的 27,028 此后又被本轮的 wrapper/客户端冲突修复（`install-client.sh` +16、`install-agentq.sh` +22）推高。**分子仍是 391**——本轮改的两个资产都不在这张表里，故未变）。
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
分母已于 2026-10-10 重算为 **27,085**（`skill/assets/` 全部 23 个资产 `wc -l` 之和）。
别再引用旧的 25.9%、13.8%、4.8%、1.6%、1.5%、25,536 或 26,264。
