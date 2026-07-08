import AppKit
import Foundation
import SwiftUI

/// Capability execution, approvals, and activity tracking.
extension AppViewModel {
    func runCapability(_ capability: PluginManifest.Capability, request: String) async {
        await runCapability(capabilityID: capability.id, request: request)
    }

    func runCapability(capabilityID: String, request: String) async {
        let cleanRequest = request.trimmingCharacters(in: .whitespacesAndNewlines)
        await runCapability(
            capabilityID: capabilityID,
            arguments: cleanRequest.isEmpty ? [:] : ["request": cleanRequest],
            requestCharacters: cleanRequest.count
        )
    }

    func runCapability(_ capability: PluginManifest.Capability, arguments: [String: Any]) async {
        await runCapability(capabilityID: capability.id, arguments: arguments)
    }

    func runCapability(capabilityID: String, arguments: [String: Any]) async {
        await runCapability(capabilityID: capabilityID, arguments: arguments, requestCharacters: argumentCharacterCount(arguments))
    }

    func runCapability(capabilityID: String, arguments: [String: Any], requestCharacters: Int) async {
        guard pluginRegistry.capability(id: capabilityID, in: plugins) != nil else {
            let message = "Capability \(capabilityID) is not installed."
            lastError = message
            messages.append(ChatMessage(role: .tool, content: "Capability Missing\n\(message)"))
            saveSessionSnapshot()
            return
        }

        recordInteractionEvent(interactionEventBus.event(
            surface: .pluginLibrary,
            kind: .manualCapabilityRequested,
            summary: "Manual capability run requested.",
            payload: [
                "capabilityID": capabilityID,
                "requestCharacters": String(requestCharacters)
            ]
        ))
        let invocation = CapabilityInvocation(
            toolCallID: "manual-\(UUID().uuidString)",
            functionName: CapabilityToolCatalog.functionName(for: capabilityID),
            capabilityID: capabilityID,
            arguments: arguments
        )

        if requiresApproval(for: invocation) {
            let (approval, isNew) = enqueueApproval(for: invocation)
            if isNew {
                messages.append(ChatMessage(
                    role: .tool,
                    content: "Approval Required\n\(approval.title)\n\(approval.detail)",
                    approvalID: approval.id
                ))
            } else {
                messages.append(ChatMessage(
                    role: .tool,
                    content: "这个操作已经在等待批准了，直接在对话里的审批卡片上点「批准」或「拒绝」即可。"
                ))
            }
            saveSessionSnapshot()
            return
        }

        connectionState = .working
        lastError = nil
        let activityID = beginCapabilityActivity(
            invocation: invocation,
            status: .running,
            summary: "Manual run from Plugin Library."
        )
        _ = await runInvocation(invocation, activityID: activityID, approved: false)
        saveSessionSnapshot()
        await reloadPlugins()
        connectionState = .ready
    }

    func argumentCharacterCount(_ arguments: [String: Any]) -> Int {
        arguments.values.reduce(0) { partial, value in
            partial + String(describing: value).count
        }
    }

    /// What runInvocation hands back. (Named to stay clearly apart from
    /// `CapabilityOutcome`, the ok/failed enum inside CapabilityResult.)
    struct InvocationOutcome {
        var result: CapabilityResult
        var pluginDraft: PluginDraftCapture?
    }

