import AppKit
import Foundation
import SwiftUI

/// Diagnostics, work plans, artifacts, and service health.
extension AppViewModel {
    func openLocalAgentDirectory() {
        openDirectory(HerWorkspacePaths.localAgentDirectory(cwd: runtimeCwd), eventType: "workspace.open_her_directory")
    }

    func openWorkspaceArtifactsDirectory() {
        openDirectory(HerWorkspacePaths.workspaceDirectory(cwd: runtimeCwd), eventType: "workspace.open_artifacts_directory")
    }

    func openWebServiceArtifactDirectory() {
        openDirectory(
            HerWorkspacePaths.webServiceArtifactDirectory(cwd: runtimeCwd),
            eventType: "workspace.open_webservice_artifacts_directory"
        )
    }

    func openWebServiceArtifact(path: String) {
        openFile(path: path, eventType: "workspace.open_webservice_artifact")
    }

    func runProductDiagnostics() async {
        await runCapability(capabilityID: "product.diagnostics", arguments: [:])
    }

    func requestProductDiagnosticsExport(filename: String? = nil) async {
        var arguments: [String: Any] = [:]
        if let filename,
           !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments["filename"] = filename
        }
        await runCapability(capabilityID: "product.exportDiagnostics", arguments: arguments)
    }

    func refreshServiceHealth() async {
        serviceHealth = serviceHealthVerifier.checkingSnapshot(pluginCount: plugins.count)
        tools = Self.tools(from: serviceHealth, model: config.agentLLMModel)
        let checked = await serviceHealthVerifier.checkAll(pluginCount: plugins.count)
        serviceHealth = checked
        tools = Self.tools(from: checked, model: config.agentLLMModel)
        await refreshAgentProfile()
        rebuildRunningTasks()
    }

    func refreshAuditEvents() {
        do {
            auditEvents = Self.recentAuditEvents(from: try auditStore.loadAll())
        } catch {
            lastError = "Could not load audit log: \(error.localizedDescription)"
        }
    }

    func refreshWebServiceArtifacts() {
        do {
            webServiceArtifacts = try webServiceArtifactStore.loadAll()
        } catch {
            lastError = "Could not load web service artifacts: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func saveWorkPlan(arguments: [String: Any], source: String) -> CapabilityResult {
        let goal = stringArgument(
            arguments,
            keys: ["goal", "request", "objective", "summary"],
            fallback: "Continue current work."
        )
        let steps = workPlanSteps(from: arguments, fallbackGoal: goal)
        var plan = WorkPlan(
            goal: goal,
            source: source,
            steps: steps,
            risks: stringArrayArgument(arguments, keys: ["risks", "risk"]),
            verification: stringArrayArgument(arguments, keys: ["verification", "checks", "verify"])
        )
        plan.updatedAt = Date()

        do {
            let url = try workPlanStore.save(plan)
            workPlan = plan
            rebuildRunningTasks()
            audit(
                type: "workspace.plan_saved",
                summary: "Saved current work plan.",
                metadata: [
                    "path": url.path,
                    "source": source,
                    "steps": String(plan.steps.count),
                    "risks": String(plan.risks.count),
                    "verification": String(plan.verification.count)
                ]
            )
            return CapabilityResult(
                title: "Workspace Plan Saved",
                content: workPlanSummary(plan: plan, path: url.path),
                requiresUserApproval: false
            )
        } catch {
            lastError = "Could not save work plan: \(error.localizedDescription)"
            audit(type: "workspace.plan_save_failed", summary: error.localizedDescription)
            return CapabilityResult(
                title: "Workspace Plan Failed",
                content: error.localizedDescription,
                requiresUserApproval: false
            )
        }
    }

    func productDiagnosticsCapability() -> CapabilityResult {
        let content = productDiagnosticsSnapshot()
        return CapabilityResult(
            title: "Product Diagnostics",
            content: content,
            requiresUserApproval: false
        )
    }

    func exportProductDiagnosticsCapability(arguments: [String: Any]) -> CapabilityResult {
        let filename = safeDiagnosticsFilename(
            stringArgument(arguments, keys: ["filename", "path", "name"], fallback: "product-diagnostics.md")
        )
        let directory = HerWorkspacePaths.diagnosticsDirectory(cwd: runtimeCwd)
        let fileURL = directory.appendingPathComponent(filename, isDirectory: false)
        let snapshot = productDiagnosticsSnapshot()
        let report = """
        # Her Desktop Product Diagnostics

        Generated by `product.exportDiagnostics`.

        ```text
        \(snapshot)
        ```
        """

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try report.write(to: fileURL, atomically: true, encoding: .utf8)
            return CapabilityResult(
                title: "Product Diagnostics Exported",
                content: """
                Wrote product diagnostics report:
                \(fileURL.path)

                The report contains readiness, service, plugin, session, and workspace state. API keys and Memory keys are reported only as configured/not configured.
                """,
                requiresUserApproval: false
            )
        } catch {
            return CapabilityResult(
                title: "Product Diagnostics Export Failed",
                content: error.localizedDescription,
                requiresUserApproval: false
            )
        }
    }

    func productDiagnosticsSnapshot() -> String {
        let runtime = PromptRuntimeContext.current(config: config, cwd: runtimeCwd)
        return ProductDiagnosticsSnapshotBuilder().build(
            readiness: productReadinessSummary,
            config: config,
            serviceHealth: serviceHealth,
            plugins: plugins,
            localInboxBridgeState: localInboxBridgeState,
            pendingApprovals: pendingApprovals,
            generatedDrafts: generatedPluginDrafts,
            workPlan: workPlan,
            dreamContext: dreamContext,
            agentProfile: agentProfile,
            memorySignal: memorySignal,
            runtime: runtime,
            sessionID: sessionID
        )
    }

    func safeDiagnosticsFilename(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let requested = trimmed.isEmpty ? "product-diagnostics.md" : trimmed
        let lastPathComponent = (requested as NSString).lastPathComponent
        let withoutTraversal = lastPathComponent.replacingOccurrences(of: "..", with: "")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let sanitized = String(withoutTraversal.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_\n\t "))
        let base = sanitized.isEmpty ? "product-diagnostics" : sanitized
        return base.lowercased().hasSuffix(".md") ? base : "\(base).md"
    }

    func workPlanSteps(from arguments: [String: Any], fallbackGoal: String) -> [WorkPlan.Step] {
        guard let raw = arguments["steps"] else {
            return [WorkPlan.Step(title: fallbackGoal, status: .inProgress)]
        }

        let parsed: [WorkPlan.Step]
        if let array = raw as? [Any] {
            parsed = array.compactMap(workPlanStep(from:))
        } else {
            parsed = String(describing: raw)
                .components(separatedBy: .newlines)
                .compactMap { line in
                    let title = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { return nil }
                    return WorkPlan.Step(title: title)
                }
        }

        if parsed.isEmpty {
            return [WorkPlan.Step(title: fallbackGoal, status: .inProgress)]
        }
        return parsed
    }

    func workPlanStep(from value: Any) -> WorkPlan.Step? {
        if let title = value as? String {
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleanTitle.isEmpty ? nil : WorkPlan.Step(title: cleanTitle)
        }
        guard let object = value as? [String: Any] else {
            let cleanTitle = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            return cleanTitle.isEmpty ? nil : WorkPlan.Step(title: cleanTitle)
        }
        let title = stringArgument(object, keys: ["title", "step", "name"], fallback: "")
        guard !title.isEmpty else { return nil }
        let rawStatus = stringArgument(object, keys: ["status", "state"], fallback: "pending")
        let normalizedStatus = rawStatus
            .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1_$2", options: .regularExpression)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let status = WorkPlanStepStatus(rawValue: rawStatus)
            ?? WorkPlanStepStatus(rawValue: normalizedStatus)
            ?? .pending
        let detail = stringArgument(object, keys: ["detail", "notes", "description"], fallback: "")
        return WorkPlan.Step(
            title: title,
            status: status,
            detail: detail.isEmpty ? nil : detail
        )
    }

    func workPlanSummary(plan: WorkPlan, path: String) -> String {
        var lines = [
            "Saved current work plan at \(path).",
            "goal: \(plan.goal)",
            "progress: \(plan.stateSummary)"
        ]
        if !plan.steps.isEmpty {
            lines.append("steps:")
            lines.append(contentsOf: plan.steps.prefix(8).map { "- [\($0.status.rawValue)] \($0.title)" })
        }
        if !plan.risks.isEmpty {
            lines.append("risks: \(plan.risks.prefix(4).joined(separator: "; "))")
        }
        if !plan.verification.isEmpty {
            lines.append("verification: \(plan.verification.prefix(4).joined(separator: "; "))")
        }
        return lines.joined(separator: "\n")
    }

}
