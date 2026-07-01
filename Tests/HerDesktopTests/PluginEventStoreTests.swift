import XCTest
@testable import HerDesktop

final class PluginEventStoreTests: XCTestCase {
    func testAppendAndLoadPluginLifecycleEventsUnderHerLogs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-plugin-events-\(UUID().uuidString)", isDirectory: true)
        let store = PluginEventStore(cwd: root.path)

        try store.append(PluginLifecycleEvent(
            createdAt: Date(timeIntervalSince1970: 100),
            action: .staged,
            pluginID: "local.first",
            pluginName: "First",
            version: "0.1.0",
            source: "vibe-composer",
            summary: "Staged plugin package for review.",
            capabilityCount: 1,
            fileCount: 2,
            metadata: ["draftID": "one"]
        ))
        try store.append(PluginLifecycleEvent(
            createdAt: Date(timeIntervalSince1970: 200),
            action: .installed,
            pluginID: "local.first",
            pluginName: "First",
            version: "0.1.0",
            source: "plugin.draft",
            summary: "Installed generated plugin draft.",
            capabilityCount: 1,
            fileCount: 2
        ))

        let loaded = try store.loadAll()

        XCTAssertEqual(loaded.map(\.action), [.staged, .installed])
        XCTAssertEqual(loaded.first?.metadata["draftID"], "one")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".her/logs/plugin-events.jsonl").path
        ))
    }

    func testLoadAllReturnsEmptyWhenPluginLifecycleLogIsMissing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-plugin-events-empty-\(UUID().uuidString)", isDirectory: true)
        let store = PluginEventStore(cwd: root.path)

        XCTAssertEqual(try store.loadAll(), [])
    }
}
