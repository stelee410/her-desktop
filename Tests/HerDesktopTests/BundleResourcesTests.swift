import XCTest
@testable import HerDesktop

final class BundleResourcesTests: XCTestCase {
    /// The custom resolver must locate a real bundled resource. If it fell
    /// back to `Bundle.main` (resource bundle not found) this returns nil —
    /// which is exactly the clean-machine crash we are guarding against,
    /// surfaced here as a test failure instead of a launch-time fatalError.
    func testHerResourcesFindsBundledResource() {
        let url = Bundle.herResources.url(forResource: "office_tool", withExtension: "py")
        XCTAssertNotNil(url, "herResources should resolve the SwiftPM resource bundle")
    }

    func testHerResourcesFindsPluginManifests() {
        let urls = Bundle.herResources.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        XCTAssertFalse(urls.isEmpty, "bundled plugin manifests should be discoverable")
    }
}
