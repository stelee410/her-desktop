import XCTest
@testable import HerDesktop

final class CapabilityRuntimeTests: XCTestCase {
    final class FakeNotificationScheduler: NativeNotificationScheduling {
        var scheduled: [(title: String, body: String, delay: TimeInterval)] = []

        func schedule(title: String, body: String, delaySeconds: TimeInterval) async throws -> String {
            scheduled.append((title, body, delaySeconds))
            return "fake-notification-id"
        }
    }

    final class FakeSpeechSynthesizer: NativeSpeechSynthesizing {
        var spoken: [(text: String, voice: String?)] = []

        func speak(_ text: String, voiceIdentifier: String?) async throws -> String {
            spoken.append((text, voiceIdentifier))
            return "fake-speech-id"
        }

        func stop() {}
    }

    final class MockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool {
            true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let handler = Self.requestHandler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    func testCatalogBuildsOpenAIToolNameMapping() {
        let manifest = PluginManifest(
            id: "local.sample",
            name: "Sample",
            version: "0.1.0",
            description: "Sample plugin",
            author: nil,
            systemPromptAddendum: nil,
            capabilities: [
                .init(id: "sample.run", title: "Run Sample", kind: "skill", invocation: "sample.run", requiresApproval: false)
            ]
        )

        let catalog = CapabilityToolCatalog.build(from: [manifest])

        XCTAssertEqual(catalog.functionToCapability["sample_run"], "sample.run")
        XCTAssertEqual(catalog.tools.count, 1)
    }

    func testDraftPluginSchemaIncludesMCPToolName() {
        let manifest = PluginRegistry(config: .empty)
            .loadPlugins()
            .first { $0.id == "builtin.vibe-plugin-creator" }!

        let catalog = CapabilityToolCatalog.build(from: [manifest])
        let draftTool = catalog.tools.first { ($0["function"] as? [String: Any])?["name"] as? String == "plugin_draft" }
        let function = draftTool?["function"] as? [String: Any]
        let parameters = function?["parameters"] as? [String: Any]
        let properties = parameters?["properties"] as? [String: Any]

        XCTAssertNotNil(properties?["tool_name"])
    }

    func testBuiltInToolCatalogUsesManifestOwnedSchemas() throws {
        let manifests = PluginRegistry(config: .empty).loadPlugins()
        let catalog = CapabilityToolCatalog.build(from: manifests)
        let draft = try XCTUnwrap(toolFunction(named: "plugin_draft", in: catalog))
        let draftParameters = try XCTUnwrap(draft["parameters"] as? [String: Any])
        let draftProperties = try XCTUnwrap(draftParameters["properties"] as? [String: Any])
        let commandArguments = try XCTUnwrap(draftProperties["command_arguments"] as? [String: Any])

        XCTAssertEqual(commandArguments["type"] as? String, "string")
        XCTAssertEqual(draftParameters["required"] as? [String], ["name", "description"])

        let remove = try XCTUnwrap(toolFunction(named: "plugin_remove", in: catalog))
        let removeParameters = try XCTUnwrap(remove["parameters"] as? [String: Any])
        let removeProperties = try XCTUnwrap(removeParameters["properties"] as? [String: Any])

        XCTAssertEqual((removeProperties["plugin_id"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertEqual(removeParameters["required"] as? [String], ["plugin_id", "confirmed"])

        let notify = try XCTUnwrap(toolFunction(named: "native_notify", in: catalog))
        let notifyParameters = try XCTUnwrap(notify["parameters"] as? [String: Any])
        let notifyProperties = try XCTUnwrap(notifyParameters["properties"] as? [String: Any])

        XCTAssertEqual((notifyProperties["delay_seconds"] as? [String: Any])?["type"] as? String, "number")
        XCTAssertEqual(notifyParameters["required"] as? [String], ["title", "body"])
    }

    @MainActor
    func testDraftPluginReturnsManifestJSON() async throws {
        let config = HerAppConfig.empty
        let registry = PluginRegistry(config: config)
        let executor = CapabilityExecutor(registry: registry)

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_1",
            functionName: "plugin_draft",
            capabilityID: "plugin.draft",
            arguments: [
                "name": "Calendar Helper",
                "description": "Helps with calendar triage.",
                "capability_kind": "skill",
                "requires_approval": true
            ]
        ))

        let data = try XCTUnwrap(result.content.data(using: .utf8))
        let package = try JSONDecoder().decode(PluginPackage.self, from: data)
        XCTAssertEqual(package.manifest.name, "Calendar Helper")
        XCTAssertEqual(package.manifest.capabilities.first?.kind, "skill")
        XCTAssertEqual(package.manifest.capabilities.first?.adapter?.type, "skill")
        XCTAssertEqual(package.manifest.capabilities.first?.adapter?.skillFile, "SKILL.md")
        XCTAssertTrue(package.manifest.capabilities.first?.requiresApproval == true)
        XCTAssertTrue(package.files.contains { $0.path == "SKILL.md" })
    }

    @MainActor
    func testDraftPluginBuildsMCPAdapterWithToolName() async throws {
        let registry = PluginRegistry(config: .empty)
        let executor = CapabilityExecutor(registry: registry)

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_1",
            functionName: "plugin_draft",
            capabilityID: "plugin.draft",
            arguments: [
                "name": "Research MCP",
                "description": "Calls a research MCP tool.",
                "capability_kind": "mcp",
                "requires_approval": true,
                "url": "http://localhost:8765/jsonrpc",
                "method_name": "tools/call",
                "tool_name": "research.summarize"
            ]
        ))

        let data = try XCTUnwrap(result.content.data(using: .utf8))
        let package = try JSONDecoder().decode(PluginPackage.self, from: data)
        let capability = try XCTUnwrap(package.manifest.capabilities.first)

        XCTAssertEqual(capability.kind, "mcp")
        XCTAssertEqual(capability.adapter?.type, "mcp")
        XCTAssertEqual(capability.adapter?.url, "http://localhost:8765/jsonrpc")
        XCTAssertEqual(capability.adapter?.methodName, "tools/call")
        XCTAssertEqual(capability.adapter?.toolName, "research.summarize")
    }

    func testBuiltInPluginInstallRequiresApproval() {
        let registry = PluginRegistry(config: .empty)
        let capability = registry.capability(id: "plugin.install")

        XCTAssertEqual(capability?.id, "plugin.install")
        XCTAssertEqual(capability?.requiresApproval, true)
    }

    func testBuiltInPluginRemoveRequiresApproval() {
        let registry = PluginRegistry(config: .empty)
        let capability = registry.capability(id: "plugin.remove")

        XCTAssertEqual(capability?.id, "plugin.remove")
        XCTAssertEqual(capability?.kind, "native")
        XCTAssertEqual(capability?.adapter?.type, "native")
        XCTAssertEqual(capability?.requiresApproval, true)
        XCTAssertEqual(CapabilityInputSchema.fields(for: capability!).map(\.name), ["plugin_id", "confirmed"])
    }

