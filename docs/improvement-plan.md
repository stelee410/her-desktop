# Her Desktop 改进计划

Date: 2026-07-04

这份文档记录 demo → 可用产品阶段的整体改进方向，接替
`mvp-summary-and-todo.md` 中已经完成的 P0/P1 项。核心判断保持不变：
**架构层已经超前，体验层是欠账**。改进优先级为 UI 收敛 → 代码结构 →
WebApp 运行时 → widget 化。

## 设计原则（Apple 设计哲学的落法）

1. **对话就是产品**。中栏对话占绝对主导；其余一切默认退后。
2. **渐进披露**。状态、日志、诊断默认隐藏，通过角标 / popover /
   抽屉按需展开；健康时保持沉默。
3. **每个 UI 元素回答"用户每天需要看它吗"**：
   - 需要用户行动的（审批、插件草稿）→ 内嵌对话流或角标 + 待办面板。
   - 出问题才需要看的（服务健康、readiness）→ 单一状态图标 + popover。
   - 日志取证性质的（audit、interaction events）→ 活动面板，不常驻。
4. **优先原生控件**（toolbar、SF Symbols、系统材质、Settings），
   自绘组件只保留有产品灵魂的部分（presence orb、Her 主题色）。
5. **情感化做减法**：呼吸圆保留并强化；trust/valence 数字仪表盘
   移入 Memory 页做趋势回顾，不常驻主界面。

## 已完成（2026-07-04）

- 多对话：`.her/conversations/` + index，切换 / 置顶 / 删除，
  删除前可 compact 写入 AgentMem 长期记忆；旧 `session.json` 自动迁移。
- AppViewModel 拆分为领域扩展文件（core / Conversation / Capabilities /
  Plugins / Memory / Workspace / Voice / Inbox / Messages），
  核心文件从 4,300 行降到 ~550 行。
- 主窗口 HIG 化：Inspector 默认隐藏（工具栏角标按钮 / ⌥⌘I 切换，
  内容重组为 待办 / 系统 / 活动 三段）；readiness 条仅在未就绪时出现；
  服务状态收敛为单图标 + popover；移除重复 chips、侧边栏信号块与
  四张冗余 Inspector 卡片（净 -700 行 UI 代码）。

## 下一步

### Phase 3 — WebApp Runtime（Phase A，不需要 Node）

目标：vibe coding 能产出可运行的小型 webapp。

- 新插件类型 `webapp`：包放 `.her/webapps/<id>/`，manifest 声明入口
  与权限，走既有 draft → review → install 审批链。
- Swift 内建 HTTP server（复用 LocalInboxBridgeServer 模式）托管静态
  HTML/JS + 一个 SQLite REST API（系统 `SQLite3` C 库，零依赖）。
- 呈现：`WKWebView` 独立 tab 页优先，widget 卡片其次。
- 安全红线：只绑 `127.0.0.1`；每个 webapp 一个随机 token；文件系统
  只允许自身目录；数据库固定 `.her/webapps/<id>/data.db`；
  网络外呼默认禁止，需 manifest 声明 + 审批。
- 验收：生成一个真实日常使用的小 app（记录/清单类），闭环跑通。

### Phase B — 进程运行时

复用用户机器已有的 `node` / `python3`（不打包 runtime）；App 负责
进程生命周期：端口分配、健康检查、日志落 `.her/logs`、退出即杀；
安装仍走审批门。

### Phase C — Widget 嵌入对话

对话内 widget 卡片（固定高度，类似 artifact chip）+ Dashboard 页。

### 持续项

- Developer ID 签名 + 公证 + DMG（发布通道）。
- 无障碍：键盘导航、对比度、VoiceOver 标签。
- 长期记忆质量评估（基于真实 AgentMem writeback）。
