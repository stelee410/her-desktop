import Foundation

struct ProductDiagnosticsSnapshotBuilder {
    func build(
        readiness: ProductReadinessSummary,
        config: HerAppConfig,
        serviceHealth: [ServiceHealth],
        plugins: [PluginManifest],
        localInboxBridgeState: LocalInboxBridgeState,
        pendingApprovals: [PendingApproval],
        generatedDrafts: [GeneratedPluginDraft],
        workPlan: WorkPlan?,
        dreamContext: DreamPromptContext?,
        agentProfile: AgentProfile,
        memorySignal: MemorySignal,
        runtime: PromptRuntimeContext,
        sessionID: String
    ) -> String {
        let requiredStatus = readiness.isReadyForCoreWork ? "ready" : "attention"
        return """
        product_readiness: \(readiness.title) (\(readiness.score), \(requiredStatus))
        detail: \(readiness.detail)

        configuration:
        - agentllm_base_url: \(config.agentLLMBaseURL.absoluteString)
        - agentllm_key_configured: \(config.hasLLMKey)
        - agentllm_model: \(config.agentLLMModel)
        - agentmem_base_url: \(config.agentMemBaseURL.absoluteString)
        - agentmem_memory_key_configured: \(config.hasMemKey)
        - local_agent_label: \(emptyLabel(config.agentCode))
        - local_user_label: \(emptyLabel(config.userID))

        runtime_paths:
        - cwd: \(runtime.cwd)
        - session_id: \(sessionID)
        - session_file: \(runtime.sessionPath)
        - local_state: \(runtime.localAgentDirectory)
        - plugin_directory: \(runtime.pluginDirectory)
        - workspace_artifacts: \(runtime.workspaceDirectory)
        - time: \(runtime.localTime) \(runtime.timeZone)

        readiness_items:
        \(readinessLines(readiness.items))

        service_health:
        \(serviceLines(serviceHealth))

        plugin_runtime:
        - plugins: \(plugins.count)
        - capabilities: \(plugins.flatMap(\.capabilities).count)
        - builtins: \(plugins.filter { $0.id.hasPrefix("builtin.") }.count)
        - local_plugins: \(plugins.filter { $0.id.hasPrefix("local.") }.count)
        \(pluginLines(plugins))

        active_state:
        - pending_approvals: \(pendingApprovals.count)
        - generated_plugin_drafts: \(generatedDrafts.count)
        - inbox_bridge: \(localInboxBridgeState.status.rawValue) · \(localInboxBridgeState.summary)
        - work_plan: \(workPlan?.stateSummary ?? "none")
        - reflection_snapshot: \(dreamContext == nil ? "none" : "active")
        - agent_profile: \(agentProfile.known ? "known" : "local") · \(agentProfile.relationship)
        - memory_signal: \(memorySignal.relationshipSummary) · mood \(memorySignal.moodLabel)

        suggested_actions:
        \(suggestedActionLines(readiness.suggestedActions(limit: 5)))

        secret_policy: API keys and Memory keys are intentionally reported only as configured/not configured.
        """
    }

    private func readinessLines(_ items: [ProductReadinessItem]) -> String {
        guard !items.isEmpty else { return "- none" }
        return items.map { item in
            let required = item.required ? "required" : "optional"
            return "- \(item.id): \(item.level.rawValue) [\(required)] · \(item.detail)"
        }
        .joined(separator: "\n")
    }

    private func serviceLines(_ health: [ServiceHealth]) -> String {
        guard !health.isEmpty else { return "- none recorded" }
        return health.sorted { $0.id < $1.id }.map { service in
            "- \(service.id): \(service.state.rawValue) · \(service.summary)"
        }
        .joined(separator: "\n")
    }

    private func pluginLines(_ plugins: [PluginManifest]) -> String {
        guard !plugins.isEmpty else { return "- installed_plugins: none" }
        return plugins.sorted { $0.id < $1.id }.map { plugin in
            "- \(plugin.id): \(plugin.name) · \(plugin.capabilities.count) capability/capabilities"
        }
        .joined(separator: "\n")
    }

    private func suggestedActionLines(_ items: [ProductReadinessItem]) -> String {
        guard !items.isEmpty else { return "- none" }
        return items.map { item in
            "- \(item.id): \(item.actionTitle ?? "Open") · \(item.detail)"
        }
        .joined(separator: "\n")
    }

    private func emptyLabel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(unset)" : trimmed
    }
}
