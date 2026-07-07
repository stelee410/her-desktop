import AppKit
import Foundation
import SwiftUI

/// Plugin drafts, install/remove/export, vibe coding, and MCP discovery.
extension AppViewModel {
    func openPluginDirectory() {
        openDirectory(HerWorkspacePaths.pluginDirectory(config: config, cwd: runtimeCwd), eventType: "workspace.open_plugin_directory")
    }

    func installGeneratedPluginDraft(_ draft: GeneratedPluginDraft) async {
        let result = await installGeneratedPluginDraftResult(
            draft,
            source: draft.source,
            eventSource: draft.source,
            summary: "generated plugin draft"
        )
        messages.append(ChatMessage(role: .tool, content: "\(result.title)\n\(result.content)"))
        saveSessionSnapshot()
    }

    func installGeneratedPluginDraftCapability(arguments: [String: Any]) async -> CapabilityResult {
        guard arguments["confirmed"] as? Bool == true else {
            return CapabilityResult(
                title: "Plugin Draft Install Needs Confirmation",
                content: "Installing a staged plugin draft needs explicit confirmation. Set confirmed=true only after the user approves.",
                requiresUserApproval: true
            )
        }
        guard let draft = stagedDraft(from: arguments) else {
            let pluginID = stringArgument(arguments, keys: ["plugin_id", "pluginID"], fallback: "")
            let draftID = stringArgument(arguments, keys: ["draft_id", "draftID"], fallback: "")
            return CapabilityResult(
                title: "Plugin Draft Install Failed",
                content: """
                Could not find staged draft plugin_id=\(pluginID.isEmpty ? "unspecified" : pluginID) draft_id=\(draftID.isEmpty ? "unspecified" : draftID).
                \(stagedDraftRetryHint(functionName: "plugin_installDraft"))
                """,
                requiresUserApproval: false
            )
        }
        return await installGeneratedPluginDraftResult(
            draft,
            source: "staged generated draft",
            eventSource: "plugin.installDraft capability",
            summary: "staged generated plugin draft"
        )
    }

    func stagedDraft(from arguments: [String: Any]) -> GeneratedPluginDraft? {
        let draftID = stringArgument(arguments, keys: ["draft_id", "draftID"], fallback: "")
        if !draftID.isEmpty {
            return generatedPluginDrafts.first {
                $0.id.uuidString.caseInsensitiveCompare(draftID) == .orderedSame
            }
        }
        let pluginID = stringArgument(arguments, keys: ["plugin_id", "pluginID"], fallback: "")
        if !pluginID.isEmpty {
            return generatedPluginDrafts.first { $0.manifest.id == pluginID }
        }
        return generatedPluginDrafts.count == 1 ? generatedPluginDrafts.first : nil
    }

    func installGeneratedPluginDraftResult(
        _ draft: GeneratedPluginDraft,
        source: String,
        eventSource: String,
        summary: String
    ) async -> CapabilityResult {
        do {
            let existingIDs = plugins.map(\.id).filter { $0 != draft.manifest.id }
            try PluginPackageValidator().validate(draft.package, existingPluginIDs: existingIDs)
            let updatingExisting = plugins.contains { $0.id == draft.manifest.id }
            try pluginRegistry.install(package: draft.package, replacingExisting: updatingExisting)
            generatedPluginDrafts.removeAll { $0.id == draft.id }
            try? pluginDraftStore.delete(draft)
            let title = updatingExisting ? "Plugin Updated" : "Plugin Installed"
            let verb = updatingExisting ? "Updated" : "Installed"
            auditPluginEvent(
                type: updatingExisting ? "plugin.updated" : "plugin.installed",
                package: draft.package,
                summary: updatingExisting ? "Updated \(summary)." : "Installed \(summary).",
                metadata: [
                    "source": eventSource,
                    "draftID": draft.id.uuidString,
                    "draftSource": draft.source
                ]
            )
            saveSessionSnapshot()
            await reloadPlugins()
            rebuildRunningTasks()
            focusInstalledPlugin(draft.manifest.id)
            prepareInstalledCapabilityRun(for: draft.manifest)
            // A webapp-kind plugin ships a runnable app; materialize it now.
            let webAppLine = materializePluginWebApp(package: draft.package)
            var content = pluginInstalledContent(
                package: draft.package,
                source: source,
                title: title,
                verb: verb
            )
            if let webAppLine {
                content += "\n\(webAppLine)"
            }
            return CapabilityResult(
                title: title,
                content: content,
                requiresUserApproval: false
            )
        } catch {
            lastError = error.localizedDescription
            audit(
                type: "plugin.install_failed",
                summary: error.localizedDescription,
                metadata: [
                    "pluginID": draft.manifest.id,
                    "source": eventSource,
                    "draftID": draft.id.uuidString,
                    "draftSource": draft.source
                ]
            )
            saveSessionSnapshot()
            return CapabilityResult(
                title: "Plugin Install Failed",
                content: error.localizedDescription,
                requiresUserApproval: false
            )
        }
    }

    func discardGeneratedPluginDraft(_ draft: GeneratedPluginDraft) {
        let result = discardGeneratedPluginDraftResult(
            draft,
            eventSource: draft.source,
            summary: "generated plugin draft"
        )
        messages.append(ChatMessage(role: .tool, content: "\(result.title)\n\(result.content)"))
        saveSessionSnapshot()
    }

    func discardGeneratedPluginDraftCapability(arguments: [String: Any]) -> CapabilityResult {
        guard arguments["confirmed"] as? Bool == true else {
            return CapabilityResult(
                title: "Plugin Draft Discard Needs Confirmation",
                content: "Discarding a staged plugin draft needs explicit confirmation. Set confirmed=true only after the user approves.",
                requiresUserApproval: true
            )
        }
        guard let draft = stagedDraft(from: arguments) else {
            let pluginID = stringArgument(arguments, keys: ["plugin_id", "pluginID"], fallback: "")
            let draftID = stringArgument(arguments, keys: ["draft_id", "draftID"], fallback: "")
            return CapabilityResult(
                title: "Plugin Draft Discard Failed",
                content: """
                Could not find staged draft plugin_id=\(pluginID.isEmpty ? "unspecified" : pluginID) draft_id=\(draftID.isEmpty ? "unspecified" : draftID).
                \(stagedDraftRetryHint(functionName: "plugin_discardDraft"))
                """,
                requiresUserApproval: false
            )
        }
        return discardGeneratedPluginDraftResult(
            draft,
            eventSource: "plugin.discardDraft capability",
            summary: "staged generated plugin draft"
        )
    }

    func stagedDraftRetryHint(functionName: String) -> String {
        guard !generatedPluginDrafts.isEmpty else {
            return "No generated plugin drafts are waiting for review."
        }
        let summaries = generatedPluginDrafts.map { draft in
            let arguments = """
            {"plugin_id":"\(draft.manifest.id)","draft_id":"\(draft.id.uuidString)","confirmed":true}
            """
            return """
            - \(draft.manifest.name) (\(draft.manifest.id))
              draft_id: \(draft.id.uuidString)
              retry: \(functionName) \(arguments)
            """
        }
        return """
        Available drafts:
        \(summaries.joined(separator: "\n"))
        """
    }

    func discardGeneratedPluginDraftResult(
        _ draft: GeneratedPluginDraft,
        eventSource: String,
        summary: String
    ) -> CapabilityResult {
        generatedPluginDrafts.removeAll { $0.id == draft.id }
        try? pluginDraftStore.delete(draft)
        auditPluginEvent(
            type: "plugin.draft_discarded",
            package: draft.package,
            summary: "Discarded \(summary).",
            metadata: [
                "source": eventSource,
                "draftID": draft.id.uuidString,
                "draftSource": draft.source
            ]
        )
        rebuildRunningTasks()
        saveSessionSnapshot()
        return CapabilityResult(
            title: "Plugin Draft Discarded",
            content: "\(draft.manifest.name) (\(draft.manifest.id)) was discarded and not installed.",
            requiresUserApproval: false
        )
    }

