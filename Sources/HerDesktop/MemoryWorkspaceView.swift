import SwiftUI

struct MemoryWorkspaceView: View {
    @EnvironmentObject private var activityFeed: ActivityFeedModel
    @EnvironmentObject private var model: AppViewModel
    private var writebacks: [MemoryWritebackStatus] {
        MemoryWritebackStatusBuilder().build(from: activityFeed.auditEvents)
    }

    var body: some View {
        // Bind once: the panel below read `writebacks` four times per body
        // pass, rebuilding the status list from auditEvents each time.
        let writebacks = self.writebacks
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

            WorkspacePanel(title: "Recent Writebacks", trailing: writebacks.isEmpty ? "Quiet" : writebacks.first?.status.capitalized ?? "\(writebacks.count)") {
                if writebacks.isEmpty {
                    EmptyWorkspaceLine(icon: "brain.head.profile", text: "AgentMem writeback task status will appear after memory is saved.")
                } else {
                    VStack(spacing: 8) {
                        ForEach(writebacks) { item in
                            MemoryWritebackStatusRow(item: item)
                        }
                    }
                }
            }

            WorkspacePanel(title: "Recent Interaction Signals", trailing: "\(activityFeed.interactionEvents.count)") {
                if activityFeed.interactionEvents.isEmpty {
                    EmptyWorkspaceLine(icon: "dot.radiowaves.left.and.right", text: "Conversation, file, voice, and inbox signals will appear here.")
                } else {
                    VStack(spacing: 8) {
                        ForEach(activityFeed.interactionEvents.prefix(6)) { event in
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

struct MemoryWritebackStatusRow: View {
    var item: MemoryWritebackStatus

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.icon)
                .foregroundStyle(color(for: item.status))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(1)
                    Spacer()
                    Text(item.status.capitalized)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(color(for: item.status))
                    Text(item.createdAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                }
                Text(item.detail)
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

    private func color(for status: String) -> Color {
        switch status {
        case "succeeded":
            return .green
        case "failed", "check failed":
            return AppTheme.coral
        case "processing", "queued":
            return AppTheme.burgundy
        default:
            return AppTheme.muted
        }
    }
}

struct ReflectionCountLine: View {
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
