import XCTest
@testable import HerDesktop

final class ToolEvidenceSummaryBuilderTests: XCTestCase {
    func testBuildsRecentToolEvidenceSummaries() {
        let base = Date(timeIntervalSince1970: 1_000)
        let messages = [
            ChatMessage(role: .user, content: "hello", createdAt: base),
            ChatMessage(role: .tool, content: "Old Tool\nolder detail", createdAt: base.addingTimeInterval(1)),
            ChatMessage(role: .tool, content: "Latest Tool\nfresh detail", createdAt: base.addingTimeInterval(3)),
            ChatMessage(role: .assistant, content: "done", createdAt: base.addingTimeInterval(4))
        ]

        let evidence = ToolEvidenceSummaryBuilder(limit: 2).build(from: messages)

        XCTAssertEqual(evidence.map(\.title), ["Latest Tool", "Old Tool"])
        XCTAssertEqual(evidence.map(\.detail), ["fresh detail", "older detail"])
    }

    func testSkipsEmptyToolMessagesAndTruncatesLongEvidence() {
        let messages = [
            ChatMessage(role: .tool, content: "   "),
            ChatMessage(
                role: .tool,
                content: """
                Very Long Tool Title That Should Be Truncated Because It Does Not Fit Inside The Compact UI
                \(String(repeating: "x", count: 40))
                """,
                createdAt: Date(timeIntervalSince1970: 2_000)
            )
        ]

        let evidence = ToolEvidenceSummaryBuilder(limit: 4, maxDetailCharacters: 12).build(from: messages)

        XCTAssertEqual(evidence.count, 1)
        XCTAssertTrue(evidence[0].title.hasSuffix("..."))
        XCTAssertEqual(evidence[0].detail, "xxxxxxxxxxx...")
    }
}
