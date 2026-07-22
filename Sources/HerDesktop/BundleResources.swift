import Foundation

/// Empty anchor so `Bundle(for:)` can locate the code module's own bundle.
private final class BundleFinder {}

extension Bundle {
    /// Robust locator for the SwiftPM resource bundle.
    ///
    /// The compiler-generated `Bundle.module` is unfit for a packaged `.app`:
    /// it looks only at `Bundle.main.bundleURL/HerDesktop_HerDesktop.bundle`
    /// (the app *root*, where a signable app never keeps resources) and then
    /// falls back to an absolute path baked into the dev machine's `.build`
    /// directory. On the build machine that fallback exists, so it silently
    /// works; on every other machine both paths miss and it `fatalError`s at
    /// launch (crash in `AppViewModel.init` → `ProjectPromptLoader.load`).
    ///
    /// This resolver checks the places the bundle actually lands — first
    /// `Contents/Resources` (the packaged `.app`, where `build-app.sh` copies
    /// it and codesign can seal it), then next to the executable (`swift run`
    /// and CLI layouts) — and degrades to `Bundle.main` instead of crashing,
    /// so a missing resource returns `nil` rather than killing the process.
    static let herResources: Bundle = {
        let bundleName = "HerDesktop_HerDesktop.bundle"
        // Anchors the bundle relative to the code that references it — this is
        // what makes it resolvable under `swift test`, where Bundle.main is the
        // xctest runner and the resource bundle sits beside the test bundle.
        let ownBundle = Bundle(for: BundleFinder.self)
        var candidates: [URL] = []
        for anchor in [Bundle.main, ownBundle] {
            if let resourceURL = anchor.resourceURL {
                candidates.append(resourceURL.appendingPathComponent(bundleName))
            }
            candidates.append(anchor.bundleURL.appendingPathComponent(bundleName))
            // Sibling of the anchor bundle — this is where SwiftPM drops the
            // resource bundle next to a `.xctest` bundle during `swift test`.
            candidates.append(anchor.bundleURL.deletingLastPathComponent().appendingPathComponent(bundleName))
            if let executableDir = anchor.executableURL?.deletingLastPathComponent() {
                candidates.append(executableDir.appendingPathComponent(bundleName))
            }
        }
        for url in candidates {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return Bundle.main
    }()
}
