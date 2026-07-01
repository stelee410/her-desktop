import XCTest
@testable import HerDesktop

final class InboxEventStoreTests: XCTestCase {
    func testAppendAndLoadInboxEventsUnderHerInbox() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-inbox-store-\(UUID().uuidString)", isDirectory: true)
        let store = InboxEventStore(cwd: root.path)
        let event = InteractionEvent(
            surface: .externalInbox,
            kind: .externalInboxCaptured,
            summary: "oyii: review this",
            payload: ["source": "oyii", "sender": "Leo"]
        )

        try store.append(event)

        let loaded = try store.loadAll()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".her/inbox/events.jsonl").path))
        let restored = try XCTUnwrap(loaded.first)
        XCTAssertEqual(restored.id, event.id)
        XCTAssertEqual(restored.surface, .externalInbox)
        XCTAssertEqual(restored.kind, .externalInboxCaptured)
        XCTAssertEqual(restored.summary, event.summary)
        XCTAssertEqual(restored.payload, event.payload)
    }

    func testLoadAllReturnsEmptyWhenInboxFileIsMissing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-empty-inbox-\(UUID().uuidString)", isDirectory: true)
        let store = InboxEventStore(cwd: root.path)

        XCTAssertEqual(try store.loadAll(), [])
    }
}
