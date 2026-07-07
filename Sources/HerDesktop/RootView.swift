import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppViewModel
    @EnvironmentObject private var chrome: UIChrome

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 240)
            Divider().opacity(0.45)
            VStack(spacing: 0) {
                CenterWorkspaceView()
                    .frame(maxHeight: .infinity)
                if chrome.isBrowserPresented {
                    Divider().opacity(0.45)
                    BrowserDrawer(controller: model.browserControllerInstance)
                        .frame(height: 360)
                }
                if chrome.isTerminalPresented {
                    Divider().opacity(0.45)
                    TerminalDrawer()
                        .frame(height: 280)
                }
            }
            .frame(minWidth: 560)
            if chrome.isInspectorPresented {
                Divider().opacity(0.45)
            }
            // The inspector is built ONCE and kept alive. Toggling only collapses
            // its footprint (outer frame 330→0 + clipped), so its cards — and the
            // expensive WKWebViews inside — are never destroyed/rebuilt. The inner
            // fixed 330 width keeps the content from re-laying-out on toggle; only
            // the space it occupies changes. Rebuilding on every open was the lag.
            InspectorView()
                .frame(width: 330)
                // Collapse the footprint to 0 when hidden, anchoring the 330-wide
                // content to the leading edge so the clipped overflow spills off the
                // window's right edge — never over the center toolbar.
                .frame(width: chrome.isInspectorPresented ? 330 : 0, alignment: .leading)
                .clipped()
                // .clipped() hides drawing but NOT hit-testing: without this the
                // invisible collapsed inspector would still eat clicks on the
                // toolbar buttons it overlaps.
                .allowsHitTesting(chrome.isInspectorPresented)
        }
        .background(AppTheme.windowBackground)
        .modifier(VibePluginComposerHost())
        .task {
            model.startBootstrap()
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
