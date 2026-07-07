import SwiftUI

/// Presentation-only toggles for the right inspector and the bottom drawers.
///
/// These live in their own tiny observable, deliberately separate from the very
/// large `AppViewModel`. SwiftUI invalidates *every* view observing an
/// `ObservableObject` whenever that object emits `objectWillChange` — regardless
/// of which property changed. So while these flags lived on `AppViewModel`,
/// flipping a pure UI switch (open the inspector) forced the sidebar, every
/// conversation message, and every inspector card to recompute their bodies. On
/// a single giant view model that made toggling feel sluggish.
///
/// Keeping them here means a toggle fires only `UIChrome.objectWillChange`, so
/// just the handful of views that actually read these flags update.
@MainActor
final class UIChrome: ObservableObject {
    @Published var isInspectorPresented = false
    @Published var isTerminalPresented = false
    @Published var isBrowserPresented = false
}
