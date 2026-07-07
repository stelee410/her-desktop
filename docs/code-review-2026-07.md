# Her Desktop — 全面代码 Review（2026-07）

> **进度（2026-07-07）**：批次 1（止血）✅ 全部完成；批次 2（性能）✅ 全部完成（含 P0 状态拆分、P2 的 audit/index 异步写盘）；批次 3 ✅ A3 管线去重、E3a/E3b 类型化、A1/E1 Handler 注册表（三套分发表已收敛）、E2 删除双份 schema、A4b 视图分离、A4d/A4f 种子缝；批次 4 ✅ S3 网络收紧（Host 校验/去通配 CORS/常数时间比较/Referrer-Policy）、E4c manifest schemaVersion。
> **批次 4 补充完成**：✅ E4d usageHint（"何时使用"指引移入 manifest，SystemPromptBuilder 手写 prose 精简为 kind 级不变式）；✅ E4a webapp adapter kind（vibe coding 可产出可运行的 webapp 插件：validator/生成器提示词/draft 管线支持 webapp kind，安装时物化到 webapp 运行时（按 sourcePluginID 更新不重复），调用能力即打开 app，端到端测试覆盖）；✅ E4b MCPClient（会话感知 actor：每 bridge 一次 initialize 握手（容错，纯 JSON-RPC bridge 不受影响）+ tools/list 缓存，executeMCP 走共享客户端）。
> **有意保留（各自独立会话执行）**：A2 AgentTurnRunner + A4c AppEnvironment——纯内部结构重构；P0 拆分已消除其性能动机、fake-LLM 测试已覆盖循环，剩余收益为结构纯度而风险集中在流式/steering 核心链路，不宜在长会话尾部执行。E4b 的"动态工具目录"需要先决定 MCP 服务器注册的配置界面（产品决策）。A4a presentationHint 等出现无头调用方（inbox 后台执行）再引入。stdio MCP 传输可在 MCPClient 同一接口后补充。

> 覆盖五个维度：**架构与分层、可扩展性、健壮性与代码质量、安全与数据安全、性能**。
> 性能维度上一轮已单独成文（[performance-optimization-plan.md](performance-optimization-plan.md)），本文只收录其结论摘要，不重复展开。
> 所有发现均定位到 `file:line`。**改动待你 review 后执行**；文末给出合并后的统一路线图。

---

## 〇、总体评估

| 维度 | 现状 | 一句话结论 |
|---|---|---|
| 架构分层 | ⚠️ 偏离设计 | `docs/her-desktop-architecture.md` 画的是 5 层，实际上 AppViewModel 吞掉了第 2、3 层——它同时是编排器、领域服务、能力路由器和 UI 状态袋（~5600 行能力逻辑在 `AppViewModel+*`） |
| 可扩展性 | ⚠️ 与愿景冲突 | 加一个新能力要改 **6–9 处**；vibe coding 造不出 webapp 类插件（愿景的旗舰场景）；MCP 只有发现没有客户端 |
| 健壮性 | 🔴 有必修项 | 退出泄漏僵尸进程；transcript 解码失败会被空数据覆盖（上次数据丢失事故的同类通路仍开着）；>64KB 输出的 shell 命令必死锁到超时 |
| 安全 | ⚠️ 两个高危 | 生成的后端继承完整用户环境变量（含 API key）；"一直批准"按能力 ID 放行，一次批准 `mkdir` 等于放行后续所有 `shell.run` |
| 性能 | ✅ 已有专项计划 | 根因是 38 个 `@Published` 的巨型 model；P0–P3 见性能文档 |
| 做得好的 | ✅ | 插件打包层（manifest/validator/generator）数据驱动、设计良好；shell 不经 shell 解释器执行；静态文件有穿越防护;原子写；扩展无 `externally_connectable`；SQLite 全参数绑定；审计不落密钥 |

**两条贯穿性的根因**（大部分发现都是它们的症状）：

