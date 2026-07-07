import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InspectorView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var pane: Pane = .attention

    private enum Pane: String, CaseIterable, Identifiable {
        case attention
        case widgets
        case system
        case activity

        var id: String { rawValue }

        var title: String {
            switch self {
            case .attention: return "待办"
            case .widgets: return "小组件"
            case .system: return "系统"
            case .activity: return "活动"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector Pane", selection: $pane) {
                ForEach(Pane.allCases) { pane in
                    Text(pane.title).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch pane {
                    case .attention:
                        ApprovalQueueCard()
                        GeneratedPluginDraftsCard()
                        RunningTasksCard()
                        CapabilityActivityCard()
                        ActivePlanCard()
                    case .widgets:
                        PinnedWebAppsPane()
                    case .system:
                        ProductReadinessCard()
                        ServiceHealthCard()
                        ServiceConfigurationCard()
                        ModelRoutingCard()
                        ConnectedToolsCard()
                        LocalInboxBridgeCard()
                        StateCard()
                    case .activity:
                        AgentLoopCard()
                        InteractionEventsCard()
                        PluginLifecycleCard()
                        WebServiceArtifactsCard()
                        AuditTrailCard()
                    }
                }
                .padding(14)
            }
        }
        .background(Color.white.opacity(0.24))
    }
}

/// Pinned web apps as a widget panel: widget-enabled apps render their
/// compact live page; apps without a widget show an icon tile. Clicking
/// either opens the full app in the Apps page.
private struct PinnedWebAppsPane: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        if model.pinnedWebApps.isEmpty {
            Panel(title: "小组件", trailing: "0") {
                VStack(alignment: .leading, spacing: 10) {
                    Label("还没有固定的应用", systemImage: "pin")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                    Text("在 Apps 页给应用点 📌 固定后，会常驻在这里。")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                    Button {
                        model.selectedSection = .apps
                    } label: {
                        Label("打开 Apps", systemImage: "macwindow.on.rectangle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        } else {
            ForEach(model.pinnedWebApps) { app in
                PinnedWebAppCard(app: app)
            }
        }
    }
}

private struct PinnedWebAppCard: View {
    @EnvironmentObject private var model: AppViewModel
    var app: WebAppManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(app.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
                Spacer()
                Button {
                    model.togglePinWebApp(app.id)
                } label: {
                    Image(systemName: "pin.slash")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.muted)
                .help("取消固定")
            }
            if app.widget != nil, let url = model.webAppWidgetURL(app.id) {
                WebAppWebView(url: url, transparent: true)
                    .frame(height: app.widget?.height ?? 160)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.black.opacity(0.06), lineWidth: 1)
                    )
                    .overlay(
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { model.openWebApp(app.id) }
                    )
                    .help("点击打开完整应用")
            } else {
                Button {
                    model.openWebApp(app.id)
                } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(AppTheme.rose.opacity(0.75))
                            .frame(width: 40, height: 40)
                            .overlay(
                                Image(systemName: "macwindow.on.rectangle")
                                    .foregroundStyle(AppTheme.coral)
                            )
                        Text(app.description.isEmpty ? "点击打开应用" : app.description)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.muted)
                            .lineLimit(2)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(AppTheme.coral)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("打开完整应用")
            }
        }
        .padding(12)
        .background(AppTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Hosts the Vibe plugin composer sheet at the window root so conversational
/// and Tools-driven plugin creation stay reachable while the inspector is
/// hidden.
struct VibePluginComposerHost: ViewModifier {
    @EnvironmentObject private var model: AppViewModel
    @State private var pluginName = ""
    @State private var pluginDescription = ""
    @State private var pluginKind = "skill"
    @State private var pluginRequiresApproval = true
    @State private var pluginURL = ""
    @State private var pluginMethod = "POST"
    @State private var pluginMCPMethod = ""
    @State private var pluginMCPToolName = ""
    @State private var pluginMCPInputSchemaJSON = ""
    @State private var pluginCommandPath = ""
    @State private var pluginCommandArguments = ""
    @State private var pluginPackageJSON = ""
    @State private var pluginUpdateTargetID = ""
    @State private var pluginExistingPackageContext = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: model.pendingVibePluginComposerPreset?.id) { _, _ in
                applyPendingComposerPreset()
            }
            .sheet(isPresented: $model.isVibePluginComposerPresented) {
                VibePluginComposerSheet(
                    isPresented: $model.isVibePluginComposerPresented,
                    pluginName: $pluginName,
                    pluginDescription: $pluginDescription,
                    pluginKind: $pluginKind,
                    pluginRequiresApproval: $pluginRequiresApproval,
                    pluginURL: $pluginURL,
                    pluginMethod: $pluginMethod,
                    pluginMCPMethod: $pluginMCPMethod,
                    pluginMCPToolName: $pluginMCPToolName,
                    pluginMCPInputSchemaJSON: $pluginMCPInputSchemaJSON,
                    pluginCommandPath: $pluginCommandPath,
                    pluginCommandArguments: $pluginCommandArguments,
                    pluginPackageJSON: $pluginPackageJSON,
                    pluginUpdateTargetID: $pluginUpdateTargetID,
                    pluginExistingPackageContext: $pluginExistingPackageContext
                )
                .environmentObject(model)
            }
    }

    private func applyPendingComposerPreset() {
        guard let preset = model.pendingVibePluginComposerPreset else { return }
        pluginName = preset.pluginName
        pluginDescription = preset.pluginDescription
        pluginKind = preset.pluginKind
        pluginRequiresApproval = preset.pluginRequiresApproval
        pluginURL = preset.pluginURL
        pluginMethod = preset.pluginMethod
        pluginMCPMethod = preset.pluginMCPMethod
        pluginMCPToolName = preset.pluginMCPToolName
        pluginMCPInputSchemaJSON = preset.pluginMCPInputSchemaJSON
        pluginCommandPath = preset.pluginCommandPath
        pluginCommandArguments = preset.pluginCommandArguments
        pluginPackageJSON = preset.pluginPackageJSON
        pluginUpdateTargetID = preset.pluginUpdateTargetID
        pluginExistingPackageContext = preset.pluginExistingPackageContext
        model.clearMCPDiscoveredTools()
        model.pendingVibePluginComposerPreset = nil
        model.isVibePluginComposerPresented = true
    }
}

