import SwiftUI

struct ProjectsWorkspaceView: View {
    @EnvironmentObject private var serviceStatus: ServiceStatusModel
    @EnvironmentObject private var activityFeed: ActivityFeedModel
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        WorkspacePage(title: "Projects", subtitle: "Workspace, artifacts, and active work") {
            HStack(spacing: 12) {
                WorkspaceMetric(title: "Tasks", value: "\(serviceStatus.runningTasks.count)", icon: "checklist")
                WorkspaceMetric(title: "Artifacts", value: "\(model.webServiceArtifacts.count)", icon: "photo.on.rectangle")
                WorkspaceMetric(title: "Audit", value: "\(activityFeed.auditEvents.count)", icon: "list.bullet.rectangle")
            }

            WorkspacePanel(title: "Active Work", trailing: serviceStatus.runningTasks.isEmpty ? "Idle" : "\(serviceStatus.runningTasks.count)") {
                if serviceStatus.runningTasks.isEmpty {
                    EmptyWorkspaceLine(icon: "moon", text: "No active runtime tasks.")
                } else {
                    VStack(spacing: 10) {
                        ForEach(serviceStatus.runningTasks) { task in
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

            WorkspacePanel(title: "Current Plan", trailing: model.workPlan == nil ? "Unset" : model.workPlan?.stateSummary ?? "Active") {
                if let plan = model.workPlan {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(plan.goal, systemImage: "target")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                            .lineLimit(3)
                            .textSelection(.enabled)

                        ProgressView(value: plan.progress)
                            .tint(AppTheme.coral)

                        VStack(spacing: 7) {
                            ForEach(plan.steps.prefix(6)) { step in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: icon(for: step.status))
                                        .foregroundStyle(color(for: step.status))
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(step.title)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(AppTheme.ink)
                                            .lineLimit(2)
                                        if let detail = step.detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            Text(detail)
                                                .font(.caption2)
                                                .foregroundStyle(AppTheme.muted)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                    Text(step.status.displayName)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(AppTheme.muted)
                                }
                                .padding(8)
                                .background(Color.white.opacity(0.36))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }

                        if !plan.risks.isEmpty || !plan.verification.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                if !plan.risks.isEmpty {
                                    Text("Risks: \(plan.risks.prefix(3).joined(separator: "; "))")
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.muted)
                                        .lineLimit(3)
                                }
                                if !plan.verification.isEmpty {
                                    Text("Verify: \(plan.verification.prefix(3).joined(separator: "; "))")
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.muted)
                                        .lineLimit(3)
                                }
                            }
                            .textSelection(.enabled)
                        }
                    }
                } else {
                    EmptyWorkspaceLine(icon: "target", text: "Ask Her to make or update a work plan; it will stay available across launches.")
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

    private func icon(for status: WorkPlanStepStatus) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "clock"
        case .done: return "checkmark.circle.fill"
        case .blocked: return "exclamationmark.triangle.fill"
        }
    }

    private func color(for status: WorkPlanStepStatus) -> Color {
        switch status {
        case .pending: return AppTheme.muted
        case .inProgress: return AppTheme.coral
        case .done: return Color.green.opacity(0.85)
        case .blocked: return Color.orange
        }
    }
}
