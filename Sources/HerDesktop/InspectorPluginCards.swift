import SwiftUI

struct GeneratedPluginDraftsCard: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var reviewingDraft: GeneratedPluginDraft?

    var body: some View {
        Panel(title: "Generated Drafts", trailing: model.generatedPluginDrafts.isEmpty ? "None" : "\(model.generatedPluginDrafts.count)") {
            if model.generatedPluginDrafts.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.sparkles")
                        .foregroundStyle(AppTheme.muted)
                    Text("Model-created plugin packages will appear here for review.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                    Spacer()
                }
                .padding(.vertical, 4)
            } else {
                VStack(spacing: 10) {
                    ForEach(model.generatedPluginDrafts) { draft in
                        let catalogManifests = model.plugins.filter { $0.id != draft.manifest.id } + [draft.manifest]
                        let review = PluginPackageReview(package: draft.package, catalogManifests: catalogManifests)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "shippingbox")
                                    .foregroundStyle(AppTheme.coral)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(draft.manifest.name)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(AppTheme.ink)
                                    Text(draft.manifest.description)
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.muted)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Text(draft.createdAt, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.muted)
                            }

                            HStack(spacing: 8) {
                                Label(review.riskLevel.rawValue, systemImage: riskIcon(review.riskLevel))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(riskColor(review.riskLevel))
                                Text("\(review.capabilityCount) capability/capabilities")
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.muted)
                                Text("\(review.permissionCount) permission(s)")
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.muted)
                                Text("\(review.fileCount) file(s)")
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.muted)
                                Spacer()
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(draft.manifest.capabilities) { capability in
                                    Label(
                                        "\(capability.id) · \(capability.kind) · \(capability.adapter?.type ?? capability.kind)",
                                        systemImage: capability.requiresApproval ? "hand.raised" : "bolt"
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.muted)
                                    .lineLimit(1)
                                }
                                Label("\(draft.package.files.count) package file(s)", systemImage: "doc.text")
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.muted)
                                ForEach(review.permissionSummaries.prefix(3)) { permission in
                                    Label(
                                        "\(permission.title) · \(permission.requiresApproval ? "Approval" : "Fast run")",
                                        systemImage: permission.systemImage
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.muted)
                                    .lineLimit(1)
                                }
                                ForEach(review.installStepSummaries.prefix(2)) { step in
                                    Label(step.detail, systemImage: step.systemImage)
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.muted)
                                        .lineLimit(1)
                                }
                            }

                            HStack {
                                Button("Review") {
                                    reviewingDraft = draft
                                }
                                .buttonStyle(.bordered)

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
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.48))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .sheet(item: $reviewingDraft) { draft in
            PluginDraftReviewSheet(draft: draft)
                .environmentObject(model)
        }
    }

    private func riskIcon(_ level: PluginPackageReview.RiskLevel) -> String {
        switch level {
        case .low: return "checkmark.shield"
        case .medium: return "exclamationmark.shield"
        case .high: return "exclamationmark.triangle"
        }
    }

    private func riskColor(_ level: PluginPackageReview.RiskLevel) -> Color {
        switch level {
        case .low: return .green
        case .medium: return AppTheme.coral
        case .high: return .red
        }
    }
}

struct PluginDraftReviewSheet: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    var draft: GeneratedPluginDraft

    private var review: PluginPackageReview {
        let catalogManifests = model.plugins.filter { $0.id != draft.manifest.id } + [draft.manifest]
        return PluginPackageReview(package: draft.package, catalogManifests: catalogManifests)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: riskIcon(review.riskLevel))
                    .font(.title2)
                    .foregroundStyle(riskColor(review.riskLevel))
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.manifest.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                    Text(draft.manifest.description)
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(3)
                    Text("\(draft.manifest.id) · \(draft.source)")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                        .textSelection(.enabled)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
            }

            HStack(spacing: 10) {
                ReviewBadge(title: "Risk", value: review.riskLevel.rawValue, icon: riskIcon(review.riskLevel), color: riskColor(review.riskLevel))
                ReviewBadge(title: "Capabilities", value: "\(review.capabilityCount)", icon: "puzzlepiece.extension", color: AppTheme.coral)
                ReviewBadge(title: "Permissions", value: "\(review.permissionCount)", icon: "key.viewfinder", color: AppTheme.burgundy)
                ReviewBadge(title: "Files", value: "\(review.fileCount)", icon: "doc.text", color: AppTheme.muted)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    reviewSection(title: "Install Preview", icon: "shippingbox") {
                        ForEach(review.installStepSummaries) { step in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(step.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(AppTheme.ink)
                                    Text(step.detail)
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.muted)
                                        .textSelection(.enabled)
                                }
                            } icon: {
                                Image(systemName: step.systemImage)
                                    .foregroundStyle(AppTheme.coral)
                            }
                            .labelStyle(.titleAndIcon)
                        }
                    }

                    reviewSection(title: "Permissions", icon: "key.viewfinder") {
                        ForEach(review.permissionSummaries) { permission in
                            PermissionSummaryRow(permission: permission)
                        }
                    }

                    reviewSection(title: "Risk Notes", icon: "shield.lefthalf.filled") {
                        if review.riskItems.isEmpty {
                            Label("No elevated risk signals found in the manifest.", systemImage: "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            ForEach(review.riskItems, id: \.self) { item in
                                Label(item, systemImage: "exclamationmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.ink)
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    reviewSection(title: "Capabilities", icon: "wand.and.sparkles") {
                        ForEach(review.capabilitySummaries) { capability in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 8) {
                                    Label(capability.title, systemImage: capability.requiresApproval ? "hand.raised" : "bolt")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(AppTheme.ink)
                                    Spacer()
                                    Text(capability.adapterType)
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.muted)
                                }
                                Text(capability.id)
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.muted)
                                    .textSelection(.enabled)
                                Text(capability.detail)
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.muted)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                                if !capability.inputFields.isEmpty {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Inputs")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(AppTheme.ink)
                                        ForEach(capability.inputFields) { field in
                                            PluginInputFieldSummary(field: field)
                                        }
                                    }
                                    .padding(.top, 3)
                                }
                            }
                            .padding(9)
                            .background(Color.white.opacity(0.45))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    reviewSection(title: "Package Files", icon: "doc.on.doc") {
                        if review.fileSummaries.isEmpty {
                            Text("No files included.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.muted)
                        } else {
                            ForEach(review.fileSummaries) { file in
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(AppTheme.muted)
                                    Text(file.path)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(AppTheme.ink)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(file.lineCount) lines · \(file.byteCount) bytes")
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.muted)
                                }
                                .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 280)

            HStack {
                Button("Discard") {
                    model.discardGeneratedPluginDraft(draft)
                    dismiss()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Install Plugin") {
                    Task {
                        await model.installGeneratedPluginDraft(draft)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.coral)
            }
            .controlSize(.regular)
        }
        .padding(22)
        .frame(width: 640, height: 620)
        .background(AppTheme.windowBackground)
    }

    @ViewBuilder
    private func reviewSection<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
            content()
        }
        .padding(10)
        .background(Color.white.opacity(0.36))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func riskIcon(_ level: PluginPackageReview.RiskLevel) -> String {
        switch level {
        case .low: return "checkmark.shield"
        case .medium: return "exclamationmark.shield"
        case .high: return "exclamationmark.triangle"
        }
    }

    private func riskColor(_ level: PluginPackageReview.RiskLevel) -> Color {
        switch level {
        case .low: return .green
        case .medium: return AppTheme.coral
        case .high: return .red
        }
    }
}