    @discardableResult
    func stageGeneratedPluginPackage(_ package: PluginPackage, source: String = "plugin.draft") -> GeneratedPluginDraft {
        let removedDrafts = generatedPluginDrafts.filter { $0.manifest.id == package.manifest.id }
        removedDrafts.forEach { try? pluginDraftStore.delete($0) }
        generatedPluginDrafts.removeAll { $0.manifest.id == package.manifest.id }
        let draft = GeneratedPluginDraft(package: package, source: source)
        generatedPluginDrafts.append(draft)
        do {
            try pluginDraftStore.save(draft)
        } catch {
            lastError = "Could not persist plugin draft: \(error.localizedDescription)"
            audit(
                type: "plugin.draft_persist_failed",
                summary: error.localizedDescription,
                metadata: ["pluginID": package.manifest.id, "source": source]
            )
        }
        auditPluginEvent(
            type: "plugin.draft_staged",
            package: package,
            summary: "Staged plugin package for review.",
            metadata: ["source": source]
        )
        rebuildRunningTasks()
        return draft
    }

    func reloadPlugins() async {
        plugins = pluginRegistry.loadPlugins()
        refreshPluginHealth()
        tools = Self.tools(from: serviceHealth, model: config.agentLLMModel)
        rebuildRunningTasks()
    }

    func refreshPluginEvents() {
        do {
            pluginEvents = Self.recentPluginEvents(from: try pluginEventStore.loadAll())
        } catch {
            lastError = "Could not load plugin lifecycle log: \(error.localizedDescription)"
        }
    }

    func installDraftPlugin(
        named name: String,
        description: String,
        kind: String = "skill",
        requiresApproval: Bool = true,
        webServiceURL: String = "",
        webServiceMethod: String = "POST",
        mcpEndpointURL: String = "",
        mcpMethodName: String = "",
        mcpToolName: String = "",
        mcpInputSchemaJSON: String = "",
        commandPath: String = "",
        commandArguments: String = ""
    ) async {
        recordInteractionEvent(interactionEventBus.event(
            surface: .pluginLibrary,
            kind: .pluginDraftRequested,
            summary: "Install local vibe plugin draft.",
            payload: [
                "name": name,
                "kind": kind,
                "requiresApproval": String(requiresApproval)
            ]
        ))
        let package = makeDraftPluginPackage(
            named: name,
            description: description,
            kind: kind,
            requiresApproval: requiresApproval,
            webServiceURL: webServiceURL,
            webServiceMethod: webServiceMethod,
            mcpEndpointURL: mcpEndpointURL,
            mcpMethodName: mcpMethodName,
            mcpToolName: mcpToolName,
            mcpInputSchemaJSON: mcpInputSchemaJSON,
            commandPath: commandPath,
            commandArguments: commandArguments
        )
        do {
            try PluginPackageValidator().validate(package, existingPluginIDs: plugins.map(\.id))
            try pluginRegistry.install(package: package)
            messages.append(ChatMessage(
                role: .tool,
                content: pluginInstalledContent(package: package, source: "the vibe composer")
            ))
            auditPluginEvent(
                type: "plugin.installed",
                package: package,
                summary: "Installed plugin from local vibe composer.",
                metadata: ["source": "vibe-composer"]
            )
            saveSessionSnapshot()
            await reloadPlugins()
            focusInstalledPlugin(package.manifest.id)
            prepareInstalledCapabilityRun(for: package.manifest)
        } catch {
            lastError = error.localizedDescription
            messages.append(ChatMessage(role: .tool, content: "Plugin Install Failed\n\(error.localizedDescription)"))
            audit(type: "plugin.install_failed", summary: error.localizedDescription)
            saveSessionSnapshot()
        }
    }

    func removePlugin(_ plugin: PluginManifest) async {
        await removePlugin(pluginID: plugin.id)
    }

    func exportPlugin(_ plugin: PluginManifest) {
        exportPlugin(pluginID: plugin.id)
    }

    func exportPlugin(pluginID: String) {
        let result = exportPluginResult(
            pluginID: pluginID,
            eventSource: "plugin-library",
            summary: "Exported local plugin package."
        )
        messages.append(ChatMessage(role: .tool, content: "\(result.title)\n\(result.content)"))
        saveSessionSnapshot()
    }

    func vibeUpdateContext(for plugin: PluginManifest) -> String {
        do {
            let package = try pluginRegistry.package(pluginID: plugin.id)
            return SecretRedactor.redact(pluginUpdateContext(for: package), config: config)
        } catch {
            let fallback = """
            Installed plugin summary:
            - id: \(plugin.id)
            - name: \(plugin.name)
            - version: \(plugin.version)
            - description: \(plugin.description)
            - package_files: unavailable (\(error.localizedDescription))

            capabilities:
            \(plugin.capabilities.map(pluginCapabilityContextLine).joined(separator: "\n"))
            """
            return SecretRedactor.redact(fallback, config: config)
        }
    }

    func prepareVibePluginUpdate(for plugin: PluginManifest) {
        guard plugin.id.hasPrefix("local.") else { return }
        let capability = plugin.capabilities.first
        let adapter = capability?.adapter
        pendingVibePluginComposerPreset = VibePluginComposerPreset(
            pluginName: plugin.name,
            pluginDescription: """
            Update the installed local plugin \(plugin.name). Preserve its useful behavior, keep the same plugin id, and return a complete replacement package.
            """,
            pluginKind: capability?.kind ?? "skill",
            pluginRequiresApproval: capability?.requiresApproval ?? true,
            pluginURL: adapter?.url ?? "",
            pluginMethod: adapter?.method ?? "POST",
            pluginMCPMethod: adapter?.methodName ?? "",
            pluginMCPToolName: adapter?.toolName ?? "",
            pluginMCPInputSchemaJSON: inputSchemaJSON(for: capability),
            pluginCommandPath: adapter?.command ?? "",
            pluginCommandArguments: adapter?.arguments?.joined(separator: "\n") ?? "",
            pluginPackageJSON: "",
            pluginUpdateTargetID: plugin.id,
            pluginExistingPackageContext: vibeUpdateContext(for: plugin)
        )
    }

    func pluginUpdateContext(for package: PluginPackage) -> String {
        let manifest = package.manifest
        let review = PluginPackageReview(package: package, catalogManifests: catalogManifestsAfterInstalling(manifest))
        let fileLines = review.fileSummaries.map { file in
            "- \(file.path) (\(file.lineCount) line(s), \(file.byteCount) byte(s))"
        }
        let excerpts = package.files
            .filter { shouldIncludePluginUpdateExcerpt(path: $0.path) }
            .prefix(6)
            .map { file in
                """
                ### \(file.path)
                \(pluginUpdateExcerpt(file.content))
                """
            }
            .joined(separator: "\n\n")
        return """
        Installed package to update:
        - id: \(manifest.id)
        - name: \(manifest.name)
        - version: \(manifest.version)
        - description: \(manifest.description)
        - author: \(manifest.author ?? "unspecified")
        - risk: \(review.riskLevel.rawValue)

        capabilities:
        \(manifest.capabilities.map(pluginCapabilityContextLine).joined(separator: "\n"))

        package_files:
        \(fileLines.isEmpty ? "(none)" : fileLines.joined(separator: "\n"))

        key_file_excerpts:
        \(excerpts.isEmpty ? "(none)" : excerpts)

        Update rule: return a complete replacement PluginPackage using the same plugin id, not a partial patch.
        """
    }

    func pluginCapabilityContextLine(_ capability: PluginManifest.Capability) -> String {
        var fields = [
            "kind=\(capability.kind)",
            "invocation=\(capability.invocation)",
            capability.requiresApproval ? "approval_required" : "no_approval"
        ]
        if let adapter = capability.adapter {
            fields.append("adapter=\(adapter.type)")
            if let url = adapter.url { fields.append("url=\(url)") }
            if let method = adapter.method { fields.append("method=\(method)") }
            if let methodName = adapter.methodName { fields.append("methodName=\(methodName)") }
            if let toolName = adapter.toolName { fields.append("toolName=\(toolName)") }
            if let skillFile = adapter.skillFile { fields.append("skillFile=\(skillFile)") }
            if let command = adapter.command { fields.append("command=\(command)") }
        }
        let inputFields = CapabilityInputSchema.fields(for: capability).map(\.name).joined(separator: ", ")
        if !inputFields.isEmpty {
            fields.append("inputFields=\(inputFields)")
        }
        return "- \(capability.id): \(capability.title) [\(fields.joined(separator: ", "))]"
    }