private struct ProductReadinessCard: View {
    @EnvironmentObject private var model: AppViewModel

    private var summary: ProductReadinessSummary {
        model.productReadinessSummary
    }

    var body: some View {
        Panel(title: "Product Readiness", trailing: summary.score) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: summary.isReadyForCoreWork ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(summary.isReadyForCoreWork ? .green : AppTheme.coral)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                        Text(summary.detail)
                            .font(.caption)
                            .foregroundStyle(AppTheme.muted)
                            .lineLimit(3)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    Button {
                        model.appendReadinessGuidance()
                    } label: {
                        Label(summary.isReadyForCoreWork ? "Ask Her" : "Guide Me", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.coral)
                    .controlSize(.small)
                    .help("Ask Her to explain the next setup step in the conversation")

                    Button {
                        perform(.runDiagnostics)
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Run read-only product diagnostics")

                    Button {
                        perform(.exportDiagnostics)
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Export product diagnostics after approval")
                }

                VStack(spacing: 7) {
                    ForEach(summary.items) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: item.systemImage)
                                .foregroundStyle(color(for: item.level))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(item.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(AppTheme.ink)
                                    Text(label(for: item))
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(color(for: item.level))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.white.opacity(0.54))
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                    Spacer(minLength: 0)
                                }
                                HStack(alignment: .top, spacing: 8) {
                                    Text(item.detail)
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.muted)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .padding(8)
                        .background(Color.white.opacity(item.required ? 0.48 : 0.34))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func perform(_ action: ProductReadinessAction) {
        model.performProductReadinessAction(action)
    }

    private func label(for item: ProductReadinessItem) -> String {
        switch item.level {
        case .ready: return item.required ? "Ready" : "Active"
        case .attention: return item.required ? "Needed" : "Review"
        case .optional: return "Optional"
        }
    }

    private func color(for level: ProductReadinessLevel) -> Color {
        switch level {
        case .ready: return .green
        case .attention: return AppTheme.coral
        case .optional: return AppTheme.muted
        }
    }
}

private struct AgentLoopCard: View {
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

private struct ServiceConfigurationCard: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var draft: HerAppConfigDraft?
    @State private var isExpanded = false

    var body: some View {
        Panel(title: "Service Configuration", trailing: configState) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label(model.config.agentLLMBaseURL.host() ?? "AgentLLM", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(AppTheme.ink)
                    Spacer()
                    Label(model.config.agentMemBaseURL.host() ?? "AgentMem", systemImage: "brain.head.profile")
                        .font(.caption)
                        .foregroundStyle(AppTheme.ink)
                }
                HStack(spacing: 8) {
                    CredentialStatePill(title: "LLM Key", configured: model.config.hasLLMKey)
                    if model.config.hasMemKey {
                        CredentialStatePill(title: "Memory", configured: true)
                    }
                    Spacer(minLength: 0)
                }

                if isExpanded {
                    configFields
                    HStack {
                        Button("Cancel") {
                            draft = HerAppConfigDraft(config: model.config)
                            isExpanded = false
                        }
                        .buttonStyle(.bordered)

                        Button("Save & Check") {
                            Task {
                                if let draft {
                                    await model.saveConfiguration(draft)
                                    self.draft = HerAppConfigDraft(config: model.config)
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.coral)
                    }
                    .controlSize(.small)
                } else {
                    Button {
                        draft = HerAppConfigDraft(config: model.config)
                        isExpanded = true
                    } label: {
                        Label("Edit Configuration", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .onAppear {
                if draft == nil {
                    draft = HerAppConfigDraft(config: model.config)
                }
            }
        }
    }

    private var configFields: some View {
        let binding = Binding<HerAppConfigDraft>(
            get: { draft ?? HerAppConfigDraft(config: model.config) },
            set: { draft = $0 }
        )
        return HerConfigurationFields(draft: binding, presentation: .compact)
    }

    private var configState: String {
        if !model.config.hasLLMKey {
            return "Incomplete"
        }
        return "Local"
    }
}

struct CredentialStatePill: View {
    var title: String
    var configured: Bool

    var body: some View {
        Label(configured ? "\(title) Set" : "\(title) Missing", systemImage: configured ? "checkmark.seal" : "exclamationmark.triangle")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(configured ? .green : AppTheme.coral)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.42))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

private struct ServiceHealthCard: View {
    @EnvironmentObject private var serviceStatus: ServiceStatusModel
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        Panel(title: "Service Health", trailing: healthSummary) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(serviceStatus.serviceHealth) { item in
                    HStack(spacing: 9) {
                        Image(systemName: icon(for: item.state))
                            .foregroundStyle(color(for: item.state))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(item.name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.ink)
                                Spacer()
                                Text(item.state.rawValue.capitalized)
                                    .font(.caption2)
                                    .foregroundStyle(color(for: item.state))
                            }
                            Text(detail(for: item))
                                .font(.caption2)
                                .foregroundStyle(AppTheme.muted)
                                .lineLimit(2)
                        }
                    }
                    .padding(8)
                    .background(Color.white.opacity(0.42))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Button {
                    Task { await model.refreshServiceHealth() }
                } label: {
                    Label("Check Services", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.coral)
                .controlSize(.small)
            }
        }
    }

    private var healthSummary: String {
        let checking = serviceStatus.serviceHealth.contains { $0.state == .checking }
        if checking { return "Checking" }
        let online = serviceStatus.serviceHealth.filter { $0.state == .online }.count
        return "\(online)/\(serviceStatus.serviceHealth.count)"
    }

    private func detail(for item: ServiceHealth) -> String {
        let host = item.baseURL?.host() ?? item.kind
        let checked = item.checkedAt.map { " · \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        return "\(host) · \(item.summary)\(checked)"
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

private struct GeneratedPluginDraftsCard: View {
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

private struct PluginDraftReviewSheet: View {
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

private struct PluginLifecycleCard: View {
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

private struct PermissionSummaryRow: View {
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

private struct PluginInputFieldSummary: View {
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

private struct ReviewBadge: View {
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

private struct ApprovalQueueCard: View {
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

private struct CapabilityActivityCard: View {
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

private struct WebServiceArtifactsCard: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        Panel(title: "Artifacts", trailing: model.webServiceArtifacts.isEmpty ? "Empty" : "\(model.webServiceArtifacts.count)") {
            VStack(alignment: .leading, spacing: 10) {
                if model.webServiceArtifacts.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle")
                            .foregroundStyle(AppTheme.muted)
                        Text("Generated images and web service outputs will appear here.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.muted)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(model.webServiceArtifacts.prefix(6)) { artifact in
                        WebServiceArtifactRow(artifact: artifact)
                    }
                }

                HStack {
                    Button {
                        model.refreshWebServiceArtifacts()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .help("Refresh artifacts")

                    Button {
                        model.openWebServiceArtifactDirectory()
                    } label: {
                        Label("Open Folder", systemImage: "folder")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.coral)
                }
                .controlSize(.small)
            }
        }
    }
}

private struct WebServiceArtifactRow: View {
    @EnvironmentObject private var model: AppViewModel
    var artifact: WebServiceArtifact

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                preview

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(artifact.capabilityID)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                            .lineLimit(1)
                        Spacer()
                        Text(artifact.createdAt, style: .time)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.muted)
                    }

                    Text("\(artifact.request.method) \(artifact.request.status) · \(artifact.artifacts.count) item(s)")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(1)

                    Text(artifact.request.url)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted.opacity(0.88))
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }

            HStack(spacing: 7) {
                Button {
                    model.openWebServiceArtifact(path: artifact.manifestPath)
                } label: {
                    Label("Manifest", systemImage: "doc.text")
                }
                .buttonStyle(.bordered)

                Button {
                    model.openWebServiceArtifact(path: artifact.responseFile)
                } label: {
                    Label("Response", systemImage: "curlybraces")
                }
                .buttonStyle(.bordered)

                if let imagePath = artifact.primaryLocalImagePath {
                    Button {
                        model.openWebServiceArtifact(path: imagePath)
                    } label: {
                        Image(systemName: "photo")
                    }
                    .buttonStyle(.bordered)
                    .help("Open generated image")
                }

                if let remoteURL = artifact.remoteURLs.first,
                   let url = URL(string: remoteURL) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "link")
                    }
                    .buttonStyle(.bordered)
                    .help("Open remote artifact URL")
                }
            }
            .controlSize(.small)
        }
        .padding(9)
        .background(Color.white.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var preview: some View {
        if let path = artifact.primaryLocalImagePath,
           let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.5))
                Image(systemName: artifact.remoteURLs.isEmpty ? "doc.richtext" : "photo")
                    .foregroundStyle(AppTheme.coral)
            }
            .frame(width: 52, height: 52)
        }
    }
}

private struct InteractionEventsCard: View {
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

private struct LocalInboxBridgeCard: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        Panel(title: "Local Inbox Bridge", trailing: model.localInboxBridgeState.status.rawValue.capitalized) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: icon)
                        .foregroundStyle(color)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.localInboxBridgeState.endpoint)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                            .textSelection(.enabled)
                        Text(model.localInboxBridgeState.summary)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.muted)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                .padding(9)
                .background(Color.white.opacity(0.42))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(samplePayload)
                    .font(.caption2.monospaced())
                    .foregroundStyle(AppTheme.muted)
                    .textSelection(.enabled)
                    .lineLimit(5)
                    .padding(8)
                    .background(Color.white.opacity(0.34))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack {
                    Button {
                        model.stopLocalInboxBridge()
                    } label: {
                        Image(systemName: "stop.circle")
                    }
                    .buttonStyle(.bordered)
                    .help("Stop local inbox bridge")
                    .disabled(model.localInboxBridgeState.status != .running)

                    Button {
                        model.startLocalInboxBridge()
                    } label: {
                        Label(model.localInboxBridgeState.status == .running ? "Restart" : "Start", systemImage: "play.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.coral)
                }
                .controlSize(.small)
            }
        }
    }

    private var icon: String {
        switch model.localInboxBridgeState.status {
        case .running: return "dot.radiowaves.left.and.right"
        case .starting: return "arrow.triangle.2.circlepath"
        case .failed: return "xmark.octagon"
        case .stopped: return "tray"
        }
    }

    private var color: Color {
        switch model.localInboxBridgeState.status {
        case .running: return .green
        case .starting: return AppTheme.coral
        case .failed: return .red
        case .stopped: return AppTheme.muted
        }
    }

    private var samplePayload: String {
        """
        POST /inbox
        {"source":"oyii","sender":"Leo","text":"Review this thread"}
        """
    }
}

