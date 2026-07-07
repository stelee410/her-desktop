import SwiftUI

struct ApprovalQueueCard: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        Panel(title: "Approvals", trailing: model.pendingApprovals.isEmpty ? "Clear" : "\(model.pendingApprovals.count)") {
            if model.pendingApprovals.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(.green)
                    Text("No pending capability approvals.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                    Spacer()
                }
                .padding(.vertical, 4)
            } else {
                VStack(spacing: 10) {
                    ForEach(model.pendingApprovals) { approval in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(approval.title, systemImage: "hand.raised")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.ink)
                                Spacer()
                                Text(approval.createdAt, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.muted)
                            }
                            Text(approval.detail)
                                .font(.caption2)
                                .foregroundStyle(AppTheme.muted)
                                .lineLimit(5)
                                .textSelection(.enabled)
                            HStack {
                                Button("Reject") {
                                    model.reject(approval)
                                }
                                .buttonStyle(.bordered)

                                Button("Approve") {
                                    Task { await model.approve(approval) }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(AppTheme.coral)
                            }
                            .controlSize(.small)
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.48))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
}

struct CapabilityActivityCard: View {
    @EnvironmentObject private var activityFeed: ActivityFeedModel
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        Panel(title: "Capability Activity", trailing: activityFeed.capabilityActivities.isEmpty ? "Idle" : "\(activityFeed.capabilityActivities.count)") {
            if activityFeed.capabilityActivities.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.horizontal.circle")
                        .foregroundStyle(AppTheme.muted)
                    Text("Tool and plugin capability execution will appear here.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                    Spacer()
                }
                .padding(.vertical, 4)
            } else {
                VStack(spacing: 10) {
                    ForEach(activityFeed.capabilityActivities.prefix(5)) { activity in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Image(systemName: icon(for: activity.status))
                                    .foregroundStyle(color(for: activity.status))
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(activity.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(AppTheme.ink)
                                        .lineLimit(1)
                                    Text("\(activity.capabilityID) · \(activity.functionName)")
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.muted)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(activity.status.rawValue.capitalized)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(color(for: activity.status))
                            }
                            Text(activity.summary)
                                .font(.caption2)
                                .foregroundStyle(AppTheme.muted)
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }
                        .padding(9)
                        .background(Color.white.opacity(0.42))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func icon(for status: CapabilityActivityStatus) -> String {
        switch status {
        case .pending: return "hand.raised"
        case .running: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .denied: return "nosign"
        }
    }

    private func color(for status: CapabilityActivityStatus) -> Color {
        switch status {
        case .pending: return AppTheme.coral
        case .running: return AppTheme.coral
        case .done: return .green
        case .failed: return .red
        case .denied: return AppTheme.muted
        }
    }
}

struct InteractionEventsCard: View {
    @EnvironmentObject private var activityFeed: ActivityFeedModel
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        Panel(title: "Interaction Events", trailing: activityFeed.interactionEvents.isEmpty ? "Idle" : "\(activityFeed.interactionEvents.count)") {
            if activityFeed.interactionEvents.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(AppTheme.muted)
                    Text("Text, voice, file, approval, and future inbox events will appear here.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                    Spacer()
                }
                .padding(.vertical, 4)
            } else {
                VStack(spacing: 10) {
                    ForEach(activityFeed.interactionEvents.prefix(6)) { event in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Image(systemName: icon(for: event))
                                    .foregroundStyle(color(for: event.surface))
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(event.kind.rawValue)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(AppTheme.ink)
                                        .lineLimit(1)
                                    Text(event.surface.rawValue)
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.muted)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(event.createdAt, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.muted)
                            }
                            Text(event.summary)
                                .font(.caption2)
                                .foregroundStyle(AppTheme.muted)
                                .lineLimit(2)
                            if !event.attachments.isEmpty {
                                Text("\(event.attachments.count) attachment(s)")
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.muted.opacity(0.82))
                            }
                        }
                        .padding(9)
                        .background(Color.white.opacity(0.42))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
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

    private func color(for surface: InteractionSurface) -> Color {
        switch surface {
        case .mac: return AppTheme.coral
        case .voice: return .purple
        case .files: return .blue
        case .pluginLibrary: return AppTheme.coral
        case .approval: return .orange
        case .configuration: return AppTheme.muted
        case .externalInbox: return .green
        }
    }
}

