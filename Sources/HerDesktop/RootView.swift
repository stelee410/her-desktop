import AppKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppViewModel
    @EnvironmentObject private var chrome: UIChrome
    // Pane sizes are user-draggable (divider handles) and persist across
    // launches.
    @AppStorage("pane.sidebarWidth") private var sidebarWidth = 240.0
    @AppStorage("pane.inspectorWidth") private var inspectorWidth = 330.0
    @AppStorage("pane.browserDrawerHeight") private var browserDrawerHeight = 360.0
    @AppStorage("pane.terminalDrawerHeight") private var terminalDrawerHeight = 280.0

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: sidebarWidth)
            PaneResizeDivider(vertical: true, grows: 1, size: $sidebarWidth, range: 190...400)
            VStack(spacing: 0) {
                CenterWorkspaceView()
                    .frame(maxHeight: .infinity)
                if chrome.isBrowserPresented {
                    PaneResizeDivider(vertical: false, grows: -1, size: $browserDrawerHeight, range: 220...640)
                    BrowserDrawer(controller: model.browserControllerInstance)
                        .frame(height: browserDrawerHeight)
                }
                if chrome.isTerminalPresented {
                    PaneResizeDivider(vertical: false, grows: -1, size: $terminalDrawerHeight, range: 160...520)
                    TerminalDrawer()
                        .frame(height: terminalDrawerHeight)
                }
            }
            .frame(minWidth: 560)
            if chrome.isInspectorPresented {
                PaneResizeDivider(vertical: true, grows: -1, size: $inspectorWidth, range: 260...480)
            }
            // The inspector is built ONCE and kept alive. Toggling only collapses
            // its footprint (outer frame 330→0 + clipped), so its cards — and the
            // expensive WKWebViews inside — are never destroyed/rebuilt. The inner
            // fixed 330 width keeps the content from re-laying-out on toggle; only
            // the space it occupies changes. Rebuilding on every open was the lag.
            InspectorView()
                .frame(width: inspectorWidth)
                // Collapse the footprint to 0 when hidden, anchoring the full-width
                // content to the leading edge so the clipped overflow spills off the
                // window's right edge — never over the center toolbar.
                .frame(width: chrome.isInspectorPresented ? inspectorWidth : 0, alignment: .leading)
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

/// A standard hairline divider that doubles as a drag handle: an invisible
/// widened grab strip overlays it, and dragging resizes the adjacent pane
/// within `range`. `grows` is +1 when the pane grows in the drag direction
/// (sidebar → drag right) and -1 when inverted (drawers grow dragging up,
/// inspector grows dragging left).
private struct PaneResizeDivider: View {
    var vertical: Bool
    var grows: Double
    @Binding var size: Double
    var range: ClosedRange<Double>
    /// The pane size at drag start; deltas apply against this so clamping
    /// doesn't drift when the pointer overshoots the range and comes back.
    @State private var dragBase: Double?

    var body: some View {
        Divider()
            .opacity(0.45)
            .overlay(
                Color.clear
                    .frame(
                        width: vertical ? 9 : nil,
                        height: vertical ? nil : 9
                    )
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let base = dragBase ?? size
                                dragBase = base
                                let delta = vertical ? value.translation.width : value.translation.height
                                size = min(max(base + grows * delta, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in dragBase = nil }
                    )
            )
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