    /// The single post-execution pipeline every capability run goes through:
    /// execute → finish activity → refresh artifacts → capture inbox event /
    /// plugin draft / installed / removed plugin → tool message → audit →
    /// persist memory. This sequence used to be copy-pasted (and had already
    /// diverged: the approval path silently dropped generated plugin drafts).
    /// Keep it in one place so the three entry points cannot drift again.
    func runInvocation(
        _ invocation: CapabilityInvocation,
        activityID: UUID,
        approved: Bool,
        postToConversation: Bool = true
    ) async -> InvocationOutcome {
        let result = await executeCapabilityInvocation(invocation)
        finishCapabilityActivity(activityID, result: result)
        refreshWebServiceArtifacts()
        captureExternalInboxEventIfNeeded(invocation: invocation, result: result)
        let pluginDraft = captureGeneratedPluginDraft(
            from: result,
            source: invocation.functionName,
            installImmediately: boolArgument(
                invocation.arguments,
                keys: ["install_immediately", "installImmediately"],
                fallback: false
            ),
            postToConversation: postToConversation
        )
        captureInstalledPluginIfNeeded(invocation: invocation, result: result, approved: approved)
        captureRemovedPluginIfNeeded(invocation: invocation, result: result, approved: approved)
        // Background jobs keep tool chatter in their own log; only the job's
        // final result card reaches the conversation.
        if pluginDraft == nil, postToConversation {
            messages.append(ChatMessage(role: .tool, content: "\(result.title)\n\(result.content)"))
        }
        auditCapabilityExecution(invocation: invocation, result: result, approved: approved)
        let boundMemoryClient = memoryClient(forConversation: activeConversationID)
        Task {
            let memoryResult = pluginDraft.map {
                CapabilityResult(
                    title: "Plugin Package Draft",
                    content: $0.content,
                    requiresUserApproval: $0.queuedInstallApproval
                )
            } ?? result
            await persistCapabilityMemory(
                invocation: invocation,
                result: memoryResult,
                approved: approved,
                boundMemoryClient: boundMemoryClient
            )
        }
        return InvocationOutcome(result: result, pluginDraft: pluginDraft)
    }

