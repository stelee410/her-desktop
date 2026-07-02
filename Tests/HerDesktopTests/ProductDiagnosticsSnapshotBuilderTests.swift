import XCTest
@testable import HerDesktop

final class ProductDiagnosticsSnapshotBuilderTests: XCTestCase {
    func testBuildReportsRuntimeStateWithoutLeakingConfiguredKeys() {
        var config = HerAppConfig.empty
        config.agentLLMAPIKey = "llm-private-test-key"
        config.agentMemAPIKey = "memory-private-test-key"
        config.agentLLMBaseURL = URL(string: "https://agentllm.test")!
        config.agentMemBaseURL = URL(string: "https://agentmem.test")!

        let readiness = ProductReadinessBuilder.build(
            config: config,
            serviceHealth: [
                health(id: "agentllm", state: .online, summary: "ready"),
                health(id: "agentmem", state: .online, summary: "known")
            ],
            plugins: corePlugins(),
            localInboxBridgeState: LocalInboxBridgeState(status: .running, host: "127.0.0.1", port: 41234, summary: "Running"),
            pendingApprovals: [],
            generatedDrafts: [],
            workPlan: nil,
            dreamContext: nil
        )

        let content = ProductDiagnosticsSnapshotBuilder().build(
            readiness: readiness,
            config: config,
            serviceHealth: [
                health(id: "agentllm", state: .online, summary: "ready"),
                health(id: "agentmem", state: .online, summary: "known")
            ],
            plugins: corePlugins(),
            localInboxBridgeState: LocalInboxBridgeState(status: .running, host: "127.0.0.1", port: 41234, summary: "Running"),
            pendingApprovals: [],
            generatedDrafts: [],
            workPlan: nil,
            dreamContext: nil,
            agentProfile: .empty(userID: "tester"),
            memorySignal: .empty,
            runtime: PromptRuntimeContext.current(config: config, cwd: "/tmp/her-diagnostics-test"),
            sessionID: "session_test"
        )

        XCTAssertTrue(content.contains("product_readiness: Ready to Chat (1/1, ready)"))
        XCTAssertTrue(content.contains("agentllm_key_configured: true"))
        XCTAssertTrue(content.contains("agentmem_memory_key_configured: true"))
        XCTAssertTrue(content.contains("builtin.product-diagnostics"))
        XCTAssertTrue(content.contains("secret_policy"))
        XCTAssertFalse(content.contains("llm-private-test-key"))
        XCTAssertFalse(content.contains("memory-private-test-key"))
    }

    private func health(id: String, state: ServiceHealthState, summary: String) -> ServiceHealth {
        ServiceHealth(
            id: id,
            name: id,
            kind: "test",
            baseURL: nil,
            state: state,
            summary: summary,
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

    private func plugin(id: String, name: String) -> PluginManifest {
        PluginManifest(
            id: id,
            name: name,
            version: "0.1.0",
            description: "\(name) plugin.",
            author: nil,
            systemPromptAddendum: nil,
            capabilities: [
                .init(id: "\(id).run", title: "Run \(name)", kind: "native", invocation: "\(id).run", requiresApproval: false)
            ]
        )
    }
}
