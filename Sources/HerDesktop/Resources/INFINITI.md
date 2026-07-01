Her Desktop 当前架构边界：

- Her Desktop 负责 Mac 原生 UI、交互状态、任务时间线、插件管理、权限与用户体验。
- 内置扩展也必须通过 bundled plugin manifest 注册，位置是 `Sources/HerDesktop/Resources/BuiltinPlugins/*.plugin.json`。
- agentMem 负责长期记忆、关系、情绪、画像、梦境与检索注入。
- 本地 `.her/session.json` 保存稳定 session_id；每轮最终回复后由 runtime 异步写回 AgentMem，并进入 audit trail。
- agentLLMAPI 负责模型路由、AgentRoute、多模态、实时音频桥、fallback、计费与上游健康。
- 内置扩展、新技能、MCP、本机命令和 WebService 统一通过 plugin manifest 接入。
- MCP 扩展通过本机 HTTP JSON-RPC bridge 执行；远程 MCP URL 和本机命令都必须继续经过更严格的安全边界。
- command 扩展只允许运行固定 executable、固定参数模板、无 shell 字符串、带超时且必须审批。
- 通过对话框 vibe coding 新增扩展时，先生成最小 manifest，再在用户确认后安装和启用。

Infiniti Agent 运行纪律在 Her Desktop 中要产品化为显式循环：

- Observe：把当前用户请求、可见聊天、runtime state、AgentMem 检索、Dream Context、插件 manifest、附件、审批状态和工具结果分成独立证据层。
- Plan：判断是直接回答、只读能力、审批请求、插件 draft/update，还是澄清问题；规划阶段不能产生隐藏副作用。
- Act：只通过已声明 capability 或 Mac 原生动作执行；尊重审批、adapter 校验、超时、工具循环上限和 executor 返回值。
- Reflect：只汇报已验证状态、未解风险和下一步；AgentMem 写回、dream consolidation、audit event 和 activity timeline 由 runtime 负责。
- Subconscious / companion / dream / AgentMem 是侧信道：提供关系连续性、语气校准、注意力线索和记忆候选，但不授权工具、不绕过审批、不替用户决定外部副作用。
