# 视频通话集成研究：Vidu-S1 实时数字人

> 来源：飞书文档《Vidu-S1：实时数字人互动 API 接入指南（内测中）》
> https://shengshu.feishu.cn/wiki/XomAwRr4riv1QJkWBPTcy4Gunue（2026-07-14 摘录）

## 一、Vidu-S1 是什么

流式视频生成模型驱动的实时交互数字人：给一张形象图 + 一段人设文字，就能生成一个可以实时视频通话的数字人。支持 audio（纯语音）和 video（音视频）两种模式，支持文字插话、音色克隆（30+ 系统音色）、短期记忆。

**传输架构**：数字人的音视频不走 HTTP，走**阿里云 RTC（ARTC）频道**；控制信令走 WebSocket。

## 二、接入流程（6 步）

1. `POST https://api.vidu.cn/live/v1/lives`（海外 api.vidu.com），`Authorization: Token vda_xxx`
   - 请求体：`call_mode`（audio/video）+ `avatar{persona, image_uri, name, voice}`
   - 返回：`live.id`（会话 ID）+ `rtc{app_id, channel_id, user_id, token, token_expire_at}`
2. 用返回的 rtc 凭证加入阿里云 RTC 频道，推本地麦克风（video 模式还要推摄像头），订阅数字人流
   - 频道内 UID 约定：我 `live-user-{creatorID}-{liveID}`，数字人音频 `live-bot-...`，数字人视频 `live-video-push-...`
3. 建 WebSocket `wss://api.vidu.cn/live/ws/live/connect?live_id={id}`（**鉴权走 Header**），发 `{type:1, payload:{conn_init:{version:1}}}`
4. 等 `conn_init_ack`：`success:true` 开始互动；`NOT_READY`（video 模式必现）→ 断开重连，指数退避 2s→4s→8s；`LIVE_CONN_INIT_FAILED` → 回到第 1 步重建会话
5. 互动中：服务端每 5s ping，15s 内无消息判死连接；文字插话 `{type:99, payload:{text_msg:{content}}}`；监听 `{type:6, hangup}` 强制断开（user_end/timeout/audit_violation/credit_insufficient…）+ WS 异常关闭兜底
6. 挂断：发 `{type:5, payload:{hangup:{hangup_reason:"user_end"}}}` → 关 WS → RTC leaveChannel；`GET /live/v1/lives/{id}` 查账单

**关键限制**：
- 单次会话最长 **600 秒**，到点服务端主动断
- 计费从 `conn_init_ack success:true` 起：**每 2 秒 3 积分**（≈ 90 积分/分钟，积分单价 0.03125 → 约 ¥2.8/分钟），发起前余额须 >45 积分
- rtc.token 默认 1 小时有效，过期需重建会话
- 音色克隆 `POST /live/v1/voices/clone`：10–20s 音频（WAV/MP3/M4A，<10MB），899 积分/次，前 10 次免费

## 三、与 her-desktop 的契合点

| Vidu 概念 | her-desktop 现有实体 |
|---|---|
| `avatar.persona`（人设文字） | `CharacterCard.prompt`（角色卡，RoleplayStore） |
| `avatar.image_uri`（形象图） | 角色卡目前只有 emoji，**需新增形象图字段** |
| `avatar.voice` / 音色克隆 | 现有 AgentLLM TTS 音色是独立体系，需在角色卡上加 Vidu 音色映射 |
| 短期记忆（Vidu 侧） | 通话结束后可把对话要点写回 AgentMem（同 recap 通路） |

文档还给了完整的人设模板（姓名/年龄/身份/性格/外貌/背景/与用户关系/动作习惯/回复习惯/口头禅），可以作为角色卡编辑器的引导结构。

## 四、方案选型

### 方案 A（推荐）：Swift 管信令 + WKWebView(ARTC Web SDK) 管媒体