struct AuditTrailCard: View {
    @EnvironmentObject private var activityFeed: ActivityFeedModel
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        Panel(title: "Audit Trail", trailing: activityFeed.auditEvents.isEmpty ? "Empty" : "\(activityFeed.auditEvents.count)") {
            VStack(alignment: .leading, spacing: 10) {
                if activityFeed.auditEvents.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle")
                            .foregroundStyle(AppTheme.muted)
                        Text("Capability and plugin events will appear here.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.muted)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(activityFeed.auditEvents.prefix(5)) { event in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Image(systemName: icon(for: event.type))
                                    .foregroundStyle(AppTheme.coral)
                                    .frame(width: 18)
                                Text(event.type)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.ink)
                                    .lineLimit(1)
                                Spacer()
                                Text(event.createdAt, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.muted)
                            }
                            Text(event.summary)
                                .font(.caption2)
                                .foregroundStyle(AppTheme.muted)
                                .lineLimit(2)
                            if !metadataLine(for: event).isEmpty {
                                Text(metadataLine(for: event))
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.muted.opacity(0.82))
                                    .lineLimit(1)
                            }
                        }
                        .padding(8)
                        .background(Color.white.opacity(0.42))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                Button {
                    model.refreshAuditEvents()
                } label: {
                    Label("Refresh Audit", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func metadataLine(for event: AuditEvent) -> String {
        ["pluginID", "capabilityID", "source"]
            .compactMap { key in
                event.metadata[key].map { "\(key): \($0)" }
            }
            .joined(separator: " · ")
    }

    private func icon(for type: String) -> String {
        if type.hasPrefix("approval.") { return "hand.raised" }
        if type.hasPrefix("plugin.") { return "puzzlepiece.extension" }
        if type.hasPrefix("capability.") { return "bolt" }
        if type.hasPrefix("config.") { return "slider.horizontal.3" }
        return "list.bullet.rectangle"
    }
}

/// Background agent jobs (the agentOS "process list"): scheduled and
/// event-triggered work running in its own context, not the conversation.
struct BackgroundJobsCard: View {
    @EnvironmentObject private var activityFeed: ActivityFeedModel

    var body: some View {
        if !activityFeed.agentJobs.isEmpty {
            Panel(
                title: "Background Jobs",
                trailing: activityFeed.agentJobs.contains { $0.state == .running } ? "Running" : "Idle"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(activityFeed.agentJobs.prefix(6)) { job in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: icon(for: job.state))
                                .font(.caption)
                                .foregroundStyle(color(for: job.state))
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.ink)
                                    .lineLimit(1)
                                Text(statusLine(for: job))
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.muted)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .background(Color.white.opacity(job.state == .running ? 0.5 : 0.36))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func statusLine(for job: AgentJob) -> String {
        switch job.state {
        case .queued: return "排队中"
        case .running: return job.log.last ?? "执行中…"
        case .done: return job.result.map { String($0.prefix(80)) } ?? "完成"
        case .needsApproval: return "等待你在对话里批准"
        case .failed: return job.failureReason ?? "失败"
        }
    }

    private func icon(for state: AgentJob.State) -> String {
        switch state {
        case .queued: return "clock"
        case .running: return "gearshape.2"
        case .done: return "checkmark.circle"
        case .needsApproval: return "hand.raised"
        case .failed: return "xmark.octagon"
        }
    }

    private func color(for state: AgentJob.State) -> Color {
        switch state {
        case .running: return AppTheme.coral
        case .done: return .green
        case .needsApproval: return .orange
        case .failed: return .red
        case .queued: return AppTheme.muted
        }
    }
}

struct RunningTasksCard: View {
    @EnvironmentObject private var serviceStatus: ServiceStatusModel
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        Panel(title: "Running Tasks", trailing: "\(serviceStatus.runningTasks.count)") {
            VStack(spacing: 8) {
                ForEach(serviceStatus.runningTasks) { task in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(task.title)
                                .font(.caption)
                            Spacer()
                            Text("\(Int(task.progress * 100))%")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.muted)
                        }
                        ProgressView(value: task.progress)
                            .tint(AppTheme.coral)
                    }
                }
            }
        }
    }
}

struct AgentLoopCard: View {
    @EnvironmentObject private var activityFeed: ActivityFeedModel
    @EnvironmentObject private var model: AppViewModel

    private var steps: [AgentLoopStep] {
        AgentLoopSummaryBuilder().build(
            events: activityFeed.interactionEvents,
            activities: activityFeed.capabilityActivities,
            pendingApprovals: model.pendingApprovals,
            generatedDrafts: model.generatedPluginDrafts,
            workPlan: model.workPlan,
            connectionState: model.connectionState
        )
    }

    var body: some View {
        // Bind once: `activePhase` re-ran the whole steps builder a 2nd time.
        let steps = self.steps
        let activePhase = steps.first(where: \.isActive)?.phase.rawValue ?? "Ready"
        return Panel(title: "Agent Loop", trailing: activePhase) {
            VStack(spacing: 8) {
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: 9) {
                        ZStack {
                            Circle()
                                .fill(step.isActive ? AppTheme.coral.opacity(0.18) : Color.white.opacity(0.58))
                            Image(systemName: icon(for: step.phase))
                                .font(.caption)
                                .foregroundStyle(step.isActive ? AppTheme.coral : AppTheme.muted)
                        }
                        .frame(width: 26, height: 26)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(step.phase.rawValue)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.ink)
                                Text(step.status)
                                    .font(.caption2)
                                    .foregroundStyle(step.isActive ? AppTheme.coral : AppTheme.muted)
                                Spacer(minLength: 0)
                            }
                            Text(step.detail)
                                .font(.caption2)
                                .foregroundStyle(AppTheme.muted)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(8)
                    .background(Color.white.opacity(step.isActive ? 0.55 : 0.36))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func icon(for phase: AgentLoopPhase) -> String {
        switch phase {
        case .observe: return "eye"
        case .plan: return "list.bullet.clipboard"
        case .act: return "bolt"
        case .reflect: return "arrow.triangle.2.circlepath"
        }
    }
}
