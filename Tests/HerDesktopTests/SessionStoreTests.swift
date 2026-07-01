import XCTest
@testable import HerDesktop

final class SessionStoreTests: XCTestCase {
    func testSaveAndLoadSessionUnderHerDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-session-store-\(UUID().uuidString)", isDirectory: true)
        let store = SessionStore(cwd: root.path)
        let messages = [
            ChatMessage(role: .assistant, content: "hello"),
            ChatMessage(role: .user, content: "start")
        ]

        try store.save(messages: messages, sessionID: "session-123")
        let loaded = try store.load()

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".her/session.json").path))
        XCTAssertEqual(loaded.map(\.content), ["hello", "start"])
        XCTAssertEqual(try store.loadSessionID(), "session-123")
    }

    func testLoadOrCreateSessionIDReusesStoredValue() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-session-id-\(UUID().uuidString)", isDirectory: true)
        let store = SessionStore(cwd: root.path)

        try store.save(messages: [], sessionID: "stable-session")

        XCTAssertEqual(store.loadOrCreateSessionID(), "stable-session")
    }

    func testLoadOldSessionFileWithoutSessionID() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-old-session-store-\(UUID().uuidString)", isDirectory: true)
        let sessionURL = root.appendingPathComponent(".her/session.json")
        try FileManager.default.createDirectory(at: sessionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {
          "version": 1,
          "cwd": "\(root.path)",
          "messages": [
            {
              "id": "\(UUID().uuidString)",
              "role": "assistant",
              "content": "legacy hello",
              "createdAt": "2026-06-30T07:00:00Z"
            }
          ]
        }
        """.write(to: sessionURL, atomically: true, encoding: .utf8)
        let store = SessionStore(cwd: root.path)

        XCTAssertEqual(try store.load().first?.content, "legacy hello")
        XCTAssertNil(try store.loadSessionID())
    }

    func testSessionSanitizeDropsEmptyAssistantAndTruncatesTools() {
        let store = SessionStore(cwd: "/tmp/her-test", maxToolResultCharacters: 12)
        let messages = [
            ChatMessage(role: .assistant, content: "   "),
            ChatMessage(role: .tool, content: String(repeating: "x", count: 20)),
            ChatMessage(role: .assistant, content: "done")
        ]

        let sanitized = store.sanitize(messages)

        XCTAssertEqual(sanitized.count, 2)
        XCTAssertEqual(sanitized.first?.role, .tool)
        XCTAssertTrue(sanitized.first?.content.contains("truncated") == true)
        XCTAssertEqual(sanitized.last?.content, "done")
    }
}
