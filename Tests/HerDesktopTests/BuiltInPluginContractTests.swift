import XCTest
@testable import HerDesktop

final class BuiltInPluginContractTests: XCTestCase {
    func testBundledBuiltInPluginsAreSelfDescribingAndReviewable() throws {
        let registry = PluginRegistry(config: .empty)
        let builtIns = registry.loadPlugins().filter { $0.id.hasPrefix("builtin.") }

        XCTAssertEqual(builtIns.count, 9)
        XCTAssertEqual(Set(builtIns.map(\.id)).count, builtIns.count)

        var capabilityIDs = Set<String>()
        for manifest in builtIns {
            XCTAssertFalse(manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, manifest.id)
            XCTAssertFalse(manifest.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, manifest.id)
            XCTAssertFalse(manifest.capabilities.isEmpty, manifest.id)
            XCTAssertNoThrow(try assertNoSecretMaterial(in: manifest, registry: registry))

            for capability in manifest.capabilities {
                XCTAssertTrue(capabilityIDs.insert(capability.id).inserted, "Duplicate capability id: \(capability.id)")
                XCTAssertEqual(capability.invocation, capability.id, capability.id)
                XCTAssertFalse(capability.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, capability.id)
                XCTAssertNotNil(capability.inputSchema, "\(capability.id) should declare a native input schema")

                let adapter = try XCTUnwrap(capability.adapter, "\(capability.id) should declare an adapter")
                XCTAssertEqual(adapter.type, capability.kind, "\(capability.id) adapter type should match kind")

                if adapter.type == "skill" {
                    let skillFile = try XCTUnwrap(adapter.skillFile, "\(capability.id) should declare skillFile")
                    let skill = try registry.readPluginFile(pluginID: manifest.id, path: skillFile)
                    XCTAssertTrue(skill.contains("#"), "\(skillFile) should be a readable skill document")
                    XCTAssertEqual(SecretRedactor.redact(skill), skill, "\(skillFile) should not contain secret-like material")
                }

                if requiresApprovalByDefault(capability) {
                    XCTAssertTrue(capability.requiresApproval, "\(capability.id) should require approval")
                }
            }
        }
    }

    func testBuiltInVibePluginCreatorHasPackagedSkillContract() throws {
        let registry = PluginRegistry(config: .empty)
        let manifest = try XCTUnwrap(registry.loadPlugins().first { $0.id == "builtin.vibe-plugin-creator" })
        let draft = try XCTUnwrap(manifest.capabilities.first { $0.id == "plugin.draft" })

        XCTAssertEqual(draft.adapter?.type, "skill")
        XCTAssertEqual(draft.adapter?.skillFile, "vibe-plugin-creator.SKILL.md")

        let skill = try registry.readPluginFile(pluginID: manifest.id, path: "vibe-plugin-creator.SKILL.md")
        XCTAssertTrue(skill.contains("PluginPackage"))
        XCTAssertTrue(skill.contains("MCP"))
        XCTAssertTrue(skill.contains("Never include API keys"))
    }

    private func requiresApprovalByDefault(_ capability: PluginManifest.Capability) -> Bool {
        let adapterType = capability.adapter?.type ?? capability.kind
        if adapterType == "webservice" || adapterType == "mcp" || adapterType == "command" {
            return true
        }
        if adapterType == "native" {
            return ![
                "workspace.inspect",
                "agentmem.query",
                "mcp.discover",
                "inbox.capture"
            ].contains(capability.id)
        }
        return false
    }

    private func assertNoSecretMaterial(in manifest: PluginManifest, registry: PluginRegistry) throws {
        let data = try JSONEncoder().encode(manifest)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(SecretRedactor.redact(text), text, "\(manifest.id) manifest should not contain secret-like material")

        for capability in manifest.capabilities {
            guard capability.adapter?.type == "skill", let skillFile = capability.adapter?.skillFile else {
                continue
            }
            let skill = try registry.readPluginFile(pluginID: manifest.id, path: skillFile)
            XCTAssertEqual(SecretRedactor.redact(skill), skill, "\(skillFile) should not contain secret-like material")
        }
    }
}