1. **上帝对象**：所有状态和编排都在 `AppViewModel`，任何领域对象都要 `self.audit(...)`、`self.chrome.xxx`、直接改 `@Published`——这三条边把一切焊死在 VM 上，既不能测、也不能拆、还导致全窗重绘。
2. **字符串驱动的能力体系**：能力 ID 是散落全库的魔法字符串（`inbox.capture` ×10、`agentmem.add` ×8…），行为靠三套平行的 switch/if-else 按 ID 匹配，schema 在 JSON 和 Swift 里各写一份,成败靠标题子串猜测。没有 `Capability` 契约。

---

## 一、健壮性与数据安全（最优先——有实际损失风险）

### R1 🔴 Critical — 退出后泄漏僵尸 node/python/Chrome 进程
- **位置**：`AppViewModel.swift:229-234`（清理全在 `deinit`）、`HerDesktopApp.swift:8-9`
- **问题**：`AppViewModel` 被 `@StateObject` 持有到进程结束，正常退出时 `deinit` 基本不会执行；子进程不随父进程退出。每次退出都留下 webapp 后端、patchright sidecar、监听端口的孤儿进程,越积越多。
- **改法**：加 `NSApplicationDelegateAdaptor` 监听 `willTerminateNotification`，显式调用 `viewModel.shutdown()`（`stopAll()`/`stop()`/sidecar terminate）。不要依赖 `deinit` 做进程清理。

### R2 🔴 Critical — transcript 解码失败被静默当作空对话，随后被覆盖 → 永久丢失
- **位置**：`ConversationStore.swift:127-148`、`AppViewModel+Conversation.swift:59-67,111,132`
- **问题**：`loadMessages` 对损坏/截断的 JSON 会 throw，但所有调用点都是 `(try? …) ?? []`——**解码失败与空对话无法区分**。切换到该对话后 placeholder 进入 `messages`，下一次 `saveSessionSnapshot()` 就把本可恢复的文件覆盖掉。这与上次数据丢失事故同类,现有 `isLoadingConversation` 守卫只挡异步窗口,**挡不住解码错误**。
- **改法**：区分"无文件/空"与"加载失败"。失败时设不可恢复标志、显示 `lastError`、**拒绝对该 id 保存**直到用户处置;绝不用 placeholder 顶替失败的加载。

### R3 🟠 High — `isLoadingConversation` 可能永久卡 `true`，静默禁用所有持久化
- **位置**：`AppViewModel+Conversation.swift:46-74,105-156`
- **问题**：切 A→B 加载中删掉 B → 在途加载任务因 activeID 不匹配提前返回,没人复位 `isLoadingConversation`。此后**每次保存都是静默 no-op**,退出即丢全部编辑。
- **改法**：在 `resetConversationScopedState()`、`deleteConversation`、`newLocalConversation` 开头复位;或改用 per-load token 与 `activeConversationID` 比对,让过期加载不可能留下"保存禁用"状态。

### R4 🟠 High — 子进程管道死锁：输出 >64KB 的命令必挂到超时且截断
- **位置**：`CapabilityRuntime.swift:1133-1163`（shell.run）、`:1254-1284`（command adapter）、`BrowserController.swift:210-227`
- **问题**：进程退出**后**才 `readDataToEndOfFile()`。管道内核缓冲 ~64KB,子进程写满即阻塞、永不退出,只能等 30–120s 超时 SIGTERM。`cat`/`grep` 大文件就中招。
- **改法**：进程运行期间并发排空管道（`readabilityHandler` 累积或后台队列先读）,再等退出。

### R5 🟠 High — 核心持久化路径 `try?` 吞错，用户不可见
- **位置**：`ConversationStore.swift:105,138,193`
- **问题**：`enqueueSave` 是 fire-and-forget `try? saveMessages`——磁盘满/权限失败时 transcript 静默不保存,无 `lastError`、无审计、无重试。鉴于已有数据丢失史,后台保存失败是最该被看见的信号。
- **改法**：失败回主线程设 `lastError` + 审计事件（`session.save_failed`）,考虑有界重试。

