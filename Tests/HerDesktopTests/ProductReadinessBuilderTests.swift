import XCTest
@testable import HerDesktop

final class ProductReadinessBuilderTests: XCTestCase {
    func testMissingKeysBlockCoreReadiness() {
        let summary = ProductReadinessBuilder.build(
            config: .empty,
            serviceHealth: [],
            plugins: [plugin()],
            localInboxBridgeState: LocalInboxBridgeState(),
            pendingApprovals: [],
            generatedDrafts: [],
            workPlan: nil,
            dreamContext: nil
        )

        XCTAssertEqual(summary.title, "Setup Needed")
        XCTAssertEqual(summary.score, "2/4")
        XCTAssertFalse(summary.isReadyForCoreWork)
        XCTAssertEqual(summary.items.first { $0.id == "agentllm" }?.level, .attention)
        XCTAssertEqual(summary.items.first { $0.id == "agentllm" }?.action, .openSettings)
        XCTAssertEqual(summary.items.first { $0.id == "agentmem" }?.level, .attention)
        XCTAssertEqual(summary.items.first { $0.id == "agentmem" }?.actionTitle, "Settings")
        XCTAssertEqual(summary.items.first { $0.id == "plugins" }?.level, .ready)
        XCTAssertEqual(summary.items.first { $0.id == "identity" }?.level, .ready)
    }

    func testOnlineServicesAndPluginRuntimeAreCoreReady() {
        var config = HerAppConfig.empty
        config.agentLLMAPIKey = "llm-test"
        config.agentMemAPIKey = "mem-test"

        let summary = ProductReadinessBuilder.build(
            config: config,
            serviceHealth: [
                health(id: "agentllm", state: .online, summary: "ready · Chat OK"),
                health(id: "agentmem", state: .online, summary: "known · Query OK"),
                health(id: "plugins", state: .online, summary: "1 installed")
            ],
            plugins: [plugin()],
            localInboxBridgeState: LocalInboxBridgeState(status: .running),
            pendingApprovals: [],
            generatedDrafts: [],
            workPlan: workPlan(),
            dreamContext: dreamContext()
        )

        XCTAssertEqual(summary.title, "Ready")
        XCTAssertEqual(summary.score, "4/4")
        XCTAssertTrue(summary.isReadyForCoreWork)
        XCTAssertEqual(summary.items.first { $0.id == "inbox" }?.level, .ready)
        XCTAssertEqual(summary.items.first { $0.id == "workplan" }?.level, .ready)
        XCTAssertEqual(summary.items.first { $0.id == "reflection" }?.level, .ready)
        XCTAssertNil(summary.items.first { $0.id == "agentllm" }?.action)
        XCTAssertNil(summary.items.first { $0.id == "reflection" }?.action)
    }

    func testPendingReviewQueueKeepsCoreReadyButNeedsAttention() {
        var config = HerAppConfig.empty
        config.agentLLMAPIKey = "llm-test"
        config.agentMemAPIKey = "mem-test"

        let summary = ProductReadinessBuilder.build(
            config: config,
            serviceHealth: [
                health(id: "agentllm", state: .online),
                health(id: "agentmem", state: .online)
            ],
            plugins: [plugin()],
            localInboxBridgeState: LocalInboxBridgeState(),
            pendingApprovals: [approval()],
            generatedDrafts: [],
            workPlan: nil,
            dreamContext: nil
        )

        XCTAssertEqual(summary.title, "Core Ready")
        XCTAssertTrue(summary.isReadyForCoreWork)
        XCTAssertEqual(summary.items.first { $0.id == "reviews" }?.level, .attention)
        XCTAssertEqual(summary.items.first { $0.id == "reviews" }?.detail, "1 approval(s), 0 plugin draft(s) waiting.")
        XCTAssertEqual(summary.items.first { $0.id == "reviews" }?.action, .openToolsWorkspace)
    }

    func testConfiguredButUncheckedServicesExposeCheckActionAndOptionalItemsExposeLocalActions() {
        var config = HerAppConfig.empty
        config.agentLLMAPIKey = "llm-test"
        config.agentMemAPIKey = "mem-test"

        let summary = ProductReadinessBuilder.build(
            config: config,
            serviceHealth: [
                health(id: "agentllm", state: .unknown),
                health(id: "agentmem", state: .offline)
            ],
            plugins: [],
            localInboxBridgeState: LocalInboxBridgeState(),
            pendingApprovals: [],
            generatedDrafts: [],
            workPlan: nil,
            dreamContext: nil
        )

        XCTAssertEqual(summary.items.first { $0.id == "agentllm" }?.action, .checkServices)
        XCTAssertEqual(summary.items.first { $0.id == "agentmem" }?.actionTitle, "Check")
        XCTAssertEqual(summary.items.first { $0.id == "plugins" }?.action, .openPluginDirectory)
        XCTAssertEqual(summary.items.first { $0.id == "workplan" }?.action, .openProjectsWorkspace)
        XCTAssertEqual(summary.items.first { $0.id == "reflection" }?.action, .generateReflection)
        XCTAssertEqual(summary.items.first { $0.id == "inbox" }?.action, .startInboxBridge)
        XCTAssertEqual(summary.items.first { $0.id == "voice" }?.action, .openSettings)
    }

    private func health(id: String, state: ServiceHealthState, summary: String? = nil) -> ServiceHealth {
        ServiceHealth(
            id: id,
            name: id,
            kind: "test",
            baseURL: nil,
            state: state,
            summary: summary ?? state.rawValue,
            checkedAt: nil
        )
    }

    private func plugin() -> PluginManifest {
        PluginManifest(
            id: "builtin.test",
            name: "Test",
            version: "1.0.0",
            description: "Test plugin.",
            author: nil,
            systemPromptAddendum: nil,
            capabilities: [
                .init(id: "test.run", title: "Run", kind: "native", invocation: "test.run", requiresApproval: false)
            ]
        )
    }

    private func approval() -> PendingApproval {
        PendingApproval(
            title: "Approve write",
            detail: "Needs approval.",
            invocation: CapabilityInvocation(
                toolCallID: "tool-1",
                functionName: "workspace_write",
                capabilityID: "workspace.writeTextFile",
                arguments: [:]
            )
        )
    }

    private func workPlan() -> WorkPlan {
        WorkPlan(
            goal: "Finish Her Desktop",
            source: "test",
            steps: [
                .init(title: "Build shell", status: .done),
                .init(title: "Ship plugin runtime", status: .inProgress)
            ],
            risks: [],
            verification: []
        )
    }

    private func dreamContext() -> DreamPromptContext {
        DreamPromptContext(
            updatedAt: "2026-07-01T00:00:00Z",
            longHorizonObjective: "Keep Her Desktop product-ready.",
            recentInsight: nil,
            relevantStableMemories: [],
            behaviorGuidance: [],
            unresolvedThreads: [],
            cautions: []
        )
    }
}