    /// The key "一直批准" stores and checks. Scoped to the risk boundary, not
    /// the bare capability ID: `shell.run` spans mkdir…rm…curl, so approving
    /// one benign command must never silently approve every later one — the
    /// executed command name is part of the identity.
    static func autoApprovalKey(capabilityID: String, arguments: [String: Any]) -> String {
        guard capabilityID == CapabilityID.shellRun else { return capabilityID }
        let command = (arguments["command"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return command.isEmpty ? capabilityID : "\(capabilityID):\(command)"
    }

    /// Approve this action and auto-approve the same action signature for the
    /// rest of the conversation.
    func approveAlways(_ approval: PendingApproval) async {
        let key = Self.autoApprovalKey(
            capabilityID: approval.invocation.capabilityID,
            arguments: approval.invocation.arguments
        )
        autoApprovedCapabilities.insert(key)
        audit(
            type: "approval.auto_approved_capability",
            summary: "Auto-approving this capability for the conversation.",
            metadata: ["capabilityID": approval.invocation.capabilityID, "signature": key]
        )
        await approve(approval)
    }

    func approve(_ approval: PendingApproval) async {
        pendingApprovals.removeAll { $0.id == approval.id }
        recordInteractionEvent(interactionEventBus.event(
            surface: .approval,
            kind: .approvalApproved,
            summary: "Approved capability execution.",
            payload: [
                "approvalID": approval.id.uuidString,
                "capabilityID": approval.invocation.capabilityID,
                "functionName": approval.invocation.functionName
            ]
        ))
        connectionState = .working
        lastError = nil
        let activityID = approval.activityID ?? beginCapabilityActivity(
            invocation: approval.invocation,
            status: .running,
            summary: "Approved by user; executing now."
        )
        updateCapabilityActivity(
            activityID,
            status: .running,
            summary: "Approved by user; executing now."
        )
        rebuildRunningTasks()
        // Shared pipeline (also captures generated plugin drafts — the old
        // hand-rolled copy here silently dropped them).
        let outcome = await runInvocation(approval.invocation, activityID: activityID, approved: true)
        audit(
            type: "approval.approved",
            summary: "User approved capability execution.",
            metadata: [
                "approvalID": approval.id.uuidString,
                "capabilityID": approval.invocation.capabilityID,
                "functionName": approval.invocation.functionName
            ]
        )
        saveSessionSnapshot()
        await reloadPlugins()
        await synthesizeApprovedCapabilityResult(approval: approval, result: outcome.result)
        connectionState = .ready
    }

    func reject(_ approval: PendingApproval) {
        pendingApprovals.removeAll { $0.id == approval.id }
        recordInteractionEvent(interactionEventBus.event(
            surface: .approval,
            kind: .approvalRejected,
            summary: "Rejected capability execution.",
            payload: [
                "approvalID": approval.id.uuidString,
                "capabilityID": approval.invocation.capabilityID,
                "functionName": approval.invocation.functionName
            ]
        ))
        messages.append(ChatMessage(role: .tool, content: "Rejected\n\(approval.title) was not executed."))
        if let activityID = approval.activityID {
            updateCapabilityActivity(
                activityID,
                status: .denied,
                summary: "User rejected this capability. Nothing was executed."
            )
        }
        rebuildRunningTasks()
        audit(
            type: "approval.rejected",
            summary: "User rejected capability execution.",
            metadata: [
                "approvalID": approval.id.uuidString,
                "capabilityID": approval.invocation.capabilityID,
                "functionName": approval.invocation.functionName
            ]
        )
        saveSessionSnapshot()
    }

    /// Single dispatch point for app-state capabilities. One registry
    /// replaces the old 30-branch if-chain that had to be kept in sync by
    /// hand with a parallel switch in CapabilityExecutor — the classic
    /// "edited one, forgot the other" split-brain. Anything not registered
    /// here routes to the stateless adapter executor.
    func executeCapabilityInvocation(_ invocation: CapabilityInvocation) async -> CapabilityResult {
        if let handler = Self.appCapabilityHandlers[invocation.capabilityID] {
            return await handler(self, invocation)
        }
        // Installed plugins with a webapp adapter open their materialized app
        // (needs app state: web app store + workspace navigation).
        if let capability = pluginRegistry.capability(id: invocation.capabilityID, in: plugins),
           (capability.adapter?.type ?? capability.kind) == "webapp" {
            return openPluginWebAppCapability(capability: capability)
        }
        return await capabilityExecutor.execute(invocation)
    }

    /// Handlers for capabilities that need live app state (registry, drafts,
    /// webapp runtime, terminal, browser). Keyed by CapabilityID constants so
    /// a typo is a compile error, not a silent mis-route. Static + explicit
    /// `model` parameter: no closure captures, no retain cycles.
    private static let appCapabilityHandlers: [String: @MainActor (AppViewModel, CapabilityInvocation) async -> CapabilityResult] = [
        CapabilityID.reflectionSnapshot: { model, invocation in
            let focus = model.stringArgument(
                invocation.arguments,
                keys: ["focus", "request", "summary"],
                fallback: ""
            )
            return model.saveReflectionSnapshot(focus: focus)
        },
        CapabilityID.workspacePlan: { model, invocation in
            model.saveWorkPlan(arguments: invocation.arguments, source: invocation.functionName)
        },
        CapabilityID.productDiagnostics: { model, _ in
            model.productDiagnosticsCapability()
        },
        CapabilityID.productExportDiagnostics: { model, invocation in
            model.exportProductDiagnosticsCapability(arguments: invocation.arguments)
        },
        CapabilityID.pluginListDrafts: { model, _ in
            model.listGeneratedPluginDraftsCapability()
        },
        CapabilityID.pluginListInstalled: { model, _ in
            model.listInstalledLocalPluginsCapability()
        },
        CapabilityID.pluginInspect: { model, invocation in
            model.inspectInstalledLocalPluginCapability(arguments: invocation.arguments)
        },
        CapabilityID.pluginReadFile: { model, invocation in
            model.readInstalledLocalPluginFileCapability(arguments: invocation.arguments)
        },
        CapabilityID.pluginStagePackage: { model, invocation in
            model.stagePluginPackageCapability(arguments: invocation.arguments)
        },
        CapabilityID.pluginInstallDraft: { model, invocation in
            await model.installGeneratedPluginDraftCapability(arguments: invocation.arguments)
        },
        CapabilityID.pluginDiscardDraft: { model, invocation in
            model.discardGeneratedPluginDraftCapability(arguments: invocation.arguments)
        },
        CapabilityID.pluginExport: { model, invocation in
            model.exportPluginCapability(arguments: invocation.arguments)
        },
        CapabilityID.webappCreate: { model, invocation in
            model.createWebAppCapability(arguments: invocation.arguments)
        },
        CapabilityID.webappUpdate: { model, invocation in
            model.updateWebAppCapability(arguments: invocation.arguments)
        },
        CapabilityID.webappList: { model, _ in
            model.listWebAppsCapability()
        },
        CapabilityID.webappOpen: { model, invocation in
            model.openWebAppCapability(arguments: invocation.arguments)
        },
        CapabilityID.webappRemove: { model, invocation in
            model.removeWebAppCapability(arguments: invocation.arguments)
        },
        CapabilityID.webappQuery: { model, invocation in
            model.queryWebAppCapability(arguments: invocation.arguments)
        },
        CapabilityID.webappExecute: { model, invocation in
            model.executeWebAppSQLCapability(arguments: invocation.arguments)
        },
        CapabilityID.webappInspect: { model, invocation in
            model.inspectWebAppCapability(arguments: invocation.arguments)
        },
        CapabilityID.webappRequest: { model, invocation in
            await model.requestWebAppBackendCapability(arguments: invocation.arguments)
        },
        CapabilityID.scheduleCreate: { model, invocation in
            model.createScheduledTaskCapability(arguments: invocation.arguments)
        },
        CapabilityID.scheduleList: { model, _ in
            model.listScheduledTasksCapability()
        },
        CapabilityID.scheduleCancel: { model, invocation in
            model.cancelScheduledTaskCapability(arguments: invocation.arguments)
        },
        CapabilityID.terminalOpen: { model, _ in
            model.openTerminalCapability()
        },
        CapabilityID.terminalRead: { model, _ in
            model.readTerminalCapability()
        },
        CapabilityID.terminalSend: { model, invocation in
            await model.sendTerminalCapability(arguments: invocation.arguments)
        },
        CapabilityID.browserOpen: { model, _ in
            await model.openBrowserCapability()
        },
        CapabilityID.browserNavigate: { model, invocation in
            await model.navigateBrowserCapability(arguments: invocation.arguments)
        },
        CapabilityID.browserRead: { model, _ in
            await model.readBrowserCapability()
        },
        CapabilityID.browserClick: { model, invocation in
            await model.clickBrowserCapability(arguments: invocation.arguments)
        },
        CapabilityID.browserType: { model, invocation in
            await model.typeBrowserCapability(arguments: invocation.arguments)
        },
        CapabilityID.browserDetect: { model, _ in
            await model.detectBrowserCapability()
        }
    ]

    func activeTaskSummary() -> String {
        ActiveWorkSummaryBuilder().build(
            tasks: runningTasks,
            activities: capabilityActivities,
            events: interactionEvents,
            generatedDrafts: generatedPluginDrafts,
            installedPlugins: plugins,
            workPlan: workPlan
        )
    }

    func agentLoopSummary() -> String {
        AgentLoopSummaryBuilder()
            .build(
                events: interactionEvents,
                activities: capabilityActivities,
                pendingApprovals: pendingApprovals,
                generatedDrafts: generatedPluginDrafts,
                workPlan: workPlan,
                connectionState: connectionState
            )
            .map { step in
                "- \(step.phase.rawValue): \(step.status) - \(step.detail)"
            }
            .joined(separator: "\n")
    }

    func parseArguments(_ raw: String) -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    /// Argument-aware gate — the one real executions go through.
    func requiresApproval(for invocation: CapabilityInvocation) -> Bool {
        // The user chose to auto-approve this action signature for the
        // conversation (for shell.run that includes the command name).
        let key = Self.autoApprovalKey(
            capabilityID: invocation.capabilityID,
            arguments: invocation.arguments
        )
        if autoApprovedCapabilities.contains(key) {
            return false
        }
        return requiresApprovalIgnoringAutoApprovals(capabilityID: invocation.capabilityID)
    }

    /// Argument-free shape for capability-level checks (settings UI, tests).
    func requiresApproval(capabilityID: String) -> Bool {
        if autoApprovedCapabilities.contains(capabilityID) {
            return false
        }
        return requiresApprovalIgnoringAutoApprovals(capabilityID: capabilityID)
    }

    private func requiresApprovalIgnoringAutoApprovals(capabilityID: String) -> Bool {
        // A user-granted browsing session lets the agent act without a click
        // per step. The manifest stays approval-required (the safe default);
        // only an explicit, user-flipped session relaxes browser actions.
        if browserAutonomyGranted,
           [CapabilityID.browserNavigate, CapabilityID.browserClick, CapabilityID.browserType]
               .contains(capabilityID) {
            return false
        }
        return pluginRegistry.capability(id: capabilityID, in: plugins)?.requiresApproval ?? true
    }

    @discardableResult
    /// Enqueues an approval, or returns the matching pending one so repeated
    /// tool calls for the same action cannot pile up duplicate requests.
    func enqueueApproval(for invocation: CapabilityInvocation) -> (approval: PendingApproval, isNew: Bool) {
        let capability = pluginRegistry.capability(id: invocation.capabilityID, in: plugins)
        let title = capability?.title ?? invocation.capabilityID
        let detail = approvalDetail(for: invocation)
        if let existing = pendingApprovals.first(where: {
            $0.invocation.capabilityID == invocation.capabilityID && $0.detail == detail
        }) {
            return (existing, false)
        }
        let activityID = beginCapabilityActivity(
            invocation: invocation,
            status: .pending,
            summary: "Waiting for user approval before execution."
        )
        let approval = PendingApproval(title: title, detail: detail, invocation: invocation, activityID: activityID)
        pendingApprovals.append(approval)
        rebuildRunningTasks()
        audit(
            type: "approval.requested",
            summary: "Capability execution requires user approval.",
            metadata: [
                "approvalID": approval.id.uuidString,
                "capabilityID": invocation.capabilityID,
                "functionName": invocation.functionName
            ]
        )
        return (approval, true)
    }

    @discardableResult
    func beginCapabilityActivity(
        invocation: CapabilityInvocation,
        status: CapabilityActivityStatus,
        summary: String
    ) -> UUID {
        let capability = pluginRegistry.capability(id: invocation.capabilityID, in: plugins)
        let activity = CapabilityActivity(
            capabilityID: invocation.capabilityID,
            functionName: invocation.functionName,
            title: capability?.title ?? invocation.capabilityID,
            status: status,
            summary: summary
        )
        capabilityActivities.insert(activity, at: 0)
        capabilityActivities = Array(capabilityActivities.prefix(20))
        rebuildRunningTasks()
        audit(
            type: "capability.activity_\(status.rawValue)",
            summary: summary,
            metadata: [
                "activityID": activity.id.uuidString,
                "capabilityID": invocation.capabilityID,
                "functionName": invocation.functionName
            ]
        )
        return activity.id
    }

    func updateCapabilityActivity(
        _ id: UUID,
        status: CapabilityActivityStatus,
        summary: String
    ) {
        guard let index = capabilityActivities.firstIndex(where: { $0.id == id }) else { return }
        capabilityActivities[index].status = status
        capabilityActivities[index].summary = summary
        capabilityActivities[index].updatedAt = Date()
        rebuildRunningTasks()
        audit(
            type: "capability.activity_\(status.rawValue)",
            summary: summary,
            metadata: [
                "activityID": id.uuidString,
                "capabilityID": capabilityActivities[index].capabilityID,
                "functionName": capabilityActivities[index].functionName
            ]
        )
    }

    func finishCapabilityActivity(_ id: UUID, result: CapabilityResult) {
        let failed: Bool
        if let outcome = result.outcome {
            // Explicit semantics from the executor — the reliable path.
            switch outcome {
            case .ok: failed = false
            case .failed, .needsApproval: failed = true
            }
        } else {
            // Legacy fallback for results that don't set `outcome` yet: guess
            // from the title. Fragile by construction — executors should set
            // outcome explicitly so new failure titles aren't misclassified.
            failed = result.requiresUserApproval
                || result.title.localizedCaseInsensitiveContains("failed")
                || result.title.localizedCaseInsensitiveContains("blocked")
                || result.title.localizedCaseInsensitiveContains("missing")
                || result.title.localizedCaseInsensitiveContains("unsupported")
                || result.title.localizedCaseInsensitiveContains("timed out")
        }
        updateCapabilityActivity(
            id,
            status: failed ? .failed : .done,
            summary: "\(result.title): \(String(result.content.prefix(160)))"
        )
    }

    func approvalDetail(for invocation: CapabilityInvocation) -> String {
        let args = invocation.arguments
            .map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: "\n")
        return args.isEmpty ? "No arguments." : args
    }

    func stringArgument(_ arguments: [String: Any], keys: [String], fallback: String) -> String {
        for key in keys {
            if let value = arguments[key] {
                let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return text
                }
            }
        }
        return fallback
    }