### R6 🟡 Medium — 存量数据的次级风险
| # | 问题 | 位置 | 改法 |
|---|---|---|---|
| R6a | 版本不符直接 `return []`——升级格式即静默清空用户数据,无迁移无备份 | `SessionStore.swift:41`、`WorkPlanStore.swift:30`、`ConversationStore.swift:113,132` | `switch version` 迁移;未知版本先把原文件改名 `.bak` 再重建 |
| R6b | `index.json` 损坏 = 无索引,直接重建并覆盖,孤儿化现存 transcript | `ConversationStore.swift:83-107` | 解码失败先备份 `index.corrupt-<ts>.json`,并扫目录重建索引 |
| R6c | 遗留迁移 `try? saveMessages` 失败仍返回"已迁移"索引 | `ConversationStore.swift:181-195` | 确认写成功后才返回;此前保留 legacy 文件 |
| R6d | `audit.jsonl` 一行损坏,`loadAll` 整体 throw,全部审计史不可读;append 非原子 | `AuditEventStore.swift:39-67` | `compactMap { try? }` 跳坏行 |
| R6e | 两个 loopback server `@unchecked Sendable` 名不副实：`listener/router/port` 主线程写、网络队列读,无锁（`BrowserExtensionServer` 是做对了的反例） | `LocalWebAppServer.swift:297-341`、`LocalInboxBridge.swift:179-203` | 补锁或把 start/stop 限定到 `queue`,看齐 `BrowserExtensionServer` |

---

## 二、安全（单用户本地 app 的现实标准）

### S1 🟠 High — 生成的后端继承完整用户环境 + 无沙箱
- **位置**：`WebAppProcessManager.swift:81-86`
- **问题**：`ProcessInfo.processInfo.environment` 全量传给 LLM 生成的 node/python 后端。环境里若有 `HER_AGENT_LLM_API_KEY`/`OPENAI_API_KEY`/`AWS_*`（`ConfigLoader.swift:12-29` 都会读）,生成代码可原样拿到并外发。且无沙箱、无资源限制,以用户全权限跑,能读写整个 home（含 `.her/Config/her-desktop.local.json`）。
- **改法**：改为白名单最小环境（`PORT`、`HER_WEBAPP_*`、`PATH`）;评估 `sandbox-exec` 限定到 app 目录。

### S2 🟠 High — "一直批准"按能力 ID 放行，与参数无关
- **位置**：`AppViewModel+Capabilities.swift:112-120,340-353`
- **问题**：`shell.run` 是**一个**能力,涵盖 `curl/rm/cp/chmod/open`。给一次无害的 `mkdir` 点了"一直批准",后续任意 `shell.run`（含 `curl -d @secret` 外发、workspace 内 `rm`）全部免审。`browserAutonomyGranted` 同型：循环最多 20 轮,浏览器读回的**不可信页面文本**进入模型,注入型页面可驱动后续导航/点击/输入而无人把关。（缓解：集合按对话重置,`+Conversation.swift:150`）
- **改法**：auto-approve 按 `(capabilityID, 参数签名)` 收窄,至少 `shell.run` 永不整体放行;浏览器自治下破坏性/跨源动作仍保留轻量确认。

### S3 🟡 Medium — 网络面收紧（纵深防御）
| # | 问题 | 位置 | 改法 |
|---|---|---|---|
| S3a | webapp token 走 URL query,且接受 `Referer` 里的 token——会进日志/历史,可能随 referrer 泄给第三方后被回放读写 SQLite | `LocalWebAppServer.swift:153-166,355-364` | 只认 `x-webapp-token` 头或 httpOnly cookie;不再从 `Referer` 取 token;HTML 加 `Referrer-Policy: no-referrer` |
| S3b | `api/query` 接受任意 SQL（含写/DROP）,与模型侧 `requireReadOnly: true` 的约定不一致 | `LocalWebAppServer.swift:229-259` | `api/query` 传 `requireReadOnly: true`,写走显式受审路径 |
| S3c | 扩展桥固定端口 8799 + `Access-Control-Allow-Origin: *` + 不校验 Host/Origin——DNS rebinding 可打到,唯一屏障是 token | `BrowserExtensionServer.swift:48,123,188-189` | 校验 `Host`/`Origin` 为 localhost;删掉通配 CORS（扩展的 fetch 不需要）。`LocalWebAppServer` 同样补 Host 校验 |
| S3d | token 比较非常数时间（理论性） | `BrowserExtensionServer.swift:125`、`LocalWebAppServer.swift:158` | 常数时间字节比较 |

