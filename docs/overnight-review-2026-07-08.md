# 通宵 Review 与改进报告(2026-07-08 晨)

> 对当前 HEAD(heartbeat/jobs/webapp 插件/MCP 落地后的代码)做了一轮全新的四维审查
> (正确性/稳定性/性能/可维护性),随后分四批修复,每批 418 测试全绿后提交推送。
> 共 4 个提交:`1184605` → `cb829b3` → `a64ac5f`(+ 本报告)。app 已重新打包。

## 批次 A — 正确性(`1184605`,12 处真实缺陷)

| 缺陷 | 后果 | 修复 |
|---|---|---|
| 心跳 tick 迭代活索引跨越 `await` | schedule.cancel 在 tick 中执行 → **数组越界崩溃** | 先快照到期任务 ID,每次 await 后按 ID 重查 |
| 心跳每 30s 无条件重写 heartbeat.json | 常驻主线程磁盘写 | 无到期任务提前返回 |
| daily/every 创建即触发 | "每天 9 点"在 10 点创建立刻响一次 | 锚点 = `lastFiredAt ?? createdAt`;首次触发是**下一个**排定时刻,漏掉的仍补发一次 |
| MCPClient actor 重入 | 并发调用同一 bridge → 双 initialize(严格 MCP 服务器会拒绝) | 首个 await 之前先落 handshakeAttempted |
| MCP 失败缓存永久中毒 | bridge 后启动也拿不到握手 | 出错时 reset 会话缓存 |
| 子进程 SIGTERM 被 trap | `trap '' TERM` 的进程让 await 永久挂起 | 5s 后升级 SIGKILL |
| 后台 job 的插件草稿卡片漏进当前对话 | 违反"job 只投一张结果卡"契约 | `captureGeneratedPluginDraft` 透传 postToConversation |
| job 结果卡在切换对话的加载窗口投递 | 被 `messages = loaded` **吞掉** | 投递前等待加载窗口结束(有界) |
| job 待批文案承诺"批准后继续" | 实际不会续跑,虚假承诺 | 文案改为诚实描述 |
| `isLoopbackHost("::1")` 误拒 | 裸 IPv6 Host 被端口剥离逻辑弄坏 | 仅单冒号时剥端口 |
| 安装后立刻打开 webapp 插件失败 | plugins 数组未刷新时查不到 | 回退到 registry 直查 |

## 批次 B — 稳定性(`cb829b3`)

- **启动不再阻塞首帧**:init 里对无界 JSONL(audit/inbox/plugin events)的同步全量解码删除——`bootstrapRuntime()` 本就会在首帧后再加载一遍,init 是纯重复劳动;audit 改为**只读文件尾 128KB**(它只展示最近 12 条,以前却解码全部历史)
- **两个 loopback server 去掉 3 秒信号量阻塞**:扩展桥端口本来就是固定的(等待毫无意义);webapp server 改为预先探测空闲端口再绑定,端口同步可知
- **`@unchecked Sendable` 兑现承诺**:LocalWebAppServer 的 listener/router/port、LocalInboxBridge 的 listener 补锁(此前主线程写、网络队列读、无同步)
- **记忆归属正确**:回合记忆回写在**回合发生时**绑定 sessionID——之前的 detached Task 惰性读 activeConversationID,切换对话后记忆会记到错误的会话名下
- **语音可停**:TTS 挂在被跟踪的 task 上,切换对话/退出即取消并停 synthesizer(之前旧对话会继续朗读)
- **shutdown 时序封口**:isShuttingDown 防止在途 heartbeat tick 在清理后复活 job worker
- 心跳/截图 timer 加 tolerance(允许系统合并唤醒省电)

## 批次 C — 性能(`a64ac5f` 前半)

- **readiness 计算撤出流式热路径**:它内联在 ConversationView.body,每次流式 flush(~14Hz)都全量重建 9 项 readiness——移入不观察 ConversationModel 的独立容器视图,只在配置/插件/健康变化时才算;顺带修复它此前不观察 serviceStatus 导致的展示过期

## 批次 D — 可维护性(`a64ac5f` 后半)

- **`JSONLStore<Event>` 泛型**:三个 JSONL store 逐字节相同的 append/loadAll 收敛为一个(audit 保留串行队列缝,尾读能力下沉共享)
- **`FileManager.backUpSiblingFile`**:三份手写的损坏备份实现合一
- **`durableCandidateLines`**:会话摘要/压缩摘要重复的消息扁平化合一
- **`CapabilityRunOutcome` → `InvocationOutcome`**(与无关的 `CapabilityOutcome` 枚举只差一个词,重命名消歧);executor 分发 switch 的 17 个 case 从字符串字面量改为 `CapabilityID` 常量(typo 变编译错误)
- **文件拆分(纯移动,行为零变化)**:`InspectorView.swift` 2568 → **70** 行(拆出 7 个文件:composer sheet、webapp/plugin/activity/service/work 卡片、共享 chrome);`WorkspaceViews.swift` 1118 → **24** 行(5 个工作区页 + chrome)

## 审查确认无问题的(未动)

流式 debounce、job 每轮 rebuild catalog(与交互循环一致)、agentJobs 每轮 publish(已隔离在 ActivityFeedModel)、messageReferenceCache(有界)、AgentLoopCard(按工具步而非 token 重算)、HeartbeatTaskStore(主 actor 独占)。

## 有意未做(需要你在场)

- **ArgumentBag 统一参数解析**(~78 处调用点签名变化,正确但面广,该在监督下做)
- **WebAppProcessManager 忙轮询**(已在后台线程,不碰后端启动路径)
- **job 审批后续跑**(feature 而非 fix:approval 需携带 jobID、恢复上下文——建议作为 R1 的后续迭代)
- **AppViewModelTests 3820 行拆分**(纯测试文件移动,收益低,留给顺手时做)

## 建议你早上验证的

1. 正常聊一轮 + 流式中开关面板(readiness 撤出热路径后应更稳)
2. 创建一个"每天 HH:mm"的提醒,确认**不会立刻触发**(新锚点语义)
3. 切换对话时如有后台任务在跑,结果卡应完整出现(不再被吞)
4. 启动速度应有感知改善(audit 历史越大越明显)
