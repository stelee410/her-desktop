import SwiftUI
import WebKit

/// 视频通话浮层：Swift 负责 Vidu 信令（ViduCallModel），内嵌 WebView
/// 用阿里云 ARTC Web SDK 负责音视频推拉流与渲染。
struct VideoCallView: View {
    @Environment(\.dismiss) private var dismiss

    let config: HerAppConfig
    let persona: String
    let displayName: String

    @StateObject private var call: ViduCallModel
    @State private var webError: String?

    init(config: HerAppConfig, persona: String, displayName: String) {
        self.config = config
        self.persona = persona
        self.displayName = displayName
        _call = StateObject(wrappedValue: ViduCallModel(
            apiKey: config.viduAPIKey,
            host: config.viduHost,
            callMode: config.viduCallMode
        ))
    }

    private var isConfigured: Bool {
        config.hasViduKey && !config.viduAvatarImageURI.isEmpty
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if isConfigured {
                CallWebView(
                    rtc: call.rtc,
                    callMode: call.callMode,
                    avatarImageURI: config.viduAvatarImageURI,
                    terminated: !call.isActive && call.phase != .idle
                ) { event, detail in
                    if event == "error" {
                        webError = detail
                    }
                }
                overlayControls
            } else {
                setupGuidance
            }
        }
        .frame(minWidth: 520, minHeight: 660)
        .task {
            guard isConfigured else { return }
            call.start(
                persona: persona,
                imageURI: config.viduAvatarImageURI,
                name: displayName,
                voice: config.viduVoice
            )
        }
        .onDisappear {
            if call.isActive { call.hangUp() }
        }
    }

    private var overlayControls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(call.phase == .live ? Color.green : AppTheme.coral)
                    .frame(width: 8, height: 8)
                Text(displayName)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                if case .live = call.phase {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(durationText(now: context.date))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.black.opacity(0.35))

            if let message = terminalMessage {
                Spacer()
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.55))
                    .clipShape(Capsule())
            }
            Spacer()

            Button {
                call.hangUp()
                dismiss()
            } label: {
                Image(systemName: terminalMessage == nil ? "phone.down.fill" : "xmark")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(terminalMessage == nil ? Color.red : Color.white.opacity(0.22))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help(terminalMessage == nil ? "挂断" : "关闭")
            .padding(.bottom, 22)
        }
    }

    private var statusText: String {
        if let webError { return webError }
        switch call.phase {
        case .idle, .creating: return "正在创建数字人…"
        case .waitingAgent(let attempt):
            return attempt <= 1 ? "等待数字人上线…" : "等待数字人上线（第 \(attempt) 次尝试）…"
        case .live: return "通话中"
        case .ended(let message), .failed(let message): return message
        }
    }

    /// 通话结束/失败后浮层中央的提示；nil 表示仍在通话流程中。
    private var terminalMessage: String? {
        switch call.phase {
        case .ended(let message), .failed(let message): return message
        case .idle, .creating, .waitingAgent, .live: return nil
        }
    }

    private func durationText(now: Date) -> String {
        guard let start = call.liveStartedAt else { return "" }
        let elapsed = max(0, Int(now.timeIntervalSince(start)))
        let limit = call.live?.liveDurationSeconds ?? 600
        let remaining = max(0, limit - elapsed)
        return String(format: "%02d:%02d · 剩余 %02d:%02d", elapsed / 60, elapsed % 60, remaining / 60, remaining % 60)
    }

    private var setupGuidance: some View {
        VStack(spacing: 14) {
            Image(systemName: "video.slash")
                .font(.system(size: 40))
                .foregroundStyle(AppTheme.coral)
            Text("视频通话还没配置好")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(config.hasViduKey
                 ? "还差数字人的形象图：在 设置 → 视频通话（Vidu 数字人）里填一张单人图片的 URL。"
                 : "在 设置 → 视频通话（Vidu 数字人）里填入 Vidu API key（vda_…）和数字人形象图。")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("关闭") { dismiss() }
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .padding(40)
    }
}

/// 测试探针：CallWebView 本体是 private，这里只暴露纯函数的 payload 构造。
enum CallWebViewJoinPayloadProbe {
    static func payload(rtc: ViduRTCCredentials, callMode: String, avatarImageURI: String) -> String {
        CallWebView.joinPayload(rtc: rtc, callMode: callMode, avatarImageURI: avatarImageURI)
    }
}

/// 承载 ARTC Web SDK 的 WebView。页面从 bundle 加载，用 https baseURL
/// 取得 secure context（getUserMedia 的前提）；RTC 凭证就绪后注入 join。
private struct CallWebView: NSViewRepresentable {
    var rtc: ViduRTCCredentials?
    var callMode: String
    var avatarImageURI: String
    /// 通话已结束：让页面退出 RTC 频道（停止推拉流）。
    var terminated: Bool
    var onEvent: (String, String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEvent: onEvent)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(context.coordinator, name: "herCall")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        if let url = Bundle.module.url(forResource: "vidu-call", withExtension: "html"),
           let html = try? String(contentsOf: url, encoding: .utf8) {
            // 假 https 源：让页面拿到 secure context，否则 getUserMedia 不可用。
            webView.loadHTMLString(html, baseURL: URL(string: "https://vidu-call.her.local/"))
        } else {
            onEvent("error", "通话页面资源缺失")
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onEvent = onEvent
        if let rtc {
            context.coordinator.joinIfNeeded(
                webView,
                payload: Self.joinPayload(rtc: rtc, callMode: callMode, avatarImageURI: avatarImageURI)
            )
        }
        if terminated {
            context.coordinator.leaveIfNeeded(webView)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.leaveIfNeeded(webView)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "herCall")
    }

    nonisolated static func joinPayload(rtc: ViduRTCCredentials, callMode: String, avatarImageURI: String) -> String {
        let object: [String: String] = [
            "token": rtc.token,
            "userId": rtc.userID,
            "channelId": rtc.channelID,
            "appId": rtc.appID,
            "callMode": callMode,
            "avatar": callMode == "audio" ? avatarImageURI : ""
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
        var onEvent: (String, String) -> Void
        private var pageLoaded = false
        private var pendingJoinPayload: String?
        private var joined = false
        private var left = false

        init(onEvent: @escaping (String, String) -> Void) {
            self.onEvent = onEvent
        }

        func joinIfNeeded(_ webView: WKWebView, payload: String) {
            guard !joined, !left else { return }
            guard pageLoaded else {
                pendingJoinPayload = payload
                return
            }
            joined = true
            webView.evaluateJavaScript("window.herCall.join(\(payload));")
        }

        func leaveIfNeeded(_ webView: WKWebView) {
            guard !left else { return }
            left = true
            webView.evaluateJavaScript("window.herCall && window.herCall.leave();")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageLoaded = true
            if let payload = pendingJoinPayload {
                pendingJoinPayload = nil
                joinIfNeeded(webView, payload: payload)
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "herCall",
                  let body = message.body as? [String: Any],
                  let event = body["event"] as? String else {
                return
            }
            onEvent(event, body["detail"] as? String ?? "")
        }

        /// getUserMedia 的授权决定：TCC 已在 app 层面弹过系统对话框，
        /// 页面是我们自己打包的，直接放行。
        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            decisionHandler(.grant)
        }
    }
}
