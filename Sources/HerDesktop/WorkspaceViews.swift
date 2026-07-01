import SwiftUI

struct CenterWorkspaceView: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        Group {
            switch model.selectedSection {
            case .today:
                ConversationView()
            case .memory:
                MemoryWorkspaceView()
            case .projects:
                ProjectsWorkspaceView()
            case .tools:
                ToolsWorkspaceView()
            case .agents:
                AgentsWorkspaceView()
            }
        }
    }
}

private struct MemoryWorkspaceView: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        WorkspacePage(title: "Memory", subtitle: model.agentProfile.relationship) {
            HStack(spacing: 12) {
                WorkspaceMetric(title: "Trust", value: "\(Int(model.memorySignal.trust * 100))%", icon: "heart")
                WorkspaceMetric(title: "Confidence", value: "\(Int(model.memorySignal.confidence * 100))%", icon: "diamond")
                WorkspaceMetric(title: "Mood", value: model.memorySignal.moodLabel, icon: "face.smiling")
            }

            WorkspacePanel(title: "Relationship Profile", trailing: model.agentProfile.known ? "AgentMem" : "Local") {
                VStack(alignment: .leading, spacing: 10) {
                    Label("\(model.agentProfile.displayName) with \(model.agentProfile.userDisplayName)", systemImage: "person.2")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                    Text(model.agentProfile.relationship)
                        .font(.body)
                        .foregroundStyle(AppTheme.muted)
                        .textSelection(.enabled)
                    if !model.agentProfile.memoryID.isEmpty {
                        Text(model.agentProfile.memoryID)
                            .font(.caption.monospaced())
                            .foregroundStyle(AppTheme.muted)
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button {
                            Task { await model.refreshAgentProfile() }
                        } label: {
                            Label("Refresh Memory", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.coral)

                        Button {
                            model.openLocalAgentDirectory()
                        } label: {
                            Label("Open Local State", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
            }

            WorkspacePanel(title: "Companion Reflection", trailing: model.dreamContext == nil ? "Not saved" : "Active") {
                VStack(alignment: .leading, spacing: 10) {
                    if let context = model.dreamContext {
                        Label(context.longHorizonObjective ?? "Compressed partner context is ready.", systemImage: "moon.stars")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                            .lineLimit(3)
                            .textSelection(.enabled)
                        if let insight = context.recentInsight {
                            Text(insight)
                                .font(.caption)
                                .foregroundStyle(AppTheme.muted)
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            ReflectionCountLine(title: "Guidance", count: context.behaviorGuidance.count, icon: "sparkles")
                            ReflectionCountLine(title: "Open threads", count: context.unresolvedThreads.count, icon: "text.badge.checkmark")
                            ReflectionCountLine(title: "Cautions", count: context.cautions.count, icon: "exclamationmark.shield")
                        }
                        Text("Updated \(context.updatedAt)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(AppTheme.muted)
                            .textSelection(.enabled)
                    } else {
                        EmptyWorkspaceLine(icon: "moon.stars", text: "Generate a local reflection snapshot to carry compact companion context into future turns.")
                    }

                    HStack {
                        Button {
                            model.generateReflectionSnapshot()
                        } label: {
                            Label("Reflect", systemImage: "moon.stars")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.coral)

                        Button {
                            model.refreshDreamContext()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
            }

            WorkspacePanel(title: "Recent Interaction Signals", trailing: "\(model.interactionEvents.count)") {
                if model.interactionEvents.isEmpty {
                    EmptyWorkspaceLine(icon: "dot.radiowaves.left.and.right", text: "Conversation, file, voice, and inbox signals will appear here.")
                } else {
                    VStack(spacing: 8) {
                        ForEach(model.interactionEvents.prefix(6)) { event in
                            WorkspaceEventRow(
                                icon: icon(for: event),
                                title: event.kind.rawValue,
                                detail: event.summary,
                                time: event.createdAt
                            )
                        }
                    }
                }
            }
        }
    }

    private func icon(for event: InteractionEvent) -> String {
        switch event.kind {
        case .userMessage: return "text.bubble"
        case .voiceDictationStarted, .voiceDictationFinished, .voiceDictationFailed: return "waveform"
        case .attachmentsImported, .attachmentImportFailed: return "paperclip"
        case .manualCapabilityRequested: return "bolt"
        case .approvalApproved, .approvalRejected: return "hand.raised"
        case .pluginDraftRequested, .pluginPackageImported: return "shippingbox"
        case .localSessionStarted: return "plus.message"
        case .externalInboxCaptured: return "tray.and.arrow.down"
        }
    }
}

private struct ReflectionCountLine: View {
    var title: String
    var count: Int
    var icon: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.coral)
                .frame(width: 17)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
            Spacer()
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(AppTheme.muted)
        }
        .padding(7)
        .background(Color.white.opacity(0.36))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ProjectsWorkspaceView: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        WorkspacePage(title: "Projects", subtitle: "Workspace, artifacts, and active work") {
            HStack(spacing: 12) {
                WorkspaceMetric(title: "Tasks", value: "\(model.runningTasks.count)", icon: "checklist")
                WorkspaceMetric(title: "Artifacts", value: "\(model.webServiceArtifacts.count)", icon: "photo.on.rectangle")
                WorkspaceMetric(title: "Audit", value: "\(model.auditEvents.count)", icon: "list.bullet.rectangle")
            }

            WorkspacePanel(title: "Active Work", trailing: model.runningTasks.isEmpty ? "Idle" : "\(model.runningTasks.count)") {
                if model.runningTasks.isEmpty {
                    EmptyWorkspaceLine(icon: "moon", text: "No active runtime tasks.")
                } else {
                    VStack(spacing: 10) {
                        ForEach(model.runningTasks) { task in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text(task.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(AppTheme.ink)
                                    Spacer()
                                    Text(task.state)
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.muted)
                                }
                                ProgressView(value: task.progress)
                                    .tint(AppTheme.coral)
                            }
                            .padding(9)
                            .background(Color.white.opacity(0.42))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }

            WorkspacePanel(title: "Workspace Folders", trailing: "Local") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    WorkspaceActionButton(title: "Her State", icon: "folder") {
                        model.openLocalAgentDirectory()
                    }
                    WorkspaceActionButton(title: "Artifacts", icon: "shippingbox") {
                        model.openWorkspaceArtifactsDirectory()
                    }
                    WorkspaceActionButton(title: "Web Outputs", icon: "photo") {
                        model.openWebServiceArtifactDirectory()
                    }
                    WorkspaceActionButton(title: "Plugins", icon: "puzzlepiece.extension") {
                        model.openPluginDirectory()
                    }
                }
            }

            WorkspacePanel(title: "Recent Artifacts", trailing: "\(model.webServiceArtifacts.count)") {
                if model.webServiceArtifacts.isEmpty {
                    EmptyWorkspaceLine(icon: "doc.richtext", text: "Generated web service artifacts will be collected here.")
                } else {
                    VStack(spacing: 8) {
                        ForEach(model.webServiceArtifacts.prefix(5)) { artifact in
                            WorkspaceEventRow(
                                icon: artifact.primaryLocalImagePath == nil ? "doc.richtext" : "photo",
                                title: artifact.capabilityID,
                                detail: "\(artifact.request.status) · \(artifact.artifacts.count) item(s)",
                                time: artifact.createdAt
                            )
                        }
                    }
                }
            }
        }
    }
}

private struct ToolsWorkspaceView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var runTarget: CapabilityRunTarget?

    var body: some View {
        WorkspacePage(title: "Tools", subtitle: "\(model.plugins.count) plugins · \(capabilityCount) capabilities") {
            HStack(spacing: 12) {
                WorkspaceMetric(title: "Plugins", value: "\(model.plugins.count)", icon: "puzzlepiece.extension")
                WorkspaceMetric(title: "Capabilities", value: "\(capabilityCount)", icon: "bolt")
                WorkspaceMetric(title: "Drafts", value: "\(model.generatedPluginDrafts.count)", icon: "shippingbox")
            }

            WorkspacePanel(title: "Capability Library", trailing: "\(capabilityCount)") {
                if model.plugins.isEmpty {
                    EmptyWorkspaceLine(icon: "puzzlepiece.extension", text: "Plugins will appear after the registry loads.")
                } else {
                    VStack(spacing: 10) {
                        ForEach(model.plugins) { plugin in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label(plugin.name, systemImage: plugin.id.hasPrefix("builtin.") ? "seal" : "folder")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(AppTheme.ink)
                                    Spacer()
                                    Text("\(plugin.capabilities.count)")
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.muted)
                                }
                                ForEach(plugin.capabilities) { capability in
                                    let summary = PluginCapabilityDisplaySummary(plugin: plugin, capability: capability)
                                    HStack(spacing: 7) {
                                        Image(systemName: icon(for: capability.kind))
                                            .foregroundStyle(AppTheme.coral)
                                            .frame(width: 18)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(capability.title)
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(AppTheme.ink)
                                                .lineLimit(1)
                                            Text(summary.detailLine)
                                                .font(.caption2)
                                                .foregroundStyle(AppTheme.muted)
                                                .lineLimit(1)
                                            HStack(spacing: 5) {
                                                PluginCapabilityChip(text: summary.approvalLabel, icon: capability.requiresApproval ? "hand.raised" : "bolt")
                                                PluginCapabilityChip(text: summary.inputLabel, icon: "text.badge.checkmark")
                                            }
                                        }
                                        Spacer()
                                        Button {
                                            runTarget = CapabilityRunTarget(pluginName: plugin.name, capability: capability)
                                        } label: {
                                            Image(systemName: "play.circle")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Run capability")
                                    }
                                    .padding(8)
                                    .background(Color.white.opacity(0.38))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                            .padding(10)
                            .background(Color.white.opacity(0.34))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }

            WorkspacePanel(title: "Generated Drafts", trailing: model.generatedPluginDrafts.isEmpty ? "Clear" : "\(model.generatedPluginDrafts.count)") {
                if model.generatedPluginDrafts.isEmpty {
                    EmptyWorkspaceLine(icon: "wand.and.sparkles", text: "Use Vibe Plugin in the command center to generate or stage extensions.")
                } else {
                    VStack(spacing: 8) {
                        ForEach(model.generatedPluginDrafts.prefix(5)) { draft in
                            let review = PluginPackageReview(package: draft.package)
                            VStack(alignment: .leading, spacing: 8) {
                                WorkspaceEventRow(
                                    icon: "shippingbox",
                                    title: draft.manifest.name,
                                    detail: draft.manifest.description,
                                    time: draft.createdAt
                                )
                                HStack {
                                    Text("\(review.riskLevel.rawValue) risk · \(review.capabilityCount) capability/capabilities · \(review.permissionCount) permission(s) · \(review.fileCount) file(s)")
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.muted)
                                        .lineLimit(1)
                                    Spacer()
                                    Button("Discard") {
                                        model.discardGeneratedPluginDraft(draft)
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Install") {
                                        Task { await model.installGeneratedPluginDraft(draft) }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(AppTheme.coral)
                                }
                                .controlSize(.small)
                                .padding(.horizontal, 2)
                            }
                            .padding(9)
                            .background(Color.white.opacity(0.34))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
        .sheet(item: $runTarget) { target in
            CapabilityRunSheet(target: target)
                .environmentObject(model)
        }
    }

    private var capabilityCount: Int {
        model.plugins.flatMap(\.capabilities).count
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "skill": return "sparkles"
        case "webservice": return "globe"
        case "mcp": return "shippingbox"
        case "command": return "terminal"
        case "native": return "macwindow"
        default: return "bolt"
        }
    }
}

private struct AgentsWorkspaceView: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        WorkspacePage(title: "Agents", subtitle: "Main loop, model routing, and subconscious context") {
            HStack(spacing: 12) {
                WorkspaceMetric(title: "State", value: model.connectionState.rawValue.capitalized, icon: "dot.radiowaves.left.and.right")
                WorkspaceMetric(title: "Model", value: model.config.agentLLMModel, icon: "sparkles")
                WorkspaceMetric(title: "Queue", value: "\(model.pendingApprovals.count)", icon: "hand.raised")
            }

            WorkspacePanel(title: "Loop State", trailing: activePhase) {
                VStack(spacing: 9) {
                    ForEach(loopSteps) { step in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: icon(for: step.phase))
                                .foregroundStyle(step.isActive ? AppTheme.coral : AppTheme.muted)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(step.phase.rawValue)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(AppTheme.ink)
                                    Spacer()
                                    Text(step.status)
                                        .font(.caption2)
                                        .foregroundStyle(step.isActive ? AppTheme.coral : AppTheme.muted)
                                }
                                Text(step.detail)
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.muted)
                                    .lineLimit(2)
                            }
                        }
                        .padding(9)
                        .background(Color.white.opacity(step.isActive ? 0.50 : 0.36))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            WorkspacePanel(title: "Service Routing", trailing: PresenceCopy.serviceStatus(model.serviceHealth).title) {
                VStack(spacing: 8) {
                    ForEach(model.serviceHealth) { item in
                        HStack(spacing: 9) {
                            Image(systemName: icon(for: item.state))
                                .foregroundStyle(color(for: item.state))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.ink)
                                Text(item.summary)
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.muted)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Text(item.state.rawValue.capitalized)
                                .font(.caption2)
                                .foregroundStyle(color(for: item.state))
                        }
                        .padding(9)
                        .background(Color.white.opacity(0.40))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private var loopSteps: [AgentLoopStep] {
        AgentLoopSummaryBuilder().build(
            events: model.interactionEvents,
            activities: model.capabilityActivities,
            pendingApprovals: model.pendingApprovals,
            generatedDrafts: model.generatedPluginDrafts,
            connectionState: model.connectionState
        )
    }

    private var activePhase: String {
        loopSteps.first(where: \.isActive)?.phase.rawValue ?? "Ready"
    }

    private func icon(for phase: AgentLoopPhase) -> String {
        switch phase {
        case .observe: return "eye"
        case .plan: return "list.bullet.clipboard"
        case .act: return "bolt"
        case .reflect: return "arrow.triangle.2.circlepath"
        }
    }

    private func icon(for state: ServiceHealthState) -> String {
        switch state {
        case .online: return "checkmark.circle.fill"
        case .offline: return "xmark.circle.fill"
        case .checking: return "arrow.triangle.2.circlepath"
        case .unknown: return "questionmark.circle"
        }
    }

    private func color(for state: ServiceHealthState) -> Color {
        switch state {
        case .online: return .green
        case .offline: return .red
        case .checking: return AppTheme.coral
        case .unknown: return AppTheme.muted
        }
    }
}

private struct WorkspacePage<Content: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(AppTheme.burgundy)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(2)
                }
                .padding(.top, 28)

                content
            }
            .padding(.horizontal, 38)
            .padding(.bottom, 34)
        }
    }
}

private struct WorkspacePanel<Content: View>: View {
    var title: String
    var trailing: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
            }
            content
        }
        .padding(14)
        .background(AppTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
    }
}

private struct WorkspaceMetric: View {
    var title: String
    var value: String
    var icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
            Text(value)
                .font(.headline)
                .foregroundStyle(AppTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .background(AppTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct WorkspaceActionButton: View {
    var title: String
    var icon: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

private struct WorkspaceEventRow: View {
    var icon: String
    var title: String
    var detail: String
    var time: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.coral)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(1)
                    Spacer()
                    Text(time, style: .time)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                }
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(9)
        .background(Color.white.opacity(0.40))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct EmptyWorkspaceLine: View {
    var icon: String
    var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.muted)
            Text(text)
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
