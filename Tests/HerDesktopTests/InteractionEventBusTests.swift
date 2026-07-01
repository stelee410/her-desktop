import XCTest
@testable import HerDesktop

final class InteractionEventBusTests: XCTestCase {
    func testUserMessageNormalizesTextAndAttachmentsIntoTurnContext() {
        let attachment = MessageAttachment(
            originalName: "brief.txt",
            storedPath: "/tmp/brief.txt",
            kind: .text,
            mimeType: "text/plain",
            byteCount: 12,
            summary: "A short brief",
            textPreview: "Important context"
        )

        let turn = InteractionEventBus().userMessage(
            text: "  help me plan  ",
            attachments: [attachment]
        )

        XCTAssertEqual(turn.displayText, "help me plan")
        XCTAssertEqual(turn.event.surface, .mac)
        XCTAssertEqual(turn.event.kind, .userMessage)
        XCTAssertEqual(turn.event.payload["attachmentCount"], "1")
        XCTAssertTrue(turn.contextText.contains("help me plan"))
        XCTAssertTrue(turn.contextText.contains("Attached files:"))
        XCTAssertTrue(turn.contextText.contains("Important context"))
    }

    func testAttachmentOnlyTurnGetsReadableDisplayText() {
        let attachment = MessageAttachment(
            originalName: "image.png",
            storedPath: "/tmp/image.png",
            kind: .image,
            mimeType: "image/png",
            byteCount: 42,
            summary: "PNG image"
        )

        let turn = InteractionEventBus().userMessage(text: "   ", attachments: [attachment])

        XCTAssertEqual(turn.displayText, "Attached 1 file(s).")
        XCTAssertTrue(turn.contextText.contains("Attached 1 file(s)."))
        XCTAssertTrue(turn.contextText.contains("image.png"))
    }
}
