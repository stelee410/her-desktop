import XCTest
@testable import HerDesktop

final class ApprovedCapabilityFollowUpBuilderTests: XCTestCase {
    func testBuildsFollowUpWithApprovedResultAndRecentConversation() {
        let builder = ApprovedCapabilityFollowUpBuilder(contextBuilder: ConversationContextBuilder(maxMessages: 4))
        let approval = PendingApproval(
            title: "Read Text File",
            detail: "path: /tmp/note.md",
            invocation: CapabilityInvocation(
                toolCallID: "call-1",
                functionName: "native_readTextFile",
                capabilityID: "native.readTextFile",
                arguments: ["path": "/tmp/note.md"]
            ),
            activityID: nil
        )
        let result = CapabilityResult(
            title: "Text File",
            content: "Project notes from the approved file.",
            requiresUserApproval: true
        )
        let transcript = [
            ChatMessage(role: .assistant, content: "我在这里。"),
            ChatMessage(role: .user, content: "帮我读这个文件。"),
            ChatMessage(role: .tool, content: "Approval Required\nRead Text File"),
            ChatMessage(role: .system, content: "hidden"),
            ChatMessage(role: .tool, content: "Text File\nProject notes from the approved file.")
        ]

        let messages = builder.build(
            systemPrompt: "system",
            transcript: transcript,
            approval: approval,
            result: result,
            availableToolSummaries: [
                "native_readTextFile -> native.readTextFile",
                "workspace_inspect -> workspace.inspect"
            ]
        )

        XCTAssertEqual(messages.first?.role, "system")
        XCTAssertEqual(messages.last?.role, "user")
        XCTAssertTrue(messages.last?.content?.contains("native.readTextFile") == true)
        XCTAssertTrue(messages.last?.content?.contains("Project notes from the approved file.") == true)
        XCTAssertTrue(messages.last?.content?.contains("Current available tools after approval:") == true)
        XCTAssertTrue(messages.last?.content?.contains("workspace_inspect -> workspace.inspect") == true)
        XCTAssertTrue(messages.last?.content?.contains("Continue the user's workflow") == true)
        XCTAssertFalse(messages.dropLast().contains { $0.content?.contains("Approval Required") == true })
        XCTAssertFalse(messages.dropLast().contains { $0.content == "hidden" })
    }

    func testTruncatesLargeResultForSynthesis() {
        let builder = ApprovedCapabilityFollowUpBuilder(
            contextBuilder: ConversationContextBuilder(maxMessages: 2),
            maxResultCharacters: 8
        )
        let approval = PendingApproval(
            title: "Large Result",
            detail: "No arguments.",
            invocation: CapabilityInvocation(
                toolCallID: "call-2",
                functionName: "large_result",
                capabilityID: "local.large.run",
                arguments: [:]
            ),
            activityID: nil
        )

        let messages = builder.build(
            systemPrompt: "system",
            transcript: [ChatMessage(role: .user, content: "run it")],
            approval: approval,
            result: CapabilityResult(title: "Huge", content: "1234567890abcdef", requiresUserApproval: true)
        )

        let followUp = messages.last?.content ?? ""
        XCTAssertTrue(followUp.contains("12345678"))
        XCTAssertFalse(followUp.contains("90abcdef"))
        XCTAssertTrue(followUp.contains("Result truncated to 8 characters"))
    }
}
