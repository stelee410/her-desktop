import XCTest
@testable import HerDesktop

/// Real end-to-end: launches the patchright sidecar and a real Chrome.
/// Skipped by default (opens a browser window); run explicitly with
/// HER_BROWSER_E2E=1 once the venv is bootstrapped.
@MainActor
final class BrowserControllerIntegrationTests: XCTestCase {
    func testRealBrowserStartNavigateRead() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HER_BROWSER_E2E"] == "1",
            "Set HER_BROWSER_E2E=1 to run the real-browser integration test"
        )
        // Uses the repo's own .her/browser venv + profile.
        let controller = BrowserController(cwd: FileManager.default.currentDirectoryPath)
        try await controller.start()
        XCTAssertTrue(controller.isRunning)

        let nav = try await controller.navigate("example.com")
        XCTAssertTrue(nav.url.contains("example.com"))
        XCTAssertEqual(nav.title, "Example Domain")
        XCTAssertNotNil(nav.screenshotPNG)

        let read = try await controller.read()
        XCTAssertTrue(read.text.contains("Example Domain"))

        let shot = try await controller.screenshotPNG()
        XCTAssertGreaterThan(shot.count, 1000)

        controller.stop()
    }
}
