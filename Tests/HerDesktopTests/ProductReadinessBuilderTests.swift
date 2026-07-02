import XCTest
@testable import HerDesktop

final class ProductReadinessBuilderTests: XCTestCase {
    func testMissingAgentLLMKeyBlocksCoreReadiness() {
        let summary = ProductReadinessBuilder.build(
            config: .empty,
            serviceHealth: [],
            plugins: corePlugins(),
            localInboxBridgeState: LocalInboxBridgeState(),
            pendingApprovals: [],
            generatedDrafts: [],
            workPlan: nil,
            dreamContext: nil
        )

        XCTAssertEqual(summary.title, "Setup Needed")
        XCTAssertEqual(summary.score, "0/1")
        XCTAssertFalse(summary.isReadyForCoreWork)
        XCTAssertEqual(summary.items.first { $0.id == "agentllm" }?.level, .attention)
        XCTAssertEqual(summary.items.first { $0.id == "agentllm" }?.action, .openSettings)
        XCTAssertEqual(summary.items.first { $0.id == "agentmem" }?.level, .optional)
        XCTAssertFalse(summary.items.first { $0.id == "agentmem" }?.required == true)
        XCTAssertEqual(summary.items.first { $0.id == "plugins" }?.level, .ready)
        XCTAssertEqual(summary.items.first { $0.id == "labels" }?.level, .ready)
        XCTAssertTrue(summary.items.first { $0.id == "labels" }?.detail.contains("local label only") == true)
    }

    func testOnlineServicesAndPluginRuntimeAreCoreReady() {
        var config = HerAppConfig.empty
        config.agentLLMAPIKey = "llm-test"

        let summary = ProductReadinessBuilder.build(
            config: config,
            serviceHealth: [
                health(id: "agentllm", state: .online, summary: "ready · Chat OK"),
                health(id: "plugins", state: .online, summary: "1 installed")
            ],
            plugins: corePlugins(),
            localInboxBridgeState: LocalInboxBridgeState(status: .running),
            pendingApprovals: [],
            generatedDrafts: [],
            workPlan: workPlan(),
            dreamContext: dreamContext()
        )

        XCTAssertEqual(summary.title, "Ready to Chat")
        XCTAssertEqual(summary.score, "1/1")
        XCTAssertTrue(summary.isReadyForCoreWork)
        XCTAssertEqual(summary.items.first { $0.id == "agentmem" }?.level, .optional)
        XCTAssertEqual(summary.items.first { $0.id == "inbox" }?.level, .ready)
        XCTAssertEqual(summary.items.first { $0.id == "workplan" }?.level, .ready)
        XCTAssertEqual(summary.items.first { $0.id == "reflection" }?.level, .ready)
        XCTAssertNil(summary.items.first { $0.id == "agentllm" }?.action)
        XCTAssertNil(summary.items.first { $0.id == "reflection" }?.action)
    }

    func testPendingReviewQueueKeepsCoreReadyButNeedsAttention() {
        var config = HerAppConfig.empty
        config.agentLLMAPIKey = "llm-test"

        let summary = ProductReadinessBuilder.build(
            config: config,
            serviceHealth: [
                health(id: "agentllm", state: .online)
            ],
            plugins: corePlugins(),
            localInboxBridgeState: LocalInboxBridgeState(),
            pendingApprovals: [approval()],
            generatedDrafts: [],
            workPlan: nil,
            dreamContext: nil
        )

        XCTAssertEqual(summary.title, "Ready to Chat")
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
        XCTAssertNil(summary.items.first { $0.id == "agentmem" }?.actionTitle)
        XCTAssertFalse(summary.items.first { $0.id == "agentmem" }?.required == true)
        XCTAssertNil(summary.items.first { $0.id == "plugins" }?.action)
        XCTAssertFalse(summary.items.first { $0.id == "plugins" }?.required == true)
        XCTAssertEqual(summary.items.first { $0.id == "workplan" }?.action, .openProjectsWorkspace)
        XCTAssertEqual(summary.items.first { $0.id == "reflection" }?.action, .generateReflection)
        XCTAssertEqual(summary.items.first { $0.id == "inbox" }?.action, .startInboxBridge)
        XCTAssertEqual(summary.items.first { $0.id == "voice" }?.action, .openSettings)
    }

