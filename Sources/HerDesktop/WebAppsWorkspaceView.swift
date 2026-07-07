import SwiftUI

struct WebAppsWorkspaceView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var removalCandidate: WebAppManifest?
    @State private var reloadToken = UUID()

    var body: some View {
        if let selected = model.selectedWebAppID,
           let app = model.webApps.first(where: { $0.id == selected }),
           let url = model.webAppURL(app.id) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button {
                        model.selectedWebAppID = nil
                    } label: {
                        Label("Apps", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.coral)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                        if !app.description.isEmpty {
                            Text(app.description)
                                .font(.caption2)
                                .foregroundStyle(AppTheme.muted)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    Button {
                        reloadToken = UUID()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.muted)
                    .help("重新加载")

                    Button {
                        model.openWebAppInBrowser(app.id)
                    } label: {
                        Image(systemName: "safari")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.muted)
                    .help("在浏览器中打开")
                }
                .padding(.horizontal, 20)
                .frame(height: 48)
                .background(Color.white.opacity(0.38))

                WebAppWebView(url: url)
                    .id(reloadToken)
            }
        } else {
            appList
        }
    }

    private var appList: some View {
        WorkspacePage(title: "Apps", subtitle: "\(model.webApps.count) 个本地小应用 · 数据保存在本机 SQLite") {
            let widgetApps = model.webApps.filter { $0.widget != nil }
            if !widgetApps.isEmpty {
                WorkspacePanel(title: "小组件", trailing: "\(widgetApps.count)") {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 280), spacing: 12)],
                        alignment: .leading,
                        spacing: 12
                    ) {
                        ForEach(widgetApps) { app in
                            if let url = model.webAppWidgetURL(app.id) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(app.name)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(AppTheme.ink)
                                        Spacer()
                                        Button {
                                            model.openWebApp(app.id)
                                        } label: {
                                            Image(systemName: "arrow.up.right.square")
                                                .font(.caption)
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(AppTheme.coral)
                                        .help("打开完整应用")
                                    }
                                    WebAppWebView(url: url, transparent: true)
                                        .frame(height: app.widget?.height ?? 160)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.black.opacity(0.06), lineWidth: 1)
                                        )
                                        // Widgets are glanceable: a click anywhere opens the full app.
                                        .overlay(
                                            Rectangle()
                                                .fill(Color.clear)
                                                .contentShape(Rectangle())
                                                .onTapGesture { model.openWebApp(app.id) }
                                        )
                                        .help("点击打开完整应用")
                                }
                                .padding(10)
                                .background(Color.white.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
            }
            if model.webApps.isEmpty {
                WorkspacePanel(title: "还没有应用", trailing: "Vibe") {
                    VStack(alignment: .leading, spacing: 12) {
                        EmptyWorkspaceLine(
                            icon: "macwindow.on.rectangle",
                            text: "在对话里直接描述你想要的小工具，Her 会为你生成一个带本地数据库的网页应用。"
                        )
                        Button {
                            model.draft = "帮我做一个每日习惯打卡的小应用：可以添加习惯、每天打卡、看最近7天的完成情况。"
                            model.selectedSection = .today
                        } label: {
                            Label("试试：习惯打卡应用", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.coral)
                        .controlSize(.small)
                    }
                }
            } else {
                WorkspacePanel(title: "已安装", trailing: "\(model.webApps.count)") {
                    VStack(spacing: 10) {
                        ForEach(model.webApps) { app in
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(AppTheme.rose.opacity(0.75))
                                    .frame(width: 38, height: 38)
                                    .overlay(
                                        Image(systemName: "macwindow.on.rectangle")
                                            .foregroundStyle(AppTheme.coral)
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AppTheme.ink)
                                    Text(app.description.isEmpty ? app.id : app.description)
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.muted)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button {
                                    model.openWebApp(app.id)
                                } label: {
                                    Label("打开", systemImage: "arrow.up.right.square")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(AppTheme.coral)
                                .controlSize(.small)

                                Button {
                                    model.togglePinWebApp(app.id)
                                } label: {
                                    Image(systemName: app.isPinned ? "pin.fill" : "pin")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(app.isPinned ? AppTheme.coral : AppTheme.muted)
                                .help(app.isPinned ? "从小组件面板取消固定" : "固定到小组件面板")

                                Button {
                                    removalCandidate = app
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(AppTheme.muted)
                                .help("删除应用及其数据")
                            }
                            .padding(10)
                            .background(Color.white.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "删除应用",
            isPresented: Binding(
                get: { removalCandidate != nil },
                set: { if !$0 { removalCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: removalCandidate
        ) { app in
            Button("删除「\(app.name)」及其数据", role: .destructive) {
                model.removeWebApp(app.id)
            }
            Button("取消", role: .cancel) {}
        } message: { app in
            Text("会同时删除该应用的 SQLite 数据（\(app.id)/data.db），无法恢复。")
        }
    }
}
