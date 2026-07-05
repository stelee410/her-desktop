import XCTest
@testable import HerDesktop

final class BuiltInPluginContractTests: XCTestCase {
    func testBundledBuiltInPluginResourceFilesAreLoaded() throws {
        let resourceDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/HerDesktop/Resources/BuiltinPlugins", isDirectory: true)
        let resourceFiles = try FileManager.default.contentsOfDirectory(
            at: resourceDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasSuffix(".plugin.json") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let fileManifests = try resourceFiles.map {
            try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: $0))
        }
        let loadedBuiltIns = PluginRegistry(config: .empty)
            .loadPlugins()
            .filter { $0.id.hasPrefix("builtin.") }

        XCTAssertFalse(resourceFiles.isEmpty)
        XCTAssertEqual(loadedBuiltIns.map(\.id).sorted(), fileManifests.map(\.id).sorted())
        XCTAssertEqual(
            loadedBuiltIns.flatMap(\.capabilities).map(\.id).sorted(),
            fileManifests.flatMap(\.capabilities).map(\.id).sorted()
        )
    }

    func testBundledBuiltInPluginsAreSelfDescribingAndReviewable() throws {
        let registry = PluginRegistry(config: .empty)
        let builtIns = registry.loadPlugins().filter { $0.id.hasPrefix("builtin.") }

        XCTAssertFalse(builtIns.isEmpty)
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
        XCTAssertTrue(skill.contains("mcp.discover"))
        XCTAssertTrue(skill.contains("plugin.draft arguments"))
        XCTAssertTrue(skill.contains("plugin.listDrafts"))
        XCTAssertTrue(skill.contains("plugin.listInstalled"))
        XCTAssertTrue(skill.contains("plugin.inspect"))
        XCTAssertTrue(skill.contains("plugin.readFile"))
        XCTAssertTrue(skill.contains("update_plugin_id"))
        XCTAssertTrue(skill.contains("plugin.stagePackage"))
        XCTAssertTrue(skill.contains("plugin.installDraft"))
        XCTAssertTrue(skill.contains("plugin.discardDraft"))
        XCTAssertTrue(skill.contains("plugin.export"))
    }

    func testFallbackWorkspacePlanMatchesNativeContract() throws {
        let registry = PluginRegistry(config: .empty, loadBundledBuiltInResources: false)
        let workspace = try XCTUnwrap(registry.loadPlugins().first { $0.id == "builtin.workspace" })
        let plan = try XCTUnwrap(workspace.capabilities.first { $0.id == "workspace.plan" })

        XCTAssertEqual(plan.kind, "native")
        XCTAssertEqual(plan.adapter?.type, "native")
        XCTAssertEqual(plan.title, "Save work plan")
        XCTAssertEqual(CapabilityInputSchema.fields(for: plan).map(\.name), [
            "goal",
            "request",
            "risks",
            "steps",
            "verification"
        ])
    }

    private func requiresApprovalByDefault(_ capability: PluginManifest.Capability) -> Bool {
        let adapterType = capability.adapter?.type ?? capability.kind
        if adapterType == "webservice" || adapterType == "mcp" || adapterType == "command" {
            return true
        }
        if adapterType == "native" {
            return ![
                "workspace.inspect",
                "workspace.plan",
                "agentmem.query",
                "mcp.discover",
                "inbox.capture",
                "plugin.listDrafts",
                "plugin.listInstalled",
                "plugin.inspect",
                "plugin.stagePackage",
                "product.diagnostics",
                "shell.inspect",
                "webapp.list",
                "webapp.open",
                "webapp.inspect",
                "webapp.query",
                "terminal.open",
                "terminal.read"
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