    func testLocalLabelsAreOptionalBecauseAgentMemV7UsesMemoryKeyIdentity() {
        var config = HerAppConfig.empty
        config.agentLLMAPIKey = "llm-test"
        config.agentCode = ""
        config.userID = ""

        let summary = ProductReadinessBuilder.build(
            config: config,
            serviceHealth: [
                health(id: "agentllm", state: .online)
            ],
            plugins: corePlugins(),
            localInboxBridgeState: LocalInboxBridgeState(),
            pendingApprovals: [],
            generatedDrafts: [],
            workPlan: nil,
            dreamContext: nil
        )

        XCTAssertEqual(summary.score, "1/1")
        XCTAssertTrue(summary.isReadyForCoreWork)
        XCTAssertEqual(summary.items.first { $0.id == "labels" }?.level, .optional)
        XCTAssertFalse(summary.items.first { $0.id == "labels" }?.required == true)
        XCTAssertTrue(summary.items.first { $0.id == "labels" }?.detail.contains("Memory-Key") == true)
        XCTAssertNil(summary.items.first { $0.id == "labels" }?.actionTitle)
        XCTAssertNil(summary.items.first { $0.id == "labels" }?.action)
    }

    func testSuggestedActionsDoNotPromoteOptionalLocalLabels() {
        var config = HerAppConfig.empty
        config.agentLLMAPIKey = "llm-test"
        config.agentCode = ""
        config.userID = ""

        let summary = ProductReadinessBuilder.build(
            config: config,
            serviceHealth: [
                health(id: "agentllm", state: .online)
            ],
            plugins: corePlugins(),
            localInboxBridgeState: LocalInboxBridgeState(),
            pendingApprovals: [approval()],
            generatedDrafts: [],
            workPlan: nil,
            dreamContext: nil
        )

        XCTAssertEqual(summary.items.first { $0.id == "labels" }?.level, .optional)
        XCTAssertFalse(summary.suggestedActions(limit: 8).map(\.id).contains("labels"))
        XCTAssertEqual(summary.suggestedActions(limit: 3).map(\.id), [])
    }

    func testSuggestedActionsReturnOnlyRequiredAttentionItemsWithLimit() {
        var config = HerAppConfig.empty
        config.agentMemAPIKey = "mem-test"

        let summary = ProductReadinessBuilder.build(
            config: config,
            serviceHealth: [
                health(id: "agentllm", state: .unknown),
                health(id: "agentmem", state: .offline)
            ],
            plugins: [],
            localInboxBridgeState: LocalInboxBridgeState(),
            pendingApprovals: [approval()],
            generatedDrafts: [],
            workPlan: nil,
            dreamContext: nil
        )

        XCTAssertEqual(summary.suggestedActions(limit: 3).map(\.id), ["agentllm"])
        XCTAssertEqual(summary.suggestedActions(limit: 5).map(\.action), [.openSettings])
        XCTAssertEqual(summary.suggestedActions(limit: 0), [])
    }

    func testMissingCoreBuiltInPluginsDoesNotBlockChatReadiness() {
        var config = HerAppConfig.empty
        config.agentLLMAPIKey = "llm-test"

        let summary = ProductReadinessBuilder.build(
            config: config,
            serviceHealth: [
                health(id: "agentllm", state: .online)
            ],
            plugins: [plugin(id: "builtin.workspace", name: "Workspace")],
            localInboxBridgeState: LocalInboxBridgeState(),
            pendingApprovals: [],
            generatedDrafts: [],
            workPlan: nil,
            dreamContext: nil
        )

        let pluginItem = summary.items.first { $0.id == "plugins" }
        XCTAssertEqual(summary.score, "1/1")
        XCTAssertTrue(summary.isReadyForCoreWork)
        XCTAssertEqual(pluginItem?.level, .attention)
        XCTAssertFalse(pluginItem?.required == true)
        XCTAssertNil(pluginItem?.action)
        XCTAssertTrue(pluginItem?.detail.contains("Vibe Plugin Creator") == true)
        XCTAssertTrue(pluginItem?.detail.contains("MCP Bridge") == true)
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

    private func corePlugins() -> [PluginManifest] {
        [
            plugin(id: "builtin.workspace", name: "Workspace"),
            plugin(id: "builtin.agentmem", name: "AgentMem"),
            plugin(id: "builtin.vibe-plugin-creator", name: "Vibe Plugin Creator"),
            plugin(id: "builtin.mcp-bridge", name: "MCP Bridge"),
            plugin(id: "builtin.native-macos", name: "Native macOS"),
            plugin(id: "builtin.companion-reflection", name: "Companion Reflection"),
            plugin(id: "builtin.product-diagnostics", name: "Product Diagnostics")
        ]
    }

    private func plugin(id: String = "builtin.test", name: String = "Test") -> PluginManifest {
        PluginManifest(
            id: id,
            name: name,
            version: "1.0.0",
            description: "\(name) plugin.",
            author: nil,
            systemPromptAddendum: nil,
            capabilities: [
                .init(id: "\(id).run", title: "Run \(name)", kind: "native", invocation: "\(id).run", requiresApproval: false)
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
