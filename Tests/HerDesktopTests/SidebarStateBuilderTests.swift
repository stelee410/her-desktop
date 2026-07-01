import XCTest
@testable import HerDesktop

final class SidebarStateBuilderTests: XCTestCase {
    func testMemoryRowsUseLiveProfileAndMemorySignalInsteadOfStaticMockMemories() {
        let rows = SidebarStateBuilder().memoryRows(
            profile: AgentProfile(
                displayName: "Her",
                userDisplayName: "Steven",
                relationship: "relationship 相识 · affection 4.20/10",
                memoryID: "mem_visible",
                known: true
            ),
            signal: MemorySignal(
                trust: 0.42,
                confidence: 0.61,
                moodLabel: "焦虑警觉",
                relationshipSummary: "relationship 相识"
            ),
            dreamContext: nil,
            auditEvents: []
        )

        XCTAssertEqual(rows.map(\.id), ["relationship", "mood", "memory-scope"])
        XCTAssertEqual(rows[0].subtitle, "relationship 相识 · affection 4.20/10")
        XCTAssertEqual(rows[1].subtitle, "焦虑警觉 · trust 42%")
        XCTAssertEqual(rows[2].subtitle, "mem_visible")
        XCTAssertFalse(rows.contains { $0.title == "Design architecture" || $0.subtitle == "Her desktop shell" })
    }

    func testMemoryRowsPreferLatestWritebackOverReflectionWhenPresent() {
        let event = AuditEvent(
            type: "memory.writeback_task_status",
            summary: "AgentMem task succeeded",
            metadata: [
                "taskID": "task_123",
                "taskStatus": "succeeded",
                "mode": "summary"
            ]
        )
        let rows = SidebarStateBuilder().memoryRows(
            profile: .empty(userID: "tester"),
            signal: .empty,
            dreamContext: dreamContext(),
            auditEvents: [event]
        )

        XCTAssertEqual(rows.last?.id, "writeback")
        XCTAssertEqual(rows.last?.title, "Last writeback")
        XCTAssertEqual(rows.last?.subtitle, "succeeded · task_123")
    }

    func testMemoryRowsUseReflectionWhenNoWritebackExists() {
        let rows = SidebarStateBuilder().memoryRows(
            profile: .empty(userID: "tester"),
            signal: .empty,
            dreamContext: dreamContext(),
            auditEvents: []
        )

        XCTAssertEqual(rows.last?.id, "reflection")
        XCTAssertEqual(rows.last?.subtitle, "Keep plugin-first architecture visible.")
    }

    private func dreamContext() -> DreamPromptContext {
        DreamPromptContext(
            updatedAt: "2026-07-01T00:00:00Z",
            longHorizonObjective: "Finish Her Desktop.",
            recentInsight: "Keep plugin-first architecture visible.",
            relevantStableMemories: [],
            behaviorGuidance: [],
            unresolvedThreads: [],
            cautions: []
        )
    }
}
