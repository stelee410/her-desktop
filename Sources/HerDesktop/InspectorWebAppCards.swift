import SwiftUI

/// Pinned web apps as a widget panel: widget-enabled apps render their
/// compact live page; apps without a widget show an icon tile. Clicking
/// either opens the full app in the Apps page.
struct PinnedWebAppsPane: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        if model.pinnedWebApps.isEmpty {
            Panel(title: "小组件", trailing: "0") {
                VStack(alignment: .leading, spacing: 10) {
                    Label("还没有固定的应用", systemImage: "pin")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                    Text("在 Apps 页给应用点 📌 固定后，会常驻在这里。")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                    Button {
                        model.selectedSection = .apps
                    } label: {
                        Label("打开 Apps", systemImage: "macwindow.on.rectangle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        } else {
            ForEach(model.pinnedWebApps) { app in
                PinnedWebAppCard(app: app)
            }
        }
    }
}

struct PinnedWebAppCard: View {
    @EnvironmentObject private var model: AppViewModel
    var app: WebAppManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(app.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                Spacer()
                Button {
                    model.togglePinWebApp(app.id)
                } label: {
                    Image(systemName: "pin.slash")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.muted)
                .help("取消固定")
            }
            if app.widget != nil, let url = model.webAppWidgetURL(app.id) {
                WebAppWebView(url: url, transparent: true)
                    .frame(height: app.widget?.height ?? 160)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.black.opacity(0.06), lineWidth: 1)
                    )
                    .overlay(
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { model.openWebApp(app.id) }
                    )
                    .help("点击打开完整应用")
            } else {
                Button {
                    model.openWebApp(app.id)
                } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(AppTheme.rose.opacity(0.75))
                            .frame(width: 40, height: 40)
                            .overlay(
                                Image(systemName: "macwindow.on.rectangle")
                                    .foregroundStyle(AppTheme.coral)
                            )
                        Text(app.description.isEmpty ? "点击打开应用" : app.description)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.muted)
                            .lineLimit(2)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(AppTheme.coral)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("打开完整应用")
            }
        }
        .padding(12)
        .background(AppTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
