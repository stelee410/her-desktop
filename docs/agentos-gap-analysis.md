# Her Desktop 距离"完整 agentOS"有多远（2026-07-08）

> 基于 2026-07 全库 review + 四批次修正 + heartbeat 落地之后的代码现状写成。
> 所有"现状"描述都对照过代码；所有建议都给出验收标准，避免变成愿景清单。

## 一、先定义:"完整的 agentOS"是什么

拿 OS 类比,一个 agentOS 至少有四层:

| 层 | OS 里的对应物 | agentOS 里的含义 |
|---|---|---|
| **L1 内核** | kernel + syscall | 回合循环、工具调用、审批门控、审计——"一次思考-行动"的原语 |
| **L2 能力与运行时** | 驱动 + 文件系统 + 进程加载器 | 插件体系、webapp/终端/浏览器运行时、持久化 |
| **L3 自治层** | 调度器 + 进程模型 + cron | 后台任务、事件驱动唤醒、并行工作、预算控制——**agent 不等人吩咐也能干活** |
| **L4 生态** | 包管理器 + 分发 | 插件分享/导入、签名分发、自动更新 |

**一句话结论:L1/L2 经过这轮 review 已经相当扎实(约七八成),L3 刚砌了第一块砖(heartbeat),L4 基本没开始。从"聊天 app + 工具"跃迁到"agentOS"的分水岭在 L3 的进程模型——这是接下来最值得投入的地方。**

## 二、现状盘点(实事求是)