struct PluginLifecycleCard: View {
    @EnvironmentObject private var activityFeed: ActivityFeedModel
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        Panel(title: "Plugin Timeline", trailing: activityFeed.pluginEvents.isEmpty ? "Quiet" : "\(activityFeed.pluginEvents.count)") {
            if activityFeed.pluginEvents.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(AppTheme.muted)
                    Text("Plugin drafts, installs, updates, exports, and removals will be tracked here.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                    Spacer()
                }
                .padding(.vertical, 4)
            } else {
                VStack(spacing: 8) {
                    ForEach(activityFeed.pluginEvents) { event in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: icon(for: event.action))
                                .foregroundStyle(color(for: event.action))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(event.pluginName)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(AppTheme.ink)
                                        .lineLimit(1)
                                    Text(event.action.title)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(color(for: event.action))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.white.opacity(0.52))
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                    Spacer(minLength: 0)
                                }
                                Text("\(event.pluginID) · v\(event.version) · \(event.source)")
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.muted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                Text(event.summary)
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.muted)
                                    .lineLimit(2)
                                Text("\(countLabel(event.capabilityCount, singular: "capability")) · \(countLabel(event.fileCount, singular: "file")) · \(event.createdAt.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.muted.opacity(0.82))
                                    .lineLimit(1)
                            }
                        }
                        .padding(9)
                        .background(Color.white.opacity(0.42))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .onAppear {
            model.refreshPluginEvents()
        }
    }

    private func icon(for action: PluginLifecycleAction) -> String {
        switch action {
        case .staged: return "shippingbox"
        case .installed: return "checkmark.seal"
        case .updated: return "arrow.triangle.2.circlepath"
        case .discarded: return "trash"
        case .removed: return "minus.circle"
        case .exported: return "square.and.arrow.up"
        case .importFailed, .installFailed, .removeFailed, .exportFailed: return "exclamationmark.triangle"
        }
    }

    private func color(for action: PluginLifecycleAction) -> Color {
        switch action {
        case .staged, .updated: return AppTheme.coral
        case .installed, .exported: return .green
        case .discarded, .removed: return AppTheme.muted
        case .importFailed, .installFailed, .removeFailed, .exportFailed: return .red
        }
    }

    private func countLabel(_ count: Int, singular: String) -> String {
        "\(count) \(singular)\(count == 1 ? "" : "s")"
    }
}

struct PermissionSummaryRow: View {
    var permission: PluginPackageReview.PermissionSummary

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: permission.systemImage)
                .foregroundStyle(permission.requiresApproval ? AppTheme.coral : .green)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(permission.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                    Text(permission.requiresApproval ? "Approval" : "Fast run")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(permission.requiresApproval ? AppTheme.coral : .green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.52))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                Text(permission.detail)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.white.opacity(0.40))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct PluginInputFieldSummary: View {
    var field: CapabilityInputField

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(field.name)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .textSelection(.enabled)
                Text(field.type.rawValue)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                if field.required {
                    Text("Required")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.coral)
                }
                Spacer(minLength: 0)
            }
            if !field.description.isEmpty {
                Text(field.description)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(2)
            }
            if !field.enumValues.isEmpty {
                Text("Choices: \(field.enumValues.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(7)
        .background(Color.white.opacity(0.34))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct ReviewBadge: View {
    var title: String
    var value: String
    var icon: String
    var color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(Color.white.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