    @MainActor
    func testBuiltInPluginInstallUpdatesExistingLocalPlugin() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-plugin-install-update-\(UUID().uuidString)", isDirectory: true)
        var config = HerAppConfig.empty
        config.pluginDirectory = root.path
        let registry = PluginRegistry(config: config)
        let manifest = PluginManifest(
            id: "local.toolinstall",
            name: "Tool Install",
            version: "0.1.0",
            description: "Installed through tool.",
            author: nil,
            systemPromptAddendum: nil,
            capabilities: [
                .init(
                    id: "local.toolinstall.run",
                    title: "Run Tool Install",
                    kind: "skill",
                    invocation: "local.toolinstall.run",
                    requiresApproval: false,
                    adapter: .init(type: "skill", skillFile: "SKILL.md")
                )
            ]
        )
        try registry.install(package: PluginPackage(
            manifest: manifest,
            files: [
                .init(path: "SKILL.md", content: "# Old"),
                .init(path: "OLD.md", content: "stale")
            ]
        ))
        let updatedPackage = PluginPackage(
            manifest: manifest,
            files: [.init(path: "SKILL.md", content: "# New")]
        )
        let packageJSON = String(data: try JSONEncoder.pretty.encode(updatedPackage), encoding: .utf8)!
        let executor = CapabilityExecutor(registry: registry)

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_install",
            functionName: "plugin_install",
            capabilityID: "plugin.install",
            arguments: [
                "confirmed": true,
                "package_json": packageJSON
            ]
        ))

        let pluginRoot = root.appendingPathComponent("local.toolinstall", isDirectory: true)
        XCTAssertEqual(result.title, "Plugin Updated")
        XCTAssertTrue(result.content.contains("Updated Tool Install"))
        XCTAssertTrue(result.content.contains("Available in the next turn"))
        XCTAssertTrue(result.content.contains("Quick start"))
        XCTAssertTrue(result.content.contains("local_toolinstall_run"))
        XCTAssertTrue(result.content.contains("inputs: free text request"))
        let skill = try String(contentsOf: pluginRoot.appendingPathComponent("SKILL.md"), encoding: .utf8)
        let readme = try String(contentsOf: pluginRoot.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(skill.contains("# New"))
        XCTAssertTrue(skill.contains("## Adapter Contract"))
        XCTAssertTrue(readme.contains("## Capability Contract"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginRoot.appendingPathComponent("OLD.md").path))
    }

    func testRegistryLoadsBundledBuiltInPluginManifests() {
        let registry = PluginRegistry(config: .empty)
        let plugins = registry.loadPlugins()

        XCTAssertTrue(plugins.contains { $0.id == "builtin.workspace" })
        XCTAssertTrue(plugins.contains { $0.id == "builtin.agentllm-media" })
        XCTAssertTrue(plugins.contains { $0.id == "builtin.agentmem" })
        XCTAssertTrue(plugins.contains { $0.id == "builtin.vibe-plugin-creator" })
        XCTAssertTrue(plugins.contains { $0.id == "builtin.native-macos" })
        XCTAssertTrue(plugins.contains { $0.id == "builtin.partner-brief" })
        XCTAssertTrue(plugins.contains { $0.id == "builtin.companion-reflection" })
        XCTAssertTrue(plugins.contains { $0.id == "builtin.external-inbox" })
        XCTAssertTrue(plugins.contains { $0.id == "builtin.mcp-bridge" })
        XCTAssertEqual(
            plugins.first { $0.id == "builtin.agentllm-media" }?
                .capabilities
                .first { $0.id == "agentllm.image.generate" }?
                .adapter?
                .type,
            "webservice"
        )
        XCTAssertEqual(
            plugins.first { $0.id == "builtin.agentmem" }?
                .capabilities
                .first { $0.id == "agentmem.query" }?
                .adapter?
                .type,
            "native"
        )
        XCTAssertEqual(
            plugins.first { $0.id == "builtin.agentmem" }?
                .capabilities
                .first { $0.id == "agentmem.add" }?
                .requiresApproval,
            true
        )
        XCTAssertEqual(
            plugins.first { $0.id == "builtin.native-macos" }?
                .capabilities
                .first { $0.id == "native.notify" }?
                .adapter?
                .type,
            "native"
        )
        XCTAssertEqual(
            plugins.first { $0.id == "builtin.native-macos" }?
                .capabilities
                .first { $0.id == "native.speak" }?
                .adapter?
                .type,
            "native"
        )
        XCTAssertEqual(
            plugins.first { $0.id == "builtin.native-macos" }?
                .capabilities
                .first { $0.id == "native.inspectAttachment" }?
                .adapter?
                .type,
            "native"
        )
        XCTAssertEqual(
            plugins.first { $0.id == "builtin.workspace" }?
                .capabilities
                .first { $0.id == "workspace.plan" }?
                .adapter?
                .skillFile,
            "workspace-plan.SKILL.md"
        )
        XCTAssertEqual(
            plugins.first { $0.id == "builtin.partner-brief" }?
                .capabilities
                .first { $0.id == "partner.brief" }?
                .adapter?
                .skillFile,
            "partner-brief.SKILL.md"
        )
        XCTAssertEqual(
            plugins.first { $0.id == "builtin.external-inbox" }?
                .capabilities
                .first { $0.id == "inbox.capture" }?
                .adapter?
                .type,
            "native"
        )
        XCTAssertEqual(
            plugins.first { $0.id == "builtin.companion-reflection" }?
                .capabilities
                .first { $0.id == "reflection.snapshot" }?
                .adapter?
                .type,
            "native"
        )
        XCTAssertEqual(
            plugins.first { $0.id == "builtin.companion-reflection" }?
                .capabilities
                .first { $0.id == "reflection.snapshot" }?
                .requiresApproval,
            true
        )
    }

    func testBundledBuiltInCapabilitiesDeclareInputSchemasInManifests() {
        let registry = PluginRegistry(config: .empty)
        let builtIns = registry.loadPlugins().filter { $0.id.hasPrefix("builtin.") }
        let missing = builtIns.flatMap { plugin in
            plugin.capabilities.compactMap { capability in
                capability.inputSchema == nil ? "\(plugin.id):\(capability.id)" : nil
            }
        }

        XCTAssertTrue(missing.isEmpty, "Missing inputSchema for \(missing)")
        XCTAssertEqual(
            CapabilityInputSchema.fields(for: registry.capability(id: "native.notify")!).map(\.name),
            ["title", "body", "delay_seconds"]
        )
        XCTAssertEqual(
            CapabilityInputSchema.fields(for: registry.capability(id: "plugin.draft")!).map(\.name).prefix(3),
            ["name", "description", "capability_kind"]
        )
        XCTAssertEqual(
            CapabilityInputSchema.fields(for: registry.capability(id: "inbox.capture")!).filter(\.required).map(\.name),
            ["source", "text"]
        )
        XCTAssertEqual(
            CapabilityInputSchema.fields(for: registry.capability(id: "reflection.snapshot")!).map(\.name),
            ["focus"]
        )
    }

    func testFallbackBuiltInsStayInParityWithBundledManifests() {
        let bundled = PluginRegistry(config: .empty)
            .loadPlugins()
            .filter { $0.id.hasPrefix("builtin.") }
        let fallback = PluginRegistry(config: .empty, loadBundledBuiltInResources: false)
            .loadPlugins()
            .filter { $0.id.hasPrefix("builtin.") }

        XCTAssertEqual(fallback.map(\.id).sorted(), bundled.map(\.id).sorted())
        XCTAssertEqual(
            fallback.flatMap(\.capabilities).map(\.id).sorted(),
            bundled.flatMap(\.capabilities).map(\.id).sorted()
        )
        XCTAssertTrue(fallback.flatMap(\.capabilities).allSatisfy { $0.inputSchema != nil })
        XCTAssertNotNil(fallback.first { $0.id == "builtin.mcp-bridge" })
    }

    func testBuiltInNativeNotificationRequiresApproval() {
        let registry = PluginRegistry(config: .empty)
        let capability = registry.capability(id: "native.notify")

        XCTAssertEqual(capability?.kind, "native")
        XCTAssertEqual(capability?.adapter?.type, "native")
        XCTAssertEqual(capability?.requiresApproval, true)
    }

    func testBuiltInNativeReadTextFileRequiresApproval() {
        let registry = PluginRegistry(config: .empty)
        let capability = registry.capability(id: "native.readTextFile")

        XCTAssertEqual(capability?.kind, "native")
        XCTAssertEqual(capability?.adapter?.type, "native")
        XCTAssertEqual(capability?.requiresApproval, true)
    }

    func testBuiltInNativeSpeakRequiresApproval() {
        let registry = PluginRegistry(config: .empty)
        let capability = registry.capability(id: "native.speak")

        XCTAssertEqual(capability?.kind, "native")
        XCTAssertEqual(capability?.adapter?.type, "native")
        XCTAssertEqual(capability?.requiresApproval, true)
    }

    func testBuiltInNativeInspectAttachmentRequiresApproval() {
        let registry = PluginRegistry(config: .empty)
        let capability = registry.capability(id: "native.inspectAttachment")

        XCTAssertEqual(capability?.kind, "native")
        XCTAssertEqual(capability?.adapter?.type, "native")
        XCTAssertEqual(capability?.requiresApproval, true)
    }

    func testBuiltInExternalInboxCaptureDoesNotRequireApproval() {
        let registry = PluginRegistry(config: .empty)
        let capability = registry.capability(id: "inbox.capture")

        XCTAssertEqual(capability?.kind, "native")
        XCTAssertEqual(capability?.adapter?.type, "native")
        XCTAssertEqual(capability?.requiresApproval, false)
    }

    func testBuiltInReflectionSnapshotRequiresApproval() {
        let registry = PluginRegistry(config: .empty)
        let capability = registry.capability(id: "reflection.snapshot")

        XCTAssertEqual(capability?.kind, "native")
        XCTAssertEqual(capability?.adapter?.type, "native")
        XCTAssertEqual(capability?.requiresApproval, true)
    }

    func testBuiltInAgentMemAddRequiresApproval() {
        let registry = PluginRegistry(config: .empty)
        let query = registry.capability(id: "agentmem.query")
        let add = registry.capability(id: "agentmem.add")

        XCTAssertEqual(query?.kind, "native")
        XCTAssertEqual(query?.adapter?.type, "native")
        XCTAssertEqual(query?.requiresApproval, false)
        XCTAssertEqual(CapabilityInputSchema.fields(for: query!).map(\.name), ["query", "top_k"])
        XCTAssertEqual(add?.kind, "native")
        XCTAssertEqual(add?.adapter?.type, "native")
        XCTAssertEqual(add?.requiresApproval, true)
    }

    func testRegistryInstallsPackageFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-plugin-package-\(UUID().uuidString)", isDirectory: true)
        var config = HerAppConfig.empty
        config.pluginDirectory = root.path
        let registry = PluginRegistry(config: config)
        let manifest = PluginManifest(
            id: "local.package",
            name: "Package",
            version: "0.1.0",
            description: "Package plugin",
            author: nil,
            systemPromptAddendum: nil,
            capabilities: []
        )

        try registry.install(package: PluginPackage(
            manifest: manifest,
            files: [.init(path: "SKILL.md", content: "# Package")]
        ))

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("local.package/plugin.json").path))
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("local.package/SKILL.md"), encoding: .utf8),
            "# Package"
        )
    }

    func testRegistryRemovesInstalledLocalPluginPackage() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-plugin-remove-\(UUID().uuidString)", isDirectory: true)
        var config = HerAppConfig.empty
        config.pluginDirectory = root.path
        let registry = PluginRegistry(config: config)
        let manifest = PluginManifest(
            id: "local.removable",
            name: "Removable",
            version: "0.1.0",
            description: "Temporary plugin",
            author: nil,
            systemPromptAddendum: nil,
            capabilities: []
        )

        try registry.install(package: PluginPackage(
            manifest: manifest,
            files: [.init(path: "SKILL.md", content: "# Removable")]
        ))
        let pluginRoot = root.appendingPathComponent("local.removable", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pluginRoot.appendingPathComponent("plugin.json").path))

        try registry.remove(pluginID: "local.removable")

        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginRoot.path))
    }

    @MainActor
    func testPluginRemoveCapabilityDeletesInstalledLocalPlugin() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-plugin-remove-capability-\(UUID().uuidString)", isDirectory: true)
        var config = HerAppConfig.empty
        config.pluginDirectory = root.path
        let registry = PluginRegistry(config: config)
        let manifest = PluginManifest(
            id: "local.capremove",
            name: "Capability Remove",
            version: "0.1.0",
            description: "Temporary plugin",
            author: nil,
            systemPromptAddendum: nil,
            capabilities: []
        )
        try registry.install(package: PluginPackage(manifest: manifest, files: []))
        let executor = CapabilityExecutor(registry: registry)

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_remove",
            functionName: "plugin_remove",
            capabilityID: "plugin.remove",
            arguments: [
                "plugin_id": "local.capremove",
                "confirmed": true
            ]
        ))

        XCTAssertEqual(result.title, "Plugin Removed")
        XCTAssertTrue(result.content.contains("Capability Remove"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("local.capremove").path))
    }

    @MainActor
    func testPluginRemoveCapabilityRejectsBuiltIns() async throws {
        let executor = CapabilityExecutor(registry: PluginRegistry(config: .empty))

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_remove_builtin",
            functionName: "plugin_remove",
            capabilityID: "plugin.remove",
            arguments: [
                "plugin_id": "builtin.workspace",
                "confirmed": true
            ]
        ))

        XCTAssertEqual(result.title, "Plugin Remove Failed")
        XCTAssertTrue(result.content.contains("Only local plugins"))
    }

    func testRegistryReplacingExistingLocalPluginRemovesStaleFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-plugin-replace-\(UUID().uuidString)", isDirectory: true)
        var config = HerAppConfig.empty
        config.pluginDirectory = root.path
        let registry = PluginRegistry(config: config)
        let manifest = PluginManifest(
            id: "local.replaceable",
            name: "Replaceable",
            version: "0.1.0",
            description: "Replaceable plugin",
            author: nil,
            systemPromptAddendum: nil,
            capabilities: [
                .init(id: "local.replaceable.run", title: "Run", kind: "skill", invocation: "local.replaceable.run", requiresApproval: false)
            ]
        )

        try registry.install(package: PluginPackage(
            manifest: manifest,
            files: [
                .init(path: "SKILL.md", content: "# Old"),
                .init(path: "OLD.md", content: "stale")
            ]
        ))
        try registry.install(package: PluginPackage(
            manifest: manifest,
            files: [.init(path: "SKILL.md", content: "# New")]
        ), replacingExisting: true)

        let pluginRoot = root.appendingPathComponent("local.replaceable", isDirectory: true)
        XCTAssertEqual(
            try String(contentsOf: pluginRoot.appendingPathComponent("SKILL.md"), encoding: .utf8),
            "# New"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginRoot.appendingPathComponent("OLD.md").path))
    }

    func testRegistryBuildsPluginPackageFromInstalledLocalPlugin() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-plugin-package-export-\(UUID().uuidString)", isDirectory: true)
        var config = HerAppConfig.empty
        config.pluginDirectory = root.path
        let registry = PluginRegistry(config: config)
        let manifest = PluginManifest(
            id: "local.exportable",
            name: "Exportable",
            version: "0.1.0",
            description: "Exportable plugin",
            author: nil,
            systemPromptAddendum: nil,
            capabilities: [
                .init(
                    id: "local.exportable.run",
                    title: "Run Exportable",
                    kind: "skill",
                    invocation: "local.exportable.run",
                    requiresApproval: false,
                    adapter: .init(type: "skill", skillFile: "nested/SKILL.md")
                )
            ]
        )

        try registry.install(package: PluginPackage(
            manifest: manifest,
            files: [
                .init(path: "README.md", content: "# Exportable"),
                .init(path: "nested/SKILL.md", content: "# Skill")
            ]
        ))

        let package = try registry.package(pluginID: "local.exportable")

        XCTAssertEqual(package.manifest.id, "local.exportable")
        XCTAssertEqual(package.files.map(\.path), ["README.md", "nested/SKILL.md"])
        XCTAssertEqual(package.files.first { $0.path == "nested/SKILL.md" }?.content, "# Skill")
    }

    func testRegistryDoesNotRemoveBuiltInPlugins() {
        let registry = PluginRegistry(config: .empty)

        XCTAssertThrowsError(try registry.remove(pluginID: "builtin.workspace")) { error in
            XCTAssertEqual(error as? PluginRegistry.InstallError, .protectedPlugin("builtin.workspace"))
        }
    }

    func testRegistryResolvesRelativePluginDirectoryAgainstBaseDirectory() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-plugin-relative-base-\(UUID().uuidString)", isDirectory: true)
        var config = HerAppConfig.empty
        config.pluginDirectory = ".her/test-plugins"
        let registry = PluginRegistry(config: config, baseDirectory: base.path)
        let manifest = PluginManifest(
            id: "local.relative",
            name: "Relative",
            version: "0.1.0",
            description: "Relative plugin",
            author: nil,
            systemPromptAddendum: nil,
            capabilities: []
        )

        try registry.install(package: PluginPackage(
            manifest: manifest,
            files: [.init(path: "SKILL.md", content: "# Relative")]
        ))

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: base.appendingPathComponent(".her/test-plugins/local.relative/plugin.json").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".her/test-plugins/local.relative/plugin.json")
                .path
        ))
    }

    func testRegistryRejectsUnsafePackageFilePaths() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-plugin-unsafe-\(UUID().uuidString)", isDirectory: true)
        var config = HerAppConfig.empty
        config.pluginDirectory = root.path
        let registry = PluginRegistry(config: config)
        let manifest = PluginManifest(
            id: "local.unsafe",
            name: "Unsafe",
            version: "0.1.0",
            description: "Unsafe plugin",
            author: nil,
            systemPromptAddendum: nil,
            capabilities: []
        )

        XCTAssertThrowsError(try registry.install(package: PluginPackage(
            manifest: manifest,
            files: [.init(path: "../escape.txt", content: "no")]
        ))) { error in
            XCTAssertEqual(error as? PluginRegistry.InstallError, .unsafePath("../escape.txt"))
        }
    }

    func testRegistryRejectsUnsafePluginFileReads() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-plugin-read-unsafe-\(UUID().uuidString)", isDirectory: true)
        var config = HerAppConfig.empty
        config.pluginDirectory = root.path
        let registry = PluginRegistry(config: config)

        XCTAssertThrowsError(try registry.readPluginFile(pluginID: "local.any", path: "../secret.txt")) { error in
            XCTAssertEqual(error as? PluginRegistry.InstallError, .unsafePath("../secret.txt"))
        }
    }

    func testRegistryReadsBundledBuiltInPluginFiles() throws {
        let registry = PluginRegistry(config: .empty)

        let workspacePlan = try registry.readPluginFile(pluginID: "builtin.workspace", path: "workspace-plan.SKILL.md")
        let partnerBrief = try registry.readPluginFile(pluginID: "builtin.partner-brief", path: "partner-brief.SKILL.md")

        XCTAssertTrue(workspacePlan.contains("Workspace Plan"))
        XCTAssertTrue(workspacePlan.contains("Planning Contract"))
        XCTAssertTrue(partnerBrief.contains("Partner Brief"))
        XCTAssertTrue(partnerBrief.contains("Balance companionship and work partnership"))
    }

    @MainActor
    func testSkillAdapterReadsInstalledSkillPackage() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-plugin-skill-\(UUID().uuidString)", isDirectory: true)
        var config = HerAppConfig.empty
        config.pluginDirectory = root.path
        let registry = PluginRegistry(config: config)
        let manifest = PluginManifest(
            id: "local.skill",
            name: "Skill",
            version: "0.1.0",
            description: "Skill plugin",
            author: nil,
            systemPromptAddendum: nil,
            capabilities: [
                .init(
                    id: "local.skill.run",
                    title: "Run Skill",
                    kind: "skill",
                    invocation: "local.skill.run",
                    requiresApproval: false,
                    adapter: .init(type: "skill", skillFile: "SKILL.md")
                )
            ]
        )
        try registry.install(package: PluginPackage(
            manifest: manifest,
            files: [.init(path: "SKILL.md", content: "# Skill\n\nRead the room before acting.")]
        ))

        let executor = CapabilityExecutor(registry: registry)
        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_skill",
            functionName: "local_skill_run",
            capabilityID: "local.skill.run",
            arguments: ["request": "help me plan"]
        ))

        XCTAssertEqual(result.title, "Skill Context")
        XCTAssertTrue(result.content.contains("Read the room before acting."))
        XCTAssertTrue(result.content.contains("help me plan"))
        XCTAssertFalse(result.requiresUserApproval)
    }

    @MainActor
    func testSkillAdapterReadsBundledBuiltInSkillPackage() async throws {
        let registry = PluginRegistry(config: .empty)
        let executor = CapabilityExecutor(registry: registry)

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_partner_brief",
            functionName: "partner_brief",
            capabilityID: "partner.brief",
            arguments: ["request": "turn this messy product direction into a brief"]
        ))

        XCTAssertEqual(result.title, "Skill Context")
        XCTAssertTrue(result.content.contains("Partner Brief"))
        XCTAssertTrue(result.content.contains("turn this messy product direction into a brief"))
        XCTAssertFalse(result.requiresUserApproval)
    }

    @MainActor
    func testWorkspaceInspectUsesInjectedBaseDirectory() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-executor-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "hello".write(to: root.appendingPathComponent("workspace-note.txt"), atomically: true, encoding: .utf8)
        let executor = CapabilityExecutor(registry: PluginRegistry(config: .empty), baseDirectory: root.path)

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_inspect",
            functionName: "workspace_inspect",
            capabilityID: "workspace.inspect",
            arguments: ["max_files": 10]
        ))

        XCTAssertEqual(result.title, "Workspace Inspect")
        XCTAssertTrue(result.content.contains("cwd: \(root.path)"))
        XCTAssertTrue(result.content.contains("workspace-note.txt"))
    }

    @MainActor
    func testNativeReadTextFileUsesInjectedBaseDirectoryForRelativePaths() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-executor-read-base-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "relative hello".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let executor = CapabilityExecutor(registry: PluginRegistry(config: .empty), baseDirectory: root.path)

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_read",
            functionName: "native_readTextFile",
            capabilityID: "native.readTextFile",
            arguments: ["path": "note.txt"]
        ))

        XCTAssertEqual(result.title, "Text File Read")
        XCTAssertTrue(result.content.contains(root.appendingPathComponent("note.txt").path))
        XCTAssertTrue(result.content.contains("relative hello"))
    }

    @MainActor
    func testWebServiceAdapterRejectsRemoteHTTP() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-plugin-web-\(UUID().uuidString)", isDirectory: true)
        var config = HerAppConfig.empty
        config.pluginDirectory = root.path
        let registry = PluginRegistry(config: config)
        let manifest = PluginManifest(
            id: "local.web",
            name: "Web",
            version: "0.1.0",
            description: "Web plugin",
            author: nil,
            systemPromptAddendum: nil,
            capabilities: [
                .init(
                    id: "local.web.run",
                    title: "Run Web",
                    kind: "webservice",
                    invocation: "local.web.run",
                    requiresApproval: false,
                    adapter: .init(type: "webservice", url: "http://example.com/run", method: "POST")
                )
            ]
        )
        try registry.install(manifest: manifest)

        let executor = CapabilityExecutor(registry: registry)
        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_web",
            functionName: "local_web_run",
            capabilityID: "local.web.run",
            arguments: ["request": "ping"]
        ))

        XCTAssertEqual(result.title, "Web Service Blocked")
        XCTAssertTrue(result.requiresUserApproval)
    }

    @MainActor
    func testWebServiceAdapterPostsJSONThroughInjectedSession() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-plugin-web-post-\(UUID().uuidString)", isDirectory: true)
        var config = HerAppConfig.empty
        config.pluginDirectory = root.path
        let registry = PluginRegistry(config: config)
        let manifest = webServiceManifest(
            id: "local.webpost",
            url: "https://service.example/run",
            method: "POST"
        )
        try registry.install(manifest: manifest)

        let session = mockSession { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://service.example/run")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try XCTUnwrap(Self.bodyData(from: request))
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(object?["request"] as? String, "ping")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"ok":true}"#.utf8))
        }
        let executor = CapabilityExecutor(registry: registry, urlSession: session)

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_webpost",
            functionName: "local_webpost_run",
            capabilityID: "local.webpost.run",
            arguments: ["request": "ping"]
        ))

        XCTAssertEqual(result.title, "Web Service Result")
        XCTAssertTrue(result.content.contains("POST https://service.example/run"))
        XCTAssertTrue(result.content.contains(#""ok" : true"#))
    }

    @MainActor
    func testWebServiceAdapterRendersBodyTemplate() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-plugin-web-template-\(UUID().uuidString)", isDirectory: true)
        var config = HerAppConfig.empty
        config.pluginDirectory = root.path
        let registry = PluginRegistry(config: config)
        let manifest = webServiceManifest(
            id: "local.webtemplate",
            url: "https://service.example/template",
            method: "POST",
            bodyTemplate: "Request={{request}}\nArgs={{arguments_json}}"
        )
        try registry.install(manifest: manifest)

        let session = mockSession { request in
            let body = String(data: try XCTUnwrap(Self.bodyData(from: request)), encoding: .utf8)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/plain; charset=utf-8")
            XCTAssertTrue(body?.contains("Request=write brief") == true)
            XCTAssertTrue(body?.contains(#""topic" : "planning""#) == true)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 201,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("templated".utf8))
        }
        let executor = CapabilityExecutor(registry: registry, urlSession: session)

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_webtemplate",
            functionName: "local_webtemplate_run",
            capabilityID: "local.webtemplate.run",
            arguments: ["request": "write brief", "topic": "planning"]
        ))

        XCTAssertEqual(result.title, "Web Service Result")
        XCTAssertTrue(result.content.contains("status: 201"))
        XCTAssertTrue(result.content.contains("templated"))
    }

    @MainActor
    func testWebServiceAdapterRendersConfigAndJSONPlaceholders() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-plugin-web-config-\(UUID().uuidString)", isDirectory: true)
        var config = HerAppConfig.empty
        config.agentLLMBaseURL = URL(string: "https://agentllm.test")!
        config.agentLLMAPIKey = "test-llm-key"
        config.pluginDirectory = root.path
        let registry = PluginRegistry(config: config)
        let manifest = PluginManifest(
            id: "local.agentllm-image",
            name: "AgentLLM Image",
            version: "0.1.0",
            description: "Image tool",
            author: nil,
            systemPromptAddendum: nil,
            capabilities: [
                .init(
                    id: "local.agentllm-image.run",
                    title: "Run Image",
                    kind: "webservice",
                    invocation: "local.agentllm-image.run",
                    requiresApproval: true,
                    adapter: .init(
                        type: "webservice",
                        url: "{{agent_llm_base_url}}/v1/images/generations",
                        method: "POST",
                        headers: [
                            "Authorization": "Bearer {{agent_llm_api_key}}",
                            "Content-Type": "application/json"
                        ],
                        bodyTemplate: #"{"model":{{json:model|gpt-image-1}},"prompt":{{json:prompt}},"size":{{json:size|1024x1024}}}"#
                    )
                )
            ]
        )
        try registry.install(manifest: manifest)

        let session = mockSession { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://agentllm.test/v1/images/generations")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-llm-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try XCTUnwrap(Self.bodyData(from: request))
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(object?["model"] as? String, "gpt-image-1")
            XCTAssertEqual(object?["prompt"] as? String, #"A "quoted" coral desktop UI"#)
            XCTAssertEqual(object?["size"] as? String, "1024x1024")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"data":[{"url":"https://cdn.example/image.png"}]}"#.utf8))
        }
        let executor = CapabilityExecutor(registry: registry, config: config, urlSession: session)

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_image",
            functionName: "local_agentllm_image_run",
            capabilityID: "local.agentllm-image.run",
            arguments: ["prompt": #"A "quoted" coral desktop UI"#]
        ))

        XCTAssertEqual(result.title, "Web Service Result")
        XCTAssertTrue(result.content.contains("https://cdn.example/image.png"))
        XCTAssertFalse(result.content.contains("test-llm-key"))
    }

    @MainActor
    func testWebServiceResultAndArtifactsRedactConfiguredSecrets() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-plugin-web-redaction-\(UUID().uuidString)", isDirectory: true)
        let llmKey = ["sk", "testredaction1234567890"].joined(separator: "-")
        let memKey = "mem" + "_" + "testredaction1234567890"
        var config = HerAppConfig.empty
        config.agentLLMAPIKey = llmKey
        config.agentMemAPIKey = memKey
        config.pluginDirectory = root.appendingPathComponent("plugins", isDirectory: true).path
        let registry = PluginRegistry(config: config)
        let manifest = webServiceManifest(
            id: "local.redactweb",
            url: "https://service.example/images?token={{agent_llm_api_key}}",
            method: "POST",
            bodyTemplate: #"{"prompt":"{{request}}","memory_key":"{{agent_mem_api_key}}"}"#
        )
        try registry.install(manifest: manifest)

        let responseJSON = """
        {
          "data": [
            { "url": "https://cdn.example/generated.png?token=\(llmKey)" }
          ],
          "echo": "\(memKey)"
        }
        """
        let session = mockSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://service.example/images?token=\(llmKey)")
            let body = String(data: try XCTUnwrap(Self.bodyData(from: request)), encoding: .utf8)
            XCTAssertTrue(body?.contains(memKey) == true)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(responseJSON.utf8))
        }
        let executor = CapabilityExecutor(
            registry: registry,
            config: config,
            baseDirectory: root.path,
            urlSession: session
        )

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_redact",
            functionName: "local_redactweb_run",
            capabilityID: "local.redactweb.run",
            arguments: ["request": "make image"]
        ))

        XCTAssertEqual(result.title, "Web Service Result")
        XCTAssertFalse(result.content.contains(llmKey))
        XCTAssertFalse(result.content.contains(memKey))
        XCTAssertTrue(result.content.contains("[redacted]"))

        let manifestPath = try XCTUnwrap(Self.value(after: "artifact_manifest:", in: result.content))
        let manifestData = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        let manifestText = String(data: manifestData, encoding: .utf8) ?? ""
        XCTAssertFalse(manifestText.contains(llmKey))
        XCTAssertTrue(manifestText.contains("[redacted]"))
    }

    @MainActor
    func testWebServiceAdapterPersistsImageGenerationArtifacts() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-plugin-web-artifacts-\(UUID().uuidString)", isDirectory: true)
        var config = HerAppConfig.empty
        config.pluginDirectory = root.path
        let registry = PluginRegistry(config: config)
        let manifest = webServiceManifest(
            id: "local.media",
            url: "https://service.example/images",
            method: "POST"
        )
        try registry.install(manifest: manifest)

        let imageBytes = Data("fake-png-bytes".utf8)
        let imageBase64 = imageBytes.base64EncodedString()
        let responseJSON = """
        {
          "data": [
            { "url": "https://cdn.example/generated.png" },
            { "b64_json": "\(imageBase64)", "mime_type": "image/png" }
          ]
        }
        """
        let session = mockSession { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(responseJSON.utf8))
        }
        let executor = CapabilityExecutor(
            registry: registry,
            config: config,
            baseDirectory: root.path,
            urlSession: session
        )

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_media",
            functionName: "local_media_run",
            capabilityID: "local.media.run",
            arguments: ["request": "make an image"]
        ))

        XCTAssertEqual(result.title, "Web Service Result")
        XCTAssertTrue(result.content.contains("artifact_manifest:"))
        XCTAssertTrue(result.content.contains("response_file:"))
        XCTAssertTrue(result.content.contains("image_url: https://cdn.example/generated.png"))
        XCTAssertTrue(result.content.contains("image_file:"))
        XCTAssertFalse(result.content.contains(imageBase64))

        let manifestPath = try XCTUnwrap(Self.value(after: "artifact_manifest:", in: result.content))
        let imagePath = try XCTUnwrap(Self.value(after: "image_file:", in: result.content))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestPath))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: imagePath)), imageBytes)

        let manifestData = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        let manifestObject = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        XCTAssertEqual(manifestObject?["capability_id"] as? String, "local.media.run")
        XCTAssertEqual((manifestObject?["request"] as? [String: Any])?["status"] as? Int, 200)
    }

    @MainActor
    func testMCPAdapterPostsJSONRPCToLocalBridge() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-plugin-mcp-\(UUID().uuidString)", isDirectory: true)
        var config = HerAppConfig.empty
        config.pluginDirectory = root.path
        let registry = PluginRegistry(config: config)
        let manifest = PluginManifest(
            id: "local.mcp",
            name: "MCP",
            version: "0.1.0",
            description: "MCP plugin",
            author: nil,
            systemPromptAddendum: nil,
            capabilities: [
                .init(
                    id: "local.mcp.run",
                    title: "Run MCP",
                    kind: "mcp",
                    invocation: "local.mcp.run",
                    requiresApproval: true,
                    adapter: .init(
                        type: "mcp",
                        url: "http://localhost:8765/jsonrpc",
                        methodName: "tools/call",
                        toolName: "research.summarize"
                    )
                )
            ]
        )
        try registry.install(manifest: manifest)

        let session = mockSession { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "http://localhost:8765/jsonrpc")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try XCTUnwrap(Self.bodyData(from: request))
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(object?["jsonrpc"] as? String, "2.0")
            XCTAssertEqual(object?["id"] as? String, "call_mcp")
            XCTAssertEqual(object?["method"] as? String, "tools/call")
            let params = object?["params"] as? [String: Any]
            XCTAssertEqual(params?["name"] as? String, "research.summarize")
            let arguments = params?["arguments"] as? [String: Any]
            XCTAssertEqual(arguments?["request"] as? String, "summarize")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"jsonrpc":"2.0","result":{"ok":true}}"#.utf8))
        }
        let executor = CapabilityExecutor(registry: registry, urlSession: session)

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_mcp",
            functionName: "local_mcp_run",
            capabilityID: "local.mcp.run",
            arguments: ["request": "summarize"]
        ))

        XCTAssertEqual(result.title, "MCP Bridge Result")
        XCTAssertTrue(result.content.contains("method: tools/call"))
        XCTAssertTrue(result.content.contains("tool: research.summarize"))
        XCTAssertTrue(result.content.contains(#""ok":true"#))
        XCTAssertFalse(result.requiresUserApproval)
    }

    @MainActor
    func testMCPDiscoverPostsToolsListAndSummarizesTools() async throws {
        let session = mockSession { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "http://localhost:8765/jsonrpc")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try XCTUnwrap(Self.bodyData(from: request))
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(object?["jsonrpc"] as? String, "2.0")
            XCTAssertEqual(object?["id"] as? String, "mcp_discover")
            XCTAssertEqual(object?["method"] as? String, "tools/list")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = Data("""
            {
              "jsonrpc": "2.0",
              "result": {
                "tools": [
                  {
                    "name": "research.summarize",
                    "description": "Summarize a research source.",
                    "inputSchema": {
                      "type": "object",
                      "properties": {
                        "prompt": {"type": "string"},
                        "limit": {"type": "integer"}
                      },
                      "required": ["prompt"]
                    }
                  }
                ]
              }
            }
            """.utf8)
            return (response, data)
        }
        let executor = CapabilityExecutor(registry: PluginRegistry(config: .empty), urlSession: session)

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_discover",
            functionName: "mcp_discover",
            capabilityID: "mcp.discover",
            arguments: ["url": "http://localhost:8765/jsonrpc"]
        ))

        XCTAssertEqual(result.title, "MCP Tool Discovery Result")
        XCTAssertTrue(result.content.contains("tool_count: 1"))
        XCTAssertTrue(result.content.contains("research.summarize"))
        XCTAssertTrue(result.content.contains("prompt*:string"))
        XCTAssertFalse(result.requiresUserApproval)
    }

    @MainActor
    func testMCPAdapterBlocksRemoteBridgeURL() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-plugin-remote-mcp-\(UUID().uuidString)", isDirectory: true)
        var config = HerAppConfig.empty
        config.pluginDirectory = root.path
        let registry = PluginRegistry(config: config)
        let manifest = PluginManifest(
            id: "local.remotemcp",
            name: "Remote MCP",
            version: "0.1.0",
            description: "Remote MCP plugin",
            author: nil,
            systemPromptAddendum: nil,
            capabilities: [
                .init(
                    id: "local.remotemcp.run",
                    title: "Run Remote MCP",
                    kind: "mcp",
                    invocation: "local.remotemcp.run",
                    requiresApproval: true,
                    adapter: .init(
                        type: "mcp",
                        url: "https://mcp.example.com/jsonrpc",
                        methodName: "tools/call"
                    )
                )
            ]
        )
        try registry.install(manifest: manifest)
        let executor = CapabilityExecutor(registry: registry)

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_mcp",
            functionName: "local_remotemcp_run",
            capabilityID: "local.remotemcp.run",
            arguments: ["request": "summarize"]
        ))

        XCTAssertEqual(result.title, "MCP Bridge Blocked")
        XCTAssertTrue(result.requiresUserApproval)
    }

    @MainActor
    func testCommandAdapterRunsFixedExecutableWithTemplatedArguments() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-plugin-command-\(UUID().uuidString)", isDirectory: true)
        var config = HerAppConfig.empty
        config.pluginDirectory = root.path
        let registry = PluginRegistry(config: config)
        let manifest = PluginManifest(
            id: "local.command",
            name: "Command",
            version: "0.1.0",
            description: "Command plugin",
            author: nil,
            systemPromptAddendum: nil,
            capabilities: [
                .init(
                    id: "local.command.run",
                    title: "Run Command",
                    kind: "command",
                    invocation: "local.command.run",
                    requiresApproval: true,
                    adapter: .init(
                        type: "command",
                        command: "/bin/echo",
                        arguments: ["prefix", "{{request}}"],
                        timeoutSeconds: 5
                    )
                )
            ]
        )
        try registry.install(manifest: manifest)
        let executor = CapabilityExecutor(registry: registry)

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_command",
            functionName: "local_command_run",
            capabilityID: "local.command.run",
            arguments: ["request": "hello"]
        ))

        XCTAssertEqual(result.title, "Command Result")
        XCTAssertTrue(result.content.contains("command: /bin/echo"))
        XCTAssertTrue(result.content.contains("prefix hello"))
        XCTAssertTrue(result.content.contains("exit_status: 0"))
        XCTAssertFalse(result.requiresUserApproval)
    }

    @MainActor
    func testCommandAdapterResolvesRelativeExecutableAgainstInjectedBaseDirectory() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-plugin-command-relative-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = bin.appendingPathComponent("echo-tool")
        try """
        #!/bin/sh
        echo "$1:$2"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        var config = HerAppConfig.empty
        config.pluginDirectory = root.appendingPathComponent("plugins", isDirectory: true).path
        let registry = PluginRegistry(config: config)
        let manifest = PluginManifest(
            id: "local.relativecommand",
            name: "Relative Command",
            version: "0.1.0",
            description: "Relative command plugin",
            author: nil,
            systemPromptAddendum: nil,
            capabilities: [
                .init(
                    id: "local.relativecommand.run",
                    title: "Run Relative Command",
                    kind: "command",
                    invocation: "local.relativecommand.run",
                    requiresApproval: true,
                    adapter: .init(
                        type: "command",
                        command: "bin/echo-tool",
                        arguments: ["prefix", "{{request}}"],
                        timeoutSeconds: 5
                    )
                )
            ]
        )
        try registry.install(manifest: manifest)
        let executor = CapabilityExecutor(registry: registry, baseDirectory: root.path)

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_relative_command",
            functionName: "local_relativecommand_run",
            capabilityID: "local.relativecommand.run",
            arguments: ["request": "hello"]
        ))

        XCTAssertEqual(result.title, "Command Result")
        XCTAssertTrue(result.content.contains("command: \(script.path)"))
        XCTAssertTrue(result.content.contains("prefix:hello"))
    }

    @MainActor
    func testCommandAdapterRejectsMissingExecutable() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-plugin-command-missing-\(UUID().uuidString)", isDirectory: true)
        var config = HerAppConfig.empty
        config.pluginDirectory = root.path
        let registry = PluginRegistry(config: config)
        let manifest = PluginManifest(
            id: "local.commandmissing",
            name: "Command Missing",
            version: "0.1.0",
            description: "Command plugin",
            author: nil,
            systemPromptAddendum: nil,
            capabilities: [
                .init(
                    id: "local.commandmissing.run",
                    title: "Run Command Missing",
                    kind: "command",
                    invocation: "local.commandmissing.run",
                    requiresApproval: true,
                    adapter: .init(type: "command", command: "/definitely/not/a/tool")
                )
            ]
        )
        try registry.install(manifest: manifest)
        let executor = CapabilityExecutor(registry: registry)

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_command",
            functionName: "local_commandmissing_run",
            capabilityID: "local.commandmissing.run",
            arguments: ["request": "hello"]
        ))

        XCTAssertEqual(result.title, "Command Not Executable")
        XCTAssertTrue(result.requiresUserApproval)
    }

    @MainActor
    func testNativeNotifySchedulesThroughInjectedScheduler() async throws {
        let scheduler = FakeNotificationScheduler()
        let registry = PluginRegistry(config: .empty)
        let executor = CapabilityExecutor(registry: registry, notificationScheduler: scheduler)

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_notify",
            functionName: "native_notify",
            capabilityID: "native.notify",
            arguments: [
                "title": "Focus",
                "body": "Time to write",
                "delay_seconds": 3
            ]
        ))

        XCTAssertEqual(result.title, "Notification Scheduled")
        XCTAssertTrue(result.content.contains("fake-notification-id"))
        XCTAssertEqual(scheduler.scheduled.count, 1)
        XCTAssertEqual(scheduler.scheduled.first?.title, "Focus")
        XCTAssertEqual(scheduler.scheduled.first?.body, "Time to write")
        XCTAssertEqual(scheduler.scheduled.first?.delay, 3)
    }

    @MainActor
    func testNativeSpeakUsesInjectedSpeechSynthesizer() async throws {
        let speech = FakeSpeechSynthesizer()
        let registry = PluginRegistry(config: .empty)
        let executor = CapabilityExecutor(registry: registry, speechSynthesizer: speech)

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_speak",
            functionName: "native_speak",
            capabilityID: "native.speak",
            arguments: [
                "text": "Hello from Her",
                "voice": "com.apple.speech.synthesis.voice.samantha"
            ]
        ))

        XCTAssertEqual(result.title, "Speech Played")
        XCTAssertTrue(result.content.contains("fake-speech-id"))
        XCTAssertEqual(speech.spoken.count, 1)
        XCTAssertEqual(speech.spoken.first?.text, "Hello from Her")
        XCTAssertEqual(speech.spoken.first?.voice, "com.apple.speech.synthesis.voice.samantha")
    }

    @MainActor
    func testNativeInspectAttachmentReadsImportedTextOnly() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-native-inspect-attachment-\(UUID().uuidString)", isDirectory: true)
        let attachmentDirectory = HerWorkspacePaths.attachmentDirectory(cwd: root.path)
        try FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
        let file = attachmentDirectory.appendingPathComponent("note.txt")
        try "attachment contents for Her".write(to: file, atomically: true, encoding: .utf8)
        let executor = CapabilityExecutor(registry: PluginRegistry(config: .empty), baseDirectory: root.path)

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_attachment",
            functionName: "native_inspectAttachment",
            capabilityID: "native.inspectAttachment",
            arguments: ["path": file.path, "max_chars": 10]
        ))

        XCTAssertEqual(result.title, "Attachment Inspected")
        XCTAssertTrue(result.content.contains("content_type: utf8_text"))
        XCTAssertTrue(result.content.contains("attachment"))
        XCTAssertTrue(result.content.contains("truncated: true"))
    }

    @MainActor
    func testNativeInspectAttachmentBlocksOutsidePaths() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-native-inspect-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.txt")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        let executor = CapabilityExecutor(registry: PluginRegistry(config: .empty), baseDirectory: root.path)

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_attachment",
            functionName: "native_inspectAttachment",
            capabilityID: "native.inspectAttachment",
            arguments: ["path": outside.path]
        ))

        XCTAssertEqual(result.title, "Attachment Inspect Failed")
        XCTAssertTrue(result.content.contains(".her/attachments"))
    }

    @MainActor
    func testNativeReadTextFileReadsUtf8Text() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-native-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("note.txt")
        try "hello from a local text file".write(to: file, atomically: true, encoding: .utf8)
        let executor = CapabilityExecutor(registry: PluginRegistry(config: .empty))

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_read",
            functionName: "native_readTextFile",
            capabilityID: "native.readTextFile",
            arguments: ["path": file.path, "max_chars": 12]
        ))

        XCTAssertEqual(result.title, "Text File Read")
        XCTAssertTrue(result.content.contains("hello from a"))
        XCTAssertTrue(result.content.contains("truncated: true"))
    }

    @MainActor
    func testInboxCaptureFormatsExternalMessage() async throws {
        let executor = CapabilityExecutor(registry: PluginRegistry(config: .empty))

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_inbox",
            functionName: "inbox_capture",
            capabilityID: "inbox.capture",
            arguments: [
                "source": "oyii",
                "sender": "Leo",
                "text": "Please review the new architecture note.",
                "url": "https://example.com/thread/1",
                "received_at": "2026-06-30T10:00:00Z"
            ]
        ))

        XCTAssertEqual(result.title, "Inbox Event Captured")
        XCTAssertFalse(result.requiresUserApproval)
        XCTAssertTrue(result.content.contains("source: oyii"))
        XCTAssertTrue(result.content.contains("sender: Leo"))
        XCTAssertTrue(result.content.contains("Please review the new architecture note."))
    }

    @MainActor
    func testAgentMemQueryUsesConfiguredClientAndDoesNotEchoKey() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-agentmem-query-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var config = HerAppConfig.empty
        config.agentMemBaseURL = URL(string: "https://agentmem.test")!
        config.agentMemAPIKey = "mem_test_key"
        config.agentCode = "her-test"
        config.userID = "user-test"
        let session = mockSession { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://agentmem.test/v1/memory/query")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Memory-API-Key"), "mem_test_key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Agent-API-Key"), "mem_test_key")
            let body = try XCTUnwrap(Self.bodyData(from: request))
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(object?["agent_code"] as? String, "her-test")
            XCTAssertEqual(object?["user_id"] as? String, "user-test")
            XCTAssertEqual(object?["query"] as? String, "architecture preferences")
            XCTAssertEqual(object?["top_k"] as? Int, 3)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"injected_context":"User likes direct architecture critique.","retrieved_memories":[{"fact":"direct architecture critique","score":0.82,"layer":"fact"}],"timing_ms":4.2}"#.utf8))
        }
        let executor = CapabilityExecutor(
            registry: PluginRegistry(config: config),
            config: config,
            baseDirectory: root.path,
            urlSession: session
        )

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_mem_query",
            functionName: "agentmem_query",
            capabilityID: "agentmem.query",
            arguments: ["query": "architecture preferences", "top_k": 3]
        ))

        XCTAssertEqual(result.title, "AgentMem Query Result")
        XCTAssertTrue(result.content.contains("User likes direct architecture critique."))
        XCTAssertTrue(result.content.contains("[fact] direct architecture critique"))
        XCTAssertTrue(result.content.contains("timing_ms: 4.2"))
        XCTAssertFalse(result.content.contains("mem_test_key"))
        XCTAssertFalse(result.requiresUserApproval)
    }

    @MainActor
    func testAgentMemAddUsesApprovalCapabilityAndDoesNotEchoKey() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-agentmem-add-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var config = HerAppConfig.empty
        config.agentMemBaseURL = URL(string: "https://agentmem.test")!
        config.agentMemAPIKey = "mem_test_key"
        config.agentCode = "her-test"
        config.userID = "user-test"
        let userInput = "User wants concise implementation reviews."
        let agentResponse = "Save as a working preference."
        let session = mockSession { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://agentmem.test/v1/memory/add")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Memory-API-Key"), "mem_test_key")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
            let body = try XCTUnwrap(Self.bodyData(from: request))
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(object?["agent_code"] as? String, "her-test")
            XCTAssertEqual(object?["user_id"] as? String, "user-test")
            XCTAssertEqual(object?["user_input"] as? String, userInput)
            XCTAssertEqual(object?["agent_response"] as? String, agentResponse)
            let metadata = object?["metadata"] as? [String: Any]
            XCTAssertEqual(metadata?["source"] as? String, "test")
            XCTAssertEqual(metadata?["capability_id"] as? String, "agentmem.add")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"status":"queued","task_id":"task_123"}"#.utf8))
        }
        let executor = CapabilityExecutor(
            registry: PluginRegistry(config: config),
            config: config,
            baseDirectory: root.path,
            urlSession: session
        )

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_mem_add",
            functionName: "agentmem_add",
            capabilityID: "agentmem.add",
            arguments: [
                "user_input": userInput,
                "agent_response": agentResponse,
                "source": "test"
            ]
        ))

        XCTAssertEqual(result.title, "AgentMem Add Result")
        XCTAssertTrue(result.content.contains("status: queued"))
        XCTAssertTrue(result.content.contains("task_id: task_123"))
        XCTAssertTrue(result.content.contains("user_input_characters: \(userInput.count)"))
        XCTAssertFalse(result.content.contains("mem_test_key"))
        XCTAssertFalse(result.requiresUserApproval)
    }

    @MainActor
    func testNativeReadTextFileRejectsBinaryData() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("her-native-binary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("blob.bin")
        try Data([0, 1, 2, 3]).write(to: file)
        let executor = CapabilityExecutor(registry: PluginRegistry(config: .empty))

        let result = await executor.execute(CapabilityInvocation(
            toolCallID: "call_read",
            functionName: "native_readTextFile",
            capabilityID: "native.readTextFile",
            arguments: ["path": file.path]
        ))

        XCTAssertEqual(result.title, "Read Text File Failed")
        XCTAssertTrue(result.content.contains("binary"))
    }

    private func mockSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        MockURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let data = request.httpBody {
            return data
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return data
    }

    private static func value(after prefix: String, in text: String) -> String? {
        text
            .components(separatedBy: .newlines)
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }?
            .replacingOccurrences(of: prefix, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func toolFunction(named name: String, in catalog: CapabilityToolCatalog) -> [String: Any]? {
        catalog.tools.compactMap { tool in
            tool["function"] as? [String: Any]
        }
        .first { $0["name"] as? String == name }
    }

    private func webServiceManifest(
        id: String,
        url: String,
        method: String,
        bodyTemplate: String? = nil
    ) -> PluginManifest {
        PluginManifest(
            id: id,
            name: "Web Service",
            version: "0.1.0",
            description: "Web service plugin",
            author: nil,
            systemPromptAddendum: nil,
            capabilities: [
                .init(
                    id: "\(id).run",
                    title: "Run Web Service",
                    kind: "webservice",
                    invocation: "\(id).run",
                    requiresApproval: false,
                    adapter: .init(
                        type: "webservice",
                        url: url,
                        method: method,
                        bodyTemplate: bodyTemplate
                    )
                )
            ]
        )
    }
}
