import SwiftUI

struct ProductReadinessCard: View {
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

struct ServiceConfigurationCard: View {
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

struct ServiceHealthCard: View {
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

struct ConnectedToolsCard: View {
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

struct ModelRoutingCard: View {
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
