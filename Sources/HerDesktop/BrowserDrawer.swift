import AppKit
import SwiftUI

/// The browser drawer: the agent's view of the browser. In 专用 (sidecar)
/// mode it streams screenshots of a dedicated-profile Chrome. In 日常 mode
/// it drives the user's everyday Chrome through the extension and shows the
/// connection + setup, since the live picture is that real Chrome window.
struct BrowserDrawer: View {
    @EnvironmentObject private var model: AppViewModel
    @EnvironmentObject private var chrome: UIChrome
    @ObservedObject private var controller: BrowserController
    @State private var pollTimer: Timer?

    init(controller: BrowserController) {
        self.controller = controller
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.browserTarget == .everyday {
                everydayPanel
            } else {
                sidecarContent
            }
        }
        .task { await start() }
        .onDisappear { pollTimer?.invalidate() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.caption)
                .foregroundStyle(AppTheme.coral)
            Picker("", selection: $model.browserTarget) {
                Text("专用 Chrome").tag(AppViewModel.BrowserTarget.sidecar)
                Text("日常 Chrome").tag(AppViewModel.BrowserTarget.everyday)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .onChange(of: model.browserTarget) { _, target in
                if target == .everyday { model.startExtensionServerIfNeeded() }
            }
            Spacer()
            Toggle(isOn: $model.browserAutonomyGranted) {
                Text("自动操作").font(.caption2)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(AppTheme.coral)
            .help("开启后，Her 在本会话可自行导航/点击/输入，无需逐步批准（仍全程可见、可随时关闭）")
            Button {
                chrome.isBrowserPresented = false
            } label: {
                Image(systemName: "chevron.down").font(.caption).foregroundStyle(AppTheme.muted)
            }
            .buttonStyle(.plain)
            .help("收起浏览器")
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Color.white.opacity(0.5))
    }

    @ViewBuilder
    private var sidecarContent: some View {
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
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.04))
            } else {
                centered("已连接，等待画面…", systemImage: "photo", detail: controller.currentURL)
            }
        }
    }

    private var everydayPanel: some View {
        let config = model.extensionConfig
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isExtensionConnected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(model.isExtensionConnected
                     ? "扩展已连接 · 驱动你的日常 Chrome" + (model.extensionVersion.isEmpty ? "" : "（v\(model.extensionVersion)）")
                     : "等待扩展连接…")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
            }
            Text("画面在你自己的 Chrome 窗口里。反检测强度最高：用的是你本人的浏览器，没有任何自动化驱动。")
                .font(.caption2)
                .foregroundStyle(AppTheme.muted)
            Divider().opacity(0.4)
            Text("首次设置：先点下方「导出扩展并打开文件夹」，然后 chrome://extensions → 打开开发者模式 → 加载已解压的扩展 → 选择「Her Desktop Browser Extension」文件夹 → 在扩展选项里填入：")
                .font(.caption2)
                .foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                configField("端口", "\(config.port)")
                configField("令牌", config.token)
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(config.token, forType: .string)
                } label: {
                    Label("复制令牌", systemImage: "doc.on.doc").font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Button {
                model.openBrowserExtensionFolder()
            } label: {
                Label("导出扩展并打开文件夹", systemImage: "folder").font(.caption2)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.coral)
            .controlSize(.small)
            .help("把扩展复制到「文稿 / Her Desktop Browser Extension」并在访达中显示")
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func configField(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(AppTheme.muted)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(AppTheme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func centered(_ title: String, systemImage: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.title2).foregroundStyle(AppTheme.coral)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.ink)
            if !detail.isEmpty {
                Text(detail).font(.caption2).foregroundStyle(AppTheme.muted)
                    .multilineTextAlignment(.center).lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
    }

    private func start() async {
        pollTimer?.invalidate()
        let controller = self.controller
        let timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in
                guard controller.isRunning else { return }
                await controller.refreshScreenshot()
            }
        }
        timer.tolerance = 0.3 // screenshot cadence is slack-tolerant
        pollTimer = timer
    }
}