private struct AuditTrailCard: View {
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

private struct ActivePlanCard: View {
    @EnvironmentObject private var serviceStatus: ServiceStatusModel
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        Panel(title: "Active Plan", trailing: "\(Int(planProgress * 100))%") {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(model.workPlan?.goal ?? "Her Desktop Runtime")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(3)
                    Spacer()
                    Gauge(value: planProgress) { EmptyView() }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .tint(AppTheme.coral)
                        .frame(width: 44, height: 44)
                }
                if let workPlan = model.workPlan {
                    ForEach(Array(workPlan.steps.prefix(5))) { step in
                        WorkPlanStepLine(step: step)
                    }
                    if workPlan.steps.isEmpty {
                        PlanLine(done: false, title: "No steps saved yet")
                    }
                } else {
                    PlanLine(done: true, title: "Architecture boundaries")
                    PlanLine(done: true, title: "Native app shell")
                    PlanLine(done: liveServicesVerified, title: "Live service verification")
                    PlanLine(done: pluginFlowReady, title: "Plugin install flow")
                    PlanLine(done: memoryReady, title: "Memory continuity")
                }
            }
        }
    }

    private var planProgress: Double {
        if let workPlan = model.workPlan {
            return workPlan.progress
        }
        let checks = [true, true, liveServicesVerified, pluginFlowReady, memoryReady]
        return Double(checks.filter { $0 }.count) / Double(checks.count)
    }

    private var liveServicesVerified: Bool {
        let remote = serviceStatus.serviceHealth.filter { $0.id == "agentllm" || $0.id == "agentmem" }
        return remote.count == 2 && remote.allSatisfy { $0.state == .online }
    }

    private var pluginFlowReady: Bool {
        serviceStatus.serviceHealth.first { $0.id == "plugins" }?.state == .online
    }

    private var memoryReady: Bool {
        model.agentProfile.known || model.config.hasMemKey
    }
}

