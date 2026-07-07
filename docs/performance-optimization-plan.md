# Her Desktop — 性能优化计划（待 review）

> 目的：把"点一下卡一下"从零敲碎打的补丁，升级为一次系统性的架构优化。
> 本文档只列优化点、定位到 `file:line`、给出改法与工作量评估；**代码改动待你 review 后再做**。

## 一、根因

整个 app 的可变状态几乎都挂在**单一巨型 `AppViewModel: ObservableObject`** 上——`AppViewModel.swift` 里有 **38 个 `@Published` 属性**，所有顶层视图都用 `@EnvironmentObject var model: AppViewModel` 观察它。

SwiftUI 的规则：一个 `ObservableObject` 只要发出一次 `objectWillChange`，**所有观察它的视图都会重算 body**——不管你改的是哪个属性。于是：

- 流式回复时每 ~70ms 给消息追加一段文本 → 侧边栏、30+ 个 Inspector 卡片、工作区、菜单栏**全部重算**，尽管它们根本不显示流式文本。
- 每次工具调用写一条 audit 事件、每次健康检查、每次插件草稿更新，都会触发同样的全窗口失效。

**已经验证过的解法**：`UIChrome`（本次）、`BrowserController`、`TerminalController` 三处已经证明——把状态拆成独立小 observable，用 `@ObservedObject` 窄观察，就能把重算范围收缩到真正相关的少数视图。下面的 P0 就是把这套做法用到三条最高频的写路径上。

## 二、已完成（本轮之前 + 本轮）

- 侧边栏 `.ultraThinMaterial` → 实色 tint（毛玻璃每帧重采样）
- 对话消息列表改 `LazyVStack` + 稳定 `.id(message.id)`
- Markdown 块级/行内解析加 `NSCache`
- Inspector 常驻不销毁重建 + 隐藏时 `.allowsHitTesting(false)`
- RootView 去掉 `.animation`（开关时逐帧全窗口重排）
- 三个 UI 开关拆入 `UIChrome`（独立 observable）

---

## 三、优化点（按优先级）

### P0 — 状态拆分（架构级，影响最大）

把三条最高频写路径从巨型 model 拆出成独立 observable，各自只被相关视图观察。这是消除"全窗口重算"的核心。

| # | 问题 | 位置 | 改法 |
|---|---|---|---|
| P0-1 | **流式 token 追加波及整窗**：每次 flush `messages[i].content += …` 触发全模型 `objectWillChange`，重算 Inspector/侧边栏/工作区/菜单栏 | `AppViewModel+Conversation.swift:451`（`flushStreamBuffer`） | 抽 `ConversationModel: ObservableObject`：`messages`、`streamingAssistantMessageID`、stream 缓冲、`draft`、`pendingAttachments`、`conversations`、`activeConversationID`、`isLoadingConversation`。只有 `ConversationView` 的消息列表观察它 |
| P0-2 | **audit / interaction / capabilityActivity 追加波及整窗**：工具循环里每步都 append，只有 Inspector 活动页显示，却重绘全部 | `AppViewModel.swift:542`（`audit`）、`:549`（`recordInteractionEvent`）、`AppViewModel+Capabilities.swift:422` | 抽 `ActivityFeedModel`：`auditEvents`、`interactionEvents`、`capabilityActivities`、`pluginEvents`、`webServiceArtifacts`。只被活动页 4 个卡片观察 |
| P0-3 | **健康检查一轮 5 次全窗失效**：`refreshServiceHealth` 连写 `serviceHealth`×2、`tools`×2、`rebuildRunningTasks()`，每次 config 保存都触发 | `AppViewModel+Workspace.swift:53-61`、`AppViewModel.swift:447`（`rebuildRunningTasks`） | 抽 `ServiceStatusModel`：`serviceHealth`、`tools`、`runningTasks`、`agentProfile`。合并那两处 double-write |

> P0 之后可继续拆（收益递减）：`PluginDraftModel`（plugins/drafts/approvals/pluginEvents，由 79KB 的 `AppViewModel+Plugins.swift` 高频写）、`WebAppModel`（webApps/selectedWebAppID）。`browserTarget`/`browserAutonomyGranted` 归到已隔离的 `BrowserController` 旁。

**工作量**：中偏大，机械但面广（需改各 View 的 `@EnvironmentObject` 声明 + 注入点）。建议一次拆一个、每步编译+跑测试。P0-1 单项收益最大。