    func shouldIncludePluginUpdateExcerpt(path: String) -> Bool {
        let lowercased = path.lowercased()
        return lowercased == "plugin.json"
            || lowercased == "skill.md"
            || lowercased == "readme.md"
            || lowercased.hasSuffix(".md")
            || lowercased.hasSuffix(".json")
    }

    func pluginUpdateExcerpt(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String(trimmed.prefix(3_000))
        if trimmed.count <= prefix.count {
            return prefix.isEmpty ? "(empty)" : prefix
        }
        return "\(prefix)\n... [truncated]"
    }

    func inputSchemaJSON(for capability: PluginManifest.Capability?) -> String {
        guard let inputSchema = capability?.inputSchema,
              let data = try? JSONEncoder.pretty.encode(inputSchema) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func exportPluginCapability(arguments: [String: Any]) -> CapabilityResult {
        guard arguments["confirmed"] as? Bool == true else {
            return CapabilityResult(
                title: "Plugin Export Needs Confirmation",
                content: "Exporting a local plugin package needs explicit confirmation. Set confirmed=true only after the user approves.",
                requiresUserApproval: true
            )
        }
        let pluginID = stringArgument(arguments, keys: ["plugin_id", "pluginID"], fallback: "")
        guard !pluginID.isEmpty else {
            return CapabilityResult(
                title: "Plugin Export Failed",
                content: "plugin_id is required.",
                requiresUserApproval: false
            )
        }
        return exportPluginResult(
            pluginID: pluginID,
            eventSource: "plugin.export capability",
            summary: "Exported local plugin package through plugin.export capability."
        )
    }

    func exportPluginResult(
        pluginID: String,
        eventSource: String,
        summary: String
    ) -> CapabilityResult {
        do {
            let package = try pluginRegistry.package(pluginID: pluginID)
            let directory = HerWorkspacePaths.pluginExportDirectory(cwd: runtimeCwd)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileName = "\(package.manifest.id).plugin-package.json"
            let destination = directory.appendingPathComponent(fileName)
            try JSONEncoder.pretty.encode(package).write(to: destination, options: .atomic)
            auditPluginEvent(
                type: "plugin.exported",
                package: package,
                summary: summary,
                metadata: [
                    "path": destination.path,
                    "source": eventSource
                ]
            )
            return CapabilityResult(
                title: "Plugin Exported",
                content: "\(package.manifest.name) (\(package.manifest.id)) was exported to \(destination.path).",
                requiresUserApproval: false
            )
        } catch {
            lastError = error.localizedDescription
            audit(
                type: "plugin.export_failed",
                summary: error.localizedDescription,
                metadata: [
                    "pluginID": pluginID,
                    "source": eventSource
                ]
            )
            return CapabilityResult(
                title: "Plugin Export Failed",
                content: error.localizedDescription,
                requiresUserApproval: false
            )
        }
    }

    func removePlugin(pluginID: String) async {
        guard let plugin = plugins.first(where: { $0.id == pluginID }) else {
            let message = "Plugin \(pluginID) is not installed."
            lastError = message
            messages.append(ChatMessage(role: .tool, content: "Plugin Remove Failed\n\(message)"))
            audit(type: "plugin.remove_failed", summary: message, metadata: ["pluginID": pluginID])
            saveSessionSnapshot()
            return
        }

        do {
            try pluginRegistry.remove(pluginID: pluginID)
            pendingApprovals.removeAll { $0.invocation.capabilityID.hasPrefix(pluginID + ".") }
            if highlightedPluginID == pluginID {
                highlightedPluginID = nil
            }
            messages.append(ChatMessage(
                role: .tool,
                content: "Plugin Removed\n\(plugin.name) (\(plugin.id)) was removed from the local plugin directory."
            ))
            audit(
                type: "plugin.removed",
                summary: "Removed local plugin \(plugin.name).",
                metadata: [
                    "pluginID": plugin.id,
                    "pluginName": plugin.name,
                    "capabilityCount": String(plugin.capabilities.count)
                ]
            )
            recordPluginLifecycleEvent(
                action: .removed,
                manifest: plugin,
                fileCount: 0,
                source: "plugin-library",
                summary: "Removed local plugin \(plugin.name)."
            )
            saveSessionSnapshot()
            await reloadPlugins()
        } catch {
            lastError = error.localizedDescription
            messages.append(ChatMessage(role: .tool, content: "Plugin Remove Failed\n\(error.localizedDescription)"))
            audit(
                type: "plugin.remove_failed",
                summary: error.localizedDescription,
                metadata: ["pluginID": pluginID]
            )
            saveSessionSnapshot()
        }
    }

    func stageDraftPlugin(
        named name: String,
        description: String,
        kind: String = "skill",
        requiresApproval: Bool = true,
        webServiceURL: String = "",
        webServiceMethod: String = "POST",
        mcpEndpointURL: String = "",
        mcpMethodName: String = "",
        mcpToolName: String = "",
        mcpInputSchemaJSON: String = "",
        commandPath: String = "",
        commandArguments: String = ""
    ) {
        recordInteractionEvent(interactionEventBus.event(
            surface: .pluginLibrary,
            kind: .pluginDraftRequested,
            summary: "Stage local vibe plugin draft.",
            payload: [
                "name": name,
                "kind": kind,
                "requiresApproval": String(requiresApproval)
            ]
        ))
        let package = makeDraftPluginPackage(
            named: name,
            description: description,
            kind: kind,
            requiresApproval: requiresApproval,
            webServiceURL: webServiceURL,
            webServiceMethod: webServiceMethod,
            mcpEndpointURL: mcpEndpointURL,
            mcpMethodName: mcpMethodName,
            mcpToolName: mcpToolName,
            mcpInputSchemaJSON: mcpInputSchemaJSON,
            commandPath: commandPath,
            commandArguments: commandArguments
        )
        do {
            try PluginPackageValidator().validate(package, existingPluginIDs: plugins.map(\.id))
            let draft = stageGeneratedPluginPackage(package, source: "vibe-composer")
            messages.append(ChatMessage(
                role: .tool,
                content: pluginDraftReviewContent(
                    title: "Plugin Draft Created",
                    draft: draft,
                    summary: "Created \(package.manifest.name) (\(package.manifest.id)) for review."
                )
            ))
        } catch {
            lastError = error.localizedDescription
            messages.append(ChatMessage(role: .tool, content: "Plugin Draft Failed\n\(error.localizedDescription)"))
            audit(type: "plugin.draft_failed", summary: error.localizedDescription)
        }
        saveSessionSnapshot()
    }

    func discoverMCPTools(endpointURL: String) async {
        let cleanURL = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        recordInteractionEvent(interactionEventBus.event(
            surface: .pluginLibrary,
            kind: .manualCapabilityRequested,
            summary: "Discover local MCP bridge tools.",
            payload: ["url": cleanURL]
        ))
        connectionState = .working
        lastError = nil
        do {
            let response = try await MCPBridgeDiscoveryClient(urlSession: urlSession)
                .discover(rawURL: cleanURL, requestID: "mcp_composer_discover")
            mcpDiscoveredTools = response.tools
            messages.append(ChatMessage(
                role: .tool,
                content: "MCP Tool Discovery Result\n\(response.displayContent)"
            ))
            audit(
                type: "mcp.tools_discovered",
                summary: "Discovered \(response.tools.count) tool(s) from local MCP bridge.",
                metadata: [
                    "url": cleanURL,
                    "toolCount": String(response.tools.count)
                ]
            )
            connectionState = config.hasLLMKey ? .ready : .offline
        } catch {
            mcpDiscoveredTools = []
            lastError = error.localizedDescription
            messages.append(ChatMessage(role: .tool, content: "MCP Tool Discovery Failed\n\(error.localizedDescription)"))
            audit(
                type: "mcp.tools_discovery_failed",
                summary: error.localizedDescription,
                metadata: ["url": cleanURL]
            )
            connectionState = .error
        }
        saveSessionSnapshot()
    }

    func clearMCPDiscoveredTools() {
        mcpDiscoveredTools = []
    }

    func stageMCPDiscoveredToolPlugin(
        _ tool: MCPDiscoveredTool,
        endpointURL: String,
        name: String = "",
        description: String = "",
        requiresApproval: Bool = true
    ) {
        let cleanURL = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else {
            lastError = "MCP endpoint URL is required before drafting a plugin."
            messages.append(ChatMessage(role: .tool, content: "MCP Plugin Draft Failed\n\(lastError ?? "")"))
            saveSessionSnapshot()
            return
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        stageDraftPlugin(
            named: cleanName.isEmpty ? pluginName(forMCPToolName: tool.name) : cleanName,
            description: cleanDescription.isEmpty ? mcpToolDescription(tool) : cleanDescription,
            kind: "mcp",
            requiresApproval: requiresApproval,
            mcpEndpointURL: cleanURL,
            mcpMethodName: "tools/call",
            mcpToolName: tool.name,
            mcpInputSchemaJSON: tool.rawInputSchema
        )
    }

    func installMCPDiscoveredToolPlugin(
        _ tool: MCPDiscoveredTool,
        endpointURL: String,
        name: String = "",
        description: String = "",
        requiresApproval: Bool = true
    ) async {
        let cleanURL = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else {
            lastError = "MCP endpoint URL is required before installing a plugin."
            messages.append(ChatMessage(role: .tool, content: "MCP Plugin Install Failed\n\(lastError ?? "")"))
            saveSessionSnapshot()
            return
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        await installDraftPlugin(
            named: cleanName.isEmpty ? pluginName(forMCPToolName: tool.name) : cleanName,
            description: cleanDescription.isEmpty ? mcpToolDescription(tool) : cleanDescription,
            kind: "mcp",
            requiresApproval: requiresApproval,
            mcpEndpointURL: cleanURL,
            mcpMethodName: "tools/call",
            mcpToolName: tool.name,
            mcpInputSchemaJSON: tool.rawInputSchema
        )
    }

    @discardableResult
    func stagePluginPackageJSON(_ text: String, source: String = "pasted-package") -> Bool {
        let result = stagePluginPackageJSONResult(text, source: source)
        messages.append(ChatMessage(role: .tool, content: "\(result.title)\n\(result.content)"))
        saveSessionSnapshot()
        return result.title == "Plugin Package Imported"
    }

    @discardableResult
    func stagePluginPackageFile(_ url: URL, source: String = "plugin-package-file") -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let sourceLabel = "\(source):\(url.lastPathComponent)"
            return stagePluginPackageJSON(text, source: sourceLabel)
        } catch {
            reportPluginPackageImportError(error, source: source, fileName: url.lastPathComponent)
            return false
        }
    }

    @discardableResult
    func stageSkillFilePlugin(
        _ url: URL,
        name: String = "",
        description: String = "",
        requiresApproval: Bool = true,
        source: String = "skill-file"
    ) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanContent.isEmpty else {
                throw PluginImportError.emptySkillFile(url.lastPathComponent)
            }
            let sourceLabel = "\(source):\(url.lastPathComponent)"
            let package = makeImportedSkillPluginPackage(
                skillContent: cleanContent,
                fileName: url.deletingPathExtension().lastPathComponent,
                name: name,
                description: description,
                requiresApproval: requiresApproval
            )
            let documented = PluginPackageReviewDocumenter().documented(package)
            try PluginPackageValidator().validate(documented, existingPluginIDs: plugins.map(\.id))
            recordInteractionEvent(interactionEventBus.event(
                surface: .pluginLibrary,
                kind: .pluginPackageImported,
                summary: "Imported skill file as plugin package.",
                payload: [
                    "source": sourceLabel,
                    "pluginID": documented.manifest.id,
                    "file": url.lastPathComponent
                ]
            ))
            let draft = stageGeneratedPluginPackage(documented, source: sourceLabel)
            messages.append(ChatMessage(
                role: .tool,
                content: pluginDraftReviewContent(
                    title: "Skill File Imported",
                    draft: draft,
                    summary: "Imported \(url.lastPathComponent) as \(documented.manifest.name) (\(documented.manifest.id)) for review."
                )
            ))
            saveSessionSnapshot()
            return true
        } catch {
            reportSkillFileImportError(error, source: source, fileName: url.lastPathComponent)
            return false
        }
    }

    func reportPluginPackageImportError(_ error: Error, source: String, fileName: String = "") {
        lastError = error.localizedDescription
        var metadata = ["source": source]
        if !fileName.isEmpty {
            metadata["file"] = fileName
        }
        audit(
            type: "plugin.package_import_failed",
            summary: error.localizedDescription,
            metadata: metadata
        )
        messages.append(ChatMessage(
            role: .tool,
            content: "Plugin Package Import Failed\n\(error.localizedDescription)"
        ))
        saveSessionSnapshot()
    }

    func reportSkillFileImportError(_ error: Error, source: String, fileName: String = "") {
        lastError = error.localizedDescription
        var metadata = ["source": source]
        if !fileName.isEmpty {
            metadata["file"] = fileName
        }
        audit(
            type: "plugin.skill_import_failed",
            summary: error.localizedDescription,
            metadata: metadata
        )
        messages.append(ChatMessage(
            role: .tool,
            content: "Skill File Import Failed\n\(error.localizedDescription)"
        ))
        saveSessionSnapshot()
    }

    func stagePluginPackageCapability(arguments: [String: Any]) -> CapabilityResult {
        let packageJSON = stringArgument(
            arguments,
            keys: ["package_json", "plugin_package_json", "json", "request"],
            fallback: ""
        )
        guard !packageJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CapabilityResult(
                title: "Plugin Package Import Failed",
                content: "package_json is required.",
                requiresUserApproval: false
            )
        }
        return stagePluginPackageJSONResult(packageJSON, source: "plugin.stagePackage capability")
    }

    func stagePluginPackageJSONResult(_ text: String, source: String) -> CapabilityResult {
        do {
            let decoded = try PluginPackageJSONExtractor().decodePackage(from: text)
            let package = PluginPackageReviewDocumenter().documented(decoded)
            let existingIDs = plugins.map(\.id).filter { $0 != package.manifest.id }
            try PluginPackageValidator().validate(package, existingPluginIDs: existingIDs)
            recordInteractionEvent(interactionEventBus.event(
                surface: .pluginLibrary,
                kind: .pluginPackageImported,
                summary: "Imported plugin package JSON.",
                payload: [
                    "source": source,
                    "pluginID": package.manifest.id,
                    "capabilityCount": String(package.manifest.capabilities.count)
                ]
            ))
            let draft = stageGeneratedPluginPackage(package, source: source)
            return CapabilityResult(
                title: "Plugin Package Imported",
                content: pluginDraftReviewContent(
                    title: "Plugin Package Imported",
                    draft: draft,
                    summary: "Imported \(package.manifest.name) (\(package.manifest.id)) for review."
                ),
                requiresUserApproval: false
            )
        } catch {
            lastError = error.localizedDescription
            audit(
                type: "plugin.package_import_failed",
                summary: error.localizedDescription,
                metadata: ["source": source]
            )
            return CapabilityResult(
                title: "Plugin Package Import Failed",
                content: error.localizedDescription,
                requiresUserApproval: false
            )
        }
    }

    func generateAIDraftPlugin(
        named name: String,
        description: String,
        kind: String = "skill",
        requiresApproval: Bool = true,
        webServiceURL: String = "",
        webServiceMethod: String = "POST",
        mcpEndpointURL: String = "",
        mcpMethodName: String = "",
        mcpToolName: String = "",
        mcpInputSchemaJSON: String = "",
        commandPath: String = "",
        commandArguments: String = "",
        vibeBrief: String = "",
        updatePluginID: String = "",
        existingPackageContext: String = "",
        installImmediately: Bool = false
    ) async {
        guard config.hasLLMKey else {
            lastError = ServiceError.missingAPIKey("AgentLLM").localizedDescription
            messages.append(ChatMessage(role: .assistant, content: """
            需要先配置 AgentLLM API key，才能用 AI 生成插件草稿。

            先把 Settings 里的 AgentLLM API key 填好并保存；插件生成、MCP 接入和安装确认都可以在聊天通路跑通后继续。
            """))
            saveSessionSnapshot()
            return
        }

        recordInteractionEvent(interactionEventBus.event(
            surface: .pluginLibrary,
            kind: .pluginDraftRequested,
            summary: "Generate AgentLLM vibe plugin draft.",
            payload: [
                "name": name,
                "kind": kind,
                "requiresApproval": String(requiresApproval),
                "updatePluginID": updatePluginID,
                "installImmediately": String(installImmediately)
            ]
        ))
        connectionState = .thinking
        lastError = nil
        let request = VibePluginPackageRequest(
            name: name,
            description: description,
            kind: kind,
            requiresApproval: requiresApproval,
            webServiceURL: webServiceURL,
            webServiceMethod: webServiceMethod,
            mcpEndpointURL: mcpEndpointURL,
            mcpMethodName: mcpMethodName,
            mcpToolName: mcpToolName,
            mcpInputSchemaJSON: mcpInputSchemaJSON,
            commandPath: commandPath,
            commandArguments: commandArguments,
            updatePluginID: updatePluginID,
            existingPackageContext: existingPackageContext,
            vibeBrief: vibeBrief,
            installImmediately: installImmediately
        )
        let promptBuilder = VibePluginPackagePromptBuilder()
        let existingPluginIDs = plugins.map(\.id)
        let llmMessages = promptBuilder.build(
            request: request,
            existingPluginIDs: existingPluginIDs
        )

        do {
            let response = try await agentLLM.chat(messages: llmMessages, tools: [])
            let content = response.content ?? ""
            let generation = try await validatedAIGeneratedPluginPackage(
                content: content,
                request: request,
                existingPluginIDs: existingPluginIDs,
                promptBuilder: promptBuilder
            )
            let package = generation.package
            if generation.repaired {
                auditPluginEvent(
                    type: "plugin.ai_generation_repaired",
                    package: package,
                    summary: "Repaired AgentLLM-generated plugin package after validation feedback.",
                    metadata: ["source": "agentllm-vibe-composer"]
                )
            }
            let draft = stageGeneratedPluginPackage(package, source: "agentllm-vibe-composer")
            var reviewContent = pluginDraftReviewContent(
                title: installImmediately ? "AI Plugin Install Ready" : "AI Plugin Draft Created",
                draft: draft,
                summary: generation.repaired
                    ? "Created \(package.manifest.name) (\(package.manifest.id)) for review after one repair pass."
                    : "Created \(package.manifest.name) (\(package.manifest.id)) for review."
            )
            var queuedApprovalID: UUID?
            if installImmediately {
                let approval = enqueueInstallDraftApproval(for: draft)
                queuedApprovalID = approval.id
                reviewContent += installDraftApprovalQueuedContent(approval: approval, draft: draft)
            }
            messages.append(ChatMessage(role: .tool, content: reviewContent, approvalID: queuedApprovalID))
            connectionState = .ready
            saveSessionSnapshot()
        } catch {
            connectionState = .error
            lastError = error.localizedDescription
            messages.append(ChatMessage(role: .assistant, content: "AI 生成插件草稿时遇到问题：\(error.localizedDescription)"))
            audit(type: "plugin.ai_generation_failed", summary: error.localizedDescription)
            saveSessionSnapshot()
        }
    }

    func validatedAIGeneratedPluginPackage(
        content: String,
        request: VibePluginPackageRequest,
        existingPluginIDs: [String],
        promptBuilder: VibePluginPackagePromptBuilder
    ) async throws -> AIGeneratedPluginPackage {
        do {
            return try AIGeneratedPluginPackage(package: validatedPluginPackage(from: content), repaired: false)
        } catch let initialError {
            let repairMessages = promptBuilder.repair(
                request: request,
                existingPluginIDs: existingPluginIDs,
                invalidResponse: content,
                errorMessage: initialError.localizedDescription
            )
            let repairedResponse = try await agentLLM.chat(messages: repairMessages, tools: [])
            let repairedContent = repairedResponse.content ?? ""
            do {
                return try AIGeneratedPluginPackage(package: validatedPluginPackage(from: repairedContent), repaired: true)
            } catch let repairError {
                throw AIPluginGenerationRepairError(
                    initialError: initialError.localizedDescription,
                    repairError: repairError.localizedDescription
                )
            }
        }
    }

    func validatedPluginPackage(from content: String) throws -> PluginPackage {
        let decoded = try PluginPackageJSONExtractor().decodePackage(from: content)
        let package = PluginPackageReviewDocumenter().documented(decoded)
        let existingIDs = plugins.map(\.id).filter { $0 != package.manifest.id }
        try PluginPackageValidator().validate(package, existingPluginIDs: existingIDs)
        return package
    }

    func pluginName(forMCPToolName toolName: String) -> String {
        let words = toolName
            .replacingOccurrences(of: "[^A-Za-z0-9]+", with: " ", options: .regularExpression)
            .split(separator: " ")
            .prefix(4)
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }
        let base = words.isEmpty ? "MCP Tool" : words.joined(separator: " ")
        return "\(base) MCP"
    }

    func mcpToolDescription(_ tool: MCPDiscoveredTool) -> String {
        let description = tool.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty { return description }
        return "Calls the \(tool.name) MCP tool through a local bridge."
    }

    func makeDraftPluginPackage(
        named name: String,
        description: String,
        kind: String,
        requiresApproval: Bool,
        webServiceURL: String,
        webServiceMethod: String,
        mcpEndpointURL: String,
        mcpMethodName: String,
        mcpToolName: String,
        mcpInputSchemaJSON: String,
        commandPath: String,
        commandArguments: String
    ) -> PluginPackage {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Plugin" : name
        let cleanDescription = description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "A conversationally generated extension." : description
        let cleanKind = kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "skill" : kind.lowercased()
        let effectiveRequiresApproval = cleanKind == "command" ? true : requiresApproval
        let resolvedSlug = PluginIdentifierBuilder.makeSlug(
            name: cleanName,
            description: cleanDescription,
            existingPluginIDs: Set(plugins.map(\.id) + generatedPluginDrafts.map(\.manifest.id))
        )
        let adapter = draftAdapter(
            kind: cleanKind,
            webServiceURL: webServiceURL,
            webServiceMethod: webServiceMethod,
            mcpEndpointURL: mcpEndpointURL,
            mcpMethodName: mcpMethodName,
            mcpToolName: mcpToolName,
            commandPath: commandPath,
            commandArguments: commandArguments
        )
        let manifest = PluginManifest(
            id: "local.\(resolvedSlug)",
            name: cleanName,
            version: "0.1.0",
            description: cleanDescription,
            author: "Vibe coded",
            systemPromptAddendum: "This plugin was created from a conversational design request. Keep behavior narrow and ask for approval before external side effects.",
            capabilities: [
                .init(
                    id: "local.\(resolvedSlug).run",
                    title: "Run \(cleanName)",
                    kind: cleanKind,
                    invocation: "local.\(resolvedSlug).run",
                    requiresApproval: effectiveRequiresApproval,
                    description: cleanDescription,
                    inputSchema: draftInputSchema(kind: cleanKind, mcpInputSchemaJSON: mcpInputSchemaJSON),
                    adapter: adapter
                )
            ]
        )
        let capability = manifest.capabilities[0]
        let contract = draftAdapterDocumentation(capability: capability, adapter: adapter)
        return PluginPackage(
            manifest: manifest,
            files: [
                .init(
                    path: "SKILL.md",
                    content: """
                    # \(cleanName)

                    \(cleanDescription)

                    ## Capability

                    - id: local.\(resolvedSlug).run
                    - kind: \(cleanKind)
                    - approval required: \(effectiveRequiresApproval)

                    ## Adapter Contract

                    \(contract)

                    ## Operating Notes

                    Use this plugin only for the declared capability. Keep the output grounded in the user's request, explain external side effects before they happen, and respect Her Desktop's approval gate.
                    """
                ),
                .init(
                    path: "README.md",
                    content: """
                    # \(cleanName)

                    \(cleanDescription)

                    Generated by Her Desktop's vibe plugin composer.

                    ## Capability Contract

                    \(contract)
                    """
                )
            ]
        )
    }

    func makeImportedSkillPluginPackage(
        skillContent: String,
        fileName: String,
        name: String,
        description: String,
        requiresApproval: Bool
    ) -> PluginPackage {
        let fallbackName = fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Imported Skill"
            : fileName
                .replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .capitalized
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallbackName
            : name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDescription = description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Imported skill instructions from \(fileName.isEmpty ? "a local file" : fileName)."
            : description.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSlug = PluginIdentifierBuilder.makeSlug(
            name: cleanName,
            description: cleanDescription,
            existingPluginIDs: Set(plugins.map(\.id) + generatedPluginDrafts.map(\.manifest.id))
        )
        let pluginID = "local.\(resolvedSlug)"
        let capabilityID = "\(pluginID).run"
        return PluginPackage(
            manifest: PluginManifest(
                id: pluginID,
                name: cleanName,
                version: "0.1.0",
                description: cleanDescription,
                author: "Imported skill file",
                systemPromptAddendum: "This plugin was imported from a local skill file. Treat the skill file as package instructions and keep side effects inside Her Desktop's approval gates.",
                capabilities: [
                    .init(
                        id: capabilityID,
                        title: "Run \(cleanName)",
                        kind: "skill",
                        invocation: capabilityID,
                        requiresApproval: requiresApproval,
                        description: cleanDescription,
                        inputSchema: defaultDraftInputSchema(kind: "skill"),
                        adapter: .init(type: "skill", skillFile: "SKILL.md")
                    )
                ]
            ),
            files: [
                .init(path: "SKILL.md", content: skillContent)
            ]
        )
    }

    func draftAdapterDocumentation(
        capability: PluginManifest.Capability,
        adapter: PluginManifest.CapabilityAdapter?
    ) -> String {
        var capability = capability
        capability.adapter = adapter
        return PluginCapabilityContractFormatter().documentation(capability: capability)
    }

    func draftInputSchema(kind: String, mcpInputSchemaJSON: String) -> [String: JSONValue] {
        if kind.lowercased() == "mcp",
           let schema = supportedMCPInputSchema(from: mcpInputSchemaJSON) {
            return schema
        }
        return defaultDraftInputSchema(kind: kind)
    }

    func defaultDraftInputSchema(kind: String) -> [String: JSONValue] {
        let requestDescription: String
        switch kind.lowercased() {
        case "webservice":
            requestDescription = "Request or payload instructions for the web service."
        case "mcp":
            requestDescription = "Request to send through the local MCP bridge."
        case "command":
            requestDescription = "User input passed into the fixed command template."
        case "native":
            requestDescription = "Request for the native macOS adapter."
        default:
            requestDescription = "User request for this capability."
        }
        return [
            "type": .string("object"),
            "properties": .object([
                "request": .object([
                    "type": .string("string"),
                    "description": .string(requestDescription)
                ])
            ]),
            "required": .array([.string("request")])
        ]
    }

    func supportedMCPInputSchema(from rawJSON: String) -> [String: JSONValue]? {
        let trimmed = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let schema = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              case let .object(properties)? = schema["properties"],
              !properties.isEmpty else {
            return nil
        }

        let required = requiredFieldNames(from: schema["required"])
        let orderedNames = required + properties.keys.sorted().filter { !required.contains($0) }
        var sanitizedProperties: [String: JSONValue] = [:]
        var sanitizedRequired: [JSONValue] = []

        for name in orderedNames {
            guard isSafeInputFieldName(name),
                  case let .object(fieldSchema)? = properties[name],
                  let field = sanitizedInputFieldSchema(fieldSchema) else {
                continue
            }
            sanitizedProperties[name] = .object(field)
            if required.contains(name) {
                sanitizedRequired.append(.string(name))
            }
        }

        guard !sanitizedProperties.isEmpty else { return nil }
        var result: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(sanitizedProperties)
        ]
        if !sanitizedRequired.isEmpty {
            result["required"] = .array(sanitizedRequired)
        }
        return result
    }

    func sanitizedInputFieldSchema(_ schema: [String: JSONValue]) -> [String: JSONValue]? {
        guard case let .string(type)? = schema["type"],
              ["string", "number", "integer", "boolean"].contains(type) else {
            return nil
        }
        var result: [String: JSONValue] = ["type": .string(type)]
        if case let .string(description)? = schema["description"], !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result["description"] = .string(description)
        }
        if type == "string",
           case let .array(values)? = schema["enum"] {
            let enumValues = values.compactMap { value -> JSONValue? in
                guard case let .string(text) = value,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return .string(text)
            }
            if !enumValues.isEmpty {
                result["enum"] = .array(enumValues)
            }
        }
        return result
    }

    func requiredFieldNames(from value: JSONValue?) -> [String] {
        guard case let .array(items)? = value else { return [] }
        return items.compactMap { item in
            guard case let .string(text) = item else { return nil }
            return text
        }
    }

    func isSafeInputFieldName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z_][A-Za-z0-9_-]{0,63}$"#, options: .regularExpression) != nil
    }

    func draftAdapter(
        kind: String,
        webServiceURL: String,
        webServiceMethod: String,
        mcpEndpointURL: String,
        mcpMethodName: String,
        mcpToolName: String,
        commandPath: String,
        commandArguments: String
    ) -> PluginManifest.CapabilityAdapter? {
        switch kind.lowercased() {
        case "skill":
            return .init(type: "skill", skillFile: "SKILL.md")
        case "webservice":
            return .init(
                type: "webservice",
                url: webServiceURL.trimmingCharacters(in: .whitespacesAndNewlines),
                method: webServiceMethod.uppercased()
            )
        case "mcp":
            return .init(
                type: "mcp",
                url: mcpEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines),
                methodName: mcpMethodName.trimmingCharacters(in: .whitespacesAndNewlines),
                toolName: mcpToolName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        case "command":
            return .init(
                type: "command",
                command: commandPath.trimmingCharacters(in: .whitespacesAndNewlines),
                arguments: commandArguments
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty },
                timeoutSeconds: 20
            )
        case "native":
            return .init(type: "native")
        default:
            return nil
        }
    }

    func listGeneratedPluginDraftsCapability() -> CapabilityResult {
        guard !generatedPluginDrafts.isEmpty else {
            return CapabilityResult(
                title: "Plugin Drafts",
                content: "No generated plugin drafts are waiting for review.",
                requiresUserApproval: false
            )
        }

        let summaries = generatedPluginDrafts.map { draft in
            let catalogManifests = catalogManifestsAfterInstalling(draft.manifest)
            let review = PluginPackageReview(package: draft.package, catalogManifests: catalogManifests)
            let functionNamesByCapabilityID = CapabilityToolCatalog.functionNamesByCapabilityID(for: catalogManifests)
            let functions = draft.manifest.capabilities
                .map { functionNamesByCapabilityID[$0.id] ?? CapabilityToolCatalog.functionName(for: $0.id) }
                .joined(separator: ", ")
            let installArguments = """
            {"plugin_id":"\(draft.manifest.id)","draft_id":"\(draft.id.uuidString)","confirmed":true}
            """
            let discardArguments = """
            {"plugin_id":"\(draft.manifest.id)","draft_id":"\(draft.id.uuidString)","confirmed":true}
            """
            return """
            - \(draft.manifest.name) (\(draft.manifest.id))
              draft_id: \(draft.id.uuidString)
              source: \(draft.source)
              risk: \(review.riskLevel.rawValue)
              capabilities: \(review.capabilityCount)
              permissions: \(review.permissionCount)
              callable_functions: \(functions.isEmpty ? "none" : functions)
              install_arguments: \(installArguments)
              discard_arguments: \(discardArguments)
            """
        }

        return CapabilityResult(
            title: "Plugin Drafts",
            content: """
            staged_drafts: \(generatedPluginDrafts.count)
            \(summaries.joined(separator: "\n"))
            """,
            requiresUserApproval: false
        )
    }

    func listInstalledLocalPluginsCapability() -> CapabilityResult {
        let localPlugins = plugins
            .filter { $0.id.hasPrefix("local.") }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        guard !localPlugins.isEmpty else {
            return CapabilityResult(
                title: "Installed Local Plugins",
                content: "No installed local plugins are available to export or remove.",
                requiresUserApproval: false
            )
        }

        let summaries = localPlugins.map { plugin in
            let functionNamesByCapabilityID = installedFunctionNamesByCapabilityID()
            let functions = plugin.capabilities
                .map { functionNamesByCapabilityID[$0.id] ?? CapabilityToolCatalog.functionName(for: $0.id) }
                .joined(separator: ", ")
            let exportArguments = """
            {"plugin_id":"\(plugin.id)","confirmed":true}
            """
            let removeArguments = """
            {"plugin_id":"\(plugin.id)","confirmed":true}
            """
            return """
            - \(plugin.name) (\(plugin.id))
              version: \(plugin.version)
              description: \(plugin.description)
              capabilities: \(plugin.capabilities.count)
              callable_functions: \(functions.isEmpty ? "none" : functions)
              export_arguments: \(exportArguments)
              remove_arguments: \(removeArguments)
            """
        }

        return CapabilityResult(
            title: "Installed Local Plugins",
            content: """
            local_plugins: \(localPlugins.count)
            \(summaries.joined(separator: "\n"))
            """,
            requiresUserApproval: false
        )
    }

    func inspectInstalledLocalPluginCapability(arguments: [String: Any]) -> CapabilityResult {
        let pluginID = stringArgument(arguments, keys: ["plugin_id", "pluginID"], fallback: "")
        guard !pluginID.isEmpty else {
            return CapabilityResult(
                title: "Plugin Inspect Failed",
                content: "plugin_id is required.",
                requiresUserApproval: false
            )
        }

        do {
            let package = try pluginRegistry.package(pluginID: pluginID)
            let catalogManifests = catalogManifestsAfterInstalling(package.manifest)
            let review = PluginPackageReview(package: package, catalogManifests: catalogManifests)
            let functionNamesByCapabilityID = CapabilityToolCatalog.functionNamesByCapabilityID(for: catalogManifests)
            let capabilityLines = package.manifest.capabilities.map { capability in
                let functionName = functionNamesByCapabilityID[capability.id] ?? CapabilityToolCatalog.functionName(for: capability.id)
                let adapter = capability.adapter?.type ?? capability.kind
                let approval = capability.requiresApproval ? "approval_required" : "no_approval"
                let fields = CapabilityInputSchema.fields(for: capability)
                    .map(\.name)
                    .joined(separator: ", ")
                return "- \(capability.id) -> \(functionName) [kind=\(capability.kind), adapter=\(adapter), \(approval), fields=\(fields.isEmpty ? "none" : fields)]"
            }
            let permissionLines = review.permissionSummaries.map { permission in
                "- \(permission.title): \(permission.detail) [\(permission.requiresApproval ? "approval_required" : "no_approval")]"
            }
            let fileLines = review.fileSummaries.map { file in
                "- \(file.path) (\(file.lineCount) line(s), \(file.byteCount) byte(s))"
            }
            let exportArguments = """
            {"plugin_id":"\(package.manifest.id)","confirmed":true}
            """
            let removeArguments = """
            {"plugin_id":"\(package.manifest.id)","confirmed":true}
            """

            return CapabilityResult(
                title: "Plugin Inspection",
                content: """
                plugin_id: \(package.manifest.id)
                name: \(package.manifest.name)
                version: \(package.manifest.version)
                description: \(package.manifest.description)
                author: \(package.manifest.author ?? "unspecified")
                risk: \(review.riskLevel.rawValue)
                capabilities: \(review.capabilityCount)
                permissions: \(review.permissionCount)
                files: \(review.fileCount)

                capability_functions:
                \(capabilityLines.isEmpty ? "(none)" : capabilityLines.joined(separator: "\n"))

                permissions_summary:
                \(permissionLines.isEmpty ? "(none)" : permissionLines.joined(separator: "\n"))

                package_files:
                \(fileLines.isEmpty ? "(none)" : fileLines.joined(separator: "\n"))

                export_arguments: \(exportArguments)
                remove_arguments: \(removeArguments)
                """,
                requiresUserApproval: false
            )
        } catch {
            return CapabilityResult(
                title: "Plugin Inspect Failed",
                content: error.localizedDescription,
                requiresUserApproval: false
            )
        }
    }

    func readInstalledLocalPluginFileCapability(arguments: [String: Any]) -> CapabilityResult {
        let pluginID = stringArgument(arguments, keys: ["plugin_id", "pluginID"], fallback: "")
        let path = stringArgument(arguments, keys: ["path", "file_path", "file"], fallback: "")
        guard !pluginID.isEmpty else {
            return CapabilityResult(
                title: "Plugin File Read Failed",
                content: "plugin_id is required.",
                requiresUserApproval: false
            )
        }
        guard !path.isEmpty else {
            return CapabilityResult(
                title: "Plugin File Read Failed",
                content: "path is required.",
                requiresUserApproval: false
            )
        }
        guard pluginID.hasPrefix("local.") else {
            return CapabilityResult(
                title: "Plugin File Read Failed",
                content: "Only installed local plugins can be read through plugin.readFile.",
                requiresUserApproval: false
            )
        }

        let maxCharacters = min(max(integerArgument(
            arguments,
            keys: ["max_characters", "max_chars", "maxCharacters"],
            fallback: 20_000
        ), 1), 80_000)

        do {
            let text = try pluginRegistry.readPluginFile(pluginID: pluginID, path: path)
            let truncated = text.count > maxCharacters
            let prefix = String(text.prefix(maxCharacters))
            return CapabilityResult(
                title: "Plugin File Read",
                content: """
                plugin_id: \(pluginID)
                path: \(path)
                characters_returned: \(prefix.count)
                total_characters: \(text.count)
                truncated: \(truncated)

                \(prefix)
                """,
                requiresUserApproval: false
            )
        } catch {
            return CapabilityResult(
                title: "Plugin File Read Failed",
                content: error.localizedDescription,
                requiresUserApproval: false
            )
        }
    }

    @discardableResult
    func captureGeneratedPluginDraft(
        from result: CapabilityResult,
        source: String,
        installImmediately: Bool = false,
        postToConversation: Bool = true
    ) -> PluginDraftCapture? {
        guard result.title == "Plugin Package Draft",
              let data = result.content.data(using: .utf8),
              let package = try? JSONDecoder().decode(PluginPackage.self, from: data) else {
            return nil
        }
        let documented = PluginPackageReviewDocumenter().documented(package)
        let draft = stageGeneratedPluginPackage(documented, source: source)
        var content = pluginDraftReviewContent(
            title: "Plugin Package Draft",
            draft: draft,
            summary: "Staged \(documented.manifest.name) (\(documented.manifest.id)) for review."
        )
        var queuedInstallApproval = false
        var queuedApprovalID: UUID?
        if installImmediately {
            let approval = enqueueInstallDraftApproval(for: draft)
            queuedInstallApproval = true
            queuedApprovalID = approval.id
            content += installDraftApprovalQueuedContent(approval: approval, draft: draft)
        }
        // Background jobs keep the draft in the review queue without
        // injecting a card into whatever conversation is focused.
        if postToConversation {
            messages.append(ChatMessage(role: .tool, content: content, approvalID: queuedApprovalID))
        }
        return PluginDraftCapture(content: content, queuedInstallApproval: queuedInstallApproval)
    }

    func installDraftApprovalQueuedContent(
        approval: PendingApproval,
        draft: GeneratedPluginDraft
    ) -> String {
        """


        Install requested:
        - Queued plugin.installDraft approval_id: \(approval.id.uuidString)
        - Approve it to install \(draft.manifest.name) and refresh the tool catalog for the next model step.
        """
    }

    func enqueueInstallDraftApproval(for draft: GeneratedPluginDraft) -> PendingApproval {
        let invocation = CapabilityInvocation(
            toolCallID: "install-draft-\(draft.id.uuidString)",
            functionName: CapabilityToolCatalog.functionName(for: "plugin.installDraft"),
            capabilityID: "plugin.installDraft",
            arguments: [
                "plugin_id": draft.manifest.id,
                "draft_id": draft.id.uuidString,
                "confirmed": true
            ]
        )
        return enqueueApproval(for: invocation).approval
    }

    func captureInstalledPluginIfNeeded(
        invocation: CapabilityInvocation,
        result: CapabilityResult,
        approved: Bool
    ) {
        guard invocation.capabilityID == "plugin.install",
              result.title == "Plugin Installed" || result.title == "Plugin Updated",
              let package = pluginPackageArgument(from: invocation.arguments) else {
            return
        }

        let documented = PluginPackageReviewDocumenter().documented(package)
        let removedDrafts = generatedPluginDrafts.filter { $0.manifest.id == documented.manifest.id }
        removedDrafts.forEach { try? pluginDraftStore.delete($0) }
        generatedPluginDrafts.removeAll { $0.manifest.id == documented.manifest.id }
        auditPluginEvent(
            type: result.title == "Plugin Updated" ? "plugin.updated" : "plugin.installed",
            package: documented,
            summary: result.title == "Plugin Updated"
                ? "Updated plugin through plugin.install capability."
                : "Installed plugin through plugin.install capability.",
            metadata: [
                "source": "plugin.install capability",
                "capabilityID": invocation.capabilityID,
                "functionName": invocation.functionName,
                "toolCallID": invocation.toolCallID,
                "approved": String(approved),
                "removedDrafts": String(removedDrafts.count)
            ]
        )
        rebuildRunningTasks()
        focusInstalledPlugin(documented.manifest.id)
        prepareInstalledCapabilityRun(for: documented.manifest)
        // A webapp-kind plugin ships a runnable app; materialize it now.
        materializePluginWebApp(package: documented)
    }

    func focusInstalledPlugin(_ pluginID: String) {
        highlightedPluginID = pluginID
        selectedSection = .tools
    }

    func prepareInstalledCapabilityRun(for manifest: PluginManifest) {
        guard manifest.capabilities.count == 1, let capability = manifest.capabilities.first else {
            pendingCapabilityRunTarget = nil
            return
        }
        pendingCapabilityRunTarget = CapabilityRunTarget(pluginName: manifest.name, capability: capability)
    }

    func pluginPackageArgument(from arguments: [String: Any]) -> PluginPackage? {
        let decoder = JSONDecoder()
        if let raw = arguments["package_json"] as? String,
           let data = raw.data(using: .utf8),
           let package = try? decoder.decode(PluginPackage.self, from: data) {
            return package
        }
        if let raw = arguments["manifest_json"] as? String,
           let data = raw.data(using: .utf8),
           let manifest = try? decoder.decode(PluginManifest.self, from: data) {
            return PluginPackage(manifest: manifest, files: [])
        }
        return nil
    }

    func captureRemovedPluginIfNeeded(
        invocation: CapabilityInvocation,
        result: CapabilityResult,
        approved: Bool
    ) {
        guard invocation.capabilityID == "plugin.remove",
              result.title == "Plugin Removed" else {
            return
        }
        let pluginID = stringArgument(invocation.arguments, keys: ["plugin_id"], fallback: "")
        guard !pluginID.isEmpty else { return }
        let manifest = plugins.first { $0.id == pluginID }
        pendingApprovals.removeAll { $0.invocation.capabilityID.hasPrefix(pluginID + ".") }
        if highlightedPluginID == pluginID {
            highlightedPluginID = nil
        }
        audit(
            type: "plugin.removed",
            summary: "Removed local plugin \(manifest?.name ?? pluginID) through plugin.remove capability.",
            metadata: [
                "pluginID": pluginID,
                "pluginName": manifest?.name ?? pluginID,
                "capabilityCount": String(manifest?.capabilities.count ?? 0),
                "source": "plugin.remove capability",
                "functionName": invocation.functionName,
                "toolCallID": invocation.toolCallID,
                "approved": String(approved)
            ]
        )
        if let manifest {
            recordPluginLifecycleEvent(
                action: .removed,
                manifest: manifest,
                fileCount: 0,
                source: "plugin.remove capability",
                summary: "Removed local plugin \(manifest.name) through plugin.remove capability.",
                metadata: [
                    "functionName": invocation.functionName,
                    "toolCallID": invocation.toolCallID,
                    "approved": String(approved)
                ]
            )
        }
        rebuildRunningTasks()
    }

    func pluginInstalledContent(
        package: PluginPackage,
        source: String,
        title: String = "Plugin Installed",
        verb: String = "Installed"
    ) -> String {
        PluginInstallSummaryFormatter().content(
            package: package,
            source: source,
            title: title,
            verb: verb,
            catalogManifests: catalogManifestsAfterInstalling(package.manifest)
        )
    }

    func pluginDraftReviewContent(
        title: String,
        draft: GeneratedPluginDraft,
        summary: String
    ) -> String {
        let catalogManifests = catalogManifestsAfterInstalling(draft.manifest)
        let review = PluginPackageReview(package: draft.package, catalogManifests: catalogManifests)
        let functionNamesByCapabilityID = CapabilityToolCatalog.functionNamesByCapabilityID(for: catalogManifests)
        let functions = draft.manifest.capabilities
            .map { functionNamesByCapabilityID[$0.id] ?? CapabilityToolCatalog.functionName(for: $0.id) }
            .joined(separator: ", ")
        let installArguments = """
        {"plugin_id":"\(draft.manifest.id)","draft_id":"\(draft.id.uuidString)","confirmed":true}
        """
        let discardArguments = """
        {"plugin_id":"\(draft.manifest.id)","draft_id":"\(draft.id.uuidString)","confirmed":true}
        """

        return """
        \(title)
        \(summary)
        draft_id: \(draft.id.uuidString)
        plugin_id: \(draft.manifest.id)
        risk: \(review.riskLevel.rawValue)
        capabilities: \(review.capabilityCount)
        permissions: \(review.permissionCount)
        callable_functions: \(functions.isEmpty ? "none" : functions)

        Next approved actions:
        - Install after user confirmation with plugin.installDraft arguments: \(installArguments)
        - Discard after user confirmation with plugin.discardDraft arguments: \(discardArguments)
        """
    }

    func installedFunctionNamesByCapabilityID() -> [String: String] {
        CapabilityToolCatalog.functionNamesByCapabilityID(for: plugins)
    }

    func catalogManifestsAfterInstalling(_ manifest: PluginManifest) -> [PluginManifest] {
        plugins.filter { $0.id != manifest.id } + [manifest]
    }

    func auditPluginEvent(
        type: String,
        package: PluginPackage,
        summary: String,
        metadata: [String: String] = [:]
    ) {
        var merged = metadata
        merged["pluginID"] = package.manifest.id
        merged["pluginName"] = package.manifest.name
        merged["capabilityCount"] = String(package.manifest.capabilities.count)
        merged["fileCount"] = String(package.files.count)
        audit(type: type, summary: summary, metadata: merged)
        if let action = Self.pluginLifecycleAction(for: type) {
            recordPluginLifecycleEvent(
                action: action,
                package: package,
                source: metadata["source"] ?? "unknown",
                summary: summary,
                metadata: metadata
            )
        }
    }

    func recordPluginLifecycleEvent(
        action: PluginLifecycleAction,
        package: PluginPackage,
        source: String,
        summary: String,
        metadata: [String: String] = [:]
    ) {
        recordPluginLifecycleEvent(
            action: action,
            manifest: package.manifest,
            fileCount: package.files.count,
            source: source,
            summary: summary,
            metadata: metadata
        )
    }

    func recordPluginLifecycleEvent(
        action: PluginLifecycleAction,
        manifest: PluginManifest,
        fileCount: Int,
        source: String,
        summary: String,
        metadata: [String: String] = [:]
    ) {
        do {
            let event = PluginLifecycleEvent(
                action: action,
                pluginID: manifest.id,
                pluginName: manifest.name,
                version: manifest.version,
                source: source,
                summary: summary,
                capabilityCount: manifest.capabilities.count,
                fileCount: fileCount,
                metadata: metadata
            )
            try pluginEventStore.append(event)
            pluginEvents = Self.recentPluginEvents(from: pluginEvents + [event])
        } catch {
            lastError = "Could not write plugin lifecycle log: \(error.localizedDescription)"
        }
    }

    static func pluginLifecycleAction(for auditType: String) -> PluginLifecycleAction? {
        switch auditType {
        case "plugin.draft_staged": return .staged
        case "plugin.installed": return .installed
        case "plugin.updated": return .updated
        case "plugin.draft_discarded": return .discarded
        case "plugin.exported": return .exported
        case "plugin.install_failed": return .installFailed
        case "plugin.remove_failed": return .removeFailed
        case "plugin.export_failed": return .exportFailed
        case "plugin.package_import_failed": return .importFailed
        default: return nil
        }
    }
}

private enum PluginImportError: LocalizedError {
    case emptySkillFile(String)

    var errorDescription: String? {
        switch self {
        case .emptySkillFile(let fileName):
            return "\(fileName.isEmpty ? "Skill file" : fileName) is empty."
        }
    }
}

struct PluginDraftCapture {
    var content: String
    var queuedInstallApproval: Bool
}

struct AIGeneratedPluginPackage {
    var package: PluginPackage
    var repaired: Bool
}

struct AIPluginGenerationRepairError: LocalizedError {
    var initialError: String
    var repairError: String

    var errorDescription: String? {
        "Initial plugin package failed validation: \(initialError). Repair attempt also failed: \(repairError)"
    }
}
