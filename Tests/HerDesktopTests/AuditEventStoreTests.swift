import XCTest
@testable import HerDesktop

final class AuditEventStoreTests: XCTestCase {
    func testAppendAndLoadAuditEventsUnderHerLogs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-audit-store-\(UUID().uuidString)", isDirectory: true)
        let store = AuditEventStore(cwd: root.path)
        let first = AuditEvent(
            type: "plugin.draft_staged",
            summary: "Staged plugin package for review.",
            metadata: ["pluginID": "local.test"]
        )
        let second = AuditEvent(
            type: "approval.requested",
            summary: "Capability execution requires user approval.",
            metadata: ["capabilityID": "native.readTextFile"]
        )

        try store.append(first)
        try store.append(second)

        let loaded = try store.loadAll()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".her/logs/audit.jsonl").path))
        XCTAssertEqual(loaded.map(\.type), ["plugin.draft_staged", "approval.requested"])
        XCTAssertEqual(loaded.first?.metadata["pluginID"], "local.test")
        XCTAssertEqual(loaded.last?.metadata["capabilityID"], "native.readTextFile")
    }

    func testLoadAllReturnsEmptyWhenAuditFileIsMissing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-empty-audit-\(UUID().uuidString)", isDirectory: true)
        let store = AuditEventStore(cwd: root.path)

        XCTAssertEqual(try store.loadAll(), [])
    }
}
