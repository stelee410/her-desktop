import XCTest
@testable import HerDesktop

final class ConversationContextBuilderTests: XCTestCase {
    func testBuildsSystemPlusRecentUserAssistantMessages() {
        let builder = ConversationContextBuilder(maxMessages: 10)
        let messages = [
            ChatMessage(role: .assistant, content: "我在这里。"),
            ChatMessage(role: .user, content: "记住我在做桌面端。"),
            ChatMessage(role: .tool, content: "Workspace Inspect\nfiles..."),
            ChatMessage(role: .assistant, content: "好的，我会延续这个方向。"),
            ChatMessage(role: .system, content: "hidden"),
            ChatMessage(role: .user, content: "下一步是什么？")
        ]

        let result = builder.build(systemPrompt: "system prompt", messages: messages)

        XCTAssertEqual(result.map(\.role), ["system", "assistant", "user", "assistant", "user"])
        XCTAssertEqual(result.first?.content, "system prompt")
        XCTAssertFalse(result.contains { $0.content?.contains("Workspace Inspect") == true })
        XCTAssertFalse(result.contains { $0.content == "hidden" })
    }

    func testKeepsOnlyMostRecentMessages() {
        let builder = ConversationContextBuilder(maxMessages: 3)
        let messages = (0..<8).map { index in
            ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant, content: "m\(index)")
        }

        let result = builder.build(systemPrompt: "system", messages: messages)

        XCTAssertEqual(result.map(\.content), ["system", "m5", "m6", "m7"])
    }

    func testDropsEmptyAssistantMessages() {
        let builder = ConversationContextBuilder()
        let messages = [
            ChatMessage(role: .assistant, content: " "),
            ChatMessage(role: .user, content: "hello")
        ]

        let result = builder.build(systemPrompt: "system", messages: messages)

        XCTAssertEqual(result.map(\.role), ["system", "user"])
    }

    func testUserAttachmentContextIsIncludedForLLM() throws {
        let builder = ConversationContextBuilder(maxMessages: 4)
        let attachment = MessageAttachment(
            originalName: "brief.txt",
            storedPath: "/tmp/her/brief.txt",
            kind: .text,
            mimeType: "text/plain",
            byteCount: 42,
            summary: "UTF-8 text preview included.",
            textPreview: "launch plan"
        )
        let messages = [
            ChatMessage(role: .user, content: "看一下这个", attachments: [attachment])
        ]

        let result = builder.build(systemPrompt: "system", messages: messages)
        let user = try XCTUnwrap(result.last?.content)

        XCTAssertTrue(user.contains("看一下这个"))
        XCTAssertTrue(user.contains("Attached files:"))
        XCTAssertTrue(user.contains("brief.txt"))
        XCTAssertTrue(user.contains("text_preview:"))
        XCTAssertTrue(user.contains("launch plan"))
    }
}