### P1 — body 内的重复计算（不改架构也能立竿见影）

这些是在 `body` 或计算属性里做实打实的工作，每次重绘都重跑。P0 落地后触发频率会自然下降，但本身也该修。

| # | 问题 | 位置 | 改法 |
|---|---|---|---|
| P1-1 | **流式消息每次 flush 重解析整段 markdown**：`NSCache` 按完整内容字符串做 key，流式消息内容每帧在变 → 每帧 cache miss 全量重解析，且 key 无限增长 | `MarkdownMessageView.swift:32,212`；参见 `:161` 行内 | 流式中的那条消息跳过块缓存直接解析；或用 `messageID + 长度分桶` 做 key |
| P1-2 | **`productReadinessSummary` 每次重绘多次重算**：聚合 9 项、`plugins.flatMap` 跑两遍、多次 `serviceHealth.first{}`；在 `ConversationView.body` 和 `LaunchReadinessStrip` 各读一次，流式中反复跑 | `AppViewModel.swift:285`；读点 `ConversationView.swift:11,84`、`InspectorView.swift:250` | body 顶部 `let summary = …` 复用；或缓存，仅当输入变化时重算 |
| P1-3 | **`sortedConversations` 每次访问全量排序**：侧边栏 + 对话切换器同屏各读一次 | `AppViewModel+Conversation.swift:7`；读点 `SidebarView.swift:71`、`ConversationView.swift:144` | `conversations` 保持有序存储（插入/置顶/改名时排序），直接暴露数组 |
| P1-4 | **AgentLoop / ToolEvidence / MemoryWriteback 构建器在 body 里跑，甚至一次 body 跑两遍**：全量扫 messages/events | `WorkspaceViews.swift:841,871,918`、`InspectorView.swift:367`、`WorkspaceViews.swift:28` | body 顶部绑一次复用；理想是把派生结果缓存到 model，仅源数组变化时重算 |
| P1-5 | **每条消息 body 内扫全文找 web app 引用/artifact**：`webApps.filter{ content.contains }`、`webServiceArtifacts(for:)` 逐行扫；O(消息×app×长度)/帧（有空集短路） | `ConversationView.swift:382`、`AppViewModel+Conversation.swift:165` | 消息定稿时预计算引用集存到消息上；或 `[messageID: refs]` 缓存，webApps 变化时失效 |

**工作量**：小到中，风险低。P1-1/P1-3 是快速见效项。

### P2 — 主线程 I/O 与启动阻塞

不一定是"点击卡"，但影响启动速度和偶发卡顿（beach ball）。

| # | 问题 | 位置 | 改法 |
|---|---|---|---|
| P2-1 | **启动时在 main actor 同步加载整个持久层**：`bootstrap()` 读 index+完整 transcript、`auditStore.loadAll()` 解码整个 `audit.jsonl`、多个 event store 全量读——全同步、全在 main，随文件增长无上限 | `AppViewModel.swift:184-201` | 改异步：先显示空壳，再 off-main 加载（复用 `ioQueue`）。至少把 audit/event 全量解码挪出 main |
| P2-2 | **`start()` 用 `DispatchSemaphore.wait` 阻塞 main 最多 3s**：扩展服务器 / webapp 服务器启动时在调用线程（main）等监听就绪 | `BrowserExtensionServer.swift:57`、`LocalWebAppServer.swift:325`；调用点 `AppViewModel+Browser.swift:97`、`AppViewModel+WebApps.swift:8` | `start()` 改 async，用 `stateUpdateHandler` continuation 等就绪；或整个 start 丢后台队列 |
| P2-3 | **`audit()` 在热路径上同步写盘**：每条用户消息/每次工具调用/每个交互事件都 `FileHandle` seek+write 到 `audit.jsonl`，一轮对话多次 | `AppViewModel.swift:538`→`AuditEventStore.append` | 追加走串行后台队列（同 `ConversationStore.ioQueue`），main 上只留内存态更新 |
| P2-4 | **`deleteConversation` 在 main 同步解码整段 transcript**：已有 `loadMessagesAsync` 却没用 | `AppViewModel+Conversation.swift:111,132` | 改 `await loadMessagesAsync(id:)` |
| P2-5 | **JSONL 文件无限增长且启动全量重读**：audit/inbox/plugin-event 只 append 不轮转，`loadAll()` 读全文解码每行（内存态已限 12/16，磁盘没限） | `AuditEventStore.swift:57`、`InboxEventStore.swift:39`、`PluginEventStore.swift:106` | 轮转/截断（只留最近 N 行），或启动只 tail 读最近片段 |
| P2-6 | **`index.json` 每次保存在 main 同步 encode+原子写**，未 debounce | `AppViewModel+Conversation.swift:579`→`ConversationStore.saveIndex` | 挪到 `ioQueue` 并 debounce |
| P2-7 | **`WebAppStore.loadAll()` 目录遍历 + N 次同步解码在 main** | `WebAppStore.swift:124`、`AppViewModel+WebApps.swift:21` | off-main 加载后回主线程发布 |
| P2-8 | **后端就绪用 `Thread.sleep(0.15)` 忙轮询最多 10s**（已 off-main，但占线程、每 150ms 唤醒） | `WebAppProcessManager.swift:172` | 异步 connect 探测 + 退避，或 `NWConnection` 就绪回调 |
| P2-9 | **截图轮询 timer 即使浏览器未运行也每 1.5s 醒来跳主线程** | `BrowserDrawer.swift:166` | 仅在 controller 真正 running 时启动 timer，停止时失效 |