**已核实无虞**：shell 参数不经 shell 元字符解释、`find -exec/-delete` 被拦（`CapabilityRuntime.swift:1088-1114`）;扩展无 `externally_connectable`,恶意网站无法 message 它;SQLite 全参数绑定;审计只记 ID/标题不记密钥;config 文件 `0o600`。

---

## 三、架构与分层

### A1 🔴 Critical — 能力分发是"三套平行路由表"，靠字符串字面量保持同步
- **位置**：`AppViewModel+Capabilities.swift:206-303`（~30 分支 if 链）、`CapabilityRuntime.swift:220-325`（100 行 switch）、`CapabilityRuntime.swift:759-830`（`executeDeclaredCapability` 再来一遍）
- **问题**：同一批能力 ID 在 VM 层被拦截、在 executor 里又有 case（其中 ~15 个是返回 *"handled by the Her Desktop app state"* 占位串的**死分支**）。新增 `webapp.rename` 时改了一处漏一处 → 静默路由错误,模型拿到占位串后幻觉成功。编译器帮不上任何忙。
- **改法**：单一 `CapabilityHandler` 协议 + `CapabilityRouter` 注册表（详见 E1）。逐族迁移（先 `webapp.*`,它在 `+WebApps.swift` 里已内聚）,迁一族删一族死 case。

### A2 🔴 Critical — agent 循环被困在 view model 里
- **位置**：`AppViewModel+Conversation.swift:222-559`（`runTurn`/`runGeneration`/`runAgentToolLoop`/`handleToolCall`）
- **问题**：纯领域逻辑（LLM 编排、工具调用、审批门控）直接改 `messages`/`connectionState`/steering 队列。**全 app 风险最高的代码没法单测**——要测一轮工具循环得先拉起 38 个 `@Published` 的 VM + 20 个 store + 服务器。
- **改法**：抽 `AgentTurnRunner`（注入 `AgentLLMChatting`、`CapabilityRouter`、`SystemPromptBuilder` + 小巧的 `TurnSink` 协议承接 UI 效果）。VM 实现 `TurnSink`。可先移纯函数,再移循环体。

### A3 🟠 High — 8 步执行管线在三处复制粘贴,已有分叉
- **位置**：`AppViewModel+Conversation.swift:529-558`、`AppViewModel+Capabilities.swift:73-98`、`:136-166`
- **问题**：*beginActivity → execute → finishActivity → refreshArtifacts → captureInboxEvent → captureDraft → capturePlugin → append/audit/persistMemory* 三处近乎逐字重复,且**已经不一致**（`approve` 路径漏了 `captureGeneratedPluginDraft`——批准后运行的能力生成的插件草稿会被丢掉）。
- **改法**：收敛为一个 `runInvocation(_:approved:)` 中间件方法,三个调用点只供 invocation 和审批上下文。**全库 ROI 最高的单项重构。**

