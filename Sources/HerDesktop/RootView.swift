import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 240)
            Divider().opacity(0.45)
            CenterWorkspaceView()
                .frame(minWidth: 560)
            if model.isInspectorPresented {
                Divider().opacity(0.45)
                InspectorView()
                    .frame(width: 330)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: model.isInspectorPresented)
        .background(AppTheme.windowBackground)
        .modifier(VibePluginComposerHost())
        .task {
            await model.bootstrapRuntime()
        }
    }
}

enum AppTheme {
    static let coral = Color(red: 0.94, green: 0.37, blue: 0.33)
    static let rose = Color(red: 0.98, green: 0.88, blue: 0.84)
    static let burgundy = Color(red: 0.22, green: 0.09, blue: 0.08)
    static let ink = Color(red: 0.16, green: 0.12, blue: 0.11)
    static let muted = Color(red: 0.46, green: 0.39, blue: 0.36)
    static let cream = Color(red: 1.0, green: 0.985, blue: 0.955)
    static let panel = Color.white.opacity(0.58)
    static let windowBackground = LinearGradient(
        colors: [Color(red: 1.0, green: 0.98, blue: 0.94), Color(red: 0.98, green: 0.93, blue: 0.88)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