**工作量**：P2-3/P2-4/P2-6 小；P2-1/P2-2 中（涉及启动时序，需小心）。

### P3 — 便宜的清理（低风险快速项）

| # | 问题 | 位置 | 改法 |
|---|---|---|---|
| P3-1 | `JSONEncoder.pretty` 是 `static var`，每次访问新建并配置 encoder | `CapabilityRuntime.swift:2338` | 改 `static let … = { … }()` |
| P3-2 | `ConversationStore.encoder()/decoder()` 每次 save/load 新建 | `ConversationStore.swift:204,211`；另 `DreamPromptContext.swift:29,53` | 缓存 `static let` |
| P3-3 | **系统提示词每轮从盘读 persona/project 文档**：`SystemPromptBuilder` 的 `projectDocs` 默认参数每次构造都 `ProjectPromptLoader.load()`（扫 6 个候选文件读盘），每条消息一次 | `SystemPromptBuilder.swift:5`；调用点 `AppViewModel+Conversation.swift:256` 等 | init 时加载一次并缓存，各调用点传入 |
| P3-4 | 正则/`ISO8601DateFormatter` 每次调用新建编译 | `CapabilityRuntime.swift:2048,130,2217`、`DreamPromptContext.swift:203` | 提到 `static let` 缓存 |
| P3-5 | 侧边栏对话列表是普通 `VStack` 非 `LazyVStack`，长历史全量构建行 | `SidebarView.swift:69` | 改 `LazyVStack` |
| P3-6 | `VibePluginComposerSheet.body` 约 480 行单表达式，任何状态变化重算整树 | `InspectorView.swift:1890-2367` | 拆成 header/字段/预览/操作栏等小 View |
| P3-7 | 空态问候圆圈上 `.blur(radius: 0.4)` 亚像素模糊，白买一次离屏重采样 | `ConversationView.swift:305` | 删掉 |
| P3-8 | 每张 pinned widget 是常驻 `WKWebView`，非 lazy（数量小时可接受） | `InspectorView.swift:100,130` | pin 数量大时改 lazy/限量 |

---

## 四、建议执行顺序

1. **先做 P3 快速项**（半天）：静态编码器/格式化器、系统提示词缓存、侧边栏 LazyVStack、删 blur。低风险、立即减负。
2. **P1 body 计算**（1 天）：markdown 流式解析、`sortedConversations` 有序存储、`productReadinessSummary` 与各构建器绑一次复用。这批直接改善"点击/滚动/流式"的手感。
3. **P0-1 拆 `ConversationModel`**（1–2 天，收益最大）：让流式 token 不再波及全窗。单独一个 PR，充分测试。
4. **P0-2 / P0-3**（各 1 天）：活动流、服务状态拆出。
5. **P2 主线程 I/O**（1–2 天）：audit 异步写、启动异步化、semaphore 去阻塞。

每一步：`swift build -c release -Xswiftc -strict-concurrency=complete` + 跑测试 + 真机点一遍，确认无回归再进下一步。

---

## 五、验证方法

- **主观**：点 Inspector/终端/浏览器开关、切换对话、流式回复时点按钮——应无卡顿。
- **客观**：`sample <pid>` 在流式回复时抓样本，确认主线程不再持续忙于 view body 重算；对比改动前后启动耗时。
- **回归**：`swift test` 全绿；strict-concurrency 编译无新警告。