### A4 🟠 High — 层次倒置与依赖注入缺口
| # | 问题 | 位置 | 改法 |
|---|---|---|---|
| A4a | 能力执行直接改 UI 状态：`chrome.isBrowserPresented = true`、`selectedSection = .apps` 藏在能力处理深处,能力无法"无头"运行 | `AppViewModel+Browser.swift:10,168`、`+Terminal.swift:9,62`、`+WebApps.swift:63` | `CapabilityResult` 加 `presentationHint`,UI 副作用集中到 `handleToolCall` 一处裁决 |
| A4b | 基础设施文件里长着依赖上帝对象的 SwiftUI 视图：`TerminalController.swift:100` 的 `TerminalDrawer` 直接 `@EnvironmentObject AppViewModel` 并绕过 `TerminalBridging` 抓具体实例 | `TerminalController.swift:100,131`、`RootView.swift:17` | 拆文件：infra 与 UI 分离;drawer 通过桥协议拿视图,不碰具体 controller |
| A4c | 无组合根：`init` 内联构造 ~20 个协作者,`applyConfiguration` 手工重建其中 8 个,两份清单靠人肉同步 | `AppViewModel.swift:140-227,405-432` | `AppEnvironment` 容器统一从 `(config, cwd)` 建图;顺带修复 A4d |
| A4d | `applyConfiguration` 无条件重建 `agentLLM`,丢弃测试注入的 fake | `AppViewModel.swift:408` | 保留注入客户端（init 已有 `allowsMissingLLMKeyForInjectedClient` 标记,复用） |
| A4e | 9 个 store 全是具体类无协议缝,VM 级测试必须打真实文件系统;`AgentMemClient` 无协议（对比 `AgentLLMChatting` 有）;`Date()` 散落领域逻辑,时序测试必然 flaky | `AppViewModel.swift:165-183`、`ServiceClients.swift:92` | 按需抽 `AuditSink`/`ConversationPersisting`/`AgentMemQuerying`,注入 `() -> Date` |
| A4f | `audit()` 是横切关注点却长成上帝对象方法,几十处 `self.audit`——这是能力处理器拆不出去的头号胶水 | `AppViewModel.swift:538-546` | `protocol AuditRecording`,VM 做适配器,处理器依赖协议不依赖 VM |

### 目标架构与迁移顺序（渐进,每步可独立交付）

```
HerCore/         AgentTurnRunner · CapabilityRouter/Handler · CapabilityPipeline
                 AuditRecording · Clock · Store 协议 · SystemPromptBuilder
HerCapabilities/ WebApp/Terminal/Browser/Plugin 各 Handler（依赖窄协议,不依赖 VM）
HerInfra/        File*Store · 服务器 · BrowserController · TerminalController（去视图）
HerUI/           SwiftUI（RootView/ConversationView/InspectorView/Drawers）
AppViewModel  →  收缩为：@Published 快照 + AppEnvironment + TurnSink/AuditRecording 适配
```

先目录分组,**不急着拆 SPM target**——等 HerCore 编译时不再 import SwiftUI/AppKit,再升 target 让边界被编译器强制。顺序：**A3（管线去重）→ A1（Handler 注册表,先 webapp 族）→ A4f+时钟协议 → A2（AgentTurnRunner）→ A4b/A4a → A4c 容器**。卡住一切的三条边是:`self.audit`、能力改 `chrome.*`、循环直改 `messages`——剪断它们之后,模块化是机械活而非重写。

---

## 四、可扩展性（对照 agentOS 愿景）

### E1 🔴 Critical — 没有 Capability 契约（同 A1,从扩展视角看代价）
今天加一个 `weather.today` 要碰 **~8 处**：executor switch、`executeDeclaredCapability` if 链、`fallbackBuiltInPlugins`、`fallbackInputSchema` switch、`weather.plugin.json`（前两者的重复）、`SystemPromptBuilder` 手写 bullet、（若涉 app 状态）VM if 链、审批特例。漏任何一处都"静默半工作"。
**重构后应该是**：1 个 `WeatherTodayHandler` 文件 + 1 个 manifest,启动时注册一行——目录、参数校验、系统提示词、审批、活动分类全部从 manifest 派生。

### E2 🔴 Critical — schema 双份定义,必然漂移
- **位置**：`Resources/BuiltinPlugins/*.plugin.json` 与 `PluginRegistry.swift:797-947`（150 行 `fallbackInputSchema` switch）;fallback 触发点 `PluginRegistry.swift:196-206,278`
- **问题**：JSON 加了参数、Swift fallback 没加 → 走 fallback 路径时工具 schema 缺参,无编译错误。`local-shell` fallback 还内联了另一份命令摘要（`:526`）,保证漂移。
- **改法**：JSON 为唯一事实源,删 `fallbackBuiltInPlugins`/`fallbackInputSchema`;测试需要时把同一批 `.plugin.json` 编译进 target 加载,或 bundle 为空时响亮地失败。

