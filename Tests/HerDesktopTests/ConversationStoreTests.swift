import XCTest
@testable import HerDesktop

final class ConversationStoreTests: XCTestCase {
    private func makeRoot(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-conversation-store-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    func testBootstrapCreatesFreshConversationWhenNothingStored() {
        let store = ConversationStore(cwd: makeRoot("fresh").path)

        let bootstrap = store.bootstrap()

        XCTAssertEqual(bootstrap.conversations.count, 1)
        XCTAssertEqual(bootstrap.conversations.first?.id, bootstrap.activeConversationID)
        XCTAssertEqual(bootstrap.conversations.first?.title, ConversationStore.defaultTitle)
        XCTAssertTrue(bootstrap.messages.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.indexURL.path))
    }

    func testSaveAndLoadMessagesRoundTrip() throws {
        let store = ConversationStore(cwd: makeRoot("roundtrip").path)
        let messages = [
            ChatMessage(role: .assistant, content: "hello"),
            ChatMessage(role: .user, content: "start")
        ]

        try store.saveMessages(messages, id: "conv-1")
        let loaded = try store.loadMessages(id: "conv-1")

        XCTAssertEqual(loaded.map(\.content), ["hello", "start"])
    }

    func testIndexRoundTripKeepsPinAndActiveState() throws {
        let store = ConversationStore(cwd: makeRoot("index").path)
        let now = Date()
        let conversations = [
            ConversationSummary(id: "a", title: "First", pinned: true, createdAt: now, updatedAt: now),
            ConversationSummary(id: "b", title: "Second", pinned: false, createdAt: now, updatedAt: now)
        ]

        try store.saveIndex(conversations: conversations, activeConversationID: "b")
        let index = try XCTUnwrap(store.loadIndex())

        XCTAssertEqual(index.activeConversationID, "b")
        XCTAssertEqual(index.conversations.map(\.id), ["a", "b"])
        XCTAssertEqual(index.conversations.first?.pinned, true)
    }

    func testBootstrapMigratesLegacySessionFile() throws {
        let root = makeRoot("legacy")
        let legacy = SessionStore(cwd: root.path)
        try legacy.save(
            messages: [
                ChatMessage(role: .assistant, content: "我在这里。"),
                ChatMessage(role: .user, content: "帮我看看今天的安排怎么样")
            ],
            sessionID: "legacy-session"
        )
        let store = ConversationStore(cwd: root.path)

        let bootstrap = store.bootstrap()

        XCTAssertEqual(bootstrap.activeConversationID, "legacy-session")
        XCTAssertEqual(bootstrap.conversations.count, 1)
        XCTAssertEqual(bootstrap.conversations.first?.title, "帮我看看今天的安排怎么样")
        XCTAssertEqual(bootstrap.messages.map(\.content), ["我在这里。", "帮我看看今天的安排怎么样"])
    }

    func testDeleteConversationFileRemovesTranscript() throws {
        let store = ConversationStore(cwd: makeRoot("delete").path)
        try store.saveMessages([ChatMessage(role: .user, content: "bye")], id: "conv-x")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.conversationURL(id: "conv-x").path))

        try store.deleteConversationFile(id: "conv-x")

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.conversationURL(id: "conv-x").path))
        XCTAssertEqual(try store.loadMessages(id: "conv-x"), [])
    }

    func testAutoTitleUsesFirstUserMessageAndTruncates() {
        XCTAssertNil(ConversationStore.autoTitle(from: [ChatMessage(role: .assistant, content: "hi")]))
        XCTAssertEqual(
            ConversationStore.autoTitle(from: [ChatMessage(role: .user, content: "短标题")]),
            "短标题"
        )
        let long = String(repeating: "长", count: 40)
        let title = ConversationStore.autoTitle(from: [ChatMessage(role: .user, content: long)])
        XCTAssertEqual(title, String(repeating: "长", count: 24) + "…")
    }

    func testConversationURLSanitizesUnsafeIdentifiers() {
        let store = ConversationStore(cwd: makeRoot("sanitize").path)

        let url = store.conversationURL(id: "../weird id/☃")

        XCTAssertEqual(url.deletingLastPathComponent().path, store.directoryURL.path)
        XCTAssertFalse(url.lastPathComponent.contains(".."))
        XCTAssertFalse(url.lastPathComponent.contains("/"))
    }
}
