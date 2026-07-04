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

        if requiresApproval(capabilityID: capabilityID) {
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
        let result = await executeCapabilityInvocation(invocation)
        finishCapabilityActivity(activityID, result: result)
        refreshWebServiceArtifacts()
        captureExternalInboxEventIfNeeded(invocation: invocation, result: result)
        let capturedPluginDraft = captureGeneratedPluginDraft(
            from: result,
            source: invocation.functionName,
            installImmediately: boolArgument(arguments, keys: ["install_immediately", "installImmediately"], fallback: false)
        )
        captureInstalledPluginIfNeeded(invocation: invocation, result: result, approved: false)
        captureRemovedPluginIfNeeded(invocation: invocation, result: result, approved: false)
        if capturedPluginDraft == nil {
            messages.append(ChatMessage(role: .tool, content: "\(result.title)\n\(result.content)"))
        }
        auditCapabilityExecution(invocation: invocation, result: result, approved: false)
        Task {
            let memoryResult = capturedPluginDraft.map {
                CapabilityResult(title: "Plugin Package Draft", content: $0.content, requiresUserApproval: $0.queuedInstallApproval)
            } ?? result
            await persistCapabilityMemory(invocation: invocation, result: memoryResult, approved: false)
        }
        saveSessionSnapshot()
        await reloadPlugins()
        connectionState = .ready
    }

    func argumentCharacterCount(_ arguments: [String: Any]) -> Int {
        arguments.values.reduce(0) { partial, value in
            partial + String(describing: value).count
        }
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
        let result = await executeCapabilityInvocation(approval.invocation)
        finishCapabilityActivity(activityID, result: result)
        refreshWebServiceArtifacts()
        captureExternalInboxEventIfNeeded(invocation: approval.invocation, result: result)
        captureInstalledPluginIfNeeded(invocation: approval.invocation, result: result, approved: true)
        captureRemovedPluginIfNeeded(invocation: approval.invocation, result: result, approved: true)
        messages.append(ChatMessage(role: .tool, content: "\(result.title)\n\(result.content)"))
        audit(
            type: "approval.approved",
            summary: "User approved capability execution.",
            metadata: [
                "approvalID": approval.id.uuidString,
                "capabilityID": approval.invocation.capabilityID,
                "functionName": approval.invocation.functionName
            ]
        )
        auditCapabilityExecution(invocation: approval.invocation, result: result, approved: true)
        Task {
            await persistCapabilityMemory(invocation: approval.invocation, result: result, approved: true)
        }
        saveSessionSnapshot()
        await reloadPlugins()
        await synthesizeApprovedCapabilityResult(approval: approval, result: result)
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

    func executeCapabilityInvocation(_ invocation: CapabilityInvocation) async -> CapabilityResult {
        if invocation.capabilityID == "reflection.snapshot" {
            let focus = stringArgument(
                invocation.arguments,
                keys: ["focus", "request", "summary"],
                fallback: ""
            )
            return saveReflectionSnapshot(focus: focus)
        }
        if invocation.capabilityID == "workspace.plan" {
            return saveWorkPlan(arguments: invocation.arguments, source: invocation.functionName)
        }
        if invocation.capabilityID == "product.diagnostics" {
            return productDiagnosticsCapability()
        }
        if invocation.capabilityID == "product.exportDiagnostics" {
            return exportProductDiagnosticsCapability(arguments: invocation.arguments)
        }
        if invocation.capabilityID == "plugin.listDrafts" {
            return listGeneratedPluginDraftsCapability()
        }
        if invocation.capabilityID == "plugin.listInstalled" {
            return listInstalledLocalPluginsCapability()
        }
        if invocation.capabilityID == "plugin.inspect" {
            return inspectInstalledLocalPluginCapability(arguments: invocation.arguments)
        }
        if invocation.capabilityID == "plugin.readFile" {
            return readInstalledLocalPluginFileCapability(arguments: invocation.arguments)
        }
        if invocation.capabilityID == "plugin.stagePackage" {
            return stagePluginPackageCapability(arguments: invocation.arguments)
        }
        if invocation.capabilityID == "plugin.installDraft" {
            return await installGeneratedPluginDraftCapability(arguments: invocation.arguments)
        }
        if invocation.capabilityID == "plugin.discardDraft" {
            return discardGeneratedPluginDraftCapability(arguments: invocation.arguments)
        }
        if invocation.capabilityID == "plugin.export" {
            return exportPluginCapability(arguments: invocation.arguments)
        }
        if invocation.capabilityID == "webapp.create" {
            return createWebAppCapability(arguments: invocation.arguments)
        }
        if invocation.capabilityID == "webapp.update" {
            return updateWebAppCapability(arguments: invocation.arguments)
        }
        if invocation.capabilityID == "webapp.list" {
            return listWebAppsCapability()
        }
        if invocation.capabilityID == "webapp.open" {
            return openWebAppCapability(arguments: invocation.arguments)
        }
        if invocation.capabilityID == "webapp.remove" {
            return removeWebAppCapability(arguments: invocation.arguments)
        }
        return await capabilityExecutor.execute(invocation)
    }

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

    func requiresApproval(capabilityID: String) -> Bool {
        pluginRegistry.capability(id: capabilityID, in: plugins)?.requiresApproval ?? true
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
        let failed = result.requiresUserApproval
            || result.title.localizedCaseInsensitiveContains("failed")
            || result.title.localizedCaseInsensitiveContains("blocked")
            || result.title.localizedCaseInsensitiveContains("missing")
            || result.title.localizedCaseInsensitiveContains("unsupported")
            || result.title.localizedCaseInsensitiveContains("timed out")
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
            let prompt = SystemPromptBuilder(pluginManifests: plugins).build(
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
                Task { await speakAssistantReplyIfEnabled(content) }
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