### E3 🟠 High — 能力语义靠猜
| # | 问题 | 位置 | 改法 |
|---|---|---|---|
| E3a | 成败靠标题子串猜（`"failed"|"blocked"|…`）,新能力失败标题不含这些词就被记成 `.done`;`requiresUserApproval` 一个 bool 身兼"要审批"和"失败/需确认"两义 | `AppViewModel+Capabilities.swift:437-448`、`CapabilityRuntime.swift:1626` | `CapabilityResult` 加 `enum CapabilityOutcome { ok, failed(reason), needsApproval }`,删子串启发式 |
| E3b | 能力 ID 魔法字符串散布全库（每个字面量重复 5–10 处）,改名 = 全库查找替换零编译保护;审批白名单也是硬编码 ID 数组 | 全库;`AppViewModel+Capabilities.swift:349` | `enum CapabilityID: String` 统一引用,机械但立刻让"多少地方知道这个 ID"对编译器可见 |
| E3c | 参数是 `[String: Any]` + 别名探测（`query`/`request`、`path`/`file_path`）,无 schema 校验;`CapabilityInvocation` 的 `Equatable` 故意忽略 arguments,审批去重靠它——不同参数的调用被判相等 | `CapabilityRuntime.swift:7-14,119,179,352,1704-1738` | 执行前按已声明的 `inputSchema` 校验(类型+required);审批去重纳入参数签名（与 S2 同一修复） |

### E4 🟡 Medium — 愿景级缺口
| # | 问题 | 位置 | 改法 |
|---|---|---|---|
| E4a | **vibe coding 造不出 webapp 插件**：生成器只允许 skill/webservice/mcp/command,`webapp` 根本不是 adapter kind——愿景的旗舰场景(自生成可运行 webapp 工具)当前是断路;kind 白名单还在 3 处独立硬编码 | `VibePluginPackageGenerator.swift:105-164,505`、`CapabilityRuntime.swift:1809-1943` | 新增 `webapp` adapter kind(携带 runtime/entry/port),路由到现有 `webapp.create` 机制;kind 清单收敛为一个 `CapabilityKind` enum |
| E4b | MCP 只有"发现",没有客户端：一次性 `tools/list` 后要求用户逐工具 vibe 生成静态插件;调用无 initialize 握手、无会话、仅 localhost HTTP,无 stdio | `MCPBridgeDiscovery.swift:41-53`、`CapabilityRuntime.swift:948-1017,2330` | `MCPClient` actor(连接、握手、缓存工具表),在 catalog 构建时**动态**把已连服务器的工具变成能力,而非每工具一插件;stdio 传输藏在同一接口后 |
| E4c | manifest 无格式版本号：`version` 是插件语义版本,不是 schema 版本;格式演进时旧插件静默解码失败被丢弃(`PluginRegistry.swift:51-56` 只 print) | `Models.swift:706-740` | 加 `manifestSchemaVersion`,validator 显式拒绝/升级 |
| E4d | 系统提示词大半由 manifest 生成(✅ 正确模式),但 `toolBoundarySection` 手写 ~20 条 "Use `xxx` when…"——加/删能力即过期/说谎 | `SystemPromptBuilder.swift:276-306`(对照 `:323-341` 好的一半) | 每能力的使用指引移入 manifest 字段(`usageHint`),prose 只留 kind 级不变式 |

---

## 五、性能（摘要,详见 [performance-optimization-plan.md](performance-optimization-plan.md)）

