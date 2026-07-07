import SwiftUI

struct AgentsWorkspaceView: View {
    @EnvironmentObject private var session: ConversationModel
    @EnvironmentObject private var serviceStatus: ServiceStatusModel
    @EnvironmentObject private var activityFeed: ActivityFeedModel
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        // Bind once per body pass: `activePhase` re-ran the whole loop-steps
        // builder a second time, and `toolEvidence` was built twice below.
        let steps = loopSteps
        let activePhase = steps.first(where: \.isActive)?.phase.rawValue ?? "Ready"
        let toolEvidence = self.toolEvidence
        WorkspacePage(title: "Agents", subtitle: "Main loop, model routing, and subconscious context") {
            HStack(spacing: 12) {
                WorkspaceMetric(title: "State", value: model.connectionState.rawValue.capitalized, icon: "dot.radiowaves.left.and.right")
                WorkspaceMetric(title: "Model", value: model.config.agentLLMModel, icon: "sparkles")
                WorkspaceMetric(title: "Queue", value: "\(model.pendingApprovals.count)", icon: "hand.raised")
            }

            WorkspacePanel(title: "Loop State", trailing: activePhase) {
                VStack(spacing: 9) {
                    ForEach(steps) { step in
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

            WorkspacePanel(title: "Recent Tool Evidence", trailing: toolEvidence.isEmpty ? "Quiet" : "\(toolEvidence.count)") {
                if toolEvidence.isEmpty {
                    EmptyWorkspaceLine(icon: "checkmark.seal", text: "Verified tool results will appear here as bounded evidence for the next turn.")
                } else {
                    VStack(spacing: 8) {
                        ForEach(toolEvidence) { evidence in
                            WorkspaceEventRow(
                                icon: "checkmark.seal",
                                title: evidence.title,
                                detail: evidence.detail,
                                time: evidence.createdAt
                            )
                        }
                    }
                }
            }

            WorkspacePanel(title: "Service Routing", trailing: PresenceCopy.serviceStatus(serviceStatus.serviceHealth).title) {
                VStack(spacing: 8) {
                    ForEach(serviceStatus.serviceHealth) { item in
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
            events: activityFeed.interactionEvents,
            activities: activityFeed.capabilityActivities,
            pendingApprovals: model.pendingApprovals,
            generatedDrafts: model.generatedPluginDrafts,
            workPlan: model.workPlan,
            connectionState: model.connectionState
        )
    }

    private var toolEvidence: [ToolEvidenceSummary] {
        ToolEvidenceSummaryBuilder().build(from: session.messages)
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
