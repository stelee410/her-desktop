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