    func boolArgument(_ arguments: [String: Any], keys: [String], fallback: Bool) -> Bool {
        for key in keys {
            guard let value = arguments[key] else { continue }
            if let boolValue = value as? Bool {
                return boolValue
            }
            if let number = value as? NSNumber {
                return number.boolValue
            }
            let text = String(describing: value)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if ["true", "yes", "1", "y"].contains(text) {
                return true
            }
            if ["false", "no", "0", "n"].contains(text) {
                return false
            }
        }
        return fallback
    }

    func integerArgument(_ arguments: [String: Any], keys: [String], fallback: Int) -> Int {
        for key in keys {
            guard let value = arguments[key] else { continue }
            if let intValue = value as? Int {
                return intValue
            }
            if let number = value as? NSNumber {
                return number.intValue
            }
            let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            if let intValue = Int(text) {
                return intValue
            }
        }
        return fallback
    }

    func stringArrayArgument(_ arguments: [String: Any], keys: [String]) -> [String] {
        for key in keys {
            guard let value = arguments[key] else { continue }
            let items: [String]
            if let strings = value as? [String] {
                items = strings
            } else if let array = value as? [Any] {
                items = array.map { String(describing: $0) }
            } else {
                items = String(describing: value)
                    .components(separatedBy: .newlines)
            }
            let cleaned = items
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        return []
    }

    func synthesizeApprovedCapabilityResult(approval: PendingApproval, result: CapabilityResult) async {
        guard config.hasLLMKey else { return }
        connectionState = .thinking
        do {
            let catalog = CapabilityToolCatalog.build(from: plugins)
            let prompt = SystemPromptBuilder(pluginManifests: plugins, projectDocs: projectPromptDocs).build(
                memoryContext: "",
                activeTaskSummary: activeTaskSummary(),
                agentLoopSummary: agentLoopSummary(),
                runtimeContext: PromptRuntimeContext.current(config: config, cwd: runtimeCwd),
                companionContext: companionPromptContext()
            )
            var llmMessages = ApprovedCapabilityFollowUpBuilder(contextBuilder: conversationContextBuilder).build(
                systemPrompt: prompt,
                transcript: messages,
                approval: approval,
                result: result,
                availableToolSummaries: toolCatalogSummaries(from: catalog)
            )
            let content = try await runAgentToolLoop(llmMessages: &llmMessages, catalog: catalog)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                deliverAssistantReply(content)
                saveSessionSnapshot()
                speechTask?.cancel()
                speechTask = Task { await speakAssistantReplyIfEnabled(content) }
            } else {
                discardEmptyStreamedAssistantMessage()
            }
        } catch {
            discardEmptyStreamedAssistantMessage()
            lastError = "The capability ran, but result synthesis failed: \(error.localizedDescription)"
            messages.append(ChatMessage(
                role: .assistant,
                content: "工具已经执行完成，但我生成总结时遇到问题：\(error.localizedDescription)"
            ))
            saveSessionSnapshot()
        }
    }

    func toolCatalogSummaries(from catalog: CapabilityToolCatalog) -> [String] {
        catalog.functionToCapability
            .map { functionName, capabilityID in "\(functionName) -> \(capabilityID)" }
            .sorted()
    }

    func auditCapabilityExecution(
        invocation: CapabilityInvocation,
        result: CapabilityResult,
        approved: Bool
    ) {
        audit(
            type: "capability.executed",
            summary: result.title,
            metadata: [
                "toolCallID": invocation.toolCallID,
                "capabilityID": invocation.capabilityID,
                "functionName": invocation.functionName,
                "approved": String(approved),
                "resultTitle": result.title
            ]
        )
    }
}
