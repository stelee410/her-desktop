import XCTest
@testable import HerDesktop

final class MarkdownMessageParserTests: XCTestCase {
    func testParsesHeadingsListsAndParagraphs() {
        let content = """
        ## 我理解的 AgentOS

        核心想法是：**把 AI Agent 当作一等公民**。

        - **天气**：雷暴大雨
        - **湿度**：89%

        1. 第一步
        2. 第二步
        """
        let blocks = MarkdownMessageParser.blocks(from: content)
        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "我理解的 AgentOS"),
            .paragraph("核心想法是：**把 AI Agent 当作一等公民**。"),
            .bulletList(items: ["**天气**：雷暴大雨", "**湿度**：89%"]),
            .orderedList(items: ["第一步", "第二步"])
        ])
    }

    func testParsesFencedCodeBlockIncludingUnclosedFence() {
        let closed = MarkdownMessageParser.blocks(from: "```swift\nlet a = 1\n```\ndone")
        XCTAssertEqual(closed, [
            .codeBlock(text: "let a = 1"),
            .paragraph("done")
        ])

        let streaming = MarkdownMessageParser.blocks(from: "```\npartial code")
        XCTAssertEqual(streaming, [.codeBlock(text: "partial code")])
    }

    func testParsesQuoteAndRule(){
        let blocks = MarkdownMessageParser.blocks(from: "> 用户 → 应用 → AI API\n\n---\n\ntail")
        XCTAssertEqual(blocks, [
            .quote("用户 → 应用 → AI API"),
            .rule,
            .paragraph("tail")
        ])
    }

    func testInlineAttributedAppliesBoldWithoutLiteralAsterisks() {
        let attributed = MarkdownMessageParser.inlineAttributed("现在 **28°C**，体感 31°C")
        let rendered = String(attributed.characters)
        XCTAssertEqual(rendered, "现在 28°C，体感 31°C")
        let hasBoldRun = attributed.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        XCTAssertTrue(hasBoldRun)
    }

    func testPlainTextSurvivesUnchanged() {
        let blocks = MarkdownMessageParser.blocks(from: "雷雨天出门记得带伞，注意防雷。")
        XCTAssertEqual(blocks, [.paragraph("雷雨天出门记得带伞，注意防雷。")])
    }
}