**已经做对的**(不少是本轮 review 的成果):
- 回合内核:有界工具循环(5/20 轮)、流式、mid-turn steering、可停止
- 能力体系:JSON manifest 唯一事实源、Handler 注册表单点分发、6 种 adapter(skill/webservice/mcp/command/native/**webapp**)、vibe coding 自扩展闭环(draft→review→install→**可运行 webapp**)
- 治理:参数级审批签名、审计全程、密钥脱敏、loopback 加固、workspace 围栏、进程退出清理
- 记忆:AgentMem 每回合检索+回写、对话 compact 入记忆、reflection/dream 上下文
- 主动性起步:heartbeat(once/every/daily;notify 零 token,prompt 全回合)
- 数据可靠性:损坏先备份、原子写、串行 IO 队列、退出前 flush

**诚实的短板**(按层):

### L3 自治层——最大差距

| # | 差距 | 现状证据 | 为什么关键 |
|---|---|---|---|
| G1 | **没有进程模型** | heartbeat 的 prompt 任务直接 `send()` 进当前活跃对话;用户正聊着天,定时任务会插进来。无后台工作会话、无并行、无任务队列/重试/优先级 | 这是"OS"与"聊天窗"的本质区别。OS 的定义就是:多个工作单元共享资源、互不踩踏 |
| G2 | **只有时间触发,没有事件触发** | `LocalInboxBridge` 收到的外部消息只被记录为数据(`inbox.capture`),不能唤醒 agent 处理 | "收到 Discord 消息自动分类回复"这类场景是 agentOS 的核心卖点,现在做不到 |
| G3 | **无成本记账与预算** | 无 token 计数、无每任务/每日花费上限;`every 60s` 的 prompt 任务能烧穿钱包(仅有 60s 下限保护) | **无人值守自治的前提是预算硬约束**。没有它,你不敢让 agent 独自工作 |
| G4 | **"潜意识"是静态的** | dream context 只是注入提示词的一段文本;reflection 靠手动点按钮 | 真正的 subconscious 应是后台低成本进程:定期反思、整理记忆、更新技能 |

### L1/L2 的残余弱点

| # | 差距 | 现状证据 | 影响 |
|---|---|---|---|
| G5 | **上下文管理是硬窗口** | `ConversationContextBuilder`: 固定最近 12 条消息 + 4 条工具证据,超出直接丢弃,无中段压缩 | 长任务(几十轮工具调用)中,agent 会"忘记"自己十轮前的发现;compact 只在删除对话时发生 |
| G6 | **模型路由是装饰** | 单一 `agentLLMModel`;Inspector 的 "Model Routing" 卡片显示 "Auto" 但无路由逻辑 | 心跳/压缩/反思该用便宜模型;全用主力模型,自治成本不可持续 |
| G7 | **权限是平面二元的** | 审批 = 每能力(+参数签名)的 yes/no;无 per-plugin scope("可读 workspace 不可联网")、授权不跨对话持久、webapp 后端无 OS 沙箱(仅环境白名单) | 插件生态越大,平面权限越不够用 |
| G8 | **技能不自进化** | SKILL.md 安装后是死文档;任务成败经验不会回流更新技能 | "自我总结生成 skill"的愿景只完成了"生成",没有"进化" |
| G9 | **内核仍在 view model** | `runAgentToolLoop` 等 ~300 行在 `AppViewModel+Conversation`(review 已知保留项 A2/A4c) | 不解决 G1 就无从谈起:后台 job 也要跑同一个循环,内核必须先能脱离 UI 存在 |

### L4 生态——未开始

- 无签名/公证/自动更新(TestFlight/Sparkle 都没有)
- 插件有 export,无导入分享渠道;无版本升级流(manifestSchemaVersion 刚埋好种子)
- MCP:有会话客户端,但服务器注册无 UX、无动态工具目录、无 stdio 传输

## 三、路线图:按价值排序的实际指导

### 第一梯队:把"自治"做实(建议顺序执行,三件事互相咬合)

**R1. 后台工作会话(Job 模型)——分水岭之作** ✅ 已完成(2026-07-08,`AppViewModel+Jobs.swift`):AgentJob 状态机 + 串行 worker(让路给用户回合)+ 轮数预算 + 审批即停排队 + 单一结果卡片 + Inspector 进程列表。A2 的无头回合循环随之落地(job 的非流式内核循环)。剩余:job 的 token 级记账等 R2。
- 新增 `AgentJob`:id、来源(heartbeat/inbox/user)、独立的消息上下文、状态机(queued/running/done/failed)、日志、预算。
- heartbeat 的 prompt 任务和未来的事件任务都跑在 job 里,**不再打进用户正在看的对话**;job 完成后向主对话投递一张结果卡片(可展开看完整过程)。
- 实现关键:这正是做 A2(AgentTurnRunner 抽取)的时机——job 需要一个不依赖 ConversationView 的回合执行器。**不要提前抽,让 job 的真实需求逼出接口。**
- 验收:用户在聊天时定时任务到点,对话不被打断;Inspector 能看到 job 列表/状态/日志;job 里的审批请求排队等用户回来处理。

**R2. Token 记账 + 预算硬约束**
- AgentLLM 响应里取 usage,按回合记账(audit 已有事件流,直接挂 metadata);每 job 带 `maxTokens` 预算,超限即停并报告;可选每日总额。
- 验收:schedule.create 一个 prompt 任务时可指定预算;Inspector 显示今日花费;超预算的 job 状态为 failed(budget) 且有审计。

**R3. 事件触发器**
- 复用 heartbeat 的任务模型,schedule 增加 `trigger: on_inbox(source)` 类型;`LocalInboxBridge` 收到事件→匹配触发器→入队 job(带预算)。
- 验收:"收到 Oyii 消息就总结并通知我"全程无人工;风暴保护(同源事件 N 秒内合并)。

### 第二梯队:深度与质量

**R4. 上下文自动压缩**:transcript 超阈值时,把窗口外的旧消息压成一条 summary 消息(用便宜模型,见 R5),替代硬丢弃。验收:50 轮工具调用的长任务里,agent 仍记得第 5 轮的关键发现。

**R5. 模型分层路由**:config 增加 `utilityModel`(便宜);heartbeat job、上下文压缩、reflection、记忆整理走它;让 "Model Routing" 卡片显示真实路由。验收:审计里能看到每次调用用了哪个模型。

**R6. 技能自进化闭环**:job/长任务结束后跑一次廉价反思:"这次哪一步绕了弯路?"→若有可固化的经验,自动产出 `plugin.draft`(更新对应 SKILL.md)进入现有 review 队列——**人审后生效,不自动改自己**。验收:同类任务第二次执行的工具调用轮数可见下降。

**R7. 潜意识进程化**:reflection 从手动按钮变成低频 heartbeat job(每天一次,utilityModel,小预算),产出 dream context 更新。

### 第三梯队:生态与产品化

- **R8** 权限 profile:manifest 声明 scopes(network/workspace/shell/…),审批界面按 scope 展示;高危 scope 组合(network+workspace 读)醒目提示
- **R9** Developer ID 签名 + 公证 + Sparkle 自动更新(开始给别人用的前提)
- **R10** MCP 服务器注册 UX(设置页)→ 动态工具目录 → stdio 传输
- **R11** 插件导入渠道:先做"从 URL/文件导入 PluginPackage"(stagePackage 已在),不做市场

## 四、反模式警示(先不要做的)

1. **别先搭多 agent 编排框架**。没有 R1 的 job 模型,"多 agent"只是并发的字符串;单 agent 的后台进程模型做好了,多 agent 是它的自然推广。
2. **别做插件市场**。先让自己攒出 10 个天天在用的插件,分发问题到时候自然清楚。
3. **别为纯度提前抽微内核**。A2/A4c 挂了两轮不是遗忘,是等 R1 给出真实接口需求——由需求驱动的抽取才不会抽错边界。
4. **别在预算(R2)之前扩大自治(R3/R6/R7)**。每个无人值守场景都要先问:失控时最多烧多少钱、改多少文件?
5. **记住 docs 里自己写的 stop rule:先真实使用,再扩架构。** R1-R3 每做完一个,先自己用一周。

## 五、量化一下"距离"

| 层 | 完成度 | 差的主要是 |
|---|---|---|
| L1 内核 | ~80% | 内核脱离 UI(A2/A4c,随 R1 做)、上下文压缩(R4) |
| L2 能力/运行时 | ~70% | 权限 profile(R8)、MCP 完整化(R10)、沙箱 |
| L3 自治 | ~15% | 进程模型(R1)、预算(R2)、事件(R3)、自进化(R6) |
| L4 生态 | ~5% | 签名分发(R9)、插件分享(R11) |

按第一梯队每项 1-2 周有效开发估算:**做完 R1-R3(即"敢让它独自干活"的 agentOS 雏形)约 4-6 周;加上第二梯队(有深度的个人 agentOS)约一个季度。** L4 取决于是否要给别人用——个人工具可以无限期推迟。

真正的下一步只有一个:**R1。** 它把 heartbeat 从"定时往对话里塞消息"升级为"操作系统调度进程",其余一切(事件、预算、多 agent、自进化)都长在它上面。