private struct ConnectedToolsCard: View {
    @EnvironmentObject private var serviceStatus: ServiceStatusModel

    var body: some View {
        Panel(title: "Connected Tools", trailing: "\(serviceStatus.tools.filter(\.enabled).count)/\(serviceStatus.tools.count)") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 8)], spacing: 8) {
                ForEach(serviceStatus.tools) { tool in
                    VStack(spacing: 7) {
                        Image(systemName: icon(for: tool.kind))
                            .font(.title3)
                            .foregroundStyle(tool.enabled ? AppTheme.coral : AppTheme.muted)
                        Text(tool.name)
                            .font(.caption)
                            .lineLimit(1)
                        Text(tool.summary)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.muted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .background(Color.white.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "memory": return "brain.head.profile"
        case "model": return "sparkles"
        case "extension": return "puzzlepiece.extension"
        default: return "shippingbox"
        }
    }
}

private struct ModelRoutingCard: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        Panel(title: "Model Routing", trailing: "Auto") {
            HStack {
                Image(systemName: "spark")
                    .foregroundStyle(AppTheme.coral)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.config.agentLLMModel)
                        .font(.subheadline)
                    Text(model.config.agentLLMBaseURL.host() ?? "agentLLMAPI")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
            }
        }
    }
}

private struct RunningTasksCard: View {
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

private struct StateCard: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        Panel(title: "State", trailing: model.agentProfile.known ? "Known" : "Local") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    MetricBox(title: "Trust", value: model.memorySignal.trust, icon: "heart")
                    MetricBox(title: "Confidence", value: model.memorySignal.confidence, icon: "diamond")
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Mood", systemImage: "face.smiling")
                            .font(.caption)
                            .foregroundStyle(AppTheme.muted)
                        Text(model.memorySignal.moodLabel)
                            .font(.caption.weight(.semibold))
                        WaveLineTiny()
                            .stroke(AppTheme.coral, lineWidth: 1.2)
                            .frame(height: 18)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: 76)
                    .background(Color.white.opacity(0.48))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 9) {
                    Image(systemName: model.agentProfile.known ? "checkmark.seal" : "person.crop.circle.badge.questionmark")
                        .foregroundStyle(model.agentProfile.known ? .green : AppTheme.muted)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(model.agentProfile.displayName) · \(model.agentProfile.userDisplayName)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                            .lineLimit(1)
                        Text(model.agentProfile.relationship)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.muted)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button {
                        Task { await model.refreshAgentProfile() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh AgentMem profile")
                }
                .background(Color.white.opacity(0.48))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct VibePluginComposerSheet: View {
    @EnvironmentObject private var model: AppViewModel
    @Binding var isPresented: Bool
    @Binding var pluginName: String
    @Binding var pluginDescription: String
    @Binding var pluginKind: String
    @Binding var pluginRequiresApproval: Bool
    @Binding var pluginURL: String
    @Binding var pluginMethod: String
    @Binding var pluginMCPMethod: String
    @Binding var pluginMCPToolName: String
    @Binding var pluginMCPInputSchemaJSON: String
    @Binding var pluginCommandPath: String
    @Binding var pluginCommandArguments: String
    @Binding var pluginPackageJSON: String
    @Binding var pluginUpdateTargetID: String
    @Binding var pluginExistingPackageContext: String
    @State private var vibeBrief = ""
    @State private var isPackageImporterPresented = false
    @State private var isSkillImporterPresented = false

    private let kinds = ["skill", "webservice", "mcp", "command", "native"]
    private let methods = ["POST", "GET"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Vibe Plugin Composer")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
            }

            TextField("Describe the extension in one paragraph...", text: $vibeBrief, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)

            if isUpdatingPlugin {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(AppTheme.coral)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Updating \(pluginUpdateTargetID)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                        Text("AI generation will reuse this local plugin id and treat the installed package as context.")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.muted)
                    }
                    Spacer()
                    Button {
                        pluginUpdateTargetID = ""
                        pluginExistingPackageContext = ""
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear update target")
                }
                .padding(10)
                .background(Color.white.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            TextField("Plugin name", text: $pluginName)
                .textFieldStyle(.roundedBorder)

            TextField("What should it do?", text: $pluginDescription, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(4...7)

            HStack(spacing: 10) {
                Picker("Kind", selection: $pluginKind) {
                    ForEach(kinds, id: \.self) { kind in
                        Label(kind.capitalized, systemImage: icon(for: kind))
                            .tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                Toggle(isOn: $pluginRequiresApproval) {
                    Image(systemName: "hand.raised")
                }
                .toggleStyle(.button)
                .help("Require approval")
            }

            if pluginKind == "webservice" {
                HStack(spacing: 8) {
                    Picker("Method", selection: $pluginMethod) {
                        ForEach(methods, id: \.self) { method in
                            Text(method).tag(method)
                        }
                    }
                    .frame(width: 92)

                    TextField("https://service.example/run", text: $pluginURL)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if pluginKind == "mcp" {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("http://localhost:8765/jsonrpc", text: $pluginURL)
                        .textFieldStyle(.roundedBorder)
                    TextField("JSON-RPC method, e.g. tools/call", text: $pluginMCPMethod)
                        .textFieldStyle(.roundedBorder)
                    TextField("MCP tool name, e.g. filesystem.read_file", text: $pluginMCPToolName)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button {
                            Task { await model.discoverMCPTools(endpointURL: pluginURL) }
                        } label: {
                            Label("Discover Tools", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!hasMCPURL || isBusy)

                        if !model.mcpDiscoveredTools.isEmpty {
                            Button {
                                model.clearMCPDiscoveredTools()
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Clear discovered tools")
                        }
                    }
                    if !model.mcpDiscoveredTools.isEmpty {
                        VStack(spacing: 6) {
                            ForEach(Array(model.mcpDiscoveredTools.prefix(6))) { tool in
                                HStack(spacing: 8) {
                                    Button {
                                        applyMCPTool(tool)
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "shippingbox")
                                                .foregroundStyle(AppTheme.coral)
                                                .frame(width: 18)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(tool.name)
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(AppTheme.ink)
                                                    .lineLimit(1)
                                                Text(tool.inputSchemaSummary.isEmpty ? "No input schema" : tool.inputSchemaSummary)
                                                    .font(.caption2)
                                                    .foregroundStyle(AppTheme.muted)
                                                    .lineLimit(1)
                                            }
                                            Spacer()
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .help("Use this discovered tool in the composer fields")

                                    Button {
                                        draftMCPTool(tool)
                                    } label: {
                                        Image(systemName: "shippingbox.fill")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Draft a plugin from this discovered MCP tool")
                                    .disabled(!hasMCPURL || isBusy)

                                    Button {
                                        installMCPTool(tool)
                                    } label: {
                                        Image(systemName: "tray.and.arrow.down.fill")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Install this discovered MCP tool as a local plugin")
                                    .disabled(!hasMCPURL || isBusy)
                                }
                                .padding(8)
                                .background(Color.white.opacity(0.42))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
            }

            if pluginKind == "command" {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("/absolute/path/to/tool or workspace-relative tool", text: $pluginCommandPath)
                        .textFieldStyle(.roundedBorder)
                    TextField("Argument templates, one per line. Use {{request}} if needed.", text: $pluginCommandArguments, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...5)
                }
            }

            TextField("Paste PluginPackage JSON for review", text: $pluginPackageJSON, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...7)

            HStack {
                Button {
                    if model.stagePluginPackageJSON(pluginPackageJSON, source: "composer-json") {
                        reset()
                        isPresented = false
                    }
                } label: {
                    Label("Stage JSON Package", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.bordered)
                .disabled(!canStagePackageJSON || isBusy)

                Button {
                    isPackageImporterPresented = true
                } label: {
                    Label("Import Package File", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)

                Button {
                    isSkillImporterPresented = true
                } label: {
                    Label("Import Skill File", systemImage: "doc.text")
                }
                .buttonStyle(.bordered)
                .disabled(isBusy || isUpdatingPlugin)
                .help(isUpdatingPlugin ? "Clear update mode before importing a standalone skill file." : "Wrap a local text or Markdown skill file as a reviewable plugin draft")
            }

            HStack {
                Button {
                    model.stageDraftPlugin(
                        named: pluginName,
                        description: effectiveDescription,
                        kind: pluginKind,
                        requiresApproval: pluginRequiresApproval,
                        webServiceURL: pluginURL,
                        webServiceMethod: pluginMethod,
                        mcpEndpointURL: pluginURL,
                        mcpMethodName: pluginMCPMethod,
                        mcpToolName: pluginMCPToolName,
                        mcpInputSchemaJSON: pluginMCPInputSchemaJSON,
                        commandPath: pluginCommandPath,
                        commandArguments: pluginCommandArguments
                    )
                    reset()
                    isPresented = false
                } label: {
                    Label("Local Draft", systemImage: "shippingbox")
                }
                .buttonStyle(.bordered)
                .disabled(!canSubmit || isBusy || isUpdatingPlugin)
                .help(isUpdatingPlugin ? "Use AI Draft or AI Install to update an installed local plugin with package context." : "Stage a local draft from the visible fields")

                Spacer()

                Button {
                    Task {
                        await model.installDraftPlugin(
                            named: pluginName,
                            description: effectiveDescription,
                            kind: pluginKind,
                            requiresApproval: pluginRequiresApproval,
                            webServiceURL: pluginURL,
                            webServiceMethod: pluginMethod,
                            mcpEndpointURL: pluginURL,
                            mcpMethodName: pluginMCPMethod,
                            mcpToolName: pluginMCPToolName,
                            mcpInputSchemaJSON: pluginMCPInputSchemaJSON,
                            commandPath: pluginCommandPath,
                            commandArguments: pluginCommandArguments
                        )
                        reset()
                        isPresented = false
                    }
                } label: {
                    Label("Local Install", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.coral)
                .disabled(!canSubmit || isBusy || isUpdatingPlugin)
                .help(isUpdatingPlugin ? "Use AI Draft or AI Install to update an installed local plugin with package context." : "Install a local plugin from the visible fields")
            }
            .controlSize(.regular)

            HStack {
                Button {
                    Task {
                        await model.generateAIDraftPlugin(
                            named: pluginName,
                            description: effectiveDescription,
                            kind: pluginKind,
                            requiresApproval: pluginRequiresApproval,
                            webServiceURL: pluginURL,
                            webServiceMethod: pluginMethod,
                            mcpEndpointURL: pluginURL,
                            mcpMethodName: pluginMCPMethod,
                            mcpToolName: pluginMCPToolName,
                            mcpInputSchemaJSON: pluginMCPInputSchemaJSON,
                            commandPath: pluginCommandPath,
                            commandArguments: pluginCommandArguments,
                            vibeBrief: vibeBrief,
                            updatePluginID: pluginUpdateTargetID,
                            existingPackageContext: pluginExistingPackageContext,
                            installImmediately: false
                        )
                        reset()
                        isPresented = false
                    }
                } label: {
                    Label(isUpdatingPlugin ? "AI Update Draft" : "AI Draft", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .disabled(!canSubmit || isBusy || !model.config.hasLLMKey)

                Spacer()

                Button {
                    Task {
                        await model.generateAIDraftPlugin(
                            named: pluginName,
                            description: effectiveDescription,
                            kind: pluginKind,
                            requiresApproval: pluginRequiresApproval,
                            webServiceURL: pluginURL,
                            webServiceMethod: pluginMethod,
                            mcpEndpointURL: pluginURL,
                            mcpMethodName: pluginMCPMethod,
                            mcpToolName: pluginMCPToolName,
                            mcpInputSchemaJSON: pluginMCPInputSchemaJSON,
                            commandPath: pluginCommandPath,
                            commandArguments: pluginCommandArguments,
                            vibeBrief: vibeBrief,
                            updatePluginID: pluginUpdateTargetID,
                            existingPackageContext: pluginExistingPackageContext,
                            installImmediately: true
                        )
                        reset()
                        isPresented = false
                    }
                } label: {
                    Label(isUpdatingPlugin ? "AI Review Update" : "AI Review & Install", systemImage: "wand.and.sparkles")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.coral)
                .disabled(!canSubmit || isBusy || !model.config.hasLLMKey)
            }
            .controlSize(.regular)
        }
        .padding(22)
        .frame(width: 560)
        .background(AppTheme.windowBackground)
        .fileImporter(
            isPresented: $isPackageImporterPresented,
            allowedContentTypes: [.json, .plainText],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result,
               let url = urls.first,
               model.stagePluginPackageFile(url, source: "composer-file") {
                reset()
                isPresented = false
            } else if case let .failure(error) = result {
                model.reportPluginPackageImportError(error, source: "composer-file")
            }
        }
        .fileImporter(
            isPresented: $isSkillImporterPresented,
            allowedContentTypes: [.plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result,
               let url = urls.first,
               model.stageSkillFilePlugin(
                   url,
                   name: pluginName,
                   description: effectiveDescription,
                   requiresApproval: pluginRequiresApproval,
                   source: "composer-skill-file"
               ) {
                reset()
                isPresented = false
            } else if case let .failure(error) = result {
                model.reportSkillFileImportError(error, source: "composer-skill-file")
            }
        }
    }

    private var canSubmit: Bool {
        let hasDescription = !effectiveDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasURL = hasMCPURL
        let hasMCPMethod = !pluginMCPMethod.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasMCPToolName = !pluginMCPToolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasCommand = !pluginCommandPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasDescription
            && (pluginKind != "webservice" || hasURL)
            && (pluginKind != "mcp" || (hasURL && hasMCPMethod && hasMCPToolName))
            && (pluginKind != "command" || hasCommand)
    }

    private var hasMCPURL: Bool {
        !pluginURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isBusy: Bool {
        model.connectionState == .thinking || model.connectionState == .working
    }

    private var isUpdatingPlugin: Bool {
        !pluginUpdateTargetID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var effectiveDescription: String {
        let description = pluginDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let brief = vibeBrief.trimmingCharacters(in: .whitespacesAndNewlines)
        if description.isEmpty { return brief }
        if brief.isEmpty { return description }
        return """
        \(description)

        Vibe brief:
        \(brief)
        """
    }

    private func reset() {
        vibeBrief = ""
        pluginName = ""
        pluginDescription = ""
        pluginKind = "skill"
        pluginRequiresApproval = true
        pluginURL = ""
        pluginMethod = "POST"
        pluginMCPMethod = ""
        pluginMCPToolName = ""
        pluginMCPInputSchemaJSON = ""
        model.clearMCPDiscoveredTools()
        pluginCommandPath = ""
        pluginCommandArguments = ""
        pluginPackageJSON = ""
        pluginUpdateTargetID = ""
        pluginExistingPackageContext = ""
    }

    private func applyMCPTool(_ tool: MCPDiscoveredTool) {
        pluginKind = "mcp"
        pluginMCPMethod = "tools/call"
        pluginMCPToolName = tool.name
        pluginMCPInputSchemaJSON = tool.rawInputSchema
        if pluginDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pluginDescription = tool.description.isEmpty
                ? "Calls the \(tool.name) MCP tool."
                : tool.description
        }
    }

    private func draftMCPTool(_ tool: MCPDiscoveredTool) {
        model.stageMCPDiscoveredToolPlugin(
            tool,
            endpointURL: pluginURL,
            name: pluginName,
            description: effectiveDescription,
            requiresApproval: pluginRequiresApproval
        )
        reset()
        isPresented = false
    }

    private func installMCPTool(_ tool: MCPDiscoveredTool) {
        Task {
            await model.installMCPDiscoveredToolPlugin(
                tool,
                endpointURL: pluginURL,
                name: pluginName,
                description: effectiveDescription,
                requiresApproval: pluginRequiresApproval
            )
            reset()
            isPresented = false
        }
    }

    private var canStagePackageJSON: Bool {
        !pluginPackageJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "skill": return "sparkles"
        case "webservice": return "globe"
        case "mcp": return "shippingbox"
        case "command": return "terminal"
        case "native": return "macwindow"
        default: return "puzzlepiece.extension"
        }
    }
}

private struct Panel<Content: View>: View {
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
        .padding(12)
        .background(AppTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
    }
}

private struct PlanLine: View {
    var done: Bool
    var title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : AppTheme.muted)
            Text(title)
                .font(.caption)
            Spacer()
        }
    }
}

private struct WorkPlanStepLine: View {
    var step: WorkPlan.Step

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.caption)
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
    }

    private var icon: String {
        switch step.status {
        case .pending: return "circle"
        case .inProgress: return "clock"
        case .done: return "checkmark.circle.fill"
        case .blocked: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch step.status {
        case .pending: return AppTheme.muted
        case .inProgress: return AppTheme.coral
        case .done: return .green
        case .blocked: return .orange
        }
    }
}

private struct MetricBox: View {
    var title: String
    var value: Double
    var icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
            Gauge(value: value) {
                EmptyView()
            }
            .gaugeStyle(.accessoryLinearCapacity)
            .tint(AppTheme.coral)
            Text("\(Int(value * 100))%")
                .font(.caption.weight(.semibold))
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 76)
        .background(Color.white.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct WaveLineTiny: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        for x in stride(from: rect.minX, through: rect.maxX, by: 5) {
            let p = (x - rect.minX) / max(rect.width, 1)
            path.addLine(to: CGPoint(x: x, y: rect.midY + sin(p * .pi * 4) * 4))
        }
        return path
    }
}
