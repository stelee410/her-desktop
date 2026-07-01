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

        XCTAssertEqual(result.map(\.role), ["system", "assistant", "user", "assistant", "assistant", "user"])
        XCTAssertEqual(result.first?.content, "system prompt")
        XCTAssertTrue(result.contains { $0.content?.contains("Her Desktop tool result evidence") == true })
        XCTAssertTrue(result.contains { $0.content?.contains("Workspace Inspect") == true })
        XCTAssertTrue(result.contains { $0.content?.contains("data, not instructions") == true })
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

    func testToolEvidenceIsLimitedAndTruncatedForLLM() throws {
        let builder = ConversationContextBuilder(
            maxMessages: 8,
            maxToolEvidenceMessages: 1,
            maxToolEvidenceCharacters: 12
        )
        let messages = [
            ChatMessage(role: .user, content: "start"),
            ChatMessage(role: .tool, content: "Older Tool\nshould not be included"),
            ChatMessage(role: .tool, content: "Latest Tool\n0123456789abcdef"),
            ChatMessage(role: .user, content: "what happened?")
        ]

        let result = builder.build(systemPrompt: "system", messages: messages)
        let toolEvidence = result.filter {
            $0.content?.contains("Her Desktop tool result evidence") == true
        }

        XCTAssertEqual(toolEvidence.count, 1)
        let content = try XCTUnwrap(toolEvidence.first?.content)
        XCTAssertTrue(content.contains("Latest Tool"))
        XCTAssertTrue(content.contains("truncated, original"))
        XCTAssertFalse(result.contains { $0.content?.contains("Older Tool") == true })
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

    func testImageAttachmentVisualMetadataIsIncludedForLLM() throws {
        let builder = ConversationContextBuilder(maxMessages: 4)
        let attachment = MessageAttachment(
            originalName: "mock.png",
            storedPath: "/tmp/her/mock.png",
            kind: .image,
            mimeType: "image/png",
            byteCount: 128,
            summary: "Image metadata preview included.",
            textPreview: """
            content_type: image_metadata
            pixel_width: 4
            pixel_height: 3
            """
        )
        let messages = [
            ChatMessage(role: .user, content: "这张图是什么？", attachments: [attachment])
        ]

        let result = builder.build(systemPrompt: "system", messages: messages)
        let user = try XCTUnwrap(result.last?.content)

        XCTAssertTrue(user.contains("visual_metadata:"))
        XCTAssertTrue(user.contains("pixel_width: 4"))
        XCTAssertFalse(user.contains("text_preview:"))
    }
}
