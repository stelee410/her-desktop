import XCTest
@testable import HerDesktop

final class AgentLoopSummaryBuilderTests: XCTestCase {
    func testBuildsIdleLoopWhenNoSignalsExist() {
        let steps = AgentLoopSummaryBuilder().build(
            events: [],
            activities: [],
            pendingApprovals: [],
            generatedDrafts: [],
            connectionState: .ready
        )

        XCTAssertEqual(steps.map(\.phase), [.observe, .plan, .act, .reflect])
        XCTAssertEqual(steps.map(\.status), ["Idle", "Ready", "Idle", "Ready"])
        XCTAssertFalse(steps.contains { $0.isActive })
    }

    func testBuildsLoopFromRecentEventsApprovalsAndActivities() {
        let approval = PendingApproval(
            title: "Read text file",
            detail: "path: note.txt",
            invocation: CapabilityInvocation(
                toolCallID: "call_read",
                functionName: "native_readTextFile",
                capabilityID: "native.readTextFile",
                arguments: ["path": "note.txt"]
            )
        )
        let steps = AgentLoopSummaryBuilder().build(
            events: [
                InteractionEvent(
                    surface: .mac,
                    kind: .userMessage,
                    summary: "Review this workspace before changing files."
                )
            ],
            activities: [
                CapabilityActivity(
                    capabilityID: "native.readTextFile",
                    functionName: "native_readTextFile",
                    title: "Read text file",
                    status: .running,
                    summary: "Reading note.txt for context."
                ),
                CapabilityActivity(
                    capabilityID: "partner.brief",
                    functionName: "partner_brief",
                    title: "Partner Brief",
                    status: .done,
                    summary: "Prepared a compact product brief."
                )
            ],
            pendingApprovals: [approval],
            generatedDrafts: [],
            connectionState: .working
        )

        XCTAssertEqual(steps.first { $0.phase == .observe }?.status, "Mac")
        XCTAssertEqual(steps.first { $0.phase == .plan }?.status, "Needs approval")
        XCTAssertEqual(steps.first { $0.phase == .act }?.status, "Running")
        XCTAssertEqual(steps.first { $0.phase == .reflect }?.status, "Captured")
        XCTAssertTrue(steps.first { $0.phase == .plan }?.isActive == true)
        XCTAssertTrue(steps.first { $0.phase == .act }?.detail.contains("Reading note.txt") == true)
    }

    func testGeneratedDraftActivatesPlanningStep() {
        let draft = GeneratedPluginDraft(
            package: PluginPackage(
                manifest: PluginManifest(
                    id: "local.generated",
                    name: "Generated",
                    version: "0.1.0",
                    description: "Generated plugin.",
                    author: nil,
                    systemPromptAddendum: nil,
                    capabilities: []
                ),
                files: []
            ),
            source: "test"
        )

        let steps = AgentLoopSummaryBuilder().build(
            events: [],
            activities: [],
            pendingApprovals: [],
            generatedDrafts: [draft],
            connectionState: .ready
        )

        let plan = steps.first { $0.phase == .plan }
        XCTAssertEqual(plan?.status, "Draft ready")
        XCTAssertTrue(plan?.detail.contains("1 generated plugin") == true)
        XCTAssertEqual(plan?.isActive, true)
    }

    func testCurrentWorkPlanFeedsPlanningStep() {
        let plan = WorkPlan(
            goal: "Finish durable planning loop.",
            source: "workspace_plan",
            steps: [
                .init(title: "Persist plan", status: .done),
                .init(title: "Surface loop state", status: .inProgress)
            ],
            risks: [],
            verification: []
        )

        let steps = AgentLoopSummaryBuilder().build(
            events: [],
            activities: [],
            pendingApprovals: [],
            generatedDrafts: [],
            workPlan: plan,
            connectionState: .ready
        )

        let planning = steps.first { $0.phase == .plan }
        XCTAssertEqual(planning?.status, "Current plan")
        XCTAssertTrue(planning?.detail.contains("Finish durable planning loop.") == true)
        XCTAssertTrue(planning?.detail.contains("In progress, 1/2 done") == true)
        XCTAssertEqual(planning?.isActive, true)
    }
}
