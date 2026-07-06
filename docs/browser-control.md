# Her Desktop 浏览器控制

Date: 2026-07-06

让对话能打开并驱动浏览器，反检测、复用登录。分两条目标路径：**专用 Chrome**
（默认，独立持久 profile）和**日常 Chrome**（通过扩展驱动你正在用的浏览器）。

## 架构

```
对话 → browser.* capability → BrowserBridging
                               ├─ 专用: BrowserController → Python sidecar(patchright) → 真实 Chrome
                               └─ 日常: ExtensionBrowserBridge → BrowserExtensionServer(loopback) ← MV3 扩展 → 你的 Chrome
```

- **引擎**：patchright（Playwright 的 CDP-泄漏修补版）。nodriver 因非 UTF-8
  源码字节在任何现代 Python 上 import 失败，已弃用。
- **反检测配置**（专用模式）：`channel="chrome"` 真实稳定版、持久 profile、
  `ignore_default_args=["--enable-automation"]` +
  `--disable-blink-features=AutomationControlled`。实测 `navigator.webdriver=false`、
  非 headless、真实 WebGL 厂商、真实语言与核心数。
- **人类化**：鼠标分段抖动移动到元素内随机点，逐字符随机延时打字、偶发词间停顿。
- **本地状态**：venv 与 profile 在 `.her/browser/`（gitignore）。

## 能力（builtin.browser-control）

| 能力 | 审批 | 说明 |
|---|---|---|
| browser.open | 免 | 打开浏览器并显示当前页 |
| browser.read | 免 | 返回 URL/标题/正文 + **带索引的可交互元素列表** |
| browser.detect | 免 | 反检测自检（webdriver/headless/插件/WebGL…） |
| browser.navigate | 需 | 导航到 URL |
| browser.click | 需 | 按元素 index / 选择器 / 坐标点击 |
| browser.type | 需 | 按 index / 选择器输入文本或特殊键 |

需审批的动作在**自动操作**开关打开时免逐步审批（用户在抽屉里显式打开，
agent 不能自授权；开启后工具循环放宽到 20 轮以支持多步串联）。

## 多步浏览（无需视觉模型）

`browser.read` 给每个可交互元素编号（`[3] input/search: 搜索框`），对话用
`{index: 3}` 精确点击/输入，再 read 看结果，循环推进 —— 纯文本 LLM 即可驱动
多步任务，不依赖截图视觉。

## 日常 Chrome（扩展）首次设置

1. 在浏览器抽屉切到「日常 Chrome」，点「打开扩展文件夹」（会把扩展复制到
   `.her/browser-extension/` 并在访达选中）。
2. Chrome → `chrome://extensions` → 打开右上「开发者模式」→「加载已解压的扩展程序」
   → 选 `.her/browser-extension/` 文件夹。
3. 在扩展的「选项」页填入抽屉里显示的**端口**（8799）和**令牌**，保存。
4. 抽屉状态变绿「扩展已连接」后，对话即可驱动你正在用的这个 Chrome。

扩展用标准 `chrome.scripting`/`chrome.tabs`（无调试横幅），只连 `127.0.0.1`
且每次请求校验令牌。因为一切发生在你本人的浏览器里、无自动化驱动，反检测
强度最高。

## 后续

- 扩展模式的人类化输入目前用 DOM 事件（不如专用模式的真实按键节奏）；
  如需可加 `chrome.debugger` 真实按键（会有横幅）。
- 专用模式截图流已在抽屉实时显示；扩展模式画面即你自己的 Chrome 窗口。