- **Swift 层**（新 `ViduLiveService`）：REST 创建/查询会话、WebSocket 控制信令、心跳、NOT_READY 指数退避、挂断、600s 倒计时。用 `URLSessionWebSocketTask` —— 项目已有 DashScope WS 的成熟经验，而且**浏览器 JS 的 WebSocket API 设不了 Authorization Header**，信令天然只能放 Swift 层（或加本地代理），正好形成"Swift 管信令、Web 管媒体"的干净分层。
- **WebView 层**：一个本地 call.html，用阿里云 **ARTC Web SDK**（npm `aliyun-rtc-sdk`，或 CDN `g.alicdn.com/apsara-media-box/imp-web-rtc/<ver>/aliyun-rtc-sdk.js`）joinChannel、推麦克风/摄像头、订阅并渲染数字人视频。Swift 通过 `WKScriptMessageHandler`/`evaluateJavaScript` 传 rtc 凭证、收状态回调。
- **为什么可行**：WKWebView 自 macOS 12 起支持 getUserMedia/WebRTC；`http://127.0.0.1` 是 secure context；只需
  1. Info.plist 加 `NSCameraUsageDescription`（麦克风描述已有）
  2. WKUIDelegate 实现 `webView(_:requestMediaCapturePermissionFor:initiatedByFrame:type:decisionHandler:)` → `.grant`（WebAppWebView 的 Coordinator 已经是 WKUIDelegate，顺手加）
- **为什么优于原生 SDK**：
  - 项目是纯 SwiftPM（无 Xcode 工程），原生 Mac SDK 是手动拷贝的 framework zip，要处理 binaryTarget/rpath/`codesign --deep` 嵌套签名，侵入 build-app.sh
  - Mac 原生 SDK 版本明显落后（7.8 vs Android/iOS 7.11），Web SDK 是阿里云持续迭代的主力端
  - **绕开 CoreAudio 语音处理的老坑**（聚合设备上 VP 输出全零，见 her-macos-voice-processing）：WebKit 的 getUserMedia 自带独立的 AEC/NS 通路，不经过我们的 AVAudioEngine
- **注意**：BlackHole 之类虚拟设备被设为系统默认输入时，getUserMedia 同样只收到静音——沿用现有"全零检测 + 提示"的经验。

### 方案 B：原生 AliRTCSdk for Mac

下载 zip framework 手动集成。控制力最强（音频路由、设备选择），但 SwiftPM 集成成本高、版本旧、可能重踩 AEC 坑。仅当 WKWebView 方案遇到不可解的媒体问题时再回退。

### 方案 C：复用 browser sidecar 开真 Chrome

体验割裂（跳出 app 窗口），不符合产品气质，排除。

## 五、落地蓝图（按阶段）

- **P0 验证（无 UI）**：拿 API Key（Vidu 开放平台工作台，格式 `Token vda_xxx`）→ 脚本建会话 → 一个临时 HTML 页（Web SDK）验证能看到/听到数字人 → 验证 WKWebView 里 getUserMedia + RTC 全链路通
- **P1 audio 模式进 app**：ViduLiveService + 通话浮层（角色卡头像 + 声波 + 挂断），角色卡 prompt → persona
- **P2 video 模式**：角色卡新增形象图字段（图片 URL 或 base64 ≤20MB，PNG/JPG/WEBP，单人图）；摄像头权限；全屏通话视图；NOT_READY 重试 UX（"数字人正在准备…"）
- **P3 打磨**：600s 到点无缝续场（提前重建会话）、积分余额显示与 credit_insufficient 处理、音色克隆管理、通话摘要写回 AgentMem

## 六、风险清单

1. **内测阶段**：API 可能变动；需要联系拿 Key（新用户 1000 体验积分）
2. **成本**：约 ¥2.8/分钟，长时间陪伴场景成本显著，UI 必须透出计费状态
3. **600s 硬上限**：续场会有形象/上下文重置感（短期记忆在 Vidu 侧，重建会话即丢失），需要把上下文压进 persona 或接受断点
4. **video 模式 NOT_READY 必现**：重试逻辑不是可选项
5. **WS 心跳**：确认 URLSessionWebSocketTask 对服务端 ping 的自动 pong（URLSession 默认会回 pong，但需实测 15s 判死规则）

## 七、实测补充（2026-07-15，WS 探测）

用脚本开真实 audio 会话（42 秒，63 积分）实测 WS 下行：**纯控制面**。
conn_init_ack 和 hangup 回执之外零内容帧——发 text_msg 逗数字人说话也没有
任何转写/回复文本下推。结论：

- 上下文注入唯一入口 = 建会话时的 `avatar.persona`（不限字符数）。
- 通话文本 Vidu 不提供，要自建 ASR（并行采集麦克风喂 DashScope）。
- 通话中注入唯一通道 = type 99 text_msg（数字人会当用户消息回应，
  非静默注入；【记忆】前缀协议待实测 = P3，暂缓）。
- audio 模式不加入 RTC 频道也能 conn_init 成功并计费（42s=63 积分）。
- 实测账号单次时长上限 7200s（文档写 600s）。
