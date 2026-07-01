import XCTest
@testable import HerDesktop

final class PluginCapabilityDisplaySummaryTests: XCTestCase {
    func testSummarizesBuiltInStructuredCapability() {
        let registry = PluginRegistry(config: .empty)
        let plugin = registry.loadPlugins().first { $0.id == "builtin.agentmem" }!
        let capability = plugin.capabilities.first { $0.id == "agentmem.add" }!

        let summary = PluginCapabilityDisplaySummary(plugin: plugin, capability: capability)

        XCTAssertEqual(summary.sourceLabel, "Built-in")
        XCTAssertEqual(summary.approvalLabel, "Approval")
        XCTAssertEqual(summary.adapterLabel, "native")
        XCTAssertEqual(summary.inputLabel, "Inputs: user_input*, agent_response*, source")
        XCTAssertEqual(summary.detailLine, "agentmem.add · native")
    }

    func testSummarizesLocalWebServiceCapability() {
        let plugin = PluginManifest(
            id: "local.web",
            name: "Web",
            version: "0.1.0",
            description: "Web plugin.",
            author: nil,
            systemPromptAddendum: nil,
            capabilities: [
                .init(
                    id: "local.web.run",
                    title: "Run Web",
                    kind: "webservice",
                    invocation: "local.web.run",
                    requiresApproval: false,
                    inputSchema: [
                        "type": .string("object"),
                        "properties": .object([
                            "prompt": .object(["type": .string("string")])
                        ]),
                        "required": .array([.string("prompt")])
                    ],
                    adapter: .init(type: "webservice", url: "https://example.com/run", method: "GET")
                )
            ]
        )

        let summary = PluginCapabilityDisplaySummary(plugin: plugin, capability: plugin.capabilities[0])

        XCTAssertEqual(summary.sourceLabel, "Local")
        XCTAssertEqual(summary.approvalLabel, "Fast run")
        XCTAssertEqual(summary.adapterLabel, "webservice GET")
        XCTAssertEqual(summary.inputLabel, "Inputs: prompt*")
        XCTAssertEqual(summary.detailLine, "local.web.run · webservice GET")
    }

    func testSummarizesFreeTextCommandCapability() {
        let plugin = PluginManifest(
            id: "local.command",
            name: "Command",
            version: "0.1.0",
            description: "Command plugin.",
            author: nil,
            systemPromptAddendum: nil,
            capabilities: [
                .init(
                    id: "local.command.run",
                    title: "Run Command",
                    kind: "command",
                    invocation: "local.command.run",
                    requiresApproval: true,
                    adapter: .init(type: "command", command: "/usr/bin/printf", arguments: ["{{request}}"])
                )
            ]
        )

        let summary = PluginCapabilityDisplaySummary(plugin: plugin, capability: plugin.capabilities[0])

        XCTAssertEqual(summary.adapterLabel, "command printf")
        XCTAssertEqual(summary.inputLabel, "Free text")
    }
}
