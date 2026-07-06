import AppKit
import SwiftUI

/// The browser drawer: the agent's view of the real Chrome window — a live
/// screenshot stream plus the current URL. The real Chrome is a separate
/// window the user can also drive by hand; this panel is optional (toggled
/// from the toolbar) and shows what the conversation is doing.
struct BrowserDrawer: View {
    @EnvironmentObject private var model: AppViewModel
    @ObservedObject private var controller: BrowserController
    @State private var pollTimer: Timer?

    init(controller: BrowserController) {
        self.controller = controller
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.caption)
                    .foregroundStyle(AppTheme.coral)
                Text("浏览器")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                Text(statusLabel)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(1)
                Spacer()
                Toggle(isOn: $model.browserAutonomyGranted) {
                    Text("自动操作")
                        .font(.caption2)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(AppTheme.coral)
                .help("开启后，Her 在本会话可自行导航/点击/输入，无需逐步批准（仍全程可见、可随时关闭）")
                Button {
                    model.isBrowserPresented = false
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }
                .buttonStyle(.plain)
                .help("收起浏览器")
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Color.white.opacity(0.5))

            content
        }
        .task { await start() }
        .onDisappear { pollTimer?.invalidate() }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .stopped:
            centered("浏览器未启动", systemImage: "globe", detail: "让 Her 打开浏览器，或在对话里说\"打开浏览器\"。")
        case .bootstrapping:
            centered("正在准备浏览器环境…", systemImage: "arrow.down.circle", detail: "首次使用会安装浏览器运行时（patchright），可能需要一两分钟。")
        case .starting:
            centered("正在启动真实 Chrome…", systemImage: "hourglass", detail: "会复用你的持久登录配置。")
        case .failed(let message):
            centered("启动失败", systemImage: "exclamationmark.triangle", detail: message)
        case .running:
            if let png = controller.latestScreenshot, let image = NSImage(data: png) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.04))
            } else {
                centered("已连接，等待画面…", systemImage: "photo", detail: controller.currentURL)
            }
        }
    }

    private func centered(_ title: String, systemImage: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(AppTheme.coral)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var statusLabel: String {
        switch controller.phase {
        case .running: return controller.currentURL.isEmpty ? "已就绪" : controller.currentURL
        case .starting: return "启动中…"
        case .bootstrapping: return "安装中…"
        case .failed: return "失败"
        case .stopped: return "未启动"
        }
    }

    private func start() async {
        // Live preview: refresh the screenshot while the drawer is visible.
        pollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            guard controller.isRunning else { return }
            Task { @MainActor in await controller.refreshScreenshot() }
        }
        pollTimer = timer
    }
}