- **P0 状态拆分**：流式 token 追加/audit 追加/健康检查 5 连写,均触发 38-`@Published` 巨型 model 的全窗重绘 → 拆 `ConversationModel`/`ActivityFeedModel`/`ServiceStatusModel`(与本文 A2/A4f 是同一根因的两面,应协同施工)
- **P1 body 重复计算**：流式 markdown 每帧全量重解析、`sortedConversations` 每帧全排序、`productReadinessSummary` 一次 body 算多遍
- **P2 主线程 I/O**：启动同步加载全部持久层、server `start()` 信号量阻塞 main 3s、`audit()` 热路径同步写盘
- **P3 快速清理**：静态化 encoder/formatter、系统提示词每轮读盘改缓存(`SystemPromptBuilder.swift:5` 默认参数每次构造都扫盘读 6 个候选文件)、侧边栏 LazyVStack

---

## 六、测试缺口

现有缝隙(✅ `AgentLLMChatting`/`TerminalBridging`/`BrowserBridging`/注入 cwd)够用但不全。最该补的回归测试:

| 场景 | 风险 | 测试 |
|---|---|---|
| 损坏 transcript 切换(R2) | 上次事故同类:坏文件被 placeholder 覆盖 | 写坏 `<id>.json` → `switchConversation` → 断言文件未被覆盖且报错 |
| 加载中删对话(R3) | 保存被永久禁用 | 大 transcript 加载中 `deleteConversation` → 编辑 → 断言保存生效 |
| 大输出 shell(R4) | 64KB 死锁 | `shell.run` 输出 200KB → 断言快速返回、不截断、非超时 |
| 保存失败可见(R5) | 静默丢数据 | 注入抛错 store → 断言 `lastError`/审计被设置 |
| 退出清理(R1) | 僵尸进程 | 显式 `shutdown()` 调用 `stopAll()` 并终止后端 |
| 审批去重按参数(E3c/S2) | 不同参数被合并/整体放行 | 同能力不同参数两次调用 → 断言各自入队 |

---

## 七、统一路线图（合并五维度,按"风险 × ROI"排序）

**第一批 — 止血（健壮性/安全必修,~2–3 天）**
1. R1 退出清理(`shutdown()` + willTerminate)
2. R2+R3 数据丢失通路(解码失败≠空 + isLoading 复位) — **并补上表中前两条回归测试**
3. R4 管道死锁(并发排空)
4. S1 后端环境白名单
5. S2+E3c 审批按参数签名(一次修复两个发现)
6. R5+R6d 保存失败可见 + audit 坏行跳过

**第二批 — 性能专项(按性能文档 P3→P1→P0-1 顺序,~3–4 天)**
性能文档已排好;其中 P0 拆 `ConversationModel` 时请与第三批的 A2 协同设计,避免拆两次。

**第三批 — 架构解耦(每步可独立交付,~1–2 周弹性)**
1. A3 管线去重(`runInvocation` 中间件) — 纯重构,顺手修掉 approve 路径的分叉
2. E3a+E3b 类型化(`CapabilityOutcome` + `CapabilityID` enum) — 机械,给后续迁移上编译器保险
3. A1/E1 `CapabilityHandler` 注册表,先迁 `webapp.*` 族,迁一族删一族死分支
4. E2 删 fallback 双份 schema
5. A4f `AuditRecording` + 时钟注入 → A2 `AgentTurnRunner`
6. A4b/A4a 视图与 infra 分离、presentationHint

**第四批 — 愿景扩展(架构解耦后自然解锁)**
- E4a webapp adapter kind(vibe coding 能造出可运行的 webapp 工具)
- E4b MCPClient(动态工具目录)
- E4c/E4d manifest schema 版本 + usageHint
- S3 网络面收紧(顺手)

每步验收:`swift build -c release -Xswiftc -strict-concurrency=complete` 零新告警 + `swift test` 全绿 + 真机走一遍核心流程(发消息、工具调用、切换对话、开关面板)。

---

*审查方法:四个独立只读 agent 分别从架构、可扩展性、健壮性、安全四个视角全库审查,与既有性能审查合并、交叉印证、去重后成文。多个关键发现(能力三重分发、audit 同步写、数据丢失守卫的缝隙)被 ≥2 个视角独立命中,置信度高。*
